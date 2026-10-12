import Foundation
import Combine
import PlayerCore

/// Real input-limit rollover keeps the same primary media and confirmed cues;
/// each independently owned helper pair remains bounded to 120 decoded seconds.
@MainActor final class LiveASRController: ObservableObject {
    enum Mode: String { case boundedPairs, persistentProvider }
    private(set) var mode: Mode = .boundedPairs
    private var linear: LiveASRLinearController?
    enum State: String { case idle, opening, following, paused, waitingForSeek, transitioning, rollingOver, finishing, sourceCompleted, closing, failed, shutDown }
    @Published private(set) var state: State = .idle
    @Published private(set) var status = "尚未开始实时字幕"
    @Published private(set) var error: String?
    @Published private(set) var partialText = ""
    @Published private(set) var finalCues: [LiveASRCue] = []
    var busy: Bool { [.opening, .transitioning, .rollingOver, .finishing, .closing].contains(state) }
    var isActive: Bool { mode == .persistentProvider ? (linear?.active ?? false) : (session != nil || rollover != nil || preparedPair != nil) }
    /// A completed external source can retain a bounded presentation/replay
    /// context without retaining a live decoder or recognizer.
    var needsHostObservation: Bool { mode == .persistentProvider ? (linear?.needsObservation ?? false) : (isActive || externalCompletion != nil || externalReplay != nil) }
    /// A failed owned overlay clear remains a user-retryable Stop operation
    /// even after the completed source context and all processes are retired.
    var canStop: Bool { mode == .persistentProvider ? (linear?.canStop ?? false) : (needsHostObservation || overlayClearFailed || Self.jobs[processID] != nil || preparedPair != nil) }

    private static var jobs: [UUID: any LiveASROwnedSession] = [:]
    private static var serial: UInt64 = 0
    static var hasActiveJobs: Bool { !jobs.isEmpty || LiveASRLinearController.hasActiveJobs }
    static func shutdownAll() async -> Bool {
        var released = true
        for (id, job) in Array(jobs) {
            let result = await job.close(.cancel)
            if result.resourcesReleased { jobs.removeValue(forKey: id) } else { released = false }
        }
        let linearReleased = await LiveASRLinearController.shutdownAll()
        return released && linearReleased
    }

    private weak var host: (any LiveASRHost)?
    private let factory: any LiveASRBackendFactory
    private var session: (any LiveASROwnedSession)?
    private var proof: LiveASRSourceProof?
    private var binding: LiveASRBinding?
    private var track: LiveASRTrack?
    private var loadedFingerprint: LiveASRFileFingerprint?
    private var owner = UUID()
    private var processID = UUID()
    private var operation = UUID()
    private var transitionID = UUID()
    private var desiredEpoch: UInt64 = 1
    private var itemSerial: UInt64 = 0
    private var streamGeneration: UInt64 = 0
    private var lastServiceSequence: UInt64 = 0
    private var controlRevision: UInt64 = 0
    // EOF finalization retires an outstanding pause callback without changing
    // its actual wire revision/epoch or fabricating a decoder ACK.
    private var pauseControlToken = UUID()
    private var lastSpeed = 1.0
    private var lastPause = false
    private var observedSeekGeneration: UInt64 = 0
    private var waitingSeekGeneration: UInt64?
    private var transitionNeeded = false
    private var decoderEOF = false
    private var inputLimit = false
    /// Optional same-Actor observer of a validated real C receipt. No synthetic
    /// limit, pause or grant is generated; the actual-App verifier uses this to
    /// test a user action at the receipt without a polling-window assumption.
    var onInputLimitObserved: ((LiveASRInputLimitReceipt) -> Void)?
    private var expectedInputLimit: LiveASRInputLimitReceipt?
    private var inputLimitObservedUptime: Double?
    private var continuationFirstSample: LiveASRTime?
    private struct Rollover {
        let id: UUID
        let operation: UUID
        let oldProcess: UUID
        let target: LiveASRTime
        let seekGeneration: UInt64
        let speed: Double
        var launchScheduled = false
    }
    private var rollover: Rollover?
    @MainActor private final class PreparedPair {
        let processID: UUID
        let owner: UUID
        let serial: UInt64
        let predecessor: UUID
        let operation: UUID
        let snapshot: LiveASRSnapshot
        let job: any LiveASROwnedSession
        let reservedUptime: Double
        var readyUptime: Double?
        var proof: LiveASRSourceProof?
        var readyDiagnostic: Data?
        var cancelled = false
        var retirement: Task<LiveASRCloseResult, Never>?
        var retirementToken: UUID?
        init(processID: UUID, owner: UUID, serial: UInt64, predecessor: UUID,
             operation: UUID, snapshot: LiveASRSnapshot, job: any LiveASROwnedSession) {
            self.processID = processID; self.owner = owner; self.serial = serial
            self.predecessor = predecessor; self.operation = operation; self.snapshot = snapshot
            self.job = job; reservedUptime = ProcessInfo.processInfo.systemUptime
        }
    }
    private var preparedPair: PreparedPair?
    private var preparationAttempt: UUID?
    private var preparationReceipts: [[String: Any]] = []
    private var preparedPairWire: [UUID: Data] = [:]
    private var preparedPairWireBytes = 0
    private var completedPairs: [[String: Any]] = []
    private var captionSessionID = UUID()
    private var completedPairWire: [(processID: UUID, data: Data)] = []
    private var completedPairWireBytes = 0
    private var completedPairWireOverflow = false
    private let maximumCompletedPairs = 256
    private var finishTask: Task<LiveASRCloseResult, Never>?
    private var accepting = false
    private var terminal = false
    private var overlayClearFailed = false
    private var timeline = LiveASRTimelineLedger()
    private var cues = LiveASRCueLedger()
    private var exportedSource: URL?
    private var exportProof: LiveASRSourceProof?
    private var lastCloseResult: LiveASRCloseResult?
    private var lastBackendDiagnostics: Data?
    private var externalCompletion: LiveASRExternalSourceCompletion?
    private var externalSourceEnd: LiveASRTime?
    private var externalTailPresentationAllowed = false
    private struct ExternalReplay {
        let id: UUID
        let operation: UUID
        let seekGeneration: UInt64
        let sourceEnd: LiveASRTime?
        var resourcesReleased = false
        var launchScheduled = false
    }
    private var externalReplay: ExternalReplay?

