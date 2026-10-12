import Combine
import Foundation
import PlayerCore

struct PlaybackProgramSnapshot {
    let itemID: UUID
    let loadToken: UUID
    let entryID: Int64
    let position: Int64
    let duration: Int64
    let remaining: Int64?
    let seeking: Bool
    let paused: Bool
    let seekable: Bool
    let eof: Bool
    let forward: Bool
    var configuredStart: Int64? = nil
    var configuredEnd: Int64? = nil
    var configuredCount: Int64? = nil
    func ticket(revision: UUID) -> PlaybackProgramTicket {
        .init(itemID: itemID, loadToken: loadToken, entryID: entryID, programRevision: revision)
    }
}

@MainActor protocol PlaybackProgramHost: AnyObject {
    var restoredPlaybackProgram: PlaybackProgram? { get }
    var persistedPlaybackProgram: PlaybackProgram? { get }
    func playbackProgramSnapshot() -> PlaybackProgramSnapshot?
    func savePlaybackProgram(_ program: PlaybackProgram?, token: UUID) -> Bool
    func preparePlaybackProgramCore() -> Bool
    func writePlaybackProgramInterval(_ interval: PlaybackInterval?) -> Bool
    func seekPlaybackProgram(_ target: Int64) -> Bool
    func holdPlaybackProgramBoundary() -> Bool
    func restorePlaybackProgramPause(_ paused: Bool) -> Bool
    func closeRecognitionForPlaybackProgram() async -> Bool
    func performPlaybackProgramAction(_ action: PlaybackProgramAction, ticket: PlaybackProgramTicket) -> Bool
}

/// MainActor lifecycle and monotonic revisions prevent an old async ASR close
/// from applying an end action to a new load, manual seek, edit, or App shutdown.
@MainActor final class PlaybackProgramController: ObservableObject {
    @Published private(set) var program: PlaybackProgram?
    @Published private(set) var status = "播放区间未启用"
    @Published private(set) var error: String?
    @Published private(set) var activeIntervalID: UUID?
    private weak var host: (any PlaybackProgramHost)?
    private var binding: PlaybackProgramTicket?
    private var completion = PlaybackIntervalCompletion()
    private var operation = UUID()
    private var ending: Task<Void, Never>?
    private var automaticSkipsDisabled = false
    private var automaticActionsDisabled = false
    private var lastPosition: Int64?
    private var lastNonEOFPaused: Bool?
    private var outroConsumed = false
    private var mediaConsumed = false
    private var intervalSeekWaiting = false
    private var intervalSeekDeadline: TimeInterval?

