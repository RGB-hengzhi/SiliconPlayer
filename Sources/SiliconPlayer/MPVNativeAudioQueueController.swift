import CMPV
import Foundation
import PlayerCore

// Coordinates qualified local audio through copied events, native readbacks,
// immutable item identities, and conservative ordinary-load boundaries.
enum NativeAudioCoreEvent {
    case start(Int64), loaded, end(Int64, mpv_end_file_reason, Int32)
}

@MainActor final class MPVNativeAudioQueueController {
    private weak var player: PlayerModel?
    private let inspector = NativeLocalAudioInspector()
    private var preparation: Task<Void, Never>?
    private var request = UUID()
    private var owner: NativeQueueOwner?
    private let coreID = UUID()
    private var revision = NativeQueueRevision(logical: 0, settings: 0, preferences: 0)
    private var plan: NativeAudioPreparedPlan?
    private var entries: [Int64: NativeAudioPlanEntry] = [:]
    private var eventLedger = NativeQueueEventLedger()
    private var historyLedger = NativeQueueHistoryLedger()
    private var activeTicket: NativeQueueTicket?
    private var activeItem: MediaItem?
    private var assemblyCount = 0
    private var assemblyStarted: TimeInterval = 0
    private var quarantined: [NativeAudioCoreEvent] = []
    private var mustClearTail = false
    private var mapConfirmed = false
    private var nativeListLoop = false
    private var dirtyLoops = false
    private var commandSerial: UInt64 = 0
    private var attemptedLoad: UUID?
    private var closing = false
    private var lastPlaying = false
    private var loopCleanupRequired = false
    private var eventOrdinal: UInt64 = 0
    private var terminationItem: MediaItem?
    private var terminationOwned = false
    private var terminationPosition = 0.0
    private var audit: [[String: Any]] = []

    init(player: PlayerModel) { self.player = player }
    var ownsEvents: Bool { owner != nil }
    var isAssembling: Bool { plan != nil && assemblyCount < (plan?.entries.count ?? 0) }
    var hasPreparation: Bool { preparation != nil }
    var continuationIntent: Bool { lastPlaying }
    var blocksOrdinaryAdvance: Bool { closing && terminationOwned }
    var diagnosticsSnapshot: [String: Any] {
        ["enabled": player?.continuousAudioEnabled == true, "closing": closing,
         "owner": owner?.session.uuidString ?? "", "core": coreID.uuidString,
         "plan": plan?.id.uuidString ?? "", "request": request.uuidString,
         "logicalRevision": revision.logical, "settingsRevision": revision.settings,
         "preferencesRevision": revision.preferences, "commandSerial": commandSerial,
         "eventOrdinal": eventOrdinal, "entryCount": entries.count, "assembling": isAssembling,
         "confirmed": mapConfirmed, "nativeListLoop": nativeListLoop,
         "loopCleanupRequired": loopCleanupRequired, "activeUUID": activeItem?.id.uuidString ?? "",
         "activeEntryID": activeTicket?.entryID ?? -1, "activeCycle": activeTicket?.cycle ?? 0,
         "lastPlayingIntent": lastPlaying, "audit": audit]
    }
    private func record(_ kind: String, _ extra: [String: Any] = [:]) {
        var row = extra; row["kind"] = kind; row["uptime"] = ProcessInfo.processInfo.systemUptime
        row["commandSerial"] = commandSerial; row["eventOrdinal"] = eventOrdinal
        row["owner"] = owner?.session.uuidString ?? ""; row["request"] = request.uuidString
        row["plan"] = plan?.id.uuidString ?? ""; row["logicalRevision"] = revision.logical
        row["settingsRevision"] = revision.settings; row["preferencesRevision"] = revision.preferences
        audit.append(row); if audit.count > 256 { audit.removeFirst(audit.count - 256) }
    }
    var currentIntent: Bool {
        guard let player, player.loaded, !player.flag("eof-reached") else { return lastPlaying }
        return !player.flag("pause")
    }
    func reserveOrdinaryAddress(_ url: URL) {
        if !historyLedger.reserveOrdinaryURL(url) { player?.continuousAudioStatus = "普通切换：历史票据预算已达上限" }
    }