    /// Actual state/ledger values only. A cue's end is accepted input range, not
    /// word alignment; this diagnostic never manufactures a render/ASR count.
    var diagnosticsSnapshot: [String: Any] {
        if mode == .persistentProvider { return linear?.diagnosticsSnapshot ?? ["mode":"persistentProvider","unavailable":true] }
        var value: [String: Any] = ["owner": owner.uuidString, "processID": processID.uuidString,
            "state": state.rawValue, "accepting": accepting, "terminal": terminal,
            "epoch": desiredEpoch, "streamGeneration": streamGeneration,
            "lastServiceSequence": lastServiceSequence, "seekGeneration": observedSeekGeneration,
            "grantedSamples": timeline.submittedSamples, "firstGrantedSequence": timeline.firstSequence,
            "lastGrantedSequence": timeline.lastSequence, "partial": partialText,
            "overlayClearFailed": overlayClearFailed, "inputLimitReached": inputLimit,
            "rolloverPending": rollover != nil, "completedPairs": completedPairs,
            "preparedProcessID": preparedPair?.processID.uuidString as Any? ?? NSNull(),
            "preparedReady": preparedPair?.proof != nil, "preparationReceipts": preparationReceipts,
            "preparedPairWireBytes": preparedPairWireBytes,
            "captionSessionID": captionSessionID.uuidString, "completedPairWireCount": completedPairWire.count,
            "completedPairWireOverflow": completedPairWireOverflow,
            "externalSourceCompleted": externalCompletion != nil,
            "externalReplayPending": externalReplay != nil,
            "finalCues": finalCues.map { ["id": $0.id.uuidString, "epoch": $0.epoch,
                "streamGeneration": $0.streamGeneration, "engineSegment": $0.engineSegment,
                "revision": $0.revision, "processID": $0.processID?.uuidString as Any? ?? NSNull(), "startNumerator": $0.start.numerator,
                "startDenominator": $0.start.denominator, "endNumerator": $0.end.numerator,
                "endDenominator": $0.end.denominator, "text": $0.text, "quality": $0.timingQuality.rawValue] as [String: Any] }]
        if let binding { value["binding"] = ["coreID": binding.coreID.uuidString, "itemID": binding.queueItemID.uuidString,
            "loadToken": binding.loadToken.uuidString, "nativeEntryID": binding.nativeEntryID] }
        if let ticket = timeline.ticket { value["ticket"] = ["epoch": ticket.epoch, "timingSegment": ticket.timingSegment,
            "itemSerial": ticket.itemSerial, "streamIndex": ticket.streamIndex] }
        if let externalSourceEnd { value["externalSourceEnd"] = ["numerator": externalSourceEnd.numerator,
            "denominator": externalSourceEnd.denominator] }
        if let externalCompletion { value["externalCompletionServiceSequence"] = externalCompletion.acceptedFinal.sequence }
        if let exportProof { value["sourceProof"] = ["rawOriginNumerator": exportProof.rawOrigin.numerator,
            "rawOriginDenominator": exportProof.rawOrigin.denominator, "originEvidence": exportProof.sourceOriginEvidence,
            "sourceHelperSHA256": exportProof.helperSourceSHA256, "ffIndex": exportProof.actualFFmpegIndex,
            "sampleRate": exportProof.actualSampleRate, "channels": exportProof.actualChannels,
            "device": exportProof.device, "inode": exportProof.inode, "bytes": exportProof.byteCount,
            "mtimeNanoseconds": exportProof.modificationNanoseconds,
            "sourceKind": track?.isExternal == true ? "externalPCM_WAV" : "embedded",
            "attachmentID": track?.externalSource?.attachmentID.uuidString as Any? ?? NSNull()] }
        if let lastCloseResult { value["close"] = ["decoderExit": lastCloseResult.decoderNaturalExitCode.map { $0 as Any } ?? NSNull(),
            "recognizerExit": lastCloseResult.recognizerNaturalExitCode.map { $0 as Any } ?? NSNull(),
            "decoderStdoutEOF": lastCloseResult.decoderStdoutEOF, "recognizerStdoutEOF": lastCloseResult.recognizerStdoutEOF,
            "decoderContexts": lastCloseResult.decoderClosedContexts.map { $0 as Any } ?? NSNull(),
            "recognizerStreams": lastCloseResult.recognizerLiveStreams.map { $0 as Any } ?? NSNull(),
            "recognizers": lastCloseResult.recognizerLiveRecognizers.map { $0 as Any } ?? NSNull(),
            "ownedReaped": lastCloseResult.ownedProcessesReaped, "forced": lastCloseResult.forcedTermination,
            "resourcesReleased": lastCloseResult.resourcesReleased, "confirmed": lastCloseResult.confirmed] }
        return value
    }
    /// Binary/JSON diagnostic capture is explicitly opt-in at factory creation;
    /// the default backend reports counters/receipts, not transcript wire logs.
    func backendDiagnostics() async -> Data? {
        if mode == .persistentProvider { return await linear?.diagnostics() }
        guard let job = session ?? Self.jobs[processID] else { return lastBackendDiagnostics }
        return await job.diagnostics()
    }

    /// Only actual completed jobs populate this bounded cache. Normal factories
    /// return counter-only diagnostics; transcript wire is opt-in private capture.
    func completedPairDiagnostics() -> [UUID: Data] {
        Dictionary(uniqueKeysWithValues: completedPairWire.map { ($0.processID, $0.data) })
    }

    /// Explicit private-verification read; ordinary polling never embeds wire.
    func preparedPairDiagnostics() -> [UUID: Data] { preparedPairWire }

    init(host: any LiveASRHost, factory: any LiveASRBackendFactory,
         linearFactory: (any LiveASRLinearBackendFactory)? = nil) {
        self.host = host; self.factory = factory
        if let linearFactory {
            let coordinator = LiveASRLinearController(host:host,factory:linearFactory)
            self.linear = coordinator
            coordinator.onChange = { [weak self] presentation in
                guard let self,self.mode == .persistentProvider else{return}
                self.state=presentation.state;self.status=presentation.status;self.error=presentation.error
                self.partialText=presentation.partial;self.finalCues=presentation.cues
            }
        }
    }

    func start(snapshot supplied: LiveASRSnapshot, mode requested: Mode = .boundedPairs) async -> Bool {
        guard !terminal else { error="实时字幕服务已关闭";return false }
        if requested != mode {
            _ = await stop()
            guard !terminal,session==nil,preparedPair==nil,Self.jobs.isEmpty,!overlayClearFailed,
                  linear?.canSelectAnotherMode ?? true else{error="旧字幕所有权未释放，未切换模式";return false}
            mode=requested
        }
        if mode == .persistentProvider {
            guard let linear else{error="当前包没有持续解码后端";state = .failed;return false}
            return await linear.start(supplied)
        }
        return await openPair(snapshot: supplied, preservingCues: false, continuationStart: nil)
    }
    private func openPair(snapshot supplied: LiveASRSnapshot, preservingCues: Bool,
                          continuationStart: LiveASRTime?) async -> Bool {
        guard !terminal else { error = "实时字幕服务已关闭"; return false }
        discardExternalTail(); rollover = nil
        let token = UUID(); operation = token
        _ = await retireCurrent()
        guard operation == token, Self.jobs.isEmpty, !overlayClearFailed, let host else {
            if overlayClearFailed { error = "进程已停止，字幕层未能清除；请再次停止后重试"; state = .failed; return false }
            if operation == token { error = "上个识别进程尚未确认释放"; state = .failed }; return false
        }
        let snapshot = host.liveASRSnapshot()
        guard snapshot.binding == supplied.binding, snapshot.selectedTrack == supplied.selectedTrack else {
            error = "媒体或音轨已变更，请重新开始"; state = .failed; return false
        }
        do {
            try eligible(snapshot)
            guard Self.serial < .max else { throw LiveASRFailure("会话编号达到上限") }
            Self.serial += 1; itemSerial = Self.serial
            owner = UUID(); processID = UUID(); desiredEpoch = 1; streamGeneration = 0; lastServiceSequence = 0; controlRevision = 0
            binding = snapshot.binding; track = snapshot.selectedTrack; loadedFingerprint = snapshot.loadedSourceFingerprint
            exportedSource = binding?.originalURL
            lastSpeed = snapshot.speed; lastPause = snapshot.paused; observedSeekGeneration = snapshot.seekGeneration
            waitingSeekGeneration = nil; transitionNeeded = false; decoderEOF = false; inputLimit = false; expectedInputLimit = nil; finishTask = nil
            continuationFirstSample = continuationStart; inputLimitObservedUptime = nil
            timeline = LiveASRTimelineLedger(); partialText = ""
            if !preservingCues {
                cues = LiveASRCueLedger(); finalCues = []; completedPairs = []; captionSessionID = UUID()
                completedPairWire = []; completedPairWireBytes = 0; completedPairWireOverflow = false
                preparationReceipts = []; preparedPairWire = [:]; preparedPairWireBytes = 0
            }
            error = nil; lastCloseResult = nil; lastBackendDiagnostics = nil; state = .opening; status = "正在核对本地音轨与时间轴"
            let request = LiveASROpenRequest(sessionID: owner, processID: processID, itemSerial: itemSerial,
                initialEpoch: desiredEpoch, snapshot: snapshot, maximumDecodedSeconds: 120, continuationStart: continuationStart, exactContinuousSourceRanges: true)
            let job = try factory.reserve(request)
            guard job.processID == processID else { throw LiveASRFailure("识别进程保留身份不匹配") }
            session = job; Self.jobs[processID] = job
            let expectedProcess = processID
            let opened = try await job.start { [weak self] event in
                guard let self else { return .stop }
                return await self.receive(event, process: expectedProcess)
            }
            guard operation == token, session?.processID == expectedProcess else {
                let result = await job.close(.cancel)
                if result.resourcesReleased { Self.jobs.removeValue(forKey: expectedProcess) }; return false
            }
            let latest = host.liveASRSnapshot()
            try opened.validate(for: latest)
            guard sameMedia(latest), !latest.seeking, latest.settledSeekGeneration == latest.seekGeneration else {
                throw LiveASRFailure("播放器仍在定位，请等待后再开始")
            }
            if preservingCues, let prior = exportProof, opened.fingerprint != prior.fingerprint {
                throw LiveASRFailure("连续字幕源身份已改变，旧结果保留但未继续接收")
            }
            proof = opened; exportProof = opened; accepting = true
            if let continuationStart { try verifyRolloverWindow(continuationStart, snapshot: latest) }
            try scheduleTransition(latest, exactNormalizedRange: continuationStart)
            return true // accepted; following starts only after actual transition ACK.
        } catch {
            guard operation == token else { return false }
            self.error = error.localizedDescription; state = .failed; status = "实时字幕未开始"
            _ = await retireCurrent(); return false
        }
    }

