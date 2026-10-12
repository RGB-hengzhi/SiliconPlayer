import Foundation
import Combine
import PlayerCore

/// Product adapter for the explicitly selected persistent-provider mode.
/// UI/OSD ownership stays on MainActor; real pipe/FD/child ownership stays in
/// LiveASRLinearProcessSession. Default bounded-pair mode is untouched.
@MainActor final class LiveASRLinearController {
    struct Presentation {
        let state: LiveASRController.State
        let status: String
        let error: String?
        let partial: String
        let cues: [LiveASRCue]
    }
    private static var jobs: [UUID: LiveASRLinearProcessSession] = [:]
    private static var acceptanceGates: [UUID: LiveASRLinearAcceptanceGate] = [:]
    private static var serial: UInt64 = 0
    static var hasActiveJobs: Bool { !jobs.isEmpty }
    static func shutdownAll() async -> Bool {
        for gate in acceptanceGates.values { gate.close() }
        var success = true
        for (id, actor) in Array(jobs) {
            let receipt = await actor.shutdownReceipt()
            // Physical release removes only this exact object. Missing native
            // close still fails acceptance; it is never synthesized as zero.
            if receipt.actualOwnedResourcesReleased, jobs[id] === actor {
                acceptanceGates[id]?.close(); jobs.removeValue(forKey: id); acceptanceGates.removeValue(forKey: id)
            }
            success = success && receipt.actualOwnedResourcesReleased
        }
        return success
    }
    private weak var host: (any LiveASRHost)?
    private let factory: any LiveASRLinearBackendFactory
    private var actor: LiveASRLinearProcessSession?
    private var acceptanceGate: LiveASRLinearAcceptanceGate?
    private var processID = UUID(), owner = UUID(), operation = UUID()
    private var binding: LiveASRBinding?, track: LiveASRTrack?
    private var fingerprint: LiveASRFileFingerprint?, loadedMediaFingerprint: LiveASRFileFingerprint?
    private var source: URL?, proof: LiveASRSourceProof?
    // Only an actual current-source callback can populate this display tail.
    // Its source/seek binding is separate from historical exported cues.
    private var latestPresentation: (source: LiveASRLinearSource, cue: LiveASRCue)?
    private var revision: UInt64 = 1
    private var lastIntent: Intent?
    private struct Intent: Equatable { let seek: UInt64; let speed: Double; let paused: Bool }
    private var monitor: Task<Void, Never>?
    private var closingTask: Task<LiveASRLinearProcessSession.ShutdownReceipt, Never>?
    private var closeToken: UUID?
    private var terminal = false, overlayClearFailed = false, sourceCompleted = false
    private(set) var state: LiveASRController.State = .idle
    private(set) var status = "持续解码模式尚未开始"
    private(set) var error: String?
    private(set) var partial = ""
    private(set) var cues: [LiveASRCue] = []
    private(set) var lastReceipt: LiveASRLinearProcessSession.ShutdownReceipt?
    private(set) var savedDiagnostics: Data?
    var onChange: ((Presentation) -> Void)?
    var active: Bool { actor != nil }
    var needsObservation: Bool { active || sourceCompleted }
    var canStop: Bool { active || sourceCompleted || overlayClearFailed || Self.jobs[processID] != nil }
    var canSelectAnotherMode: Bool { actor == nil && !overlayClearFailed && !Self.hasActiveJobs }
    init(host: any LiveASRHost, factory: any LiveASRLinearBackendFactory) {
        self.host = host; self.factory = factory
    }
    func start(_ supplied: LiveASRSnapshot) async -> Bool {
        guard !terminal, canSelectAnotherMode, let host else { return false }
        let current = host.liveASRSnapshot()
        guard current.binding == supplied.binding, current.selectedTrack == supplied.selectedTrack,
              let binding = current.binding, let track = current.selectedTrack,
              let fingerprint = track.externalSource?.fingerprint ?? current.loadedSourceFingerprint,
              current.loaded, !current.loading, !current.seeking, !current.eof,
              current.settledSeekGeneration == current.seekGeneration,
              current.audioDelay == 0, current.speed.isFinite, (0.5...2).contains(current.speed),
              current.corePosition.map({ $0.isFinite && $0 >= 0 }) == true,
              current.currentDemuxer == "lavf", current.loadedSourceFingerprint != nil else {
            fail("请先载入并完成定位一个可核实的本地音轨"); return false
        }
        guard Self.serial < .max else { fail("持续解码会话编号耗尽"); return false }
        Self.serial += 1
        let token = UUID(); operation = token; processID = UUID(); owner = UUID()
        self.binding = binding; self.track = track; self.fingerprint = fingerprint
        loadedMediaFingerprint = current.loadedSourceFingerprint
        source = binding.originalURL; proof = nil; cues = []; partial = ""; error = nil
        lastReceipt = nil; savedDiagnostics = nil; sourceCompleted = false
        revision = 1; lastIntent = Intent(seek: current.seekGeneration, speed: current.speed, paused: current.paused)
        state = .opening; status = "正在核验持续解码工具与源 FD"; publish()
        let id = processID
        let gate = LiveASRLinearAcceptanceGate(); acceptanceGate = gate
        do {
            let request = LiveASROpenRequest(sessionID: owner, processID: id, itemSerial: Self.serial,
                initialEpoch: 1, snapshot: current, maximumDecodedSeconds: 120)
            let reserved = try factory.reserve(request, acceptance: gate, core: { [weak host] in
                guard gate.isOpen, let host else { return throwawayPrecondition() }
                return await host.liveASRSnapshot()
            }, cues: { [weak self] source, callback, completed, partial in
                guard let self else { return }
                await self.receive(source: source, callback: callback, completed: completed, partial: partial,
                                   process: id, launch: token)
            })
            actor = reserved; Self.jobs[id] = reserved; Self.acceptanceGates[id] = gate
            // Registration precedes the first await, including resolver/ffprobe.
            let opened = try await reserved.start()
            guard operation == token, actor === reserved, !terminal, gate.isOpen else { _ = await retire(reserved, id: id); return false }
            let fresh = host.liveASRSnapshot(); try opened.validate(for: fresh)
            guard fresh.binding == binding, fresh.selectedTrack == track else { throw LiveASRFailure("启动中媒体绑定已改变") }
            proof = opened; state = fresh.paused ? .paused : .following
            status = fresh.paused ? "持续解码已就绪，等待播放" : "正在持续解码并分窗识别"
            publish(); beginMonitor(reserved, id: id, launch: token); return true
        } catch {
            guard operation == token else { return false }
            fail(error.localizedDescription)
            if let actor { _ = await retire(actor, id: id) }
            return false
        }
    }
    /// Source is reread after the actor identity check, with no suspension
    /// between this snapshot and the real osd-overlay command.
    private func receive(source actual: LiveASRLinearSource, callback: UUID,
                         completed: [LiveASRCue], partial: LiveASRCue?, process: UUID, launch: UUID) async {
        guard operation == launch, processID == process, let actor, !terminal,
              await actor.presentationIsCurrent(source: actual, operation: callback),
              operation == launch, processID == process, !terminal, acceptanceGate?.isOpen == true, let host else { return }
        let now = host.liveASRSnapshot()
        guard now.binding == actual.binding, now.selectedTrack == actual.track,
              now.seekGeneration == actual.seekGeneration, !now.seeking,
              (actual.track.externalSource?.fingerprint ?? now.loadedSourceFingerprint) == actual.fingerprint else { return }
        let previousCueIDs = Set(cues.map(\.id))
        if latestPresentation?.source != actual { latestPresentation = nil }
        if let latest = partial ?? completed.last(where: { !previousCueIDs.contains($0.id) }) {
            latestPresentation = (actual, latest)
        }
        cues = completed; self.partial = partial?.text ?? ""
        do { try render(now, partial: partial) } catch { fail(error.localizedDescription); invalidate(.discontinuity) }
        publish()
    }
    func observe(_ current: LiveASRSnapshot) {
        guard !terminal else { return }
        if sourceCompleted, actor == nil {
            guard current.binding == binding, current.selectedTrack == track else { sourceCompleted = false; _ = clearOverlay(); return }
            // Replay requires a new explicit Start after source FD actually
            // closed. Never loop automatically at external/source EOF.
            do { try render(current, partial: nil) } catch { fail(error.localizedDescription) }; return
        }
        guard let actor, !terminal, state != .closing else { return }
        guard current.binding == binding, current.selectedTrack == track,
              (track?.externalSource?.fingerprint ?? current.loadedSourceFingerprint) == fingerprint,
              current.loaded, !current.loading, current.audioDelay == 0,
              current.speed.isFinite, (0.5...2).contains(current.speed) else { invalidate(.discontinuity); return }
        let intent = Intent(seek: current.seekGeneration, speed: current.speed, paused: current.paused)
        if intent != lastIntent {
            guard revision < .max else { fail("持续解码控制版本耗尽"); invalidate(.discontinuity); return }
            revision += 1; lastIntent = intent
        }
        let local = revision, token = operation
        // Core fields are fresh on every poll even if user intent is identical.
        Task { await actor.update(current, revision: local) }
        if current.seeking { state = .waitingForSeek; partial = ""; _ = clearOverlay() }
        else if !current.eof { state = current.paused ? .paused : .following }
        if operation == token {
            // Use the existing poll to expire the tail while paused/playing;
            // do not create another timer or alter the actor control cadence.
            if !current.seeking, !current.eof {
                do { try render(current, partial: nil) }
                catch { fail(error.localizedDescription); invalidate(.discontinuity) }
            }
            publish()
        }
    }
    func willSeek(generation: UInt64) {
        guard actor != nil else { sourceCompleted = false; partial = ""; _ = clearOverlay(); publish(); return }
        // The synchronous host generation invalidates old OSD before the seek
        // command returns; only real SEEK/RESTART supplies settled state.
        partial = ""; state = .waitingForSeek; _ = clearOverlay(); publish()
        if let current = host?.liveASRSnapshot() { observe(current) }
    }
    func invalidate(_ reason: LiveASRInvalidation) {
        guard actor != nil else { sourceCompleted = false; _ = clearOverlay(); return }
        operation = UUID(); partial = ""; sourceCompleted = false
        _ = clearOverlay(); state = .closing; status = "正在释放持续解码资源（\(reason.rawValue)）"; publish()
        Task { [weak self] in _ = await self?.stop() }
    }
    private func beginMonitor(_ job: LiveASRLinearProcessSession, id: UUID, launch: UUID) {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.actor === job, self.processID == id, self.operation == launch else { return }
                let actual = await job.productStatus()
                guard self.actor === job, self.processID == id, self.operation == launch else { return }
                if let failure = actual.failure { self.fail(failure) }
                if actual.physicallyReleased {
                    let receipt = await job.shutdownReceipt()
                    let raw = try? await job.diagnostics()
                    guard self.actor === job, self.processID == id, self.operation == launch else { return }
                    if Self.jobs[id] === job { Self.acceptanceGates[id]?.close(); Self.jobs.removeValue(forKey: id); Self.acceptanceGates.removeValue(forKey: id) }
                    self.actor = nil; self.lastReceipt = receipt; self.savedDiagnostics = raw
                    self.sourceCompleted = actual.sourceEOF && receipt.actualNativeNormalClosure
                    let mainFinal = actual.coreEOFCompleted && receipt.actualNativeNormalClosure
                    self.state = self.sourceCompleted ? .sourceCompleted : (mainFinal ? .idle:.failed)
                    self.status = self.sourceCompleted ? "本地音轨已结束，已确定字幕可导出" : (mainFinal ? "当前媒体字幕已完成，可以导出":"持续解码已停止，请查看实际关闭结果")
                    if !self.sourceCompleted { _ = self.clearOverlay() }
                    self.publish(); return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
    private func retire(_ job: LiveASRLinearProcessSession, id: UUID) async -> LiveASRLinearProcessSession.ShutdownReceipt {
        Self.acceptanceGates[id]?.close()
        let receipt = await job.shutdownReceipt()
        if receipt.actualOwnedResourcesReleased, Self.jobs[id] === job { Self.acceptanceGates[id]?.close(); Self.jobs.removeValue(forKey: id); Self.acceptanceGates.removeValue(forKey: id) }
        let raw = try? await job.diagnostics()
        if actor === job, processID == id {
            lastReceipt = receipt; savedDiagnostics = raw
            if receipt.actualOwnedResourcesReleased { actor = nil }
        }
        return receipt
    }
    /// Every awaiter is ticket-checked; a failed attempt leaves the owned actor
    /// and registry retained, clears its task token and permits a genuine retry.
    func stop() async -> LiveASRCloseResult {
        acceptanceGate?.close()
        operation = UUID(); monitor?.cancel(); monitor = nil
        partial = ""; sourceCompleted = false; _ = clearOverlay()
        guard let actor else {
            if overlayClearFailed { fail("识别资源已释放，但字幕层仍需重试清除") }
            if let receipt = lastReceipt {
                if !overlayClearFailed{state=terminal ? .shutDown:.idle;publish()}
                return receipt.result
            }
            return noResourcesReceipt()
        }
        let job = actor, id = processID
        if let task = closingTask { return (await task.value).result }
        let attempt = UUID(); closeToken = attempt; state = .closing; publish()
        let task = Task { await job.shutdownReceipt() }; closingTask = task
        let receipt = await task.value
        if receipt.actualOwnedResourcesReleased, Self.jobs[id] === job { Self.acceptanceGates[id]?.close(); Self.jobs.removeValue(forKey: id); Self.acceptanceGates.removeValue(forKey: id) }
        let raw = try? await job.diagnostics()
        guard self.actor === job, processID == id, closeToken == attempt else { return receipt.result }
        closingTask = nil; closeToken = nil; lastReceipt = receipt; savedDiagnostics = raw
        if receipt.actualOwnedResourcesReleased { self.actor = nil }
        state = receipt.actualOwnedResourcesReleased && !overlayClearFailed ? (terminal ? .shutDown : .idle) : .failed
        status = receipt.actualNativeNormalClosure ? "持续解码已正常停止，已确定字幕可导出" : "持续解码关闭结果未完整，请查看错误"
        if !receipt.actualNativeNormalClosure { error = receipt.result.detail }
        publish(); return receipt.result
    }
    func beginTermination() {
        guard !terminal else { return }
        terminal = true; operation = UUID()
        monitor?.cancel(); monitor = nil
        acceptanceGate?.close()
        // Include retained owned actors even if an earlier close changed the
        // current instance slot. Registration persists until physical release.
        for gate in Self.acceptanceGates.values { gate.close() }
    }
    func shutdown() async -> Bool {
        beginTermination(); _ = await stop()
        return actor == nil && !Self.hasActiveJobs && !overlayClearFailed
            // Product quit requires physical safety. Native normal-close
            // failure remains in receipt/error and fails native acceptance.
    }
    func resumeAfterCancelledTermination() {
        terminal = false
        // Never reopen the old gate. A retained actor/overlay still blocks
        // replacement; a released new Start reserves a different ticket/gate.
        if canStop || Self.hasActiveJobs { fail("退出已取消，请重试清理持续解码资源") }
        else { state = .idle; status = "退出已取消，可重新开始持续解码" }
        publish()
    }
    func finishForEOF() async {
        guard !terminal, acceptanceGate?.isOpen == true else { return }
        guard let job = actor else { _ = clearOverlay(); sourceCompleted = false; return }
        let id=processID,launch=operation
        state = .finishing; status = "正在完成已授权的最终字幕"; publish()
        do { try await job.finishGrantedForCoreEOF() }
        catch { if actor === job,processID==id,operation==launch{fail(error.localizedDescription)} }
        guard actor === job,processID==id,operation==launch else{return}
        _ = await stop() // after the real final callback; never preempt it
    }
    func diagnostics() async -> Data? { if let actor { return try? await actor.diagnostics() }; return savedDiagnostics }
    // Read cached actual callback identity only; no Host GET, actor await or
    // presentation eligibility/pass is manufactured by these diagnostics.
    private var latestPresentationDiagnostics: [String: Any]? {
        guard let value = latestPresentation else { return nil }
        let source = value.source, cue = value.cue, binding = source.binding
        return ["source": ["coreID":binding.coreID.uuidString,
                 "queueItemID":binding.queueItemID.uuidString,"loadToken":binding.loadToken.uuidString,
                 "nativeEntryID":binding.nativeEntryID,"seekGeneration":source.seekGeneration,
                 "runtimeAudioID":source.track.runtimeAudioID,"ffmpegIndex":source.track.absoluteFFmpegIndex,
                 "fingerprint":["device":source.fingerprint.device,"inode":source.fingerprint.inode,
                     "bytes":source.fingerprint.byteCount,"mtimeNS":source.fingerprint.modificationNanoseconds]],
                "cue": ["id":cue.id.uuidString,"processID":cue.processID?.uuidString as Any? ?? NSNull(),
                 "epoch":cue.epoch,"streamGeneration":cue.streamGeneration,
                 "engineSegment":cue.engineSegment,"revision":cue.revision,"final":cue.final,
                 "startNumerator":cue.start.numerator,"startDenominator":cue.start.denominator,
                 "endNumerator":cue.end.numerator,"endDenominator":cue.end.denominator,
                 "textUTF8Bytes":cue.text.utf8.count]]
    }
    var diagnosticsSnapshot: [String: Any] {
        ["mode":"persistentProvider", "state":state.rawValue, "owner":owner.uuidString,
         "processID":processID.uuidString, "operation":operation.uuidString,
         "latestPresentation":latestPresentationDiagnostics as Any? ?? NSNull(),
         "active":active, "ownedJobs":Self.jobs.count,
         "sourceCompleted":sourceCompleted, "overlayClearFailed":overlayClearFailed,
         "terminal":terminal, "acceptanceGateTicket":acceptanceGate?.ticket.uuidString as Any? ?? NSNull(),
         "acceptanceGateOpen":acceptanceGate?.isOpen as Any? ?? NSNull(),
         "actualOwnedResourcesReleased":lastReceipt?.actualOwnedResourcesReleased as Any? ?? NSNull(),
         "actualNativeNormalClosure":lastReceipt?.actualNativeNormalClosure as Any? ?? NSNull(),
         "error":error as Any? ?? NSNull(), "finalCueCount":cues.count]
    }
    func export(to destination: URL) async throws {
        guard let source, let proof, !cues.isEmpty else { throw LiveASRFailure("没有可导出的已确定字幕") }
        let snapshot = cues.map { SubtitleCue(start: $0.start.seconds, end: $0.end.seconds, text: $0.text) }
        let document = SubtitleDocument(cues: snapshot); try document.validate(); let text = try document.srtText()
        let parsed = try SubtitleDocument.parse(text)
        guard parsed.cues.count == snapshot.count, zip(parsed.cues,snapshot).allSatisfy({
            $0.0.text.trimmingCharacters(in:.whitespacesAndNewlines) == $0.1.text.trimmingCharacters(in:.whitespacesAndNewlines)
            && abs($0.0.start-$0.1.start)<=0.001 && abs($0.0.end-$0.1.end)<=0.001 }) else { throw LiveASRFailure("持续字幕导出重读不符") }
        let protected = loadedMediaFingerprint
        try await Task.detached(priority:.utility) {
            try LiveASRExport.write(Data(text.utf8),to:destination,source:source,proof:proof,protectedMediaFingerprint:protected)
        }.value
    }
    private func render(_ snapshot: LiveASRSnapshot, partial: LiveASRCue?) throws {
        guard !terminal, let host, let binding, snapshot.binding == binding,
              snapshot.loaded, !snapshot.loading, !snapshot.seeking,
              snapshot.settledSeekGeneration == snapshot.seekGeneration,
              let now = snapshot.corePosition, now.isFinite else { return }
        let currentPresentation = latestPresentation.flatMap { value in
            snapshot.selectedTrack == value.source.track &&
            snapshot.binding == value.source.binding &&
            snapshot.seekGeneration == value.source.seekGeneration &&
            (value.source.track.externalSource?.fingerprint ?? snapshot.loadedSourceFingerprint) == value.source.fingerprint
                ? value.cue : nil
        }
        let actualPartial = partial ?? currentPresentation.flatMap { $0.final ? nil : $0 }
        var cue = actualPartial.flatMap { $0.start.seconds<=now && now<$0.end.seconds ? $0:nil }
            ?? cues.last(where: { $0.start.seconds<=now && now<$0.end.seconds })
        // Match the ordinary controller's bounded source-time presentation
        // grace, without moving any real cue or exported SRT timestamp. Old
        // completed history cannot supply a tail after a seek/replacement.
        if let latest = currentPresentation, latest.processID != nil,
           latest.start.seconds <= now, now >= latest.end.seconds,
           now - latest.end.seconds <= 2, (!latest.final || cue == nil) {
            cue = latest
        }
        try host.setLiveASROverlay(cue.map { LiveASROverlay(plainText:$0.text,isPartial:!$0.final) },owner:owner,binding:binding)
    }
    @discardableResult private func clearOverlay() -> Bool {
        latestPresentation = nil
        guard let host else { overlayClearFailed = true; return false }
        let ok = host.clearLiveASROverlay(owner:owner); overlayClearFailed = !ok; return ok
    }
    private func fail(_ message:String) { error=message;state = .failed;status="持续解码发生错误";publish() }
    private func publish() { onChange?(Presentation(state:state,status:status,error:error,partial:partial,cues:cues)) }
    private func noResourcesReceipt() -> LiveASRCloseResult {
        // No spawned resource at all; distinct from a missing native close.
        LiveASRCloseResult(decoderNaturalExitCode:0,recognizerNaturalExitCode:0,
            decoderStdoutEOF:true,recognizerStdoutEOF:true,decoderClosedContexts:0,
            recognizerLiveStreams:0,recognizerLiveRecognizers:0,ownedProcessesReaped:true,
            forcedTermination:false,detail:"No persistent provider was reserved")
    }
}
/// A dropped weak host is an impossible snapshot source while an owned job is
/// registered. Return a typed ineligible observation, never trap or stale clock.
private func throwawayPrecondition() -> LiveASRSnapshot {
    LiveASRSnapshot(binding:nil,selectedTrack:nil,loaded:false,loading:false,paused:true,
        seeking:false,eof:false,corePosition:nil,coreAudioPTS:nil,speed:1,audioDelay:0,
        currentDemuxer:"",rebaseStartTime:true,demuxerStartTime:nil,loadedSourceFingerprint:nil,
        observedUptime:ProcessInfo.processInfo.systemUptime,seekGeneration:0,settledSeekGeneration:nil)
}
