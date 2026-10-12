import Foundation

/// One gate belongs to one reserved actor for its entire lifetime. Closing is
/// synchronous and irreversible; cancelling App termination can create a NEW
/// gate only after the old actor's actual owned resources have been released.
/// The lock makes freeze atomic with a synchronous grant/adoption/spawn. Never
/// await, hash models or perform unbounded work while holding this permit.
final class LiveASRLinearAcceptanceGate: @unchecked Sendable {
    let ticket = UUID()
    private let lock = NSLock()
    private var open = true
    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }; return open
    }
    func close() {
        lock.lock(); defer { lock.unlock() }; open = false
    }
    func withPermit<T>(_ body: () throws -> T) rethrows -> T? {
        lock.lock(); defer { lock.unlock() }
        guard open else { return nil }
        return try body()
    }
}
/// Expected retirement is separate from a real decoder/protocol failure.
/// It never fabricates an ACK or a native/physical release receipt.
struct LiveASRLinearAcceptanceRetired: Error {}

/// Prepared-only ownership policy. No subprocess/I/O/capability claim occurs in
/// this file. Future actors must construct these receipts from the exact child,
/// actual C lines and current Core reads; unit receipts are synthetic only.
struct LiveASRLinearSource: Equatable, Sendable {
    let binding: LiveASRBinding
    let fingerprint: LiveASRFileFingerprint
    let track: LiveASRTrack
    let seekGeneration: UInt64
}
/// The adapter must build this only from an actual long-mode C control event.
/// serial belongs to the provider protocol, not a locally assumed reply.
struct LiveASRLinearPaceReceipt: Sendable {
    enum Command: String, Sendable { case pause, resume, speed }
    let provider: UUID
    let generation: UUID
    let operation: UUID
    let child: UUID
    let ticket: LiveASRWireTicket
    let intentRevision: UInt64
    let controlSerial: UInt64
    let command: Command
    let actualPaused: Bool
    let actualSpeed: Double
}
struct LiveASRLinearSeekReceipt: Sendable {
    let provider: UUID
    let oldGeneration: UUID
    let operation: UUID
    let child: UUID
    let oldTicket: LiveASRWireTicket
    let newTicket: LiveASRWireTicket
    let target: LiveASRTime
    let heldSourceFingerprint: LiveASRFileFingerprint
    let sameSourceDescriptor: Bool
    let codecFlushed: Bool
    let resamplerReset: Bool
    let actualPaused: Bool
    let nextWindowSerial: UInt64
}
struct LiveASRLinearSourceEnd: Sendable {
    let provider: UUID
    let generation: UUID
    let child: UUID
    let ticket: LiveASRWireTicket
    let window: LiveASRLinearWindowID
    /// Actual provider CLOCK_MONOTONIC at the hold, not Host arrival order.
    let observedUptime: Double
    let outputSamples: UInt64
    let lastSequence: UInt64
    let rawEnd: LiveASRTime
    let codecEOF: Bool
    let resamplerDrained: Bool
}
struct LiveASRLinearWindowID: Hashable, Sendable {
    let provider: UUID
    let generation: UUID
    let window: UUID
    let child: UUID
    let serial: UInt64
}
struct LiveASRLinearReady: Sendable {
    let id: LiveASRLinearWindowID
    /// Actual C CLOCK_MONOTONIC at ready, not Host line-arrival time.
    let readyUptime: Double
    let serviceSequence: UInt64
    let liveRecognizers: Int
    let liveStreams: Int
    let writtenBytes: UInt64
    let acceptedSamples: UInt64
}
struct LiveASRLinearBoundary: Sendable {
    let id: LiveASRLinearWindowID
    let ticket: LiveASRWireTicket
    let observedUptime: Double
    let outputSamples: UInt64
    let lastSequence: UInt64
    let rawEnd: LiveASRTime
    let nextRawStart: LiveASRTime
    let nextSamplesHeld: UInt32
}
struct LiveASRLinearNextACK: Sendable {
    let provider: UUID
    let generation: UUID
    let operation: UUID
    let child: UUID
    let ticket: LiveASRWireTicket
    let previousWindow: UInt64
    let nextWindow: UInt64
    let lastSequence: UInt64
    let previousRawEnd: LiveASRTime
    let nextRawStart: LiveASRTime
    let nextWindowOutputBeforeRelease: UInt64
}
struct LiveASRLinearChildClose: Sendable {
    let child: UUID
    let naturalExitCode: Int32?
    let stdoutEOF: Bool
    let stderrEOF: Bool
    let remainingResources: Int?
    let reaped: Bool
    let leaderHeldUntilQuiescent: Bool
    let completeExactGroupSnapshot: Bool
    let forced: Bool
    /// Normal handover additionally requires the actual native zero-resource event.
    var nativeClosedZero: Bool = false
    var resourcesReleased: Bool {
        stdoutEOF && stderrEOF && remainingResources == 0 && reaped
        && leaderHeldUntilQuiescent && completeExactGroupSnapshot
    }
    var clean: Bool { resourcesReleased && naturalExitCode == 0 && !forced && nativeClosedZero }
}
struct LiveASRLinearProviderClose: Sendable {
    let provider: UUID
    let generation: UUID
    let child: LiveASRLinearChildClose
    let heldSourceFDClosed: Bool
    let sourceFingerprintVerified: Bool
    let remainingAVContexts: Int?
    var resourcesReleased: Bool {
        child.resourcesReleased && heldSourceFDClosed && remainingAVContexts == 0
    }
    var clean: Bool { resourcesReleased && child.clean && sourceFingerprintVerified }
}
struct LiveASRLinearPrefix: Sendable {
    let id: LiveASRLinearWindowID
    let ticket: LiveASRWireTicket
    let acceptedSamples: UInt64
    let firstSequence: UInt64
    let lastSequence: UInt64
    let streamGeneration: UInt64
    let finalServiceSequence: UInt64
    let rawEnd: LiveASRTime
    let eofFinal: Bool
    let paddingSamples: UInt64
    let liveStreamsAtFinal: Int
    let liveRecognizersAtFinal: Int
}