    /// Call synchronously before dispatching an accepted seek request. Native
    /// SEEK events supply their own host serial; queue acceptance alone is not
    /// a seek-settled receipt. New native seek receipts also call this method.
    func willSeek(generation: UInt64) {
        if mode == .persistentProvider { linear?.willSeek(generation:generation);return }
        if rollover != nil || inputLimit {
            invalidate(reason: .seek); return // Retire the old plan, never reuse a dead decoder.
        }
        if !terminal, track?.isExternal == true,
           decoderEOF || externalCompletion != nil || externalReplay != nil {
            requestExternalReplay(generation: generation); return
        }
        guard session != nil, !terminal else { return }
        cancelPreparedPair()
        observedSeekGeneration = generation; waitingSeekGeneration = generation
        retireRecognitionEpoch()
        guard !overlayClearFailed else { fail("旧字幕层尚未确认清除"); return }
        state = .waitingForSeek; status = "定位中，旧字幕结果已失效"
    }

    func observe(_ snapshot: LiveASRSnapshot) {
        if mode == .persistentProvider { linear?.observe(snapshot);return }
        if rollover != nil, session == nil { observeRollover(snapshot); return }
        if !terminal, session == nil, externalCompletion != nil || externalReplay != nil {
            observeExternalTail(snapshot); return
        }
        guard session != nil, !terminal, state != .closing else { return }
        guard sameMedia(snapshot), snapshot.loaded, !snapshot.loading else {
            invalidate(reason: .queueAdvance); return
        }
        guard snapshot.audioDelay == 0 else { fail("当前音频延迟不为零；首阶段未验证这种时间映射"); return }
        if snapshot.selectedTrack != track { invalidate(reason: .trackChange); return }
        if inputLimit {
            // The decoder ended at its real process bound, while retained PCM
            // still follows Host grant/hold. No controls go to a dead process.
            if snapshot.seekGeneration != observedSeekGeneration || snapshot.speed != lastSpeed {
                invalidate(reason: snapshot.speed != lastSpeed ? .speedChange : .seek); return
            }
            lastPause = snapshot.paused
            if snapshot.eof { pauseControlToken = UUID(); scheduleFinalization(requireEOF: true); return }
            if finishTask == nil {
                state = snapshot.paused ? .paused : .following
                status = snapshot.paused ? "已暂停，保留本分段真实待授权音频" : "正在完成本分段真实音频前缀"
            }
            render(snapshot); return
        }
        if track?.isExternal == true, decoderEOF {
            // The decoder has naturally exited; its retained ring/service can
            // still finish. Never submit PAUSE/SEEK/SPEED to that dead child.
            if snapshot.seekGeneration != observedSeekGeneration || waitingSeekGeneration != nil {
                requestExternalReplay(generation: snapshot.seekGeneration); return
            }
            guard snapshot.speed.isFinite, (0.5...2).contains(snapshot.speed) else {
                fail("外置音频结束后的播放速度超出支持范围"); return
            }
            lastSpeed = snapshot.speed; lastPause = snapshot.paused
            if snapshot.eof { pauseControlToken = UUID(); scheduleFinalization(requireEOF: true); return }
            render(snapshot); return
        }
        if snapshot.seekGeneration != observedSeekGeneration { willSeek(generation: snapshot.seekGeneration) }
        if snapshot.speed != lastSpeed {
            lastSpeed = snapshot.speed; retireRecognitionEpoch(); transitionNeeded = true
        }
        if let expected = waitingSeekGeneration {
            guard !snapshot.seeking, snapshot.settledSeekGeneration == expected,
                  snapshot.seekGeneration == expected else { return }
            waitingSeekGeneration = nil; transitionNeeded = true
        }
        if snapshot.seeking { return }
        if transitionNeeded {
            do { try eligible(snapshot); try scheduleTransition(snapshot) }
            catch { fail(error.localizedDescription) }
            return
        }
        // Core may automatically pause at EOF. Finalize the already granted
        // prefix before dispatching any new pause control. All media, track,
        // seek and speed checks above remain active during this close window.
        if snapshot.eof {
            pauseControlToken = UUID() // Retire queued errors before the Task can begin.
            scheduleFinalization(requireEOF: true); return
        }
        if finishTask != nil { return }
        if snapshot.paused != lastPause, let job = session {
            guard controlRevision < .max else { fail("音频控制版本达到上限"); return }
            controlRevision += 1; let revision = controlRevision
            lastPause = snapshot.paused; let epoch = desiredEpoch, id = processID
            let pauseToken = pauseControlToken
            state = snapshot.paused ? .paused : .following
            Task { [weak self] in
                do { try await job.setPaused(snapshot.paused, epoch: epoch, controlRevision: revision) }
                catch {
                    guard let self, self.processID == id, self.desiredEpoch == epoch, self.controlRevision == revision,
                          self.pauseControlToken == pauseToken, self.accepting, self.finishTask == nil,
                          self.session?.processID == id else { return }
                    self.fail(error.localizedDescription)
                }
            }
        }
        beginPreparingNextPair(snapshot)
        render(snapshot)
    }

    func invalidate(reason: LiveASRInvalidation) {
        if mode == .persistentProvider { linear?.invalidate(reason);return }
        cancelPreparedPair()
        if rollover != nil, session == nil {
            rollover = nil; operation = UUID(); transitionID = UUID(); pauseControlToken = UUID()
            cues.clearPartial(); partialText = ""; _ = clearOwnedOverlay()
            state = overlayClearFailed || error != nil ? .failed : .idle
            status = overlayClearFailed ? "进程已停止，字幕层未能清除" : "连续字幕已停止，已确定结果可导出"
            return
        }
        rollover = nil
        if session == nil, externalCompletion != nil || externalReplay != nil {
            discardExternalTail(); operation = UUID(); transitionID = UUID(); pauseControlToken = UUID()
            _ = clearOwnedOverlay()
            state = overlayClearFailed ? .failed : .idle
            status = overlayClearFailed ? "进程已停止，字幕层未能清除" : "实时字幕已停止（\(reason.rawValue)）"
            return
        }
        discardExternalTail()
        guard session != nil else { return }
        accepting = false; operation = UUID(); transitionID = UUID(); cues.clearPartial(); partialText = ""
        let token = operation
        _ = clearOwnedOverlay()
        status = reason == .trackChange ? "音轨已变更，请重新开始实时字幕" : "实时字幕已停止（\(reason.rawValue)）"
        state = .closing
        Task { [weak self] in
            guard let self else { return }; let result = await self.retireCurrent()
            if self.operation == token && self.session == nil && !self.terminal {
                self.state = result.resourcesReleased && self.error == nil && !self.overlayClearFailed ? .idle : .failed
            }
        }
    }

    func stop() async -> LiveASRCloseResult {
        if mode == .persistentProvider, let linear { return await linear.stop() }
        // Close every reserved standby before reporting this controller stopped.
        // Original active-pair receipt stays a receipt for that exact pair.
        accepting = false; operation = UUID(); pauseControlToken = UUID(); transitionID = UUID(); state = .closing
        var preparationClosed = true
        if session == nil { preparationClosed = await retirePreparedPair() }
        if rollover != nil, session == nil, let completed = lastCloseResult {
            rollover = nil; operation = UUID(); transitionID = UUID(); pauseControlToken = UUID()
            _ = clearOwnedOverlay(); cues.clearPartial(); partialText = ""
            state = overlayClearFailed || !preparationClosed ? .failed : terminal ? .shutDown : .idle
            status = overlayClearFailed ? "进程已停止，字幕层未能清除" : preparationClosed ? "连续字幕已停止，已确定结果可导出" : "预备识别进程尚未确认释放"
            return completed // Actual prior pair receipt, not an empty synthetic close.
        }
        rollover = nil
        if session == nil, Self.jobs[processID] == nil,
           let completedReceipt = externalCompletion?.closeResult ?? (overlayClearFailed ? lastCloseResult : nil) {
            operation = UUID(); transitionID = UUID(); pauseControlToken = UUID()
            discardExternalTail(); _ = clearOwnedOverlay()
            state = overlayClearFailed || !preparationClosed ? .failed : terminal ? .shutDown : .idle
            status = overlayClearFailed ? "进程已停止，字幕层未能清除" : preparationClosed ? "实时字幕已停止，已确定结果可以导出" : "预备识别进程尚未确认释放"
            lastCloseResult = completedReceipt
            return completedReceipt // Keep the actual pair receipt during an overlay-only retry.
        }
        discardExternalTail()
        operation = UUID(); accepting = false; transitionID = UUID(); state = .closing
        let token = operation
        let result = await retireCurrent()
        preparationClosed = preparationClosed && preparedPair == nil && Self.jobs.isEmpty
        guard operation == token else { return result }
        lastCloseResult = result
        state = overlayClearFailed || !preparationClosed ? .failed : terminal ? .shutDown : result.resourcesReleased ? .idle : .failed
        status = overlayClearFailed ? "进程已停止，字幕层未能清除" : result.resourcesReleased ? "实时字幕已停止，已确定结果可以导出" : "识别进程尚未确认释放"
        if !result.resourcesReleased { error = result.detail }
        return result
    }
    /// Freeze the bounded controller and each persistent actor synchronously,
    /// after dirty-document approval and before any termination snapshot/await.
    func beginTermination() {
        guard !terminal else { return }
        terminal = true; accepting = false
        operation = UUID(); transitionID = UUID(); pauseControlToken = UUID()
        preparedPair?.cancelled = true
        linear?.beginTermination()
    }
    func shutdown() async -> Bool {
        beginTermination()
        if mode == .persistentProvider,let linear{return await linear.shutdown()}
        let result=await stop();return result.resourcesReleased && Self.jobs.isEmpty && preparedPair==nil && !overlayClearFailed
    }
    /// A cancelled application exit can reopen acceptance; retained owned jobs
    /// remain registered and keep start blocked until a real close receipt.
    func resumeAfterCancelledTermination() {
        terminal = false
        linear?.resumeAfterCancelledTermination()
        if mode == .persistentProvider { return }
        if !Self.jobs.isEmpty || session != nil || preparedPair != nil || overlayClearFailed { state = .failed; status = "退出已取消，请先重试停止实时字幕" }
        else { state = .idle; status = "退出已取消，可重新开始实时字幕" }
    }