    func setEnabled(_ enabled: Bool) {
        guard let player else { return }
        player.continuousAudioEnabled = enabled
        request = UUID(); inspector.cancel(); preparation?.cancel(); preparation = nil
        attemptedLoad = nil
        if player.loaded && !player.flag("eof-reached") { lastPlaying = !player.flag("pause") }
        if !enabled {
            if owner != nil { mustClearTail = true; mapConfirmed = false }
            else { player.continuousAudioStatus = "连续音频已关闭" }
        } else { player.continuousAudioStatus = "连续音频：等待本地 WAV/FLAC 预检" }
    }
    func ordinaryRequest(startPlaying: Bool) { lastPlaying = startPlaying; attemptedLoad = nil }
    func logicalChanged() {
        guard let player, player.continuousAudioEnabled || owner != nil else { return }
        revision.logical &+= 1
        invalidatePreparation()
        if owner != nil { mustClearTail = true; mapConfirmed = false }
        attemptedLoad = nil
    }
    func configurationChanged() {
        guard let player, player.continuousAudioEnabled || owner != nil else { return }
        revision.settings &+= 1; revision.preferences &+= 1
        invalidatePreparation()
        if owner != nil { mustClearTail = true; mapConfirmed = false }
        attemptedLoad = nil
    }
    func loopsChanged() { dirtyLoops = true }
    private func invalidatePreparation() {
        request = UUID(); inspector.cancel(); preparation?.cancel(); preparation = nil
        // A copied real END already provides reason evidence even if assembly
        // has not committed its successor map. Settle known old receipts only;
        // never publish quarantined START/LOADED or advance from cancellation.
        for event in quarantined {
            if case .end(let id, let reason, _) = event,
               case .end(let ticket) = eventLedger.end(entryID: id) {
                write(historyLedger.end(ticket, naturalEOF: reason == MPV_END_FILE_REASON_EOF))
            }
        }
        plan = nil; assemblyCount = 0
        // Previously quarantined events must be consumed by fail-closed below,
        // never replayed into an unrelated new ordinary request.
        if !quarantined.isEmpty { mustClearTail = true; mapConfirmed = false }
    }
    private func write(_ value: NativeQueueHistorySettlement?) {
        guard let value, let player else { return }
        player.history.record(url: value.originalURL, position: value.position, duration: value.duration)
        record("history", ["uuid": value.itemID.uuidString, "entryID": value.ticket.entryID,
            "cycle": value.ticket.cycle, "position": value.position, "duration": value.duration,
            "reason": String(describing: value.reason)])
    }
    func saveActiveHistory() -> Bool {
        guard owner != nil, let player, let ticket = activeTicket else { return false }
        updateActive()
        // cancel() is only for lifecycle; periodic persistence keeps the ticket
        // alive and doesn't mark it settled or advance logical selection.
        if let value = historyLedger.currentSettlement(ticket) { write(value) }
        return true
    }
    @discardableResult func retire(reason: NativeQueueHistorySettlement.Reason) -> Bool {
        loopCleanupRequired = loopCleanupRequired || nativeListLoop
            || (owner != nil && player?.string("loop-playlist") != "no")
        invalidatePreparation()
        if let owner {
            updateActive()
            historyLedger.cancel(owner: owner, reason: reason).forEach { write($0) }
            eventLedger.retireSession()
        }
        owner = nil; activeTicket = nil; activeItem = nil; entries = [:]
        plan = nil; quarantined = []; mapConfirmed = false; nativeListLoop = false
        mustClearTail = false; dirtyLoops = false
        if loopCleanupRequired, let player {
            guard player.executeNativeAudioLoop(false) >= 0, player.string("loop-playlist") == "no" else {
                player.error = "连续音频列表循环未能清理，请先停止再重试"
                player.nativeAudioEmergencyStop()
                return false
            }
            loopCleanupRequired = false
        }
        return true
    }
    /// Explicit program mode owns the current media. Clear the native future
    /// tail before retiring ownership, keeping its confirmed current entry.
    @discardableResult func retireForPlaybackProgram() -> Bool {
        if owner != nil, !clearTail() { return false }
        guard retire(reason: .unsafeTransition) else { return false }
        player?.continuousAudioStatus = "普通播放：此媒体启用了区间或片头片尾程序"
        return true
    }
    func beginTermination() {
        guard !closing else { return }
        lastPlaying = currentIntent
        terminationOwned = ownsEvents || player?.continuousAudioEnabled == true
        terminationItem = player?.playlist.currentItem; terminationPosition = player?.number("time-pos") ?? 0
        closing = true
        // Intentional App lifecycle boundary may synchronously drop the native
        // tail outside poll. Keep the current source running when readback
        // confirms it; otherwise Stop fails closed without opening a successor.
        if owner != nil { _ = clearTail() }
        retire(reason: .manualStop)
        record("termination-begin")
    }
    func resumeAfterCanceledTermination() {
        closing = false; attemptedLoad = nil
        player?.continuousAudioStatus = "连续音频：退出已取消，等待重新预检"
        if let player, player.continuousAudioEnabled {
            if !player.loaded, let item = terminationItem {
                player.nativeAudioOrdinaryFallback(item, startPlaying: lastPlaying, resumeAt: terminationPosition)
            } else if player.flag("eof-reached") { player.next() }
        }
        terminationItem = nil
        terminationOwned = false
        record("termination-canceled")
    }
    func coreDestroyed() {
        // Core is already gone: no property mutation/readback is legal here.
        closing = true; invalidatePreparation()
        if let owner { historyLedger.cancel(owner: owner, reason: .manualStop).forEach { write($0) } }
        owner = nil; entries = [:]; activeTicket = nil; activeItem = nil
        quarantined = []; mustClearTail = false; mapConfirmed = false; nativeListLoop = false
        loopCleanupRequired = false
        eventLedger.coreDestroyed(); historyLedger.coreDestroyed()
    }