/// All components are disjoint physical queued Float32 counts. Source AVFrame
/// input memory and already accepted historical ledger have their own bounds.
struct LiveASRLinearFutureBuffers: Sendable {
    let convertedAndSWRAndRecordCopy: UInt64
    let stdoutUnparsed: UInt64
    let parserIncomplete: UInt64
    let ring: UInt64
    let partialService: UInt64
    let writtenButNotAccepted: UInt64
    func checkedTotal() throws -> UInt64 {
        guard convertedAndSWRAndRecordCopy <= 16000, parserIncomplete <= 319,
              ring <= 4096, partialService <= 320, writtenButNotAccepted <= 4096 else {
            throw LiveASRFailure("长片音频分区缓冲超过原总预算")
        }
        var total: UInt64 = 0
        for value in [convertedAndSWRAndRecordCopy, stdoutUnparsed, parserIncomplete,
                      ring, partialService, writtenButNotAccepted] {
            let next = total.addingReportingOverflow(value)
            guard !next.overflow, next.partialValue <= 32000 else {
                throw LiveASRFailure("长片音频未来样本超过32000总预算")
            }
            total = next.partialValue
        }
        return total
    }
}

struct LiveASRLinearOwnership {
    enum ProviderPhase: String { case reserved, held, publishing, seeking, ending, retiring, released }
    enum WindowPhase: String { case reserved, ready, active, finishing, retiring }
    struct Window {
        let id: LiveASRLinearWindowID
        var phase = WindowPhase.reserved
        var ready: LiveASRLinearReady?
        var ledger = LiveASRTimelineLedger()
        var acceptedSamples: UInt64 = 0
        var lastServiceSequence: UInt64 = 0
        var streamGeneration: UInt64 = 0
        var closeAttempt: UUID?
    }
    let providerID: UUID
    let decoderChildID: UUID
    private(set) var generation = UUID()
    private(set) var operation = UUID()
    private(set) var source: LiveASRLinearSource
    private(set) var phase = ProviderPhase.reserved
    private(set) var windows: [UUID: Window] = [:]
    private(set) var active: UUID?
    private(set) var boundary: LiveASRLinearBoundary?
    private(set) var sourceEnd: LiveASRLinearSourceEnd?
    private(set) var completedPrefix: LiveASRLinearPrefix?
    private(set) var providerCloseAttempt: UUID?
    private(set) var firstFailure: String?
    private var lastActivatedSerial: UInt64 = 0
    private var sourceWindowSerial: UInt64 = 1
    private var sourceTicket: LiveASRWireTicket?
    private var sourceVerified = false
    private var lastSourceSequence: UInt64 = 0
    private var expectedFirstSourceTime: LiveASRTime?
    private var seekTarget: LiveASRTime?
    private var pendingPace: (revision: UInt64, serial: UInt64, command: LiveASRLinearPaceReceipt.Command,
                              paused: Bool, speed: Double, userPaused: Bool)?
    private var lastControlSerial: UInt64 = 0
    private var confirmedIntentRevision: UInt64 = 0
    private var confirmedSpeed: Double = 1
    private var confirmedPaused = true
    var hasOwnedResources: Bool { phase != .released || !windows.isEmpty }
    var acceptsPCM: Bool { phase == .publishing && active != nil && firstFailure == nil && pendingPace == nil && !confirmedPaused && confirmedIntentRevision>0 }
    func currentIntentAllowsGrant(_ revision:UInt64)->Bool {
        firstFailure==nil && sourceVerified && pendingPace==nil && !confirmedPaused &&
        confirmedIntentRevision>0 && revision==confirmedIntentRevision
    }
    init(source: LiveASRLinearSource, providerID: UUID = UUID(), decoderChildID: UUID = UUID()) {
        self.source = source; self.providerID = providerID; self.decoderChildID = decoderChildID
    }
    private mutating func fail(_ message: String) {
        if firstFailure == nil { firstFailure = message }
        phase = .retiring; operation = UUID()
    }
    mutating func providerReady(_ proof: LiveASRSourceProof, snapshot: LiveASRSnapshot,
                                ticket: LiveASRWireTicket, actualPaused: Bool) throws {
        try proof.validate(for: snapshot) // Validates nonnegative stream index before UInt32 conversion.
        guard phase == .reserved, actualPaused, snapshot.speed.isFinite, (0.5...2).contains(snapshot.speed),
              snapshot.loaded, !snapshot.loading, !snapshot.seeking, !snapshot.eof,
              snapshot.settledSeekGeneration == source.seekGeneration, snapshot.audioDelay == 0,
              snapshot.binding == source.binding,
              snapshot.selectedTrack == source.track, snapshot.seekGeneration == source.seekGeneration,
              proof.fingerprint == source.fingerprint,
              ticket.epoch > 0, ticket.itemSerial > 0,
              ticket.streamIndex == UInt32(source.track.absoluteFFmpegIndex) else {
            throw LiveASRFailure("持续解码器出生凭据不符")
        }
        sourceTicket = ticket; sourceVerified = true; phase = .held
        confirmedSpeed = snapshot.speed; confirmedPaused = true
    }
    mutating func reserveWindow(child: UUID = UUID()) throws -> LiveASRLinearWindowID {
        guard sourceVerified, [.held, .publishing].contains(phase),
              windows.count < 2, !windows.values.contains(where: { $0.id.child == child }),
              child != decoderChildID, lastActivatedSerial < .max,
              !windows.values.contains(where: { $0.id.serial == (active==nil ? sourceWindowSerial:lastActivatedSerial+1) }) else {
            throw LiveASRFailure("持续解码器最多保留一个当前和一个预备识别服务")
        }
        let serial = active==nil ? sourceWindowSerial:lastActivatedSerial+1
        let id = LiveASRLinearWindowID(provider: providerID, generation: generation,
                                      window: UUID(), child: child, serial: serial)
        windows[id.window] = Window(id: id)
        return id // Registry reservation precedes any spawn/await.
    }
    mutating func receiveReady(_ receipt: LiveASRLinearReady) throws {
        guard var slot = windows[receipt.id.window], slot.id == receipt.id, slot.phase == .reserved,
              receipt.readyUptime.isFinite, receipt.readyUptime >= 0,
              receipt.serviceSequence > 0, receipt.liveRecognizers == 1,
              receipt.liveStreams == 0, receipt.writtenBytes == 0, receipt.acceptedSamples == 0,
              phase != .retiring, phase != .released else { throw LiveASRFailure("预备识别服务未证实零输入真实就绪") }
        slot.phase = .ready; slot.ready = receipt; slot.lastServiceSequence = receipt.serviceSequence
        windows[slot.id.window] = slot
    }
    /// Caller must also retain the actual C RESUME/NEXT ACK; this method alone
    /// does not send controls or claim a visible renderer/recognizer result.
    mutating func adoptInitial(_ id: LiveASRLinearWindowID) throws {
        guard phase == .held, active == nil, boundary == nil, completedPrefix == nil,
              !confirmedPaused, pendingPace == nil, var slot = windows[id.window], slot.id == id,
              slot.phase == .ready, id.serial == sourceWindowSerial else { throw LiveASRFailure("首次窗口尚未实际解锁") }
        slot.phase = .active; windows[id.window] = slot; active = id.window; phase = .publishing
        lastActivatedSerial = id.serial
    }
    /// Request identity retires the old grant authorization synchronously. A
    /// later matching actual C event settles it; UI intent alone grants nothing.
    mutating func requestPace(revision: UInt64, command: LiveASRLinearPaceReceipt.Command,
                              paused: Bool, speed: Double, userPaused: Bool? = nil) throws -> UInt64 {
        guard firstFailure == nil, sourceVerified, [.held, .publishing].contains(phase),
              pendingPace == nil, speed.isFinite, (0.5...2).contains(speed),
              lastControlSerial < .max,
              (command != .pause || paused), (command != .resume || !paused) else {
            throw LiveASRFailure("持续解码器控制请求不属于当前可用所有权")
        }
        let serial = lastControlSerial + 1
        pendingPace = (revision, serial, command, paused, speed, userPaused ?? paused)
        return serial
    }
    mutating func receivePace(_ receipt: LiveASRLinearPaceReceipt, current: LiveASRSnapshot,
                              currentIntentRevision: UInt64) throws {
        guard let pending = pendingPace, sourceVerified, firstFailure == nil,
              [.held, .publishing].contains(phase), receipt.provider == providerID,
              receipt.generation == generation, receipt.operation == operation,
              receipt.child == decoderChildID, receipt.ticket == sourceTicket,
              receipt.intentRevision == pending.revision, currentIntentRevision == pending.revision,
              receipt.controlSerial == pending.serial, receipt.controlSerial > lastControlSerial,
              receipt.command == pending.command, receipt.actualPaused == pending.paused,
              receipt.actualSpeed == pending.speed, current.speed == pending.speed,
              current.paused == pending.userPaused, current.binding == source.binding,
              current.selectedTrack == source.track, current.seekGeneration == source.seekGeneration,
              current.settledSeekGeneration == source.seekGeneration else {
            throw LiveASRFailure("迟到或不匹配的控制回执不能重新开启grant")
        }
        lastControlSerial = receipt.controlSerial; confirmedSpeed = receipt.actualSpeed
        confirmedPaused = receipt.actualPaused; confirmedIntentRevision = pending.revision; pendingPace = nil
    }
    mutating func retirePaceReply(serial:UInt64,ticket:LiveASRWireTicket,paused:Bool,speed:Double)throws {
        guard let p=pendingPace,p.serial==serial,ticket==sourceTicket,p.paused==paused,p.speed==speed else{throw LiveASRFailure("退役控制不是实际原pending回复")}
        lastControlSerial=serial;confirmedPaused=paused;confirmedSpeed=speed;confirmedIntentRevision=0;pendingPace=nil
    }
    mutating func receiveRetiredControlSerial(serial:UInt64,ticket:LiveASRWireTicket)throws {
        guard phase == .seeking || phase == .retiring,ticket==sourceTicket,serial>=lastControlSerial,
              lastControlSerial<UInt64.max,serial<=lastControlSerial+1 else{throw LiveASRFailure("退役Native控制序号未绑定旧ticket")}
        lastControlSerial=serial;pendingPace=nil;confirmedIntentRevision=0
    }
    mutating func streamCreated(_ id: LiveASRLinearWindowID, ticket: LiveASRWireTicket,
                                generation: UInt64, eventSequence: UInt64) throws {
        guard var slot = windows[id.window], slot.id == id, active == id.window,
              slot.ledger.ticket == ticket, ticket == sourceTicket,
              generation > slot.streamGeneration, eventSequence > slot.lastServiceSequence,
              slot.phase == .active || slot.phase == .finishing else { throw LiveASRFailure("识别流创建属于旧窗口或无真实grant") }
        slot.streamGeneration = generation; slot.lastServiceSequence = eventSequence
        windows[id.window] = slot
    }
    mutating func grant(_ frame: LiveASRPCMFrame, id: LiveASRLinearWindowID,
                        current: LiveASRSnapshot, proof: LiveASRSourceProof,
                        intentRevision: UInt64) throws {
        guard firstFailure == nil, phase == .publishing || phase == .held || phase == .ending,
              current.binding == source.binding, current.selectedTrack == source.track,
              current.loadedSourceFingerprint == source.fingerprint || source.track.isExternal,
              current.seekGeneration == source.seekGeneration,
              current.settledSeekGeneration == source.seekGeneration,
              current.loaded, !current.loading, !current.seeking, !current.paused, (!current.eof || phase == .ending),
              pendingPace == nil, !confirmedPaused, intentRevision == confirmedIntentRevision, current.audioDelay == 0,
              current.speed == confirmedSpeed, (0.5...2).contains(current.speed),
              let now = current.corePosition, now.isFinite,
              active == id.window, var slot = windows[id.window], slot.id == id,
              slot.phase == .active || slot.phase == .finishing,
              frame.ticket == sourceTicket, frame.sequence > lastSourceSequence, frame.ptsKnown else {
            throw LiveASRFailure("持续字幕grant的源/窗口/主播放器意图已改变")
        }
        try proof.validate(for: current)
        let raw = try frame.rawTime(atSampleOffset: 0)
        let normalized = current.rebaseStartTime ? try raw.subtracting(proof.rawOrigin) : raw
        if slot.ledger.submittedSamples == 0 {
            if let first = expectedFirstSourceTime, raw != first {
                throw LiveASRFailure("接续第一块不等于原prefix真实结束时码")
            }
            if let target = seekTarget, try raw.subtracting(target).numerator < 0 {
                throw LiveASRFailure("seek后第一块尚未越过真实目标floor")
            }
        }
        let sampleEnd = slot.ledger.submittedSamples.addingReportingOverflow(UInt64(frame.sampleCount))
        guard normalized.seconds >= now - 2, normalized.seconds <= now + 0.5, !sampleEnd.overflow,
              sampleEnd.partialValue <= 1920000,
              boundary == nil || frame.sequence <= boundary!.lastSequence,
              sourceEnd == nil || frame.sequence <= sourceEnd!.lastSequence else {
            throw LiveASRFailure("持续字幕输入超过原时钟/120秒边界")
        }
        try slot.ledger.grant(frame); lastSourceSequence = frame.sequence; windows[id.window] = slot
        expectedFirstSourceTime = nil; seekTarget = nil
    }
    mutating func actualAccepted(_ id: LiveASRLinearWindowID, ticket: LiveASRWireTicket,
                                generation: UInt64, eventSequence: UInt64,
                                samples: UInt64, first: UInt64, last: UInt64, padding: UInt64) throws {
        guard var slot = windows[id.window], slot.id == id, active == id.window,
              slot.ledger.ticket == ticket, generation == slot.streamGeneration,
              eventSequence > slot.lastServiceSequence, samples >= slot.acceptedSamples,
              padding == 0, slot.phase == .active || slot.phase == .finishing || slot.phase == .retiring else {
            throw LiveASRFailure("识别输入进度回执不属于当前实际服务")
        }
        try slot.ledger.verifyAccepted(samples, first: first, last: last)
        slot.acceptedSamples = samples; slot.lastServiceSequence = eventSequence; windows[id.window] = slot
        // Only this real accepted receipt, never write(2), releases pipe credit.
    }
    mutating func receiveBoundary(_ receipt: LiveASRLinearBoundary) throws {
        guard firstFailure == nil, phase == .publishing, active == receipt.id.window,
              var slot = windows[receipt.id.window], slot.id == receipt.id, slot.phase == .active,
              receipt.ticket == sourceTicket, receipt.outputSamples > 0, receipt.outputSamples <= 1920000,
              receipt.observedUptime.isFinite, receipt.observedUptime >= 0,
              (1...320).contains(receipt.nextSamplesHeld),
              receipt.outputSamples + UInt64(receipt.nextSamplesHeld) > 1920000,
              receipt.nextRawStart == receipt.rawEnd,
              receipt.lastSequence >= slot.ledger.lastSequence else { throw LiveASRFailure("真实provider边界不满足连续seam") }
        boundary = receipt; phase = .held; slot.phase = .finishing; windows[receipt.id.window] = slot
    }
    mutating func beginWindowClose(_ id: LiveASRLinearWindowID) throws -> UUID {
        guard var slot = windows[id.window], slot.id == id else { throw LiveASRFailure("窗口所有权不存在") }
        if let attempt = slot.closeAttempt { return attempt }
        let token = UUID(); slot.closeAttempt = token; slot.phase = .retiring; windows[id.window] = slot
        return token
    }
    /// False means the exact lease remains retryable, not forgotten. A stale
    /// await result cannot reset/clear a newer attempt or a different window.
    @discardableResult mutating func finishWindowClose(_ id: LiveASRLinearWindowID, attempt: UUID,
                                                       close: LiveASRLinearChildClose,
                                                       finalized: LiveASRLinearPrefix?) throws -> Bool {
        guard var slot = windows[id.window], slot.id == id, slot.closeAttempt == attempt else { return false }
        guard close.child == id.child else { throw LiveASRFailure("窗口关闭属于另一真实child") }
        guard close.resourcesReleased else {
            slot.closeAttempt = nil; windows[id.window] = slot; return false
        }
        var validationFailure: Error?
        if let final = finalized, phase == .held || phase == .ending {
            do {
                let expectedSamples = boundary?.outputSamples ?? sourceEnd?.outputSamples
                let expectedEnd = boundary?.rawEnd ?? sourceEnd?.rawEnd
                let expectedLast = boundary?.lastSequence ?? sourceEnd?.lastSequence
                let expectedID = boundary?.id ?? sourceEnd?.window
                guard close.clean, expectedID == id,
                      final.id == id, final.ticket == slot.ledger.ticket, final.ticket == sourceTicket,
                      final.eofFinal, final.liveStreamsAtFinal == 1, final.liveRecognizersAtFinal == 1,
                      final.paddingSamples == 16000, final.acceptedSamples == expectedSamples,
                      final.acceptedSamples == slot.ledger.submittedSamples,
                      final.lastSequence == expectedLast, final.streamGeneration == slot.streamGeneration,
                      final.finalServiceSequence > slot.lastServiceSequence,
                      try slot.ledger.rawTime(atSample: final.acceptedSamples) == expectedEnd,
                      final.rawEnd == expectedEnd else {
                    throw LiveASRFailure("窗口final/真实prefix/强close未闭合")
                }
                try slot.ledger.verifyAccepted(final.acceptedSamples, first: final.firstSequence, last: final.lastSequence)
                completedPrefix = final
            } catch { validationFailure = error }
        } else if active == id.window && phase != .retiring && phase != .seeking {
            validationFailure = LiveASRFailure("当前窗口未取得自然final，不允许连续handover")
        }
        // A proved released child is removed even if its final result is bad.
        // The provider remains owned and grant is retired: no ghost retry lease.
        windows.removeValue(forKey: id.window)
        if active == id.window { active = nil }
        if !close.clean { fail("窗口已释放但没有自然零退出凭据") }
        if let error = validationFailure { fail(error.localizedDescription); throw error }
        return true
    }
    mutating func adoptNext(_ id: LiveASRLinearWindowID, ack: LiveASRLinearNextACK,
                           current: LiveASRSnapshot, proof: LiveASRSourceProof,
                           intentRevision: UInt64) throws {
        guard firstFailure == nil, phase == .held, active == nil,
              let held = boundary, let prior = completedPrefix,
              prior.id == held.id, prior.rawEnd == held.nextRawStart,
              var next = windows[id.window], next.id == id, next.phase == .ready,
              held.id.serial < .max, id.serial == held.id.serial + 1,
              let ready = next.ready, ready.readyUptime <= held.observedUptime,
              ack.provider == providerID, ack.generation == generation, ack.operation == operation,
              ack.child == decoderChildID, ack.ticket == sourceTicket,
              ack.previousWindow == held.id.serial, ack.nextWindow == id.serial,
              ack.lastSequence == held.lastSequence, ack.previousRawEnd == prior.rawEnd,
              ack.nextRawStart == held.nextRawStart, ack.nextWindowOutputBeforeRelease == 0,
              current.binding == source.binding, current.selectedTrack == source.track,
              current.seekGeneration == source.seekGeneration,
              current.settledSeekGeneration == source.seekGeneration,
              current.loaded, !current.loading, !current.seeking, !current.eof, !current.paused,
              pendingPace == nil, !confirmedPaused, intentRevision == confirmedIntentRevision,
              current.speed == confirmedSpeed, current.audioDelay == 0,
              let now = current.corePosition, now.isFinite else { throw LiveASRFailure("下一识别窗口未在真实边界前就绪或旧所有权未关闭") }
        try proof.validate(for: current)
        let normalized = current.rebaseStartTime ? try prior.rawEnd.subtracting(proof.rawOrigin) : prior.rawEnd
        guard normalized.seconds >= now - 2, normalized.seconds <= now + 0.5 else { throw LiveASRFailure("接续超过原2秒lag/0.5秒lead") }
        next.phase = .active; windows[id.window] = next; active = id.window; phase = .publishing
        lastActivatedSerial = id.serial;sourceWindowSerial=id.serial
        expectedFirstSourceTime = prior.rawEnd
        boundary = nil; completedPrefix = nil
    }
    /// Invalidates all old window/control callbacks before any external await.
    /// Adapter must PAUSE the exact decoder and strongly close both services.
    mutating func beginSeek(current: LiveASRSnapshot, target: LiveASRTime? = nil) throws -> UUID {
        guard firstFailure == nil, sourceVerified, [.held, .publishing, .seeking].contains(phase),
              current.binding == source.binding, current.selectedTrack == source.track,
              current.loaded, !current.loading, current.seekGeneration > source.seekGeneration,
              target == nil || (target!.seconds.isFinite && abs(target!.seconds) <= 86400) else {
            throw LiveASRFailure("用户seek必须保留同源真实FD与音轨身份")
        }
        operation = UUID(); phase = .seeking; pendingPace = nil; active = nil
        boundary = nil; completedPrefix = nil; sourceEnd = nil; expectedFirstSourceTime = nil
        seekTarget = target
        for id in Array(windows.keys) { windows[id]?.phase = .retiring }
        return operation
    }
    mutating func bindSeekTarget(_ target: LiveASRTime, current: LiveASRSnapshot) throws {
        guard phase == .seeking, current.binding == source.binding, current.selectedTrack == source.track,
              current.seekGeneration > source.seekGeneration,
              current.settledSeekGeneration == current.seekGeneration, !current.seeking,
              target.seconds.isFinite, abs(target.seconds) <= 86400 else {
            throw LiveASRFailure("seek目标必须来自已settled的实际Core")
        }
        seekTarget = target
    }
    mutating func finishSeek(_ receipt: LiveASRLinearSeekReceipt, current: LiveASRSnapshot,
                             proof: LiveASRSourceProof) throws {
        guard phase == .seeking, firstFailure == nil, windows.isEmpty,
              receipt.provider == providerID, receipt.oldGeneration == generation,
              receipt.operation == operation, receipt.child == decoderChildID,
              receipt.oldTicket == sourceTicket, receipt.target == seekTarget,
              receipt.sameSourceDescriptor, receipt.heldSourceFingerprint == source.fingerprint,
              receipt.codecFlushed, receipt.resamplerReset, receipt.actualPaused,
              sourceWindowSerial < .max, receipt.nextWindowSerial == sourceWindowSerial + 1,
              receipt.newTicket.epoch > receipt.oldTicket.epoch,
              receipt.newTicket.timingSegment > receipt.oldTicket.timingSegment,
              receipt.newTicket.itemSerial == receipt.oldTicket.itemSerial,
              receipt.newTicket.streamIndex == receipt.oldTicket.streamIndex,
              current.binding == source.binding, current.selectedTrack == source.track,
              current.seekGeneration > source.seekGeneration,
              current.settledSeekGeneration == current.seekGeneration,
              current.loaded, !current.loading, !current.seeking, !current.eof,
              current.audioDelay == 0, current.speed.isFinite, (0.5...2).contains(current.speed),
              proof.fingerprint == source.fingerprint else {
            throw LiveASRFailure("seek真实ACK/服务强关闭/同FD凭据未闭合")
        }
        try proof.validate(for: current)
        source = LiveASRLinearSource(binding: source.binding, fingerprint: source.fingerprint,
            track: source.track, seekGeneration: current.seekGeneration)
        generation = UUID(); sourceTicket = receipt.newTicket; phase = .held;sourceWindowSerial=receipt.nextWindowSerial
        confirmedPaused = true; confirmedSpeed = current.speed
        // The C seek ACK commits a fresh logical source window serial, but
        // failed service preparations may retry it with a new child UUID.
        // Global provider sequence/control serial never resets on user seek.
        // New window IDs bind this fresh generation; old awaiters cannot match.
    }
    mutating func alignInitialSource(_ receipt: LiveASRLinearSeekReceipt,
                                      current: LiveASRSnapshot, proof: LiveASRSourceProof) throws {
        guard phase == .held, active == nil,
              windows.values.allSatisfy({$0.phase == .ready && $0.ledger.ticket==nil && $0.acceptedSamples==0}),
              lastActivatedSerial == 0,
              lastSourceSequence == 0, sourceVerified, firstFailure == nil,
              receipt.provider == providerID, receipt.oldGeneration == generation,
              receipt.operation == operation, receipt.child == decoderChildID,
              receipt.oldTicket == sourceTicket, receipt.newTicket.epoch > receipt.oldTicket.epoch,
              receipt.newTicket.timingSegment > receipt.oldTicket.timingSegment,
              receipt.newTicket.itemSerial == receipt.oldTicket.itemSerial,
              receipt.newTicket.streamIndex == receipt.oldTicket.streamIndex,
              receipt.nextWindowSerial == 1, receipt.actualPaused,
              receipt.sameSourceDescriptor, receipt.heldSourceFingerprint == source.fingerprint,
              receipt.codecFlushed, receipt.resamplerReset,
              current.binding == source.binding, current.selectedTrack == source.track,
              current.seekGeneration == source.seekGeneration,
              current.settledSeekGeneration == source.seekGeneration,
              current.loaded, !current.loading, !current.seeking, !current.eof,
              proof.fingerprint == source.fingerprint else { throw LiveASRFailure("初始实际Core对齐不能伪造用户seek") }
        try proof.validate(for: current)
        // Zero-input prepared services keep their child/window IDs. They have no
        // native stream ticket until the first actual SPCM, so the new source
        // ticket is bound before any write without respawning a warm model.
        sourceTicket = receipt.newTicket; seekTarget = receipt.target
        confirmedPaused = true
    }
    mutating func discardUnspawnedWindow(_ id: LiveASRLinearWindowID) throws {
        guard let slot = windows[id.window], slot.id == id, slot.phase == .reserved,
              slot.ready == nil, slot.ledger.ticket == nil, slot.closeAttempt == nil else {
            throw LiveASRFailure("有真实child或ready的窗口不能按未spawn丢弃")
        }
        // Only the concrete adapter's failed initializer-before-child receipt
        // permits this method. A returned ChildProcess must use strong close.
        windows.removeValue(forKey: id.window)
    }
    mutating func receiveSourceEnd(_ receipt: LiveASRLinearSourceEnd) throws {
        guard firstFailure == nil, phase == .publishing, receipt.provider == providerID,
              receipt.generation == generation, receipt.child == decoderChildID,
              receipt.ticket == sourceTicket, receipt.window.window == active,
              var slot = windows[receipt.window.window], slot.id == receipt.window,
              slot.phase == .active, receipt.codecEOF, receipt.resamplerDrained,
              receipt.observedUptime.isFinite, receipt.observedUptime >= 0,
              receipt.outputSamples > 0, receipt.outputSamples <= 1920000,
              receipt.lastSequence >= slot.ledger.lastSequence else {
            throw LiveASRFailure("源EOF必须是实际codec+SWR drain，不能借窗口limit声明")
        }
        sourceEnd = receipt; phase = .ending; slot.phase = .finishing
        windows[receipt.window.window] = slot
        // Remaining already-published packets may still be drained under this
        // namespace; adapter stops new reads once all source-end rows arrive.
    }
    mutating func retireAll() -> UUID {
        operation = UUID(); phase = .retiring; active = nil; pendingPace = nil
        for id in Array(windows.keys) { windows[id]?.phase = .retiring }
        return operation // Tokens retire before any actor await or signal.
    }
    mutating func beginProviderClose() throws -> UUID {
        guard (phase == .retiring || (phase == .ending && completedPrefix != nil)), windows.isEmpty else { throw LiveASRFailure("服务窗口仍有真实所有权，不能忘记provider") }
        if let token = providerCloseAttempt { return token }
        let token = UUID(); providerCloseAttempt = token; return token
    }
    @discardableResult mutating func finishProviderClose(attempt: UUID,
                                                        receipt: LiveASRLinearProviderClose) -> Bool {
        guard providerCloseAttempt == attempt, receipt.provider == providerID,
              receipt.generation == generation, receipt.child.child == decoderChildID else { return false }
        guard receipt.resourcesReleased else { providerCloseAttempt = nil; return false }
        phase = .released; providerCloseAttempt = nil; sourceVerified = false
        if !receipt.clean && firstFailure == nil { firstFailure = "provider已释放但自然exit/FD指纹未确认" }
        return true
    }
}