    typealias Journal = (String, [String: Any]) -> Void
    private let journal: Journal?
    init(host: any PlaybackProgramHost, journal: Journal? = nil) {
        self.host = host; self.journal = journal
    }
    private func journalProgram(_ value: PlaybackProgram?) -> Any {
        guard let value else { return NSNull() }
        return ["revision": value.revision.uuidString, "enabled": value.enabled,
                "intervalCount": value.intervals.count,
                "selectedIntervalID": value.selectedIntervalID?.uuidString as Any? ?? NSNull(),
                "automaticallyStartSelected": value.automaticallyStartSelected,
                "afterInterval": value.afterInterval.rawValue, "afterMedia": value.afterMedia.rawValue,
                "introEndMicroseconds": value.introEndMicroseconds as Any? ?? NSNull(),
                "outroStartMicroseconds": value.outroStartMicroseconds as Any? ?? NSNull(),
                "intervals": value.intervals.prefix(PlaybackProgram.maximumIntervals).map { row in
                    ["id": row.id.uuidString, "startMicroseconds": row.startMicroseconds,
                     "endMicroseconds": row.endMicroseconds,
                     "totalPlays": row.totalPlays as Any? ?? NSNull()] as [String: Any]
                }] as [String: Any]
    }
    private func journalTicket(_ value: PlaybackProgramTicket) -> [String: Any] {
        ["itemID": value.itemID.uuidString, "loadToken": value.loadToken.uuidString,
         "entryID": value.entryID, "programRevision": value.programRevision.uuidString]
    }
    private func emitJournal(_ event: String, details: [String: Any] = [:], fullConfiguration: Bool = false) {
        guard let journal else { return }
        let active = activeIntervalID.flatMap { id in program?.intervals.first { $0.id == id } }
        var intent: [String: Any] = ["enabled": program?.enabled as Any? ?? NSNull(),
            "programRevision": program?.revision.uuidString as Any? ?? NSNull(),
            "selectedIntervalID": program?.selectedIntervalID?.uuidString as Any? ?? NSNull(),
            "activeIntervalID": activeIntervalID?.uuidString as Any? ?? NSNull(),
            "activeStartMicroseconds": active?.startMicroseconds as Any? ?? NSNull(),
            "activeEndMicroseconds": active?.endMicroseconds as Any? ?? NSNull(),
            "activeTotalPlays": active?.totalPlays as Any? ?? NSNull(),
            "activeCountIsInfinite": active != nil && active?.totalPlays == nil,
            "afterInterval": program?.afterInterval.rawValue as Any? ?? NSNull(),
            "afterMedia": program?.afterMedia.rawValue as Any? ?? NSNull()]
        if fullConfiguration { intent["fullConfiguration"] = journalProgram(program) }
        journal(event, ["intent": intent, "controller": diagnosticsSnapshot,
            "operationID": operation.uuidString, "intervalSeekWaiting": intervalSeekWaiting,
            "intervalSeekDeadline": intervalSeekDeadline as Any? ?? NSNull(), "details": details])
    }
    /// Called in the existing 0.15-second Engine poll, before observe can clear A/B.
    func journalNativePoll() {
        guard journal != nil, preventsNativePrefetch else { return }
        emitJournal("native-poll-before-program-observe")
    }
    var preventsNativePrefetch: Bool { program?.enabled == true || activeIntervalID != nil }
    var ownsMediaEnd: Bool { program?.enabled == true && binding != nil }
    var savedProgram: PlaybackProgram? { host?.persistedPlaybackProgram }
    var editingTicket: PlaybackProgramTicket? {
        host?.playbackProgramSnapshot()?.ticket(revision: host?.persistedPlaybackProgram?.revision
            ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
    }
    var diagnosticsSnapshot: [String: Any] {
        ["itemID": binding?.itemID.uuidString ?? "", "loadToken": binding?.loadToken.uuidString ?? "",
         "entryID": binding?.entryID ?? -1, "programRevision": binding?.programRevision.uuidString ?? "",
         "activeIntervalID": activeIntervalID?.uuidString ?? "", "ending": ending != nil,
         "manualSkipsDisabled": automaticSkipsDisabled, "automaticActionsDisabled": automaticActionsDisabled,
         "outroConsumed": outroConsumed,
         "mediaConsumed": mediaConsumed, "status": status, "error": error as Any? ?? NSNull()]
    }
    func invalidate(reason: String = "unspecified-caller") {
        emitJournal("controller-invalidation", details: ["reason": reason])
        operation = UUID(); ending?.cancel(); ending = nil; binding = nil
        completion.invalidate(); activeIntervalID = nil; lastPosition = nil; lastNonEOFPaused = nil
        automaticSkipsDisabled = true; outroConsumed = false; mediaConsumed = false; intervalSeekWaiting = false; intervalSeekDeadline = nil
        program = nil; automaticActionsDisabled = false; status = "播放区间未启用"
    }
    func mediaLoaded(explicitStart: Bool) {
        invalidate(reason: "media-loaded"); error = nil
        defer { emitJournal("media-loaded-return", details: ["explicitStart": explicitStart], fullConfiguration: true) }
        guard let host, let snapshot = host.playbackProgramSnapshot(),
              let restored = host.restoredPlaybackProgram, restored.enabled else { return }
        do { program = try restored.validated() }
        catch { self.error = "此媒体播放区间无效，未启用"; return }
        // Even an afterMedia-only program must release an already installed
        // native owner before it can own EOF. A failed readback leaves that
        // original owner and ordinary EOF route intact, with no program action.
        guard host.preparePlaybackProgramCore() else {
            program = nil; binding = nil
            error = "连续音频队列尚未确认退出，播放程序未启用"; status = "播放程序未启用"; return
        }
        binding = snapshot.ticket(revision: restored.revision)
        automaticSkipsDisabled = false; lastPosition = snapshot.position; lastNonEOFPaused = snapshot.paused
        status = "已载入此媒体的播放程序"
        guard snapshot.seekable, snapshot.duration > 0 else {
            automaticSkipsDisabled = true; error = "当前媒体没有可确认时长或不能定位，自动区间与跳过已停用"; return
        }
        if !explicitStart, restored.automaticallyStartSelected, let interval = restored.selectedInterval {
            emitJournal("automatic-interval-start-request", details: ["intervalID": interval.id.uuidString])
            _ = activate(interval.id); return
        }
        if !explicitStart, let intro = restored.introEndMicroseconds {
            guard intro < snapshot.duration else { error = "片头结束点超过媒体时长，未跳过"; return }
            guard host.preparePlaybackProgramCore(), host.seekPlaybackProgram(intro) else {
                error = "片头定位未确认，未继续自动跳过"; automaticSkipsDisabled = true; return
            }
            status = "已提交一次片头跳过"
            emitJournal("intro-seek-submitted", details: ["targetMicroseconds": intro])
        }
    }
    @discardableResult func save(_ value: PlaybackProgram?) -> Bool {
        var saved = false
        defer { if journal != nil { emitJournal("configuration-save-return",
            details: ["saved": saved, "requestedConfiguration": journalProgram(value)], fullConfiguration: true) } }
        guard let host, let snapshot = host.playbackProgramSnapshot() else { error = "请先加载媒体"; return false }
        do { _ = try value?.validated() }
        catch { self.error = "区间、次数或跳过设置无效"; return false }
        guard clearActiveInterval() else { return false }
        if value?.enabled == true, !host.preparePlaybackProgramCore() {
            error = "连续音频队列尚未确认退出，播放程序未保存"; return false
        }
        operation = UUID(); ending?.cancel(); ending = nil
        guard host.savePlaybackProgram(value, token: snapshot.loadToken) else {
            error = "播放程序保存失败，原文件保留"; return false
        }
        // Saving configuration doesn't seek or start playback. Explicit Start
        // or a later loaded event applies the user's opt-in activation choice.
        program = value; error = nil
        binding = value.map { snapshot.ticket(revision: $0.revision) }
        automaticSkipsDisabled = false; automaticActionsDisabled = false; lastPosition = snapshot.position
        outroConsumed = false; mediaConsumed = false; status = "播放程序已保存"
        saved = true
        return true
    }
    @discardableResult func activate(_ id: UUID) -> Bool {
        var submitted = false
        defer { emitJournal("interval-activation-return", details: ["intervalID": id.uuidString,
            "propertiesAndSeekSubmitted": submitted, "seekSettlementProven": false]) }
        guard ending == nil, let host, let p = program, p.enabled,
              let interval = p.intervals.first(where: { $0.id == id }), let current = fresh(),
              current.seekable, !current.seeking, current.duration > 0, interval.endMicroseconds <= current.duration else {
            error = "区间需要当前已加载、可定位媒体内的有效 A/B 点"; return false
        }
        operation = UUID(); completion.invalidate(); activeIntervalID = nil; automaticActionsDisabled = false
        intervalSeekWaiting = false; intervalSeekDeadline = nil
        guard host.preparePlaybackProgramCore() else {
            automaticActionsDisabled = true
            error = "连续音频队列尚未确认退出，区间属性保持原状"; return false
        }
        guard host.writePlaybackProgramInterval(interval),
              let configured = fresh(), configured.remaining == interval.nativeLoopSeeks,
              host.seekPlaybackProgram(interval.startMicroseconds) else {
            _ = host.writePlaybackProgramInterval(nil)
            automaticActionsDisabled = true
            error = "区间属性或开始定位未确认；自动完成动作未启用"; return false
        }
        do { try completion.arm(interval, ticket: configured.ticket(revision: p.revision),
                                  actualRemaining: interval.nativeLoopSeeks) }
        catch { self.error = "实际区间次数未确认"; return false }
        activeIntervalID = id; intervalSeekWaiting = true; mediaConsumed = false
        intervalSeekDeadline = ProcessInfo.processInfo.systemUptime + 3
        automaticSkipsDisabled = false; error = nil
        status = interval.totalPlays.map { "播放区间：总共 \($0) 次" } ?? "播放区间：无限循环"
        submitted = true
        return true
    }
    @discardableResult func clearActiveInterval() -> Bool {
        guard activeIntervalID != nil else { return true }
        guard host?.writePlaybackProgramInterval(nil) == true else {
            automaticActionsDisabled = true
            error = "区间属性未能清除，请先停止播放再重试"
            emitJournal("native-interval-clear-return", details: ["confirmed": false]); return false
        }
        operation = UUID(); ending?.cancel(); ending = nil
        completion.invalidate(); activeIntervalID = nil; intervalSeekWaiting = false; intervalSeekDeadline = nil
        emitJournal("native-interval-clear-return", details: ["confirmed": true]); return true
    }
    /// Only an accepted external/manual seek enters this method. Program seeks
    /// are explicitly excluded by the host's synchronous command scope.
    func manualSeekAccepted() {
        emitJournal("manual-seek-cancels-program-action", details: ["reason": "accepted-external-manual-seek"])
        operation = UUID(); ending?.cancel(); ending = nil
        automaticSkipsDisabled = true; mediaConsumed = false; outroConsumed = false
        automaticActionsDisabled = !clearActiveInterval(); completion.invalidate(); lastPosition = nil
        status = "本次手动定位优先，自动区间和片头片尾跳过已停用"
    }
    @discardableResult func configurationWillChange() -> Bool {
        guard clearActiveInterval() else { return false }
        invalidate(reason: "configuration-will-change"); return true
    }
    func manualABRequested() -> Bool {
        let wasActive = activeIntervalID != nil
        manualSeekAccepted(); return wasActive
    }
    func playbackRestartObserved() {
        guard intervalSeekWaiting, let current = fresh(), !current.seeking, !current.eof,
              let id = activeIntervalID, let row = program?.intervals.first(where: { $0.id == id }),
              current.position >= row.startMicroseconds, current.position < row.endMicroseconds else { return }
        intervalSeekWaiting = false; intervalSeekDeadline = nil
        emitJournal("interval-seek-settled-at-playback-restart"); observe()
    }
    func observe() {
        guard let p = program, p.enabled, let current = fresh() else {
            if binding != nil { invalidate(reason: "program-or-current-binding-unavailable") }; return
        }
        guard !automaticActionsDisabled else { return }
        if intervalSeekWaiting {
            if let deadline = intervalSeekDeadline, ProcessInfo.processInfo.systemUptime >= deadline {
                _ = clearActiveInterval(); _ = host?.holdPlaybackProgramBoundary()
                intervalSeekWaiting = false; intervalSeekDeadline = nil; mediaConsumed = true
                automaticSkipsDisabled = true; automaticActionsDisabled = true
                error = "区间开始定位在三秒内未确认，自动动作已停用；若清除失败请停止播放"
                emitJournal("interval-seek-deadline-return", details: ["reason": "three-second-settlement-deadline"])
            }
            return
        }
        guard ending == nil, !current.eof else { return } // Actual EOF goes through the shared ASR-finalization path.
        lastNonEOFPaused = current.paused
        if let activeID = activeIntervalID, let expected = p.intervals.first(where: { $0.id == activeID }),
           current.configuredStart != expected.startMicroseconds || current.configuredEnd != expected.endMicroseconds
            || current.configuredCount != expected.nativeLoopSeeks {
            // A user/script changed native A/B/count. Leave their new properties
            // untouched; retire our old completion rather than writing them back.
            invalidate(reason: "native-AB-or-count-changed"); status = "播放器区间配置已变更，旧播放程序动作取消"; return
        }
        if let activeIntervalID, let remaining = current.remaining,
           completion.observe(ticket: current.ticket(revision: p.revision), position: current.position,
                              remaining: remaining, seeking: current.seeking, forward: current.forward),
           let interval = p.intervals.first(where: { $0.id == activeIntervalID }) {
            execute(p.afterInterval, interval: interval, naturalEOF: false); return
        }
        defer { lastPosition = current.position }
        guard activeIntervalID == nil, !automaticSkipsDisabled, !outroConsumed,
              !current.seeking, !current.paused, current.forward,
              let outro = p.outroStartMicroseconds, outro < current.duration,
              let previous = lastPosition, previous < outro, current.position >= outro else { return }
        outroConsumed = true; mediaConsumed = true; execute(p.afterMedia, interval: nil, naturalEOF: false)
    }
    /// The Engine calls this only after the existing actual-EOF ASR close and
    /// its media/seek-generation checks. No fake EOF is generated for a skip.
    func mediaEOF() {
        emitJournal("native-media-EOF-callback")
        guard ending == nil, !intervalSeekWaiting, !automaticActionsDisabled else { return }
        guard !mediaConsumed, let p = program, p.enabled, fresh()?.eof == true else {
            return
        }
        if let activeID = activeIntervalID, let interval = p.intervals.first(where: { $0.id == activeID }) {
            guard let current = fresh(), current.remaining == 0, interval.totalPlays != nil,
                  current.configuredStart == interval.startMicroseconds,
                  current.configuredEnd == interval.endMicroseconds,
                  current.configuredCount == interval.nativeLoopSeeks else {
                error = "区间尚未确认有限次数完成，意外 EOF 不执行结束动作"; return
            }
            mediaConsumed = true; execute(p.afterInterval, interval: interval, naturalEOF: true); return
        }
        mediaConsumed = true; execute(p.afterMedia, interval: nil, naturalEOF: true)
    }
    private func fresh() -> PlaybackProgramSnapshot? {
        guard let host, let binding, let p = program,
              host.restoredPlaybackProgram?.revision == p.revision,
              let current = host.playbackProgramSnapshot(), current.ticket(revision: p.revision) == binding else { return nil }
        return current
    }
    private func execute(_ action: PlaybackProgramAction, interval: PlaybackInterval?, naturalEOF: Bool) {
        guard let host, let p = program, let ticket = binding, let current = fresh() else { return }
        let nextInterval = action == .nextInterval ? interval.flatMap { p.successor(after: $0.id) } : nil
        let effectiveAction = action == .nextInterval && nextInterval == nil ? p.afterMedia : action
        // Core may auto-pause at EOF. Carry the last same-media non-EOF intent,
        // not that automatic pause, into the next explicitly configured interval.
        let preservePause = naturalEOF ? (lastNonEOFPaused ?? current.paused) : current.paused
        emitJournal("end-action-request", details: ["requestedAction": action.rawValue,
            "effectiveAction": effectiveAction.rawValue, "naturalEOF": naturalEOF,
            "preservePause": preservePause, "expectedTicket": journalTicket(ticket),
            "intervalID": interval?.id.uuidString as Any? ?? NSNull()])
        guard clearActiveInterval() else { return }
        if effectiveAction == .continuePlayback { status = "区间已完成，继续当前媒体"; return }
        guard host.holdPlaybackProgramBoundary() else { error = "结束边界暂停未确认，动作未执行"; return }
        emitJournal("end-action-boundary-held", details: ["action": effectiveAction.rawValue])
        operation = UUID(); let token = operation
        ending = Task { @MainActor [weak self] in
            guard let self else { return }
            // Stop is cancellation of recognition at a deliberate interval/
            // outro boundary. It retains determined cues, never labels it EOF.
            let closed = await host.closeRecognitionForPlaybackProgram()
            guard self.operation == token else {
                self.emitJournal("end-action-cancelled", details: ["reason": "obsolete-operation",
                    "expectedOperationID": token.uuidString, "expectedTicket": self.journalTicket(ticket)]); return
            }
            self.ending = nil // Retire only this exact completed task, including cancellation.
            guard !Task.isCancelled, self.binding == ticket, self.fresh()?.paused == true else {
                self.status = "媒体或播放意图已变化，旧结束动作取消"
                self.emitJournal("end-action-cancelled", details: ["reason": "task-or-media-or-pause-guard", "expectedOperationID": token.uuidString, "expectedTicket": self.journalTicket(ticket)]); return
            }
            self.emitJournal("recognition-close-return", details: ["confirmed": closed,
                "action": effectiveAction.rawValue, "expectedOperationID": token.uuidString,
                "expectedTicket": self.journalTicket(ticket)])
            guard closed else { self.error = "字幕进程尚未确认清理，结束动作未执行"; return }
            if let nextInterval {
                guard self.activate(nextInterval.id), host.restorePlaybackProgramPause(preservePause) else {
                    _ = host.holdPlaybackProgramBoundary()
                    self.automaticActionsDisabled = true; self.error = "下一区间或原播放意图未确认，保持暂停"; return
                }
                self.lastNonEOFPaused = preservePause
                self.emitJournal("next-interval-and-pause-restoration-return", details: ["confirmed": true, "intervalID": nextInterval.id.uuidString, "pause": preservePause])
                return
            }
            guard host.performPlaybackProgramAction(effectiveAction, ticket: ticket) else {
                self.error = "结束动作未确认，当前媒体保留"; return
            }
            self.emitJournal("end-action-host-return", details: ["hostReturned": true, "action": effectiveAction.rawValue, "terminationProven": false, "expectedOperationID": token.uuidString, "expectedTicket": self.journalTicket(ticket)])
            if self.operation == token { self.status = effectiveAction == .quit ? "已提交应用退出请求" : "已执行播放程序结束动作" }
        }
    }
}