    func export(to destination: URL) async throws {
        if mode == .persistentProvider, let linear { try await linear.export(to:destination);return }
        guard destination.isFileURL, !finalCues.isEmpty, let source = exportedSource, let exportProof,
              destination.standardizedFileURL != source.standardizedFileURL else {
            throw LiveASRFailure("请选择独立 SRT 文件；当前没有可导出的已确定字幕")
        }
        let snapshot = finalCues.map { SubtitleCue(start: $0.start.seconds, end: $0.end.seconds, text: $0.text) }
        let document = SubtitleDocument(cues: snapshot)
        try document.validate()
        let protectedMediaFingerprint = loadedFingerprint
        let text = try document.srtText()
        let exported = try SubtitleDocument.parse(text)
        guard exported.cues.count == snapshot.count, zip(exported.cues, snapshot).allSatisfy({
            $0.0.text.trimmingCharacters(in: .whitespacesAndNewlines) == $0.1.text.trimmingCharacters(in: .whitespacesAndNewlines)
            && abs($0.0.start - $0.1.start) <= 0.001 && abs($0.0.end - $0.1.end) <= 0.001
        }) else { throw LiveASRFailure("字幕导出重读不一致") }
        try await Task.detached(priority: .utility) {
            try LiveASRExport.write(Data(text.utf8), to: destination, source: source, proof: exportProof,
                protectedMediaFingerprint: protectedMediaFingerprint)
        }.value
    }

    private func discardExternalTail() {
        externalCompletion = nil; externalSourceEnd = nil
        externalReplay = nil; externalTailPresentationAllowed = false
    }

    /// User/native seek is the trigger, never an automatic EOF retry. Retire the
    /// whole old pair even if its EOF final is still in flight, then wait for the
    /// real primary SEEK/RESTART generation. New start rereads the actual host
    /// binding/source/fingerprint and allocates a new owner/process/item serial.
    private func requestExternalReplay(generation: UInt64) {
        if externalReplay?.seekGeneration == generation { return }
        let id = UUID(), token = UUID()
        operation = token; transitionID = UUID(); pauseControlToken = UUID()
        accepting = false; observedSeekGeneration = generation; waitingSeekGeneration = generation
        externalTailPresentationAllowed = false; cues.clearPartial(); partialText = ""
        externalReplay = ExternalReplay(id: id, operation: token, seekGeneration: generation, sourceEnd: externalSourceEnd)
        guard clearOwnedOverlay() else { state = .failed; return }
        state = .waitingForSeek; status = "正在回退定位；等待旧进程释放后重新识别外置音频"
        Task { [weak self] in
            guard let self else { return }
            let closed = await self.retireCurrent()
            guard self.operation == token, self.externalReplay?.id == id, !self.terminal else { return }
            guard closed.resourcesReleased, !self.overlayClearFailed else {
                self.state = .failed; self.error = closed.detail
                self.status = "旧识别进程尚未确认释放，未创建新的进程对"; return
            }
            self.externalReplay?.resourcesReleased = true
            if let current = self.host?.liveASRSnapshot() { self.observeExternalTail(current) }
        }
    }

    private func observeExternalTail(_ snapshot: LiveASRSnapshot) {
        guard !terminal, sameMedia(snapshot), snapshot.loaded, !snapshot.loading else {
            invalidate(reason: .queueAdvance); return
        }
        guard snapshot.audioDelay == 0, snapshot.speed.isFinite, (0.5...2).contains(snapshot.speed) else {
            error = "外置音频结束后的速度或音频延迟超出已验证范围"
            invalidate(reason: .discontinuity); return
        }
        if snapshot.seekGeneration != observedSeekGeneration {
            requestExternalReplay(generation: snapshot.seekGeneration); return
        }
        guard !snapshot.seeking, snapshot.settledSeekGeneration == snapshot.seekGeneration else { return }
        lastSpeed = snapshot.speed; lastPause = snapshot.paused
        guard var replay = externalReplay else { render(snapshot); return }
        guard replay.resourcesReleased, !replay.launchScheduled,
              replay.seekGeneration == snapshot.seekGeneration,
              let now = snapshot.corePosition, now.isFinite, now >= 0 else { return }
        if let end = replay.sourceEnd, now >= end.seconds {
            externalReplay = nil; waitingSeekGeneration = nil; state = .sourceCompleted
            status = "当前位置已越过外置音频已确认的结尾；向前回退后可重新识别"
            return // No restart loop at/beyond this actual accepted source end.
        }
        replay.launchScheduled = true; externalReplay = replay
        let id = replay.id, token = replay.operation, seek = replay.seekGeneration
        Task { [weak self] in
            guard let self, !self.terminal, self.operation == token,
                  self.externalReplay?.id == id, self.externalReplay?.resourcesReleased == true,
                  let fresh = self.host?.liveASRSnapshot(), self.sameMedia(fresh),
                  fresh.loaded, !fresh.loading, !fresh.seeking, fresh.audioDelay == 0,
                  fresh.seekGeneration == seek, fresh.settledSeekGeneration == seek,
                  let position = fresh.corePosition, position.isFinite, position >= 0,
                  replay.sourceEnd == nil || position < replay.sourceEnd!.seconds else { return }
            // start allocates a new pair. The primary load token need not change
            // on a seek; it is freshly read, never invented or copied to wire.
            _ = await self.start(snapshot: fresh)
        }
    }