    func poll() {
        guard let player, !closing else { return }
        if player.loaded && !player.flag("eof-reached") { lastPlaying = !player.flag("pause") }
        updateActive()
        // Exactly one synchronous node mutation per poll. There is no async
        // native mutation that can run after a new replace/Stop request.
        if mustClearTail {
            guard clearTail() else { return }
            return
        }
        if isAssembling {
            appendOne()
            return
        }
        if ownsEvents {
            refreshLoopsIfNeeded()
            if player.flag("eof-reached"), mapConfirmed,
               let ticket = activeTicket, let activeItem,
               let rows = player.nativeAudioPlaylistReadback(),
               rows.last?.entryID == ticket.entryID,
               rows.allSatisfy({ entries[$0.entryID] != nil }),
               player.number("time-pos") >= max(0, player.duration - 0.05) {
                finish(ticket: ticket, item: activeItem, natural: true)
            }
        }
        guard player.continuousAudioEnabled, preparation == nil, plan == nil,
              player.loaded, !player.isLoading, !player.flag("eof-reached"),
              let item = player.playlist.currentItem,
              attemptedLoad != player.mediaPreferenceToken else { return }
        attemptedLoad = player.mediaPreferenceToken
        prepare(item: item)
    }
    private func updateActive() {
        guard let player, let ticket = activeTicket,
              let rows = player.nativeAudioPlaylistReadback(),
              rows.first(where: { $0.playing })?.entryID == ticket.entryID else { return }
        let position = player.number("time-pos"), duration = player.number("duration")
        // Detect an ordinary inter-entry change across separate property calls.
        // Public properties cannot independently prove a repeated-ID cycle;
        // the copied START/END receipt ordering remains mandatory for loops.
        guard player.nativeAudioPlaylistReadback()?.first(where: { $0.playing })?.entryID == ticket.entryID else { return }
        historyLedger.update(ticket, loaded: player.loaded, position: position, duration: duration)
    }
    private func prepare(item: MediaItem) {
        guard let player, player.nativeAudioDiscoveryDirectories(for: item.url) != nil,
              let covers = player.nativeAudioCoverNames(),
              let environment = player.nativeAudioPreparationEnvironment(revision: revision),
              player.duration - player.position >= 6,
              let index = player.playlist.items.firstIndex(where: { $0.id == item.id }) else {
            player?.continuousAudioStatus = "普通切换：当前媒体、目录或输出尚不适用连续音频"
            return
        }
        let token = UUID(); request = token
        let loadToken = player.mediaPreferenceToken
        let logical = player.playlist
        let candidates = Array(logical.items.dropFirst(index).prefix(8))
        let currentOwner = owner ?? NativeQueueOwner(core: coreID, session: UUID())
        let observedRevision = revision
        let playback = lastPlaying
        player.continuousAudioStatus = "连续音频：正在预检最多 8 首"
        preparation = Task { [weak self] in
            guard let self else { return }
            var inspections: [UUID: NativeAudioInspection] = [:]
            for candidate in candidates {
                guard !Task.isCancelled, self.request == token else { break }
                do {
                    guard let folders = self.player?.nativeAudioDiscoveryDirectories(for: candidate.url) else { break }
                    let info = try await self.inspector.inspect(item: candidate, directories: folders, coverNames: covers)
                    inspections[candidate.id] = info
                } catch { break } // This media is an explicit ordinary boundary.
            }
            guard self.request == token, let player = self.player,
                  player.mediaPreferenceToken == loadToken, self.revision == observedRevision,
                  player.continuousAudioEnabled, !self.closing else { return }
            self.preparation = nil
            do {
                var resumePositions: [UUID: Double] = [:]
                for candidate in candidates where candidate.id != item.id {
                    resumePositions[candidate.id] = player.history.resumePosition(for: candidate.url)
                }
                let plan = try NativeAudioPlanBuilder.make(logical: logical, owner: currentOwner,
                    environment: environment, inspections: inspections,
                    resumePositions: resumePositions, startPlaying: playback)
                guard let fresh = player.nativeAudioPreparationEnvironment(revision: observedRevision),
                      fresh.base == environment.base, fresh.effective == environment.effective,
                      fresh.activeSpeed == environment.activeSpeed,
                      fresh.observedSampleRate == environment.observedSampleRate,
                      fresh.observedChannels == environment.observedChannels,
                      fresh.observedLayout == environment.observedLayout, player.duration - player.position >= 2.5,
                      let rows = player.nativeAudioPlaylistReadback(), rows.count == 1,
                      let current = rows.first, current.playing, current.url == item.url else {
                    throw NativeAudioPreparationFailure.staleOrIncompleteProof
                }
                guard self.eventLedger.install(owner: currentOwner,
                    rows: [.init(entryID: current.entryID, item: item)]) else {
                    throw NativeAudioPreparationFailure.staleOrIncompleteProof
                }
                self.owner = currentOwner
                if self.activeTicket == nil {
                    guard let ticket = self.eventLedger.adoptAlreadyLoaded(entryID: current.entryID, itemID: item.id),
                          self.historyLedger.register(ticket, item: item) else {
                        throw NativeAudioPreparationFailure.staleOrIncompleteProof
                    }
                    self.activeTicket = ticket; self.activeItem = item
                    self.historyLedger.update(ticket, loaded: true, position: player.number("time-pos"),
                                              duration: player.number("duration"))
                }
                self.plan = plan; self.entries = [current.entryID: plan.entries[0]]
                self.assemblyCount = 1; self.assemblyStarted = ProcessInfo.processInfo.systemUptime
                self.mapConfirmed = false; self.quarantined = []
                player.continuousAudioStatus = "连续音频：正在确认原生队列"
            } catch {
                // install/adopt/register is a real staged transaction. A
                // failed History ledger registration must not leave an owner
                // swallowing ordinary EOF forever with no active ticket.
                if self.owner != nil || self.eventLedger.owner != nil {
                    let hasTail = (player.nativeAudioPlaylistReadback()?.count ?? 2) > 1
                    if hasTail { self.failClosed("预检提交未完成", allowNext: false) }
                    else { _ = self.retire(reason: .unsafeTransition) }
                }
                player.continuousAudioStatus = "普通切换：没有可确认的连续音频段"
            }
        }
    }
    private func appendOne() {
        guard let player, let plan, plan.owner == owner, plan.revision == revision,
              ProcessInfo.processInfo.systemUptime - assemblyStarted <= 2,
              assemblyCount < plan.entries.count else { failClosed("连续段确认超时"); return }
        let next = plan.entries[assemblyCount]
        do {
            guard NativeLocalAudioInspector.stillMatches(next.inspection) else {
                throw NativeAudioPreparationFailure.staleOrIncompleteProof
            }
            commandSerial &+= 1
            let status = player.executeNativeAudioAppend(next.item.url.path, options: next.options)
            guard status >= 0, let rows = player.nativeAudioPlaylistReadback(),
                  rows.count == assemblyCount + 1,
                  zip(rows, plan.entries.prefix(rows.count)).allSatisfy({ pair in pair.0.url == pair.1.item.url }),
                  entries.allSatisfy({ id, item in rows.contains { $0.entryID == id && $0.url == item.item.url } }) else {
                throw NativeAudioPreparationFailure.staleOrIncompleteProof
            }
            let row = rows[assemblyCount]; entries[row.entryID] = next; assemblyCount += 1
            guard eventLedger.install(owner: plan.owner,
                rows: rows.enumerated().map { .init(entryID: $0.element.entryID, item: plan.entries[$0.offset].item) }) else {
                throw NativeAudioPreparationFailure.staleOrIncompleteProof
            }
            if assemblyCount == plan.entries.count {
                mapConfirmed = true; dirtyLoops = true
                record("window-confirmed", ["entryCount": assemblyCount,
                    "uuids": plan.entries.map { $0.item.id.uuidString }])
                player.continuousAudioStatus = "连续音频：已确认 \(plan.entries.count) 首本地同参数 WAV/FLAC"
                let saved = quarantined; quarantined = []
                for event in saved { _ = receive(event) }
            }
        } catch { failClosed("原生队列读回或文件身份不一致") }
    }
    @discardableResult func receive(_ event: NativeAudioCoreEvent) -> Bool {
        guard eventOrdinal < UInt64.max else { failClosed("原生事件票据已达上限", allowNext: false); return true }
        eventOrdinal += 1
        if isAssembling {
            guard quarantined.count < 256 else { failClosed("原生事件缓冲超过上限"); return true }
            quarantined.append(event); return true
        }
        switch event {
        case .start(let id):
            if eventLedger.isRetired(id) { return true }
            guard owner != nil else { return false }
            if id == activeTicket?.entryID, player?.loopFile != true {
                return true // Duplicate current START never grants another cycle.
            }
            guard mapConfirmed, let item = entries[id]?.item, item.id == expectedNativeSuccessor() else {
                failClosed("原生后继与最新队列或循环状态不一致"); return true
            }
            switch eventLedger.start(entryID: id, expectedUUID: item.id, repeatingFile: player?.loopFile == true) {
            case .start(let ticket, _):
                guard let player, let prepared = entries[id],
                      NativeLocalAudioInspector.stillMatches(prepared.inspection),
                      historyLedger.register(ticket, item: item), player.nativeAudioAdoptStart(item, entryID: id) else {
                    failClosed("媒体状态已改变，恢复普通加载"); return true
                }
                activeTicket = ticket; activeItem = item
                record("start", ["uuid": item.id.uuidString, "entryID": id, "cycle": ticket.cycle])
            case .ignored: break
            default: failClosed("无法唯一关联原生 START")
            }
            return true
        case .loaded:
            guard owner != nil else { return false }
            switch eventLedger.fileLoaded() {
            case .loaded(let ticket):
                guard let player, ticket == activeTicket, let entry = entries[ticket.entryID] else {
                    failClosed("加载票据过期"); return true
                }
                historyLedger.update(ticket, loaded: true, position: 0, duration: entry.inspection.duration)
                player.nativeAudioAdoptLoaded(duration: entry.inspection.duration)
                record("loaded", ["uuid": entry.item.id.uuidString, "entryID": ticket.entryID, "cycle": ticket.cycle])
            default: failClosed("FILE_LOADED 没有唯一 START")
            }
            return true
        case .end(let id, let reason, _):
            switch eventLedger.end(entryID: id) {
            case .end(let ticket):
                if reason == MPV_END_FILE_REASON_EOF {
                    write(historyLedger.end(ticket, naturalEOF: true))
                    if ticket == activeTicket, let item = activeItem { finish(ticket: ticket, item: item, natural: true, alreadySettled: true) }
                } else {
                    write(historyLedger.end(ticket, naturalEOF: false))
                    if ticket == activeTicket && owner != nil { failClosed("原生媒体未正常结束", allowNext: false) }
                }
                return true
            case .ignored: return true
            default: return false
            }
        }
    }
    private func expectedNativeSuccessor() -> UUID? {
        guard let player, let activeItem else { return nil }
        if player.loopFile || player.nativeAudioCompleteAB { return activeItem.id }
        var copy = player.playlist; guard copy.select(id: activeItem.id) != nil else { return nil }
        return copy.next(wrap: player.loopPlaylist && nativeListLoop)?.id
    }
    private func latestLogicalSuccessor() -> MediaItem? {
        guard let player, let activeItem else { return nil }
        if player.loopFile || player.nativeAudioCompleteAB { return player.playlist.items.first { $0.id == activeItem.id } }
        var copy = player.playlist; guard copy.select(id: activeItem.id) != nil else { return nil }
        return copy.next(wrap: player.loopPlaylist)
    }
    private func finish(ticket: NativeQueueTicket, item: MediaItem, natural: Bool, alreadySettled: Bool = false) {
        guard let player, ticket == activeTicket, owner != nil, !closing else { return }
        if !alreadySettled { write(historyLedger.end(ticket, naturalEOF: natural)) }
        if player.loopFile || player.nativeAudioCompleteAB { return }
        if let next = latestLogicalSuccessor() {
            if mapConfirmed, entries.values.contains(where: { $0.item.id == next.id }),
               !player.loopPlaylist || nativeListLoop || player.playlist.currentIndex != player.playlist.items.count - 1 {
                return // Native START owns publishing and advance, never host next().
            }
            let intent = lastPlaying
            retire(reason: .newRequest)
            record("ordinary-boundary", ["nextUUID": next.id.uuidString, "playingIntent": intent])
            player.continuousAudioStatus = "普通边界：进入下一媒体后重新准备连续段"
            player.nativeAudioOrdinaryFallback(next, startPlaying: intent)
        } else {
            player.position = max(player.position, player.duration)
            player.continuousAudioStatus = "连续音频：已到列表末尾"
        }
    }
    private func clearTail() -> Bool {
        guard let player, let ticket = activeTicket,
              let before = player.nativeAudioPlaylistReadback(), before.first(where: { $0.playing })?.entryID == ticket.entryID else {
            failClosed("变更时原生当前项已移动"); return false
        }
        commandSerial &+= 1
        let status = player.executeNativeAudioPlaylistClear()
        guard status >= 0, player.string("loop-playlist") == "no",
              let rows = player.nativeAudioPlaylistReadback(), rows.count == 1,
              rows.first?.entryID == ticket.entryID else {
            failClosed("无法确认原生尾部清理"); return false
        }
        eventLedger.removeBindingsKeepingActive()
        entries = entries.filter { $0.key == ticket.entryID }
        mustClearTail = false; mapConfirmed = true; nativeListLoop = false; dirtyLoops = true
        plan = nil; assemblyCount = 0
        let saved = quarantined; quarantined = []
        for event in saved { _ = receive(event) }
        if !player.continuousAudioEnabled {
            let remaining = activeItem?.url
            retire(reason: .newRequest)
            if let remaining { reserveOrdinaryAddress(remaining) }
            player.continuousAudioStatus = "连续音频已关闭，当前媒体继续普通播放"
        }
        record("tail-cleared")
        return true
    }
    private func refreshLoopsIfNeeded() {
        guard let player, dirtyLoops, mapConfirmed else { return }
        let all = Set(entries.values.map { $0.item.id }) == Set(player.playlist.items.map(\.id))
        let wanted = player.continuousAudioEnabled && player.loopPlaylist && !player.loopFile && !player.nativeAudioCompleteAB && all
        commandSerial &+= 1
        let status = player.executeNativeAudioLoop(wanted)
        guard status >= 0, player.string("loop-playlist") == (wanted ? "inf" : "no") else {
            failClosed("列表循环读回失败"); return
        }
        nativeListLoop = wanted; dirtyLoops = false
        record("loop-readback", ["wanted": wanted, "actual": player.string("loop-playlist")])
    }
    private func failClosed(_ reason: String, allowNext: Bool = true) {
        guard let player else { retire(reason: .unsafeTransition); return }
        let next = allowNext ? latestLogicalSuccessor() : nil
        let intent = lastPlaying
        let hadAB = player.nativeAudioCompleteAB
        retire(reason: .unsafeTransition)
        player.stopPlayback()
        player.continuousAudioStatus = "普通切换：\(reason)"
        record("fail-closed", ["reason": reason])
        if closing { return }
        // A nil tail is final. Complete A/B violation stops with an explicit
        // notice; no stale A/B is pretended restored after ordinary load.
        if hadAB { player.toast("接续已停止，请重新确认 A/B 区间"); return }
        if let next { player.nativeAudioOrdinaryFallback(next, startPlaying: intent) }
    }
}