    private func eligible(_ snapshot: LiveASRSnapshot) throws {
        guard snapshot.loaded, !snapshot.loading, snapshot.binding?.originalURL.isFileURL == true,
              (snapshot.binding?.nativeEntryID ?? -1) >= 0, let selected = snapshot.selectedTrack,
              selected.runtimeAudioID > 0, selected.absoluteFFmpegIndex >= 0,
              selected.absoluteFFmpegIndex <= 4096, snapshot.currentDemuxer == "lavf",
              selected.isExternal == (selected.externalSource != nil),
              !selected.isExternal || (snapshot.rebaseStartTime && selected.absoluteFFmpegIndex == 0 && selected.codec.hasPrefix("pcm_")),
              snapshot.audioDelay == 0, snapshot.speed.isFinite, snapshot.speed >= 0.5, snapshot.speed <= 2,
              snapshot.loadedSourceFingerprint != nil,
              let position = snapshot.corePosition, position.isFinite, position >= 0,
              snapshot.observedUptime.isFinite else {
            throw LiveASRFailure("支持可核实的本地内置音轨或已加载的单音轨 PCM WAV、0.5–2 倍速和零音频延迟")
        }
    }
    private func sameMedia(_ snapshot: LiveASRSnapshot) -> Bool {
        snapshot.binding == binding && snapshot.selectedTrack == track && snapshot.loadedSourceFingerprint == loadedFingerprint
    }
    private func retireRecognitionEpoch() {
        cancelPreparedPair()
        accepting = false; transitionID = UUID(); timeline = LiveASRTimelineLedger(); streamGeneration = 0
        cues.clearPartial(); partialText = ""; _ = clearOwnedOverlay()
        transitionNeeded = true
    }
    private func scheduleTransition(_ snapshot: LiveASRSnapshot, normalizedTarget: Double? = nil, exactNormalizedRange: LiveASRTime? = nil) throws {
        guard !overlayClearFailed else { throw LiveASRFailure("旧字幕层尚未确认清除") }
        guard let job = session, let proof, let position = snapshot.corePosition else { throw LiveASRFailure("识别时间轴尚未就绪") }
        guard desiredEpoch < .max, controlRevision < .max else { throw LiveASRFailure("音频代次达到上限") }
        let rawSeconds = (normalizedTarget ?? position) + (snapshot.rebaseStartTime ? proof.rawOrigin.seconds : 0)
        guard rawSeconds.isFinite, abs(rawSeconds) <= 86_400 else { throw LiveASRFailure("音频定位超过上限") }
        // New local-continuous epochs all share a fresh source history. A user
        // position is a floor; only a proved predecessor endpoint requires equality.
        let normalized: LiveASRTime
        if let exactNormalizedRange { normalized = exactNormalizedRange }
        else {
            let target = normalizedTarget ?? position
            guard target.isFinite, abs(target) <= 86_400 else { throw LiveASRFailure("音频定位超过上限") }
            normalized = try LiveASRTime(Int64((target * 1_000_000).rounded()), 1_000_000)
        }
        let exactRaw = snapshot.rebaseStartTime ? try normalized.adding(proof.rawOrigin) : normalized
        guard exactRaw.denominator <= 1_000_000_000, abs(exactRaw.seconds) <= 86_400 else {
            throw LiveASRFailure("精确源区间超过可处理时基")
        }
        desiredEpoch += 1; transitionID = UUID(); let id = transitionID, epoch = desiredEpoch, process = processID
        controlRevision += 1; let revision = controlRevision
        accepting = true; transitionNeeded = false; timeline = LiveASRTimelineLedger(); streamGeneration = 0
        // These are the intent submitted to this transition, not acknowledgments
        // for any later Core change while its asynchronous controls are pending.
        lastPause = snapshot.paused; lastSpeed = snapshot.speed
        state = .transitioning; status = "正在对齐实际媒体时钟"
        let request = LiveASRTransition(requestID: id, controlRevision: revision, targetEpoch: epoch,
            rawTargetMicroseconds: Int64((rawSeconds * 1_000_000).rounded()), paused: snapshot.paused, speed: snapshot.speed, exactRawRangeStart: exactRaw, exactRangeKind: exactNormalizedRange == nil ? .sourceFloor : .confirmedContinuation)
        Task { [weak self] in
            do {
                try await job.transition(request)
                guard let self, self.transitionID == id, self.processID == process,
                      let current = self.host?.liveASRSnapshot(), self.sameMedia(current),
                      !current.seeking, current.seekGeneration == self.observedSeekGeneration,
                      current.settledSeekGeneration == current.seekGeneration else { return }
                self.state = current.paused ? .paused : .following
                self.status = current.paused ? "已暂停实时字幕" : "正在识别原始已选本地音轨"
                // Reconcile fresh Core intent through the existing real pause
                // control/new-epoch path instead of silently swallowing it.
                self.observe(current)
            } catch {
                guard let self, self.transitionID == id, self.processID == process else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func receive(_ event: LiveASRPipelineEvent, process: UUID) -> LiveASRFeedDecision {
        guard !terminal else { return .stop }
        guard processID == process, session != nil else { return .dropRetired }
        if case .failure(let message) = event { fail(message); return .stop }
        if case .decoderInputLimitReached(let limit) = event {
            guard limit.processID == process, limit.ticket.epoch == desiredEpoch,
                  limit.ticket.itemSerial == itemSerial,
                  let track, track.absoluteFFmpegIndex >= 0,
                  limit.ticket.streamIndex == UInt32(track.absoluteFFmpegIndex),
                  limit.maximumSamples == 1920000, limit.decodedSamples <= limit.maximumSamples,
                  (1...320).contains(limit.nextChunkSamplesNotPublished),
                  limit.decodedSamples + UInt64(limit.nextChunkSamplesNotPublished) > limit.maximumSamples else {
                fail("连续字幕输入限额凭据不属于当前进程与源轨"); return .stop
            }
            // This can arrive before acceptance starts. Latch the real bound;
            // never finalize/drop the ring merely because this notice arrived.
            expectedInputLimit = limit; inputLimit = true; pauseControlToken = UUID()
            inputLimitObservedUptime = ProcessInfo.processInfo.systemUptime
            onInputLimitObserved?(limit)
            return .grant
        }
        if case .externalDecoderReachedEOF(let ticket) = event {
            guard track?.isExternal == true, ticket.epoch == desiredEpoch,
                  ticket.itemSerial == itemSerial, ticket.streamIndex == 0 else { return .dropRetired }
            // This notification may arrive while startup proof/transition is
            // held. It is not a finalization request and never clears the ring.
            decoderEOF = true; return .grant
        }
        guard accepting, let host else { return .dropRetired }
        let snapshot = host.liveASRSnapshot()
        guard sameMedia(snapshot), snapshot.loaded, !snapshot.loading,
              snapshot.audioDelay == 0, snapshot.speed == lastSpeed,
              snapshot.seekGeneration == observedSeekGeneration,
              snapshot.settledSeekGeneration == snapshot.seekGeneration,
              !snapshot.seeking else { return .dropRetired }
        do {
            switch event {
            case .pcmBeforeForward(let frame):
                guard state != .finishing, let track else { return .dropRetired }
                guard frame.ticket.epoch == desiredEpoch, frame.ticket.itemSerial == itemSerial,
                      frame.ticket.streamIndex == UInt32(track.absoluteFFmpegIndex) else { return .dropRetired }
                if snapshot.paused || snapshot.seeking || waitingSeekGeneration != nil { return .hold }
                guard let proof, let now = snapshot.corePosition else { return .hold }
                if frame.ptsKnown {
                    let raw = try frame.rawTime(atSampleOffset: 0)
                    let normalized = snapshot.rebaseStartTime ? try raw.subtracting(proof.rawOrigin) : raw
                    if normalized.seconds > now + 0.5 { return .hold }
                    guard normalized.seconds >= now - 2 else { throw LiveASRFailure("识别输入已落后播放超过两秒") }
                }
                if let expected = continuationFirstSample {
                    guard frame.ptsKnown else { throw LiveASRFailure("连续字幕首块缺少真实 PTS") }
                    let raw = try frame.rawTime(atSampleOffset: 0)
                    let start = snapshot.rebaseStartTime ? try raw.subtracting(proof.rawOrigin) : raw
                    guard start == expected else {
                        throw LiveASRFailure("连续字幕分段首块未接上已确认源区间，未猜测或跳过语音")
                    }
                    continuationFirstSample = nil
                }
                if timeline.ticket != frame.ticket { streamGeneration = 0; cues.clearPartial(); partialText = "" }
                try timeline.grant(frame); return .grant
            case .recognizerStreamCreated(let ticket, let generation, let sequence):
                guard ticket == timeline.ticket, generation > streamGeneration else { return .dropRetired }
                guard sequence > lastServiceSequence else { throw LiveASRFailure("识别服务创建流事件重复") }
                lastServiceSequence = sequence
                streamGeneration = generation; return .grant
            case .recognition(let result):
                guard result.ticket == timeline.ticket, result.epoch == desiredEpoch,
                      result.stream_generation == streamGeneration else { return .dropRetired }
                guard result.sequence > lastServiceSequence else { throw LiveASRFailure("识别事件序号重复") }
                lastServiceSequence = result.sequence
                guard let proof else { return .hold }
                try cues.accept(result, timeline: timeline, proof: proof, rebase: snapshot.rebaseStartTime, processID: processID)
                partialText = cues.partial?.text ?? ""; finalCues = cues.completed; render(snapshot); return .grant
            case .decoderReachedEOF:
                decoderEOF = true; status = "音频输入已结束，等待播放器当前位置"; return .grant
            case .externalDecoderReachedEOF: return .dropRetired // Handled before the acceptance gate.
            case .externalSourceCompleted(let completed):
                guard track?.isExternal == true, !inputLimit, completed.processID == process,
                      completed.sourceEOFTicket == timeline.ticket,
                      completed.acceptedFinal.ticket == timeline.ticket,
                      completed.acceptedFinal.event == "eof_final",
                      completed.acceptedFinal.sequence == lastServiceSequence,
                      completed.acceptedFinal.stream_generation == streamGeneration,
                      completed.acceptedFinal.accepted_samples == timeline.submittedSamples,
                      completed.acceptedFinal.last_input_sequence == timeline.lastSequence,
                      completed.closeResult.confirmed, let proof else {
                    throw LiveASRFailure("外置音频完成凭据不属于当前已接受源前缀")
                }
                try timeline.verifyAccepted(completed.acceptedFinal.accepted_samples,
                    first: completed.acceptedFinal.first_input_sequence, last: completed.acceptedFinal.last_input_sequence)
                if finishTask != nil { return .grant } // Primary EOF owns its existing identical close task.
                externalSourceEnd = try timeline.normalizedTime(atSample: completed.acceptedFinal.accepted_samples,
                    proof: proof, rebase: snapshot.rebaseStartTime)
                guard !completed.diagnosticSnapshot.isEmpty,
                      completed.diagnosticSnapshot.count <= 32 * 1_048_576 else {
                    throw LiveASRFailure("外置音频完成诊断缺失或达到有界容量")
                }
                // Install the receipt-bound snapshot synchronously before
                // sourceCompleted becomes observable; no post-retirement Task.
                lastBackendDiagnostics = completed.diagnosticSnapshot
                externalCompletion = completed; externalTailPresentationAllowed = true
                lastCloseResult = completed.closeResult
                Self.jobs.removeValue(forKey: process) // Receipt is already confirmed/reaped, not a UI assertion.
                cancelPreparedPair()
                session = nil; self.proof = nil; accepting = false; pauseControlToken = UUID()
                cues.clearPartial(); partialText = ""; state = .sourceCompleted
                status = "外置音频已结束，主媒体继续播放；已确定字幕可导出，回退定位可重新识别"
                render(snapshot); return .grant
            case .decoderInputLimitReached: return .dropRetired // Latched before the acceptance gate.
            case .inputLimitSourceCompleted(let completed):
                try acceptInputLimitCompletion(completed, snapshot: snapshot, process: process)
                return .grant
            case .failure(let message): fail(message); return .stop
            }
        } catch { fail(error.localizedDescription); return .stop }
    }

    private func render(_ snapshot: LiveASRSnapshot) {
        guard accepting || rollover != nil || (externalCompletion != nil && externalTailPresentationAllowed && externalReplay == nil),
              let binding, sameMedia(snapshot), let position = snapshot.corePosition else { return }
        if externalCompletion != nil {
            guard snapshot.loaded, !snapshot.loading, !snapshot.seeking,
                  snapshot.audioDelay == 0, snapshot.speed == lastSpeed,
                  snapshot.seekGeneration == observedSeekGeneration,
                  snapshot.settledSeekGeneration == snapshot.seekGeneration else { return }
        }
        // Recognition text normally arrives after its accepted source range.
        // Same-ticket partial/final text may remain visible for up to two source
        // seconds after that range, without moving its cue/export timestamps.
        // Never show future text, or reuse a retired epoch/stream's late text.
        var overlay = cues.overlay(at: position)
        if let partial = cues.partial, partial.processID == processID, partial.epoch == desiredEpoch,
           partial.streamGeneration == streamGeneration,
           partial.start.seconds <= position, position >= partial.end.seconds,
           position - partial.end.seconds <= 2 {
            overlay = LiveASROverlay(plainText: partial.text, isPartial: true)
        } else if overlay == nil, let final = cues.completed.last(where: {
            $0.processID == processID && $0.epoch == desiredEpoch && $0.streamGeneration == streamGeneration &&
            $0.start.seconds <= position && position >= $0.end.seconds &&
            position - $0.end.seconds <= 2
        }) {
            overlay = LiveASROverlay(plainText: final.text, isPartial: false)
        }
        do { try host?.setLiveASROverlay(overlay, owner: owner, binding: binding) }
        catch { fail(error.localizedDescription) }
    }
    // An EOF/limit callback belongs to the session observed before scheduling.
    // A same-stack seek/Stop/replacement must not close the next live session.
    private func scheduleFinalization(requireEOF: Bool) {
        let process = processID, token = operation, epoch = desiredEpoch
        let transition = transitionID, seek = observedSeekGeneration
        Task { [weak self] in
            guard let self, self.processID == process, self.operation == token,
                  self.desiredEpoch == epoch, self.transitionID == transition,
                  self.observedSeekGeneration == seek, self.accepting,
                  self.session?.processID == process,
                  let current = self.host?.liveASRSnapshot(), self.sameMedia(current),
                  current.loaded, !current.loading, !current.seeking,
                  current.audioDelay == 0, current.speed == self.lastSpeed,
                  current.seekGeneration == seek, current.settledSeekGeneration == seek,
                  !requireEOF || current.eof else { return }
            await self.finishForEOF()
        }
    }

    /// Host awaits this before invalidating the old load/advancing the queue.
    /// Concurrent observer/Host EOF calls await the identical close operation.
    /// Only already granted PCM is finalized; new input is rejected while final
    /// recognition events still pass the same live binding/epoch checks.
    func finishForEOF() async {
        guard !terminal else { return }
        if mode == .persistentProvider { await linear?.finishForEOF();return }
        cancelPreparedPair()
        if rollover != nil, session == nil {
            rollover = nil; operation = UUID(); pauseControlToken = UUID()
            _ = clearOwnedOverlay(); cues.clearPartial(); partialText = ""
            let preparationClosed = await retirePreparedPair()
            state = overlayClearFailed || !preparationClosed ? .failed : .idle
            status = overlayClearFailed ? "进程已停止，字幕层未能清除" : preparationClosed ? "当前媒体字幕已完成，可以导出" : "预备识别进程尚未确认释放"
            return
        }
        if session == nil, externalCompletion != nil {
            discardExternalTail(); _ = clearOwnedOverlay()
            let preparationClosed = await retirePreparedPair()
            state = overlayClearFailed || !preparationClosed ? .failed : .idle
            status = overlayClearFailed ? "进程已停止，字幕层未能清除" : "当前媒体字幕已完成，可以导出"
            return // The external pair's actual confirmed receipt remains in lastCloseResult.
        }
        if let finishTask { _ = await finishTask.value; return }
        guard let job = session else { return }
        pauseControlToken = UUID() // Retire pending control errors before closing the pair.
        state = .finishing; status = inputLimit ? "正在完成当前已授权字幕分段" : "正在完成当前媒体字幕"
        let id = processID, token = operation
        let task = Task { await job.close(.finalizeGrantedPCM) }
        finishTask = task
        let preparationClosed = await retirePreparedPair()
        let result = await task.value
        let savedDiagnostics = await job.diagnostics()
        // Exact old-job cleanup may complete after a new operation begins, but
        // no late close receipt may replace the current pair's diagnostics.
        if result.resourcesReleased { Self.jobs.removeValue(forKey: id) }
        guard processID == id, operation == token else { return }
        lastCloseResult = result
        lastBackendDiagnostics = savedDiagnostics
        do { try retainCompletedWire(savedDiagnostics, process: id) }
        catch { self.error = error.localizedDescription }
        accepting = false; session = nil; proof = nil; finishTask = nil
        _ = clearOwnedOverlay(); cues.clearPartial(); partialText = ""
        state = result.resourcesReleased && preparationClosed && !overlayClearFailed && error == nil ? .idle : .failed
        status = overlayClearFailed ? "进程已停止，字幕层未能清除" : result.confirmed ? (inputLimit ? "连续字幕已结束，已确定结果可以导出" : "当前媒体字幕已完成，可以导出") : "识别已结束，请查看关闭结果"
        if !result.confirmed { error = result.detail }
    }
    private func retainCompletedWire(_ raw: Data, process: UUID) throws {
        guard !raw.isEmpty, raw.count <= 32 * 1_048_576,
              let value = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw LiveASRFailure("连续字幕关闭原始凭据无效")
        }
        guard value["captureEnabled"] as? Bool == true else { return } // No normal-user transcript storage.
        guard value["processID"] as? String == process.uuidString else { throw LiveASRFailure("连续字幕关闭原始凭据属于旧进程") }
        if completedPairWire.contains(where: { $0.processID == process }) { return }
        guard completedPairWire.count < 256, completedPairWireBytes + raw.count <= 160 * 1_048_576 else {
            completedPairWireOverflow = true
            throw LiveASRFailure("私有验收原始记录达到有界容量，停止接续而不丢弃证据")
        }
        completedPairWire.append((process, raw)); completedPairWireBytes += raw.count
    }

    private func verifyRolloverWindow(_ target: LiveASRTime, snapshot: LiveASRSnapshot) throws {
        guard let now = snapshot.corePosition, now.isFinite, !snapshot.seeking,
              snapshot.seekGeneration == observedSeekGeneration,
              snapshot.settledSeekGeneration == snapshot.seekGeneration,
              target.seconds >= now - 2, target.seconds <= now + 0.5 else {
            throw LiveASRFailure("连续字幕接续已超出真实播放时钟窗口，已确定字幕仍可导出")
        }
    }
    private func acceptInputLimitCompletion(_ completed: LiveASRInputLimitCompletion,
                                           snapshot: LiveASRSnapshot, process: UUID) throws {
        let final = completed.acceptedFinal, limit = completed.limit
        guard inputLimit, let expected = expectedInputLimit,
              limit.processID == process, expected.processID == process,
              limit.ticket == expected.ticket, limit.maximumSamples == expected.maximumSamples,
              limit.decodedSamples == expected.decodedSamples,
              limit.nextChunkSamplesNotPublished == expected.nextChunkSamplesNotPublished,
              limit.ticket == timeline.ticket, final.ticket == timeline.ticket,
              final.event == "eof_final", final.sequence == lastServiceSequence,
              final.stream_generation == streamGeneration,
              final.accepted_samples == timeline.submittedSamples,
              final.last_input_sequence == timeline.lastSequence,
              completed.closeResult.confirmed, let proof else {
            throw LiveASRFailure("连续字幕完成凭据不属于当前实际授权前缀")
        }
        try timeline.verifyAccepted(final.accepted_samples, first: final.first_input_sequence, last: final.last_input_sequence)
        let target = try timeline.normalizedTime(atSample: final.accepted_samples, proof: proof, rebase: snapshot.rebaseStartTime)
        if let raw = completed.diagnosticCapture {
            try retainCompletedWire(raw, process: process)
            lastBackendDiagnostics = raw
        }
        Self.jobs.removeValue(forKey: process) // Only real confirmed/reaped receipt permits this.
        session = nil; accepting = false; pauseControlToken = UUID()
        lastCloseResult = completed.closeResult; cues.clearPartial(); partialText = ""
        guard completedPairs.count < maximumCompletedPairs else {
            state = .failed; error = "连续字幕会话已到安全容量，请导出后重新开始"; _ = clearOwnedOverlay(); return
        }
        completedPairs.append(["processID": process.uuidString, "owner": owner.uuidString,
            "kind": "input_limit_reached", "epoch": limit.ticket.epoch, "itemSerial": limit.ticket.itemSerial,
            "maximumSamples": limit.maximumSamples, "decodedSamples": limit.decodedSamples,
            "nextChunkSamplesNotPublished": limit.nextChunkSamplesNotPublished,
            "acceptedSamples": final.accepted_samples, "firstInputSequence": final.first_input_sequence,
            "lastInputSequence": final.last_input_sequence, "finalServiceSequence": final.sequence,
            "endNumerator": target.numerator, "endDenominator": target.denominator,
            "confirmed": completed.closeResult.confirmed, "resourcesReleased": completed.closeResult.resourcesReleased,
            "inputLimitObservedUptime": inputLimitObservedUptime as Any? ?? NSNull()])
        if snapshot.eof {
            cancelPreparedPair()
            state = .idle; status = "当前媒体字幕已完成，可以导出"; _ = clearOwnedOverlay(); return
        }
        rollover = Rollover(id: UUID(), operation: operation, oldProcess: process,
            target: target, seekGeneration: observedSeekGeneration, speed: lastSpeed)
        try verifyRolloverWindow(target, snapshot: snapshot)
        state = .rollingOver; status = "正在接续实时字幕，已确定结果保留"
        render(snapshot); observeRollover(snapshot)
    }
    private func observeRollover(_ snapshot: LiveASRSnapshot) {
        guard var plan = rollover, !terminal else { return }
        guard sameMedia(snapshot), snapshot.loaded, !snapshot.loading,
              snapshot.audioDelay == 0, snapshot.speed == plan.speed,
              snapshot.seekGeneration == plan.seekGeneration else {
            invalidate(reason: .discontinuity); return
        }
        if snapshot.eof {
            let id = plan.id, token = plan.operation, process = plan.oldProcess
            Task { [weak self] in
                guard let self, self.rollover?.id == id, self.operation == token, self.processID == process,
                      self.session == nil, let fresh = self.host?.liveASRSnapshot(), self.sameMedia(fresh),
                      fresh.loaded, !fresh.loading, fresh.eof, !fresh.seeking, fresh.audioDelay == 0,
                      fresh.speed == plan.speed, fresh.seekGeneration == plan.seekGeneration,
                      fresh.settledSeekGeneration == plan.seekGeneration else { return }
                await self.finishForEOF()
            }
            return
        }
        guard !snapshot.seeking, snapshot.settledSeekGeneration == plan.seekGeneration, !plan.launchScheduled else { return }
        do { try verifyRolloverWindow(plan.target, snapshot: snapshot) }
        catch { fail(error.localizedDescription); return }
        plan.launchScheduled = true; rollover = plan
        let id = plan.id, token = plan.operation, oldProcess = plan.oldProcess
        Task { [weak self] in
            guard let self, !self.terminal, self.operation == token, self.processID == oldProcess,
                  self.rollover?.id == id, self.session == nil,
                  let fresh = self.host?.liveASRSnapshot(), self.sameMedia(fresh),
                  fresh.loaded, !fresh.loading, !fresh.eof, !fresh.seeking,
                  fresh.audioDelay == 0, fresh.speed == plan.speed,
                  fresh.seekGeneration == plan.seekGeneration, fresh.settledSeekGeneration == plan.seekGeneration else { return }
            let caption = self.captionSessionID
            let started: Bool
            do { started = try self.adoptPreparedPair(plan, snapshot: fresh) }
            catch { self.fail(error.localizedDescription); return }
            if started, self.captionSessionID == caption,
               let index = self.completedPairs.lastIndex(where: { $0["processID"] as? String == oldProcess.uuidString }) {
                self.completedPairs[index]["nextProcessID"] = self.processID.uuidString
                self.completedPairs[index]["nextOwner"] = self.owner.uuidString
            }
        }
    }

    // One owned ready-but-zero-forward pair avoids model/source cold-start at
    // the seam. Preparation never supplies a guessed continuation timestamp.
    private func beginPreparingNextPair(_ snapshot: LiveASRSnapshot) {
        guard !terminal, accepting, session != nil, finishTask == nil,
              !inputLimit, rollover == nil, preparedPair == nil,
              preparationAttempt != transitionID, timeline.submittedSamples > 0,
              [.following, .paused].contains(state), sameMedia(snapshot),
              snapshot.loaded, !snapshot.loading, !snapshot.eof, !snapshot.seeking,
              snapshot.seekGeneration == observedSeekGeneration,
              snapshot.settledSeekGeneration == snapshot.seekGeneration,
              snapshot.speed == lastSpeed, snapshot.audioDelay == 0,
              Self.jobs.count == 1, Self.jobs[processID] != nil else { return }
        preparationAttempt = transitionID
        do {
            try eligible(snapshot)
            guard Self.serial < .max, preparationReceipts.count < 256 else {
                throw LiveASRFailure("连续字幕预备会话达到安全容量")
            }
            Self.serial += 1
            let nextID = UUID(), nextOwner = UUID()
            let request = LiveASROpenRequest(sessionID: nextOwner, processID: nextID,
                itemSerial: Self.serial, initialEpoch: 1, snapshot: snapshot,
                maximumDecodedSeconds: 120, preparedContinuationTransport: true, exactContinuousSourceRanges: true)
            let job = try factory.reserve(request)
            guard job.processID == nextID else { throw LiveASRFailure("预备识别进程保留身份不匹配") }
            let next = PreparedPair(processID: nextID, owner: nextOwner, serial: Self.serial,
                predecessor: processID, operation: operation, snapshot: snapshot, job: job)
            preparedPair = next; Self.jobs[nextID] = job // Register before async setup.
            Task { [weak self] in
                guard let self else { return }
                do {
                    let opened = try await job.start { [weak self] event in
                        guard let self else { return .stop }
                        return await self.receivePrepared(event, process: nextID)
                    }
                    guard self.preparedMatches(next), let current = self.host?.liveASRSnapshot() else {
                        _ = await self.retirePreparedPair(expected: nextID); return
                    }
                    try opened.validate(for: current)
                    let raw = await job.diagnostics()
                    guard self.preparedMatches(next), raw.count <= 32 * 1_048_576,
                          let actual = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                          actual["processID"] as? String == nextID.uuidString,
                          actual["setupFinished"] as? Bool == true,
                          actual["recognizerReady"] as? Bool == true,
                          actual["decoderPaused"] as? Bool == true,
                          (actual["servicePCMBytesWritten"] as? NSNumber)?.uint64Value == 0,
                          (actual["actualEpoch"] as? NSNumber)?.uint64Value == 1,
                          (actual["desiredEpoch"] as? NSNumber)?.uint64Value == 1,
                          (actual["controlReceipts"] as? [[String: Any]] ?? []).contains(where: {
                              $0["event"] as? String == "paused" && ($0["epoch"] as? NSNumber)?.uint64Value == 1
                          }) else { throw LiveASRFailure("预备音轨未证实真实暂停、就绪与零输入") }
                    try self.savePreparedWire(raw, process: nextID)
                    next.readyDiagnostic = raw; next.readyUptime = ProcessInfo.processInfo.systemUptime
                    next.proof = opened
                } catch {
                    let current = self.preparedMatches(next)
                    _ = await self.retirePreparedPair(expected: nextID)
                    if current, self.operation == next.operation, self.processID == next.predecessor {
                        self.fail(error.localizedDescription)
                    }
                }
            }
        } catch { fail(error.localizedDescription) }
    }
    private func preparedMatches(_ next: PreparedPair) -> Bool {
        guard preparedPair === next, !next.cancelled, !terminal,
              operation == next.operation, processID == next.predecessor,
              let current = host?.liveASRSnapshot() else { return false }
        return current.binding == next.snapshot.binding && current.selectedTrack == next.snapshot.selectedTrack
            && current.loadedSourceFingerprint == next.snapshot.loadedSourceFingerprint
            && current.loaded && !current.loading && !current.seeking && !current.eof
            && current.audioDelay == 0 && current.speed == next.snapshot.speed
            && current.seekGeneration == next.snapshot.seekGeneration
            && current.settledSeekGeneration == current.seekGeneration
    }
    private func receivePrepared(_ event: LiveASRPipelineEvent, process: UUID) -> LiveASRFeedDecision {
        guard !terminal else { return .stop }
        // The identical registered pair becomes active only after strong old
        // close and exact handover. Its callback does not capture old tickets.
        if process == processID, session?.processID == process { return receive(event, process: process) }
        guard let next = preparedPair, next.processID == process, !next.cancelled else { return .stop }
        switch event {
        case .pcmBeforeForward: return .hold // No warm audio ever reaches the recognizer.
        case .decoderReachedEOF, .externalDecoderReachedEOF:
            cancelPreparedPair(); return .stop // A short source needs no automatic restart.
        case .failure(let message):
            fail(message); return .stop
        default:
            fail("预备识别会话在授权前产生了不允许的识别或完成事件"); return .stop
        }
    }
    private func cancelPreparedPair() {
        guard let next = preparedPair else { return }
        next.cancelled = true // Synchronous token retirement before any await.
        Task { [weak self] in _ = await self?.retirePreparedPair(expected: next.processID) }
    }
    @discardableResult private func retirePreparedPair(expected: UUID? = nil) async -> Bool {
        guard let next = preparedPair, expected == nil || next.processID == expected else { return true }
        next.cancelled = true
        if next.retirement == nil {
            next.retirementToken = UUID()
            next.retirement = Task { await next.job.close(.cancel) }
        }
        guard let task = next.retirement, let closeToken = next.retirementToken else { return false }
        let result = await task.value
        // All concurrent callers await one close; only this exact slot may
        // publish a receipt/remove its own registered job.
        guard preparedPair === next, next.retirementToken == closeToken else { return result.resourcesReleased && result.confirmed }
        let raw = await next.job.diagnostics()
        guard preparedPair === next, next.retirementToken == closeToken else { return result.resourcesReleased && result.confirmed }
        do { try savePreparedWire(raw, process: next.processID) }
        catch { self.error = error.localizedDescription }
        if !preparationReceipts.contains(where: { $0["closeAttempt"] as? String == closeToken.uuidString }) {
            if preparationReceipts.count >= 256 {
                // A bounded diagnostic failure must not retain a released job.
                error = "连续字幕预备关闭记录达到安全容量"; state = .failed
            } else {
                preparationReceipts.append(["processID": next.processID.uuidString,
                    "closeAttempt": closeToken.uuidString,
                    "predecessor": next.predecessor.uuidString, "kind": "cancelled_preparation",
                    "reservedUptime": next.reservedUptime, "readyUptime": next.readyUptime as Any? ?? NSNull(),
                    "confirmed": result.confirmed, "resourcesReleased": result.resourcesReleased,
                    "forced": result.forcedTermination,
                    "decoderExit": result.decoderNaturalExitCode as Any? ?? NSNull(),
                    "recognizerExit": result.recognizerNaturalExitCode as Any? ?? NSNull()])
            }
        }
        if result.resourcesReleased { Self.jobs.removeValue(forKey: next.processID); preparedPair = nil }
        else {
            // The same exact failed attempt cannot pin Stop forever. Keep its
            // receipt and reserved job; a later user operation gets a new
            // actual close/readback. Old awaiters cannot clear that new attempt.
            next.retirement = nil; next.retirementToken = nil
        }
        if !result.confirmed { error = "预备识别进程尚未确认正常释放"; state = .failed }
        return result.resourcesReleased && result.confirmed
    }
    private func savePreparedWire(_ raw: Data, process: UUID) throws {
        guard !raw.isEmpty, raw.count <= 32 * 1_048_576,
              let value = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              value["processID"] as? String == process.uuidString else {
            throw LiveASRFailure("预备识别凭据缺失或进程身份错误")
        }
        guard value["captureEnabled"] as? Bool == true else { return }
        let previous = preparedPairWire[process]?.count ?? 0
        guard preparedPairWire.count < 256 || previous > 0,
              preparedPairWireBytes - previous + raw.count <= 8 * 1_048_576 else {
            throw LiveASRFailure("私有预备识别凭据达到安全容量，未丢弃所需记录")
        }
        preparedPairWire[process] = raw; preparedPairWireBytes = preparedPairWireBytes - previous + raw.count
    }
    private func adoptPreparedPair(_ plan: Rollover, snapshot: LiveASRSnapshot) throws -> Bool {
        guard let next = preparedPair, preparedMatches(next), next.predecessor == plan.oldProcess,
              let opened = next.proof, let readyUptime = next.readyUptime,
              session == nil, lastCloseResult?.confirmed == true,
              let boundUptime = inputLimitObservedUptime, readyUptime <= boundUptime,
              Self.jobs.count == 1, Self.jobs[next.processID] != nil else {
            throw LiveASRFailure("下一字幕分段尚未证实真实暂停就绪，已确定结果仍可导出")
        }
        try eligible(snapshot); try verifyRolloverWindow(plan.target, snapshot: snapshot)
        try opened.validate(for: snapshot)
        guard let prior = exportProof, prior.fingerprint == opened.fingerprint,
              clearOwnedOverlay() else { throw LiveASRFailure("连续字幕源身份或旧字幕层清理未确认") }
        preparedPair = nil // Ownership moves, never unregister this live pair.
        operation = UUID(); owner = next.owner; processID = next.processID; itemSerial = next.serial
        session = next.job; binding = snapshot.binding; track = snapshot.selectedTrack
        loadedFingerprint = snapshot.loadedSourceFingerprint; proof = opened; exportProof = opened
        desiredEpoch = 1; streamGeneration = 0; lastServiceSequence = 0; controlRevision = 0
        lastSpeed = snapshot.speed; lastPause = snapshot.paused; observedSeekGeneration = snapshot.seekGeneration
        waitingSeekGeneration = nil; transitionNeeded = false; decoderEOF = false; inputLimit = false
        expectedInputLimit = nil; inputLimitObservedUptime = nil; finishTask = nil; continuationFirstSample = plan.target
        timeline = LiveASRTimelineLedger(); partialText = ""; pauseControlToken = UUID()
        rollover = nil; error = nil; lastCloseResult = nil; lastBackendDiagnostics = nil; accepting = true
        if let index = completedPairs.lastIndex(where: { $0["processID"] as? String == plan.oldProcess.uuidString }) {
            completedPairs[index]["preparedReservedUptime"] = next.reservedUptime
            completedPairs[index]["preparedReadyUptime"] = readyUptime
            completedPairs[index]["handoverUptime"] = ProcessInfo.processInfo.systemUptime
        }
        try scheduleTransition(snapshot, exactNormalizedRange: plan.target)
        return true // Actual PAUSE/RANGE/SPEED/RESUME receipts still gate grants.
    }

    private func fail(_ message: String) {
        error = message; invalidate(reason: .discontinuity)
    }
    private func retireCurrent() async -> LiveASRCloseResult {
        accepting = false; transitionID = UUID(); proof = nil; cues.clearPartial(); partialText = ""
        _ = clearOwnedOverlay()
        let old = session ?? Self.jobs[processID]
        session = nil // Retire acceptance before either owned close can suspend.
        _ = await retirePreparedPair()
        guard let old else {
            return LiveASRCloseResult(decoderNaturalExitCode: 0, recognizerNaturalExitCode: 0,
                decoderStdoutEOF: true, recognizerStdoutEOF: true, decoderClosedContexts: 0,
                recognizerLiveStreams: 0, recognizerLiveRecognizers: 0, ownedProcessesReaped: true,
                forcedTermination: false, detail: "本控制器没有保留进程")
        }
        session = nil
        let result = await old.close(.cancel)
        let savedDiagnostics = await old.diagnostics()
        if processID == old.processID { lastBackendDiagnostics = savedDiagnostics }
        if processID == old.processID { lastCloseResult = result }
        if result.resourcesReleased { Self.jobs.removeValue(forKey: old.processID) }
        return result
    }
    private func clearOwnedOverlay() -> Bool {
        let cleared = host?.clearLiveASROverlay(owner: owner) ?? false
        overlayClearFailed = !cleared
        if !cleared { error = "进程已停止，字幕层未能清除" }
        else if error == "进程已停止，字幕层未能清除" { error = nil }
        return cleared
    }
}
