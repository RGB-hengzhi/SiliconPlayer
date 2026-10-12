import Foundation
import Darwin
import CoreFoundation

@MainActor final class LiveASRProcessBackendFactory: LiveASRBackendFactory {
    typealias ConfigurationProvider = @Sendable () async throws -> LiveASRToolsConfiguration
    private let workRootURL: URL
    private let configurationProvider: ConfigurationProvider
    private let captureDiagnostics: Bool
    init(workRootURL: URL, captureDiagnostics: Bool = false, configurationProvider: @escaping ConfigurationProvider) {
        self.workRootURL = workRootURL; self.configurationProvider = configurationProvider
        self.captureDiagnostics = captureDiagnostics
    }
    func reserve(_ request: LiveASROpenRequest) throws -> any LiveASROwnedSession {
        guard request.processID != request.sessionID, request.itemSerial > 0,
              request.initialEpoch > 0, request.maximumDecodedSeconds == 120,
              workRootURL.isFileURL, workRootURL.path.hasPrefix("/") else { throw LiveASRFailure("识别会话保留参数无效") }
        // No model hashing, disk probing or spawn on MainActor.
        return LiveASRProcessSession(request: request, workRootURL: workRootURL, captureDiagnostics: captureDiagnostics, configurationProvider: configurationProvider)
    }
}

/// Concrete candidate implementation; not compiled/applied or run in an App.
/// One actor owns one ffprobe setup job and then one decoder/recognizer pair.
actor LiveASRProcessSession: LiveASROwnedSession {
    nonisolated let processID: UUID
    private let request: LiveASROpenRequest
    private let workURL: URL
    private let workRootURL: URL
    private var workCreated = false
    private let configurationProvider: LiveASRProcessBackendFactory.ConfigurationProvider
    private var probe: LiveASRChildProcess?
    private var capturedSourceProbe: [String: Any]?
    private var decoder: LiveASRChildProcess?
    private var service: LiveASRChildProcess?
    private var setupFinished = false
    private var setupStarted = false
    private var configuration: LiveASRToolsConfiguration?
    private var emit: (@Sendable (LiveASRPipelineEvent) async -> LiveASRFeedDecision)?
    private var pumpTask: Task<Void, Never>?
    private var ticking = false
    private var parser = LiveASRSPCMParser()
    private var decoderLines = LiveASRJSONLines(maximumLine: 65536, maximumTotal: 64 * 1048576)
    private var serviceLines = LiveASRJSONLines(maximumLine: 262144, maximumTotal: 64 * 1048576)
    private var serviceDiagnostics = 0
    private var ring: [LiveASRPCMFrame] = []
    private var ringSamples: UInt64 = 0
    private var packet: LiveASRPCMFrame?
    private var packetOffset = 0
    // Counts bytes actually accepted by write(2), including a partial packet.
    // It is independent of decoded/Host-granted samples and service padding.
    private var servicePCMBytesWritten: UInt64 = 0
    private var parsedSamples: UInt64 = 0
    private var firstFrame: LiveASRPCMFrame?
    private var pendingRangeStart: (epoch: UInt64, target: LiveASRTime, kind: LiveASRSourceRangeKind)?
    private var capturedRangeFirstSample: [String: Any]?
    private var runtimeVerified = false
    private var decoderFingerprint: LiveASRFileFingerprint?
    private var opened: [String: Any]?
    private var ready = false
    private var actualEpoch: UInt64
    private var desiredEpoch: UInt64
    private var userPaused = true
    private var flowHeld = true
    // Continuation pairs catch up through Host grant, not a second nominal
    // wall-clock pace anchor. Each unpaced burst is explicitly pause-drained.
    private var bufferHeld = false
    private var unpacedContinuation: Bool { request.preparedContinuationTransport || request.continuationStart != nil }
    private var decoderPaused = false
    private var latestRevision: UInt64 = 0
    private var latestTransitionRevision: UInt64 = 0
    private var transitioning = false
    private var controlBusy = false
    private var controlBytes: Data?
    private var controlOffset = 0
    private var automaticControl: (paused: Bool, afterSerial: UInt64, submittedUptime: Double)?
    private struct PendingAutomaticWrite {
        let failure: LiveASRChildWriteFailure
        let epoch: UInt64
        let afterSerial: UInt64
        let paused: Bool
        let submittedUptime: Double
        let bytes: Data
        let deadline: Double
    }
    private var pendingAutomaticWrite: PendingAutomaticWrite?
    private var firstPipelineWriteFailure: [String: Any]?
    private var retiredAutomaticWrite: [String: Any]?
    private var failedAutomaticWriteRetirement: [String: Any]?
    private var receiptSerial: UInt64 = 0
    private var receipts: [(serial: UInt64, event: String, epoch: UInt64)] = []
    private var decoderMediaEOF = false
    private var decoderEOFTicket: LiveASRWireTicket?
    private var decoderClosedEpoch: UInt64?
    private var decoderClosedOutputSamples: UInt64?
    private var externalEOFTicket: LiveASRWireTicket?
    private var externalAcceptedFinal: LiveASRRecognitionEvent?
    private var externalEOFClosingStarted: Double?
    private var decoderInputLimit = false
    private var inputLimitReceipt: LiveASRInputLimitReceipt?
    private var inputLimitAcceptedFinal: LiveASRRecognitionEvent?
    private var inputLimitClosingStarted: Double?
    private var decoderClosedContexts: Int?
    private var decoderClosedOK: Bool?
    private var serviceLiveStreams: Int?
    private var serviceLiveRecognizers: Int?
    private var serviceClosedOK: Bool?
    private var serviceInputClosed = false
    private var serviceSequence: UInt64 = 0
    private var closeMode: LiveASRCloseMode?
    private var closeStarted: Double?
    private var cancellationSubmitted = false
    private var terminalError: String?
    private var reportedFailure = false
    private var closedResult: LiveASRCloseResult?
    private let captureDiagnostics: Bool
    private var capturedPCM: [[String: Any]] = []
    private var capturedDecoderEvents: [[String: Any]] = []
    private var capturedServiceLines: [String] = []
    private var diagnosticBytes = 0

    init(request: LiveASROpenRequest, workRootURL: URL, captureDiagnostics: Bool,
         configurationProvider: @escaping LiveASRProcessBackendFactory.ConfigurationProvider) {
        self.request = request; processID = request.processID
        self.workRootURL = workRootURL.standardizedFileURL
        workURL = workRootURL.appendingPathComponent("LiveASR-" + request.processID.uuidString, isDirectory: true)
        self.configurationProvider = configurationProvider
        self.captureDiagnostics = captureDiagnostics
        actualEpoch = request.initialEpoch; desiredEpoch = request.initialEpoch
    }

    func start(emit: @escaping @Sendable (LiveASRPipelineEvent) async -> LiveASRFeedDecision) async throws -> LiveASRSourceProof {
        guard !setupStarted, closeMode == nil else { throw LiveASRFailure("识别会话不能重复打开") }
        setupStarted = true; self.emit = emit
        defer { setupFinished = true }
        do {
            // Provider performs full manifest/model/runtime hashing off MainActor.
            let config = try await configurationProvider()
            guard closeMode == nil else { throw LiveASRFailure("识别预检已取消") }
            guard config.pcmHelperSourceSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  config.supportsGracefulInputLimit else {
                throw LiveASRFailure("当前打包解码器尚未验证显式两分钟输入限额")
            }
            guard !request.exactContinuousSourceRanges || config.supportsExactSourceRange else {
                throw LiveASRFailure("当前解码工具尚未通过精确源区间的实际验证")
            }
            configuration = config
            try prepareWorkDirectory()
            guard let binding = request.snapshot.binding, let track = request.snapshot.selectedTrack,
                  request.snapshot.currentDemuxer == "lavf",
                  track.isExternal == (track.externalSource != nil),
                  let expected = track.externalSource?.fingerprint ?? request.snapshot.loadedSourceFingerprint else {
                throw LiveASRFailure("无法核实当前本地音轨")
            }
            let source = (track.externalSource?.url ?? binding.originalURL).standardizedFileURL
            let info = try await inspectSource(source, selected: track, expected: expected, executable: config.ffprobeURL)
            guard closeMode == nil else { throw LiveASRFailure("识别预检已取消") }
            let requiresFirstBlockHold = info.formatName == "wav" && (track.isExternal || (info.formatStart == nil && info.streamStart == nil))
            guard !requiresFirstBlockHold || config.supportsFirstBlockHold else {
                throw LiveASRFailure("当前解码工具尚未通过短 WAV 首块暂停握手验证")
            }
            var decoderArguments = ["--input", source.path, "--audio-stream", String(track.absoluteFFmpegIndex),
                "--epoch", String(actualEpoch), "--item", String(request.itemSerial), "--max-seconds", "120"]
            if !unpacedContinuation { decoderArguments.append("--paced") }
            if requiresFirstBlockHold { decoderArguments.append("--first-block-hold") }
            decoder = try LiveASRChildProcess(executable: config.pcmDecoderURL,
                arguments: decoderArguments, workURL: workURL)
            try await command("PAUSE \(actualEpoch)", receipt: "paused", epoch: actualEpoch)
            try await waitUntil(timeout: 5) { self.runtimeVerified && self.decoderFingerprint != nil && self.opened != nil }
            guard decoderFingerprint == expected, let opened,
                  number(opened, "selected_stream_index") == Int64(track.absoluteFFmpegIndex),
                  number(opened, "codec_id").map({ $0 > 0 }) == true else { throw LiveASRFailure("真实解码器源身份或音轨不符") }
            let rawFormatStart = try requiredNumber(opened, "format_start_time")
            let rawStreamStart = try requiredNumber(opened, "stream_start_time")
            let origin: LiveASRTime
            let originEvidence: String
            if track.isExternal {
                guard request.snapshot.rebaseStartTime, info.formatName == "wav", track.absoluteFFmpegIndex == 0,
                      info.codec.hasPrefix("pcm_"), (rawFormatStart == .min || rawFormatStart == 0),
                      (rawStreamStart == .min || rawStreamStart == 0),
                      (info.formatStart == nil || info.formatStart == 0), (info.streamStart == nil || info.streamStart == 0) else {
                    throw LiveASRFailure("外置音频首阶段需要单音轨、零起点的 PCM WAV")
                }
                // mpv rebases an external demuxer using that external source's
                // own origin, not the main video's demuxer-start-time. Unknown
                // WAV starts still require an actual first decoded PTS of zero.
                try await command("RESUME \(actualEpoch)", receipt: "resumed", epoch: actualEpoch)
                try await waitUntil(timeout: 2) { self.firstFrame != nil }
                try await command("PAUSE \(actualEpoch)", receipt: "paused", epoch: actualEpoch)
                guard let firstFrame, firstFrame.ptsKnown,
                      try firstFrame.rawTime(atSampleOffset: 0).seconds == 0,
                      firstFrame.ticket.epoch == request.initialEpoch, firstFrame.ticket.streamIndex == 0 else {
                    throw LiveASRFailure("外置 WAV 的真实首个 PCM PTS 未证实为零")
                }
                origin = try LiveASRTime(0, 1)
                originEvidence = "external-PCM-WAV/attach-fingerprint/held-FD-single-stream/actual-first-PCM-zero/mpv-external-rebase"
            } else if rawFormatStart != .min {
                guard let ffprobeStart = info.formatStart, let coreStart = request.snapshot.demuxerStartTime,
                      coreStart.isFinite, abs(ffprobeStart - Double(rawFormatStart) / 1000000) <= 0.001,
                      abs(coreStart - Double(rawFormatStart) / 1000000) <= 0.001 else {
                    throw LiveASRFailure("容器源起点与实际播放器起点不一致")
                }
                origin = try LiveASRTime(rawFormatStart, 1000000)
                originEvidence = "decoder-format-start/ffprobe-held-FD/Core-demuxer-start"
            } else {
                // Real WAV reports both starts missing. Unknown is not zero:
                // require actual first decoded PTS and actual Core zero as well.
                guard rawStreamStart == .min, info.formatName == "wav", info.formatStart == nil,
                      info.streamStart == nil, request.snapshot.demuxerStartTime == 0 else {
                    throw LiveASRFailure("未提供可交叉验证的原始音频起点")
                }
                try await command("RESUME \(actualEpoch)", receipt: "resumed", epoch: actualEpoch)
                try await waitUntil(timeout: 2) { self.firstFrame != nil }
                try await command("PAUSE \(actualEpoch)", receipt: "paused", epoch: actualEpoch)
                guard let firstFrame, firstFrame.ptsKnown, try firstFrame.rawTime(atSampleOffset: 0).seconds == 0,
                      firstFrame.ticket.epoch == request.initialEpoch,
                      firstFrame.ticket.streamIndex == UInt32(track.absoluteFFmpegIndex) else {
                    throw LiveASRFailure("未知 WAV 容器起点未被首个实际 PCM PTS 证实为零")
                }
                origin = try LiveASRTime(0, 1)
                originEvidence = "WAV-unknown-container-start/held-FD/Core-zero/actual-first-PCM-zero"
            }
            guard closeMode == nil else { throw LiveASRFailure("识别打开已取消") }
            service = try LiveASRChildProcess(executable: config.recognizerServiceURL,
                arguments: ["--encoder", config.encoderModelURL.path, "--decoder", config.decoderModelURL.path,
                    "--joiner", config.joinerModelURL.path, "--tokens", config.tokensURL.path], workURL: workURL)
            try await waitUntil(timeout: 15) { self.ready }
            let proof = LiveASRSourceProof(canonicalSourceURL: source, device: expected.device, inode: expected.inode,
                byteCount: expected.byteCount, modificationNanoseconds: expected.modificationNanoseconds,
                actualFFmpegIndex: track.absoluteFFmpegIndex, actualCodec: info.codec, actualSampleRate: info.rate,
                actualChannels: info.channels, rawOrigin: origin, sourceOriginEvidence: originEvidence,
                helperSourceSHA256: config.pcmHelperSourceSHA256,
                decoderLibraryABI: "avformat63/avcodec63/avutil61/swresample7", sourceDescriptorHeld: true)
            try proof.validate(for: request.snapshot)
            // ring remains held. No service PCM reaches it until a new, actual
            // numeric SEEK ACK to the current Core clock has retired startup PCM.
            pumpTask = Task { await self.runPump() }
            return proof
        } catch {
            terminalError = error.localizedDescription; setupFinished = true
            _ = await close(.cancel)
            throw error
        }
    }

    func transition(_ value: LiveASRTransition) async throws {
        if decoderInputLimit || (request.snapshot.selectedTrack?.isExternal == true && (decoderMediaEOF || decoder?.reaped == true)) {
            throw LiveASRFailure("外置音频源已结束，需要新的解码与识别进程对")
        }
        guard closeMode == nil, setupFinished, value.controlRevision > latestRevision,
              value.targetEpoch > desiredEpoch, value.rawTargetMicroseconds >= -86400000000,
              value.rawTargetMicroseconds <= 86400000000,
              value.speed.isFinite, (0.5...2).contains(value.speed) else { throw LiveASRFailure("音频定位控制已失效") }
        latestRevision = value.controlRevision; latestTransitionRevision = value.controlRevision; desiredEpoch = value.targetEpoch
        transitioning = true; userPaused = value.paused; flowHeld = true
        let revision = value.controlRevision
        defer { if latestTransitionRevision == revision { transitioning = false } }
        try await command("PAUSE \(actualEpoch)", receipt: "paused", epoch: actualEpoch)
        try current(revision, transition: true)
        // Discard only whole unforwarded retired packets. A partially written
        // older granted packet keeps its original ticket until it is complete.
        ring.removeAll(); ringSamples = 0
        if let target = value.exactRawRangeStart {
            guard request.exactContinuousSourceRanges, configuration?.supportsExactSourceRange == true,
                  target.denominator <= 1_000_000_000, abs(target.seconds) <= 86_400 else {
                throw LiveASRFailure("连续字幕源区间没有经过实际验证或超过边界")
            }
            pendingRangeStart = (value.targetEpoch, target, value.exactRangeKind)
            capturedRangeFirstSample = nil
            try await command("RANGE \(actualEpoch) \(value.targetEpoch) \(target.numerator) \(target.denominator)", receipt: "epoch_changed", epoch: value.targetEpoch)
            guard let expected = request.snapshot.selectedTrack?.externalSource?.fingerprint ?? request.snapshot.loadedSourceFingerprint,
                  decoderFingerprint == expected, let opened,
                  number(opened, "selected_stream_index") == Int64(request.snapshot.selectedTrack?.absoluteFFmpegIndex ?? -1) else {
                throw LiveASRFailure("重建源区间后的真实持有文件身份不符")
            }
        } else {
            pendingRangeStart = nil
            try await command("SEEK \(actualEpoch) \(value.targetEpoch) \(value.rawTargetMicroseconds)", receipt: "epoch_changed", epoch: value.targetEpoch)
        }
        try current(revision, transition: true)
        try await command("SPEED \(actualEpoch) \(String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value.speed))", receipt: "speed_changed", epoch: actualEpoch)
        try current(revision, transition: true)
        flowHeld = false
        if !userPaused { try await command("RESUME \(actualEpoch)", receipt: "resumed", epoch: actualEpoch); try current(revision, transition: true) }
    }

    func setPaused(_ paused: Bool, epoch: UInt64, controlRevision: UInt64) async throws {
        guard closeMode == nil, epoch == desiredEpoch, controlRevision > latestRevision else { throw LiveASRFailure("旧代次暂停控制已丢弃") }
        latestRevision = controlRevision; userPaused = paused
        // Pause updates intent without invalidating the matching seek. A newer
        // seek supersedes it; no ACK from a previous epoch proves this pause.
        let deadline = uptime + 5
        while transitioning {
            try current(controlRevision)
            guard uptime < deadline else { throw LiveASRFailure("暂停等待定位超时") }
            try await Task.sleep(nanoseconds: 10000000)
        }
        try current(controlRevision)
        guard actualEpoch == epoch else { throw LiveASRFailure("暂停控制未获得相同实际代次") }
        let shouldPause = paused || flowHeld || bufferHeld
        try await command("\(shouldPause ? "PAUSE" : "RESUME") \(actualEpoch)", receipt: shouldPause ? "paused" : "resumed", epoch: actualEpoch)
        try current(controlRevision)
    }
    private func current(_ revision: UInt64, transition: Bool = false) throws {
        guard closeMode == nil, (transition ? latestTransitionRevision : latestRevision) == revision else { throw LiveASRFailure("旧控制请求已被新请求取代") }
    }

    private func command(_ text: String, receipt: String, epoch: UInt64) async throws {
        let deadline = uptime + 2
        while controlBusy {
            guard uptime < deadline, decoder?.reaped != true else { throw LiveASRFailure("音频控制串行等待超时") }
            try await step(); try await Task.sleep(nanoseconds: 10000000)
        }
        guard let decoder, !decoder.reaped, text.utf8.count < 511,
              text.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { throw LiveASRFailure("音频数值控制无效") }
        guard closeMode == nil || text.hasPrefix("CANCEL ") else { throw LiveASRFailure("音频控制已因退出取消") }
        controlBusy = true; defer { controlBusy = false; controlBytes = nil; controlOffset = 0 }
        automaticControl = nil
        let before = receiptSerial
        controlBytes = Data((text + "\n").utf8); controlOffset = 0
        while true {
            try await step()
            if controlBytes != nil, controlOffset == controlBytes!.count,
               receipts.contains(where: { $0.serial > before && $0.event == receipt && $0.epoch == epoch }) { return }
            guard uptime < deadline, !decoder.reaped, terminalError == nil else {
                throw LiveASRFailure(terminalError ?? "音频控制未收到实际 ACK")
            }
            try await Task.sleep(nanoseconds: 10000000)
        }
    }

    private var uptime: Double { ProcessInfo.processInfo.systemUptime }
    private func waitUntil(timeout: Double, predicate: () -> Bool) async throws {
        let deadline = uptime + timeout
        while !predicate() {
            guard closeMode == nil, terminalError == nil, uptime < deadline else {
                throw LiveASRFailure(terminalError ?? "识别预检已取消或超时")
            }
            try await step(); try await Task.sleep(nanoseconds: 10000000)
        }
    }
    private func runPump() async {
        while closedResult == nil {
            do { try await step() }
            catch {
                captureWriteFailure(error)
                terminalError = terminalError ?? error.localizedDescription
                retirePendingAutomaticWriteAsFailure("pump_error")
                if !reportedFailure, let emit { reportedFailure = true; _ = await emit(.failure(terminalError!)) }
                if closeMode == nil { closeMode = .cancel; closeStarted = uptime }
            }
            if closeMode != nil { await advanceClose() }
            try? await Task.sleep(nanoseconds: 10000000)
        }
    }

    /// Fair pipe draining continues during PAUSE, seek, hold and cancellation.
    /// Actor reentrancy cannot process a PCM head twice while awaiting MainActor.
    private func step() async throws {
        guard !ticking else { return }; ticking = true; defer { ticking = false }
        // Setup failure may leave ffprobe pipes with unread bytes. Discard them
        // in bounded fair batches during teardown before claiming its EOF.
        if closeMode != nil, let probe {
            _ = try probe.readOutput(); _ = try probe.readDiagnostic()
        }
        if let decoder {
            // Actual Child.readOutput is bounded to 4 * 16384 bytes. The SPCM
            // parser retains less than 1392 bytes, so one call can complete at
            // most 48 * 320 = 15360 samples. Only admit that call at ring<=16000;
            // even a separate 320-sample service packet totals <=31680<32000.
            // This budget does not depend on pipe capacity or a prompt PAUSE ACK.
            if unpacedContinuation, setupFinished, !transitioning, !controlBusy,
               !decoderInputLimit, !decoderMediaEOF, !decoder.reaped,
               !ring.isEmpty || packet != nil {
                bufferHeld = true
                if !decoderPaused {
                    controlBytes = Data("PAUSE \(actualEpoch)\n".utf8); controlOffset = 0; controlBusy = true
                    automaticControl = (true, receiptSerial, uptime)
                }
            }
            // Consume bounded real terminal receipts and exact native exit
            // before considering a queued flow-control write. This alone does
            // not close the write(2)/exit race: only automatic EPIPE is deferred.
            for chunk in try decoder.readDiagnostic() {
                for line in try decoderLines.append(chunk) { try await decoderEvent(line) }
            }
            try decoder.pollExit(cancel: false, now: uptime)
            if pendingAutomaticWrite == nil {
                if decoder.reaped {
                    controlBytes = nil; controlOffset = 0; controlBusy = false; automaticControl = nil
                } else if let bytes = controlBytes {
                    // A genuine terminal input event retires future automatic
                    // flow commands; it does not acknowledge a requested PAUSE.
                    let terminalAutomatic = automaticControl != nil && (decoderInputLimit || decoderMediaEOF)
                    if !terminalAutomatic {
                        do { try decoder.write(bytes, offset: &controlOffset) }
                        catch let failure as LiveASRChildWriteFailure {
                            captureWriteFailure(failure)
                            guard failure.errorNumber == EPIPE, failure.pid == decoder.pid,
                                  let automaticControl, actualEpoch == desiredEpoch,
                                  closeMode == nil, !transitioning else { throw failure }
                            pendingAutomaticWrite = PendingAutomaticWrite(failure: failure,
                                epoch: actualEpoch, afterSerial: automaticControl.afterSerial,
                                paused: automaticControl.paused, submittedUptime: automaticControl.submittedUptime,
                                bytes: bytes,
                                deadline: min(uptime + 0.5, automaticControl.submittedUptime + 2))
                        }
                    }
                }
            }
            let terminalPrefixParsed = (decoderInputLimit || decoderMediaEOF)
                && decoderClosedEpoch == actualEpoch && decoderClosedOutputSamples == parsedSamples
            let mayReadPCM = !unpacedContinuation || closeMode != nil || transitioning
                || !setupFinished || ringSamples <= 16000 || terminalPrefixParsed
            let outputChunks: [Data]
            if mayReadPCM { outputChunks = try decoder.readOutput() } else { outputChunks = [] }
            for chunk in outputChunks {
                for frame in try parser.append(chunk) {
                    parsedSamples += UInt64(frame.sampleCount)
                    guard parsedSamples <= UInt64(request.maximumDecodedSeconds * 16000),
                          frame.ticket.itemSerial == request.itemSerial else { throw LiveASRFailure("实际 PCM 输入超过本次两分钟范围") }
                    if firstFrame == nil { firstFrame = frame }
                    if captureDiagnostics {
                        guard capturedPCM.count < 16384 else { throw LiveASRFailure("PCM 诊断头达到有界容量") }
                        capturedPCM.append(["epoch": frame.ticket.epoch, "segment": frame.ticket.timingSegment,
                            "item": frame.ticket.itemSerial, "streamIndex": frame.ticket.streamIndex, "flags": frame.flags,
                            "tbNumerator": frame.streamTimeBaseNumerator, "tbDenominator": frame.streamTimeBaseDenominator,
                            "sourceBestEffortTimestamp": frame.sourceBestEffortTimestamp, "pcmPTS": frame.pcmStartTimestamp,
                            "pcmDenominator": frame.pcmTimeDenominator, "delayBefore": frame.delayBeforeConvert,
                            "sequence": frame.sequence, "samples": frame.sampleCount, "inputRate": frame.inputSampleRate,
                            "frameOrdinal": frame.decodedFrameOrdinal, "convertedOffset": frame.offsetInConvertedFrameSamples])
                    }
                    if let track = request.snapshot.selectedTrack, frame.inputSampleRate != UInt32(track.sampleRate) {
                        throw LiveASRFailure("实际解码 PCM 输入率与所选流不符")
                    }
                    // Retired whole packets may be dropped, never relabelled.
                    if frame.ticket.epoch == desiredEpoch, closeMode == nil {
                        if let range = pendingRangeStart, range.epoch == frame.ticket.epoch {
                            let first = try frame.rawTime(atSampleOffset: 0)
                            let difference = try first.subtracting(range.target)
                            guard difference.numerator >= 0,
                                  range.kind != .confirmedContinuation || difference.numerator == 0 else {
                                throw LiveASRFailure("连续字幕首个真实样本未接上已确认源区间")
                            }
                            if captureDiagnostics {
                                capturedRangeFirstSample = ["epoch": frame.ticket.epoch,
                                    "sequence": frame.sequence, "kind": range.kind.rawValue,
                                    "target": [range.target.numerator, range.target.denominator],
                                    "actualFirst": [first.numerator, first.denominator],
                                    "actualDifference": [difference.numerator, difference.denominator]]
                            }
                            pendingRangeStart = nil
                        }
                        ring.append(frame); ringSamples += UInt64(frame.sampleCount)
                        guard ringSamples + UInt64(packet?.sampleCount ?? 0) <= 32000 else {
                            throw LiveASRFailure("暂停音频缓存超过两秒")
                        }
                    }
                }
            }
            if decoder.outputEOF { try parser.finish() }
            if decoder.diagnosticEOF { try decoderLines.finish() }
            try decoder.pollExit(cancel: false, now: uptime)
            try resolveAutomaticWriteRetirement(decoder)
        }
        if let service {
            for chunk in try service.readOutput() { for line in try serviceLines.append(chunk) { try await serviceEvent(line) } }
            for chunk in try service.readDiagnostic() {
                serviceDiagnostics += chunk.count
                guard serviceDiagnostics <= 131072 else { throw LiveASRFailure("识别器 stderr 超过上限") }
            }
            if service.outputEOF { try serviceLines.finish() }
            try service.pollExit(cancel: false, now: uptime)
            if let packet {
                try writeServicePCM(packet.packet, to: service)
                if packetOffset == packet.packet.count { self.packet = nil; packetOffset = 0 }
            }
        }
        // Drain a bounded burst without adding a full pump sleep between a
        // real grant and its first write. At most eight new complete packets
        // plus one already in-flight packet per turn; other pipes remain fair.
        if let service, let emit {
            for _ in 0..<8 {
                guard closeMode == nil, setupFinished, !transitioning, packet == nil,
                      let frame = ring.first else { break }
                ring.removeFirst(); ringSamples -= UInt64(frame.sampleCount)
                let decision = await emit(.pcmBeforeForward(frame))
                switch decision {
                case .grant:
                    guard closeMode == nil, frame.ticket.epoch == desiredEpoch else { continue }
                    packet = frame; packetOffset = 0; flowHeld = false
                    try writeServicePCM(frame.packet, to: service)
                    if packetOffset == frame.packet.count { packet = nil; packetOffset = 0 }
                case .hold:
                    if closeMode == nil, frame.ticket.epoch == desiredEpoch {
                        ring.insert(frame, at: 0); ringSamples += UInt64(frame.sampleCount); flowHeld = true
                    }
                case .dropRetired: continue
                case .stop: closeMode = .cancel; closeStarted = uptime
                }
                if case .hold = decision { break }
                if packet != nil || closeMode != nil { break }
            }
        }
        if unpacedContinuation { bufferHeld = !ring.isEmpty || packet != nil }
        if closeMode == nil, setupFinished, !transitioning, !controlBusy, !decoderInputLimit, !decoderMediaEOF, decoder?.reaped != true,
           !(request.snapshot.selectedTrack?.isExternal == true && externalEOFTicket != nil),
           decoderPaused != (userPaused || flowHeld || bufferHeld) {
            // Only queue the command here. The next ticks read its real receipt;
            // no recursive command wait while ticking is locked.
            controlBytes = Data("\((userPaused || flowHeld || bufferHeld) ? "PAUSE" : "RESUME") \(actualEpoch)\n".utf8)
            controlOffset = 0; controlBusy = true
            automaticControl = (userPaused || flowHeld || bufferHeld, receiptSerial, uptime)
        }
        if let automaticControl, controlBytes != nil, controlOffset == controlBytes!.count,
           receipts.contains(where: { $0.serial > automaticControl.afterSerial && $0.epoch == actualEpoch
               && $0.event == (automaticControl.paused ? "paused" : "resumed") }) {
            controlBytes = nil; controlOffset = 0; controlBusy = false; self.automaticControl = nil
        }
        if let automaticControl, !decoderInputLimit, !decoderMediaEOF, decoder?.reaped != true,
           uptime - automaticControl.submittedUptime > 2 {
            throw LiveASRFailure("真实解码流控未按时确认，未伪造暂停或继续")
        }
        // After genuine source EOF all retained granted packets drain first.
        if closeMode == nil, (decoderMediaEOF || decoderInputLimit), decoder?.outputEOF == true, ring.isEmpty, packet == nil, !serviceInputClosed {
            service?.closeInput(); serviceInputClosed = true
            if decoderInputLimit { inputLimitClosingStarted = uptime }
            else if request.snapshot.selectedTrack?.isExternal == true { externalEOFClosingStarted = uptime }
        }
        try await completeExternalSourceIfReady()
        try await completeInputLimitIfReady()
    }

    /// Do not call close(finalize) while an ungranted ring prefix remains: that
    /// operation deliberately discards it. The natural external path first
    /// grants/writes complete records, delivers stdin EOF, accepts the actual
    /// eof_final, and observes both natural exits. Only then reuse cleanup.
    private func completeExternalSourceIfReady() async throws {
        guard request.snapshot.selectedTrack?.isExternal == true, !decoderInputLimit, closeMode == nil,
              setupFinished, terminalError == nil, let eof = externalEOFTicket,
              eof.epoch == desiredEpoch, eof.itemSerial == request.itemSerial,
              serviceInputClosed, ring.isEmpty, packet == nil else { return }
        if let started = externalEOFClosingStarted, uptime - started > 20 {
            throw LiveASRFailure("外置音频自然结束后的识别收尾超时")
        }
        guard probe != nil, decoder != nil, service != nil,
              [probe, decoder, service].compactMap({ $0 }).allSatisfy({
                  $0.reaped && $0.outputEOF && $0.diagnosticEOF
              }) else { return }
        guard decoderClosedOK == true, serviceClosedOK == true,
              let final = externalAcceptedFinal, final.event == "eof_final",
              final.ticket == eof else { throw LiveASRFailure("外置音频结束未获得当前已接受前缀的真实 final") }
        let completed = result(detail: "外置音频源自然结束；主媒体尚可继续播放")
        guard completed.confirmed else { throw LiveASRFailure("外置音频自然关闭凭据不完整") }
        closeMode = .finalizeGrantedPCM; closeStarted = uptime
        await advanceClose()
        guard let closedResult, closedResult.confirmed else { throw LiveASRFailure("外置音频独占资源尚未确认释放") }
        // Publish the actual final/close snapshot with the completion receipt,
        // before the consumer can retire this job or start another owned pair.
        let snapshot = await diagnostics()
        guard !snapshot.isEmpty, snapshot.count <= 32 * 1_048_576 else {
            throw LiveASRFailure("外置音频完成诊断达到有界容量")
        }
        await publish(.externalSourceCompleted(LiveASRExternalSourceCompletion(processID: processID,
            sourceEOFTicket: eof, acceptedFinal: final, closeResult: closedResult,
            diagnosticSnapshot: snapshot)))
    }

    /// Unlike close(finalize), this path does not drop an ungranted ring. A
    /// paused Host can hold it indefinitely within the existing two-second bound;
    /// the 20s finalization deadline begins only after all real input is forwarded.
    private func completeInputLimitIfReady() async throws {
        guard closeMode == nil, setupFinished, terminalError == nil,
              let limit = inputLimitReceipt, limit.ticket.epoch == desiredEpoch,
              serviceInputClosed, ring.isEmpty, packet == nil else { return }
        if let started = inputLimitClosingStarted, uptime - started > 20 {
            throw LiveASRFailure("连续字幕分段收尾超时")
        }
        guard probe != nil, decoder != nil, service != nil,
              [probe, decoder, service].compactMap({ $0 }).allSatisfy({
                  $0.reaped && $0.outputEOF && $0.diagnosticEOF
              }) else { return }
        guard parsedSamples == limit.decodedSamples,
              decoderClosedOK == true, serviceClosedOK == true,
              let final = inputLimitAcceptedFinal, final.event == "eof_final",
              final.ticket == limit.ticket else {
            throw LiveASRFailure("连续字幕输入限额缺少真实已接受前缀或自然关闭凭据")
        }
        let completed = result(detail: "本分段已到真实输入限额，源媒体尚未声明 EOF")
        guard completed.confirmed else { throw LiveASRFailure("连续字幕分段关闭凭据不完整") }
        closeMode = .finalizeGrantedPCM; closeStarted = uptime
        await advanceClose()
        guard let closedResult, closedResult.confirmed, terminalError == nil else {
            throw LiveASRFailure("连续字幕分段资源尚未确认释放")
        }
        let wire = captureDiagnostics ? await diagnostics() : nil
        guard wire == nil || wire!.count <= 32 * 1_048_576 else {
            throw LiveASRFailure("连续字幕分段私有原始证据达到有界容量")
        }
        await publish(.inputLimitSourceCompleted(LiveASRInputLimitCompletion(limit: limit,
            acceptedFinal: final, closeResult: closedResult, diagnosticCapture: wire)))
    }

    private func decoderEvent(_ line: Data) async throws {
        let fields = try object(line), name = try string(fields, "event")
        if captureDiagnostics, name != "decoded_frame", name != "pcm_chunk" {
            guard capturedDecoderEvents.count < 16384 else { throw LiveASRFailure("解码诊断事件达到有界容量") }
            var observed = fields
            observed["hostObservedUptime"] = uptime // Host receive clock; not the C emission clock.
            capturedDecoderEvents.append(observed)
        }
        if name == "error" {
            terminalError = "解码器错误：" + (fields["category"] as? String ?? "unknown")
            if !reportedFailure, let emit { reportedFailure = true; _ = await emit(.failure(terminalError!)) }
            return // Keep draining following real closed/resource receipts.
        }
        if name == "runtime_versions" {
            let names = ["avformat", "avcodec", "avutil", "swresample"]
            guard let compiled = fields["compiled"] as? [NSNumber], compiled.count == 4,
                  zip(names, compiled).allSatisfy({ number(fields, $0.0) == $0.1.int64Value }),
                  number(fields, "avformat").map({ ($0 >> 16) == 63 }) == true,
                  number(fields, "avcodec").map({ ($0 >> 16) == 63 }) == true,
                  number(fields, "avutil").map({ ($0 >> 16) == 61 }) == true,
                  number(fields, "swresample").map({ ($0 >> 16) == 7 }) == true else { throw LiveASRFailure("真实 FFmpeg ABI 不匹配") }
            runtimeVerified = true; return
        }
        if name == "source_fd_fingerprint" {
            guard fields["nofollow"] as? Bool == true, fields["custom_avio"] as? Bool == true else { throw LiveASRFailure("解码器未使用独占本地 FD") }
            let seconds = try requiredNumber(fields, "mtime_seconds"), nanoseconds = try requiredNumber(fields, "mtime_nanoseconds")
            let product = seconds.multipliedReportingOverflow(by: 1000000000), total = product.partialValue.addingReportingOverflow(nanoseconds)
            guard seconds >= 0, (0..<1000000000).contains(nanoseconds), !product.overflow, !total.overflow,
                  let device = unsigned(fields, "device"), let inode = unsigned(fields, "inode"), let bytes = unsigned(fields, "bytes") else {
                throw LiveASRFailure("真实解码 FD 指纹无效")
            }
            decoderFingerprint = LiveASRFileFingerprint(device: device, inode: inode, byteCount: bytes, modificationNanoseconds: total.partialValue)
        } else if name == "media_opened" { opened = fields }
        if ["paused", "resumed", "epoch_changed", "speed_changed", "cancel_acknowledged", "control_rejected"].contains(name) {
            guard let epoch = unsigned(fields, "epoch"), epoch > 0 else { throw LiveASRFailure("解码控制 ACK 无代次") }
            receiptSerial += 1; receipts.append((receiptSerial, name, epoch))
            if receipts.count > 32 { receipts.removeFirst(receipts.count - 32) }
            if name == "control_rejected" { throw LiveASRFailure("真实解码器拒绝了控制代次") }
            if name == "epoch_changed" { guard epoch > actualEpoch else { throw LiveASRFailure("解码器代次未推进") }; actualEpoch = epoch }
            if name == "paused" { decoderPaused = true }
            if name == "resumed" { decoderPaused = false }
        }
        if name == "media_eof" {
            decoderMediaEOF = true
            if let epoch = unsigned(fields, "epoch"), epoch == actualEpoch,
               let segment = unsigned(fields, "segment"), unsigned(fields, "item") == request.itemSerial,
               let index = request.snapshot.selectedTrack?.absoluteFFmpegIndex {
                decoderEOFTicket = LiveASRWireTicket(epoch: epoch, timingSegment: segment,
                    itemSerial: request.itemSerial, streamIndex: UInt32(index))
            }
            if request.snapshot.selectedTrack?.isExternal == true {
                guard let epoch = unsigned(fields, "epoch"), epoch == actualEpoch,
                      let segment = unsigned(fields, "segment"),
                      unsigned(fields, "item") == request.itemSerial,
                      let index = request.snapshot.selectedTrack?.absoluteFFmpegIndex else {
                    throw LiveASRFailure("外置音频自然 EOF 身份不符")
                }
                let ticket = LiveASRWireTicket(epoch: epoch, timingSegment: segment,
                    itemSerial: request.itemSerial, streamIndex: UInt32(index))
                externalEOFTicket = ticket // Latched even during first-PCM proof setup.
                await publish(.externalDecoderReachedEOF(ticket: ticket))
            } else { await publish(.decoderReachedEOF) }
        }
        if name == "input_limit_reached" {
            guard configuration?.supportsGracefulInputLimit == true, !decoderMediaEOF, inputLimitReceipt == nil,
                  let epoch = unsigned(fields, "epoch"), epoch == actualEpoch, epoch == desiredEpoch,
                  let segment = unsigned(fields, "segment"), unsigned(fields, "item") == request.itemSerial,
                  unsigned(fields, "max_samples") == 1920000,
                  let output = unsigned(fields, "output_samples"), output <= 1920000,
                  let next = unsigned(fields, "next_chunk_samples_not_published"), (1...320).contains(next),
                  output + next > 1920000, let track = request.snapshot.selectedTrack else {
                throw LiveASRFailure("解码输入限额事件不符")
            }
            let receipt = LiveASRInputLimitReceipt(processID: processID,
                ticket: LiveASRWireTicket(epoch: epoch, timingSegment: segment, itemSerial: request.itemSerial,
                    streamIndex: UInt32(track.absoluteFFmpegIndex)), maximumSamples: 1920000,
                decodedSamples: output, nextChunkSamplesNotPublished: UInt32(next))
            inputLimitReceipt = receipt; decoderInputLimit = true
            await publish(.decoderInputLimitReached(receipt))
        }
        if name == "closed" {
            decoderClosedEpoch = unsigned(fields, "epoch")
            decoderClosedOutputSamples = unsigned(fields, "output_samples")
            decoderClosedContexts = number(fields, "remaining_owned_contexts").flatMap(Int.init(exactly:))
            decoderClosedOK = fields["ok"] as? Bool
            guard decoderClosedContexts == 0 else { throw LiveASRFailure("解码器 owned contexts 未释放") }
        }
    }
    private func serviceEvent(_ line: Data) async throws {
        let fields = try object(line), name = try string(fields, "event")
        if captureDiagnostics {
            guard diagnosticBytes + line.count <= 4194304, capturedServiceLines.count < 4096,
                  let text = String(data: line, encoding: .utf8) else { throw LiveASRFailure("识别诊断事件达到有界容量") }
            diagnosticBytes += line.count; capturedServiceLines.append(text)
        }
        guard let sequence = unsigned(fields, "sequence"), sequence > serviceSequence else { throw LiveASRFailure("识别服务事件序号无效") }
        serviceSequence = sequence
        if name == "error" {
            terminalError = "识别器错误：" + (fields["category"] as? String ?? "unknown")
            if !reportedFailure, let emit { reportedFailure = true; _ = await emit(.failure(terminalError!)) }
            return
        }
        if name == "ready" {
            guard unsigned(fields, "epoch") == 0, number(fields, "live_recognizers") == 1,
                  number(fields, "live_streams") == 0 else { throw LiveASRFailure("真实识别服务资源状态无效") }
            ready = true
        } else if name == "stream_created" {
            guard let epoch = unsigned(fields, "epoch"), let segment = unsigned(fields, "timing_segment"),
                  let item = unsigned(fields, "item"), let index = unsigned(fields, "stream_index"), index <= 4096,
                  let generation = unsigned(fields, "stream_generation"), generation > 0,
                  unsigned(fields, "accepted_samples") == 0, unsigned(fields, "first_input_sequence") == 0,
                  number(fields, "live_recognizers") == 1, number(fields, "live_streams") == 1 else { throw LiveASRFailure("新识别流创建凭据无效") }
            await publish(.recognizerStreamCreated(ticket: LiveASRWireTicket(epoch: epoch, timingSegment: segment,
                itemSerial: item, streamIndex: UInt32(index)), generation: generation, serviceSequence: sequence))
        } else if ["partial", "endpoint_final", "eof_final"].contains(name) {
            let event = try LiveASRRecognitionEvent.decode(line)
            let decision = await publish(.recognition(event))
            if request.snapshot.selectedTrack?.isExternal == true, event.event == "eof_final",
               case .grant = decision { externalAcceptedFinal = event }
            if decoderInputLimit, event.event == "eof_final", case .grant = decision {
                inputLimitAcceptedFinal = event
            }
        } else if name == "closed" {
            serviceLiveStreams = number(fields, "live_streams").flatMap(Int.init(exactly:))
            serviceLiveRecognizers = number(fields, "live_recognizers").flatMap(Int.init(exactly:))
            serviceClosedOK = fields["ok"] as? Bool
            guard serviceLiveStreams == 0, serviceLiveRecognizers == 0 else { throw LiveASRFailure("识别器 owned 资源未释放") }
        }
    }
    @discardableResult private func publish(_ event: LiveASRPipelineEvent) async -> LiveASRFeedDecision {
        guard let emit else { return .dropRetired }
        let decision = await emit(event)
        if case .stop = decision {
            if closeMode == nil { closeMode = .cancel; closeStarted = uptime }
        }
        return decision
    }

    func close(_ mode: LiveASRCloseMode) async -> LiveASRCloseResult {
        if let closedResult { return closedResult }
        if !setupStarted { setupFinished = true } // reserved, never spawned
        if closeMode == nil { closeMode = mode; closeStarted = uptime }
        if case .cancel = mode { closeMode = .cancel }
        if case .cancel? = closeMode { retirePendingAutomaticWriteAsFailure("cancel_requested") }
        flowHeld = true; userPaused = true
        // If setup is in an await, its next checkpoint observes closeMode. No
        // reported clean exit until setup is finished and every spawned child is
        // reaped, so a late provider cannot secretly spawn a new child.
        let deadline = uptime + 20
        while closedResult == nil, uptime < deadline {
            do { try await step() }
            catch {
                captureWriteFailure(error)
                terminalError = terminalError ?? error.localizedDescription
                retirePendingAutomaticWriteAsFailure("close_error")
                closeMode = .cancel
            }
            await advanceClose(); try? await Task.sleep(nanoseconds: 10000000)
        }
        if let closedResult { return closedResult }
        return result(detail: "识别 owned 进程或设置预检尚未确认释放；保留会话供再次关闭")
    }
    private func advanceClose() async {
        guard closeMode != nil else { return }
        let elapsed = uptime - (closeStarted ?? uptime)
        let cancelling: Bool = { if case .cancel? = closeMode { return true }; return false }()
        if cancelling { retirePendingAutomaticWriteAsFailure("cancellation_drain") }
        ring.removeAll(); ringSamples = 0
        // A granted but zero-byte packet may be discarded on cancellation.
        // Already partial writes finish the original header/payload first.
        if cancelling, packetOffset == 0 { packet = nil }
        if let decoder, !decoder.reaped, !decoderMediaEOF, !decoderInputLimit, !cancellationSubmitted, !controlBusy {
            controlBytes = Data("CANCEL \(actualEpoch)\n".utf8); controlOffset = 0
            controlBusy = true; cancellationSubmitted = true
            automaticControl = nil
        }
        // Cancellation is an owned signal, not an empty-input EOF. Keep stdin
        // open until the cooperative service has exited; pollExit closes it only
        // after the reserved process/group is reaped. Natural finalization still
        // delivers EOF after every already-granted complete packet.
        if !cancelling, packet == nil, !serviceInputClosed {
            service?.closeInput(); serviceInputClosed = true
        }
        do {
            try probe?.pollExit(cancel: true, now: uptime)
            try decoder?.pollExit(cancel: elapsed > 2, now: uptime)
            // Finish an in-flight original SPCM record before signalling normal
            // cancellation; the existing bounded timeout still handles a stall.
            try service?.pollExit(cancel: (cancelling && packet == nil) || elapsed > 5, now: uptime)
        } catch { terminalError = terminalError ?? error.localizedDescription }
        let processes = [probe, decoder, service].compactMap { $0 }
        guard setupFinished, processes.allSatisfy({ $0.reaped && $0.outputEOF && $0.diagnosticEOF }) else { return }
        let proofOK = (decoder == nil || decoderClosedContexts == 0) && (service == nil || (serviceLiveStreams == 0 && serviceLiveRecognizers == 0))
        guard proofOK else { return }
        let message = terminalError ?? (decoderInputLimit ? "实际输入限额已到达，独占进程已回收" : "独占解码与识别进程已回收")
        closedResult = result(detail: message)
        pumpTask?.cancel(); pumpTask = nil
        // Only this task's private directory, only after all owned children exit.
        if workCreated { try? FileManager.default.removeItem(at: workURL); workCreated = false }
    }
    private func result(detail: String) -> LiveASRCloseResult {
        LiveASRCloseResult(decoderNaturalExitCode: decoder?.exitCode ?? (decoder == nil ? 0 : nil),
            recognizerNaturalExitCode: service?.exitCode ?? (service == nil ? 0 : nil),
            decoderStdoutEOF: decoder?.outputEOF ?? true, recognizerStdoutEOF: service?.outputEOF ?? true,
            decoderClosedContexts: decoder == nil ? 0 : decoderClosedContexts,
            recognizerLiveStreams: service == nil ? 0 : serviceLiveStreams,
            recognizerLiveRecognizers: service == nil ? 0 : serviceLiveRecognizers,
            ownedProcessesReaped: setupFinished && [probe, decoder, service].compactMap({ $0 }).allSatisfy({ $0.reaped && $0.outputEOF && $0.diagnosticEOF }),
            forcedTermination: [probe, decoder, service].compactMap({ $0 }).contains(where: { $0.forced }), detail: detail)
    }
    private func captureWriteFailure(_ error: Error) {
        guard captureDiagnostics, firstPipelineWriteFailure == nil,
              let failure = error as? LiveASRChildWriteFailure else { return }
        firstPipelineWriteFailure = failure.receipt
    }
    private func matchesPendingAutomaticControl(_ pending: PendingAutomaticWrite) -> Bool {
        guard decoder?.pid == pending.failure.pid, let automaticControl else { return false }
        return automaticControl.afterSerial == pending.afterSerial
            && automaticControl.paused == pending.paused
            && automaticControl.submittedUptime == pending.submittedUptime
            && controlBytes == pending.bytes && controlOffset == pending.failure.offsetBefore
    }
    private func retirePendingAutomaticWriteAsFailure(_ reason: String) {
        guard let pending = pendingAutomaticWrite else { return }
        let exactQueuedAutomatic = matchesPendingAutomaticControl(pending)
        if captureDiagnostics, failedAutomaticWriteRetirement == nil {
            var receipt = pending.failure.receipt
            receipt["epoch"] = pending.epoch; receipt["afterSerial"] = pending.afterSerial
            receipt["submittedUptime"] = pending.submittedUptime; receipt["deadline"] = pending.deadline
            receipt["decisionUptime"] = uptime; receipt["reason"] = reason
            receipt["terminalConfirmed"] = false; receipt["resolvedAsSuccess"] = false
            receipt["exactQueuedAutomaticRetired"] = exactQueuedAutomatic
            failedAutomaticWriteRetirement = receipt
        }
        // Retire the old obligation even after a namespace change. Only the
        // matching automatic queue may be released; a new/manual control keeps
        // its own bytes, busy state and ACK obligation. This is failure/cancel,
        // never terminal success or a synthesized PAUSE/RESUME acknowledgement.
        pendingAutomaticWrite = nil
        if exactQueuedAutomatic {
            controlBytes = nil; controlOffset = 0; controlBusy = false; automaticControl = nil
        }
    }
    private func resolveAutomaticWriteRetirement(_ child: LiveASRChildProcess) throws {
        guard let pending = pendingAutomaticWrite else { return }
        if case .cancel? = closeMode {
            retirePendingAutomaticWriteAsFailure("cancellation_drain")
            return
        }
        guard pending.failure.pid == child.pid, pending.epoch == actualEpoch,
              pending.epoch == desiredEpoch, matchesPendingAutomaticControl(pending) else {
            retirePendingAutomaticWriteAsFailure("control_ownership_changed")
            throw pending.failure
        }
        let ticket = decoderInputLimit ? inputLimitReceipt?.ticket : decoderEOFTicket
        let matchingTicket = ticket?.epoch == pending.epoch && ticket?.itemSerial == request.itemSerial
            && ticket?.streamIndex == request.snapshot.selectedTrack.map { UInt32($0.absoluteFFmpegIndex) }
        let terminal = (decoderInputLimit || decoderMediaEOF) && matchingTicket
        if terminal, decoderClosedEpoch == pending.epoch,
           decoderClosedOutputSamples == parsedSamples,
           decoderClosedOK == true, decoderClosedContexts == 0,
           child.reaped, child.exitCode == 0, !child.forced, child.outputEOF, child.diagnosticEOF {
            // Exact real terminal/closed/native-zero/EOF/reap evidence replaces
            // the need to send a now-inapplicable automatic command, never its
            // ACK. All parsed/granted ring packets keep their original tickets.
            if captureDiagnostics {
                var receipt = pending.failure.receipt
                receipt["epoch"] = pending.epoch; receipt["terminalConfirmed"] = true
                receipt["timingSegment"] = ticket?.timingSegment; receipt["itemSerial"] = ticket?.itemSerial
                receipt["streamIndex"] = ticket?.streamIndex; receipt["decodedSamples"] = parsedSamples
                receipt["resolvedUptime"] = uptime; receipt["inputLimit"] = decoderInputLimit
                receipt["mediaEOF"] = decoderMediaEOF; receipt["naturalExitCode"] = child.exitCode
                receipt["stdoutEOF"] = child.outputEOF; receipt["stderrEOF"] = child.diagnosticEOF
                receipt["reaped"] = child.reaped; receipt["closedContexts"] = decoderClosedContexts
                retiredAutomaticWrite = receipt
            }
            pendingAutomaticWrite = nil
            controlBytes = nil; controlOffset = 0; controlBusy = false; self.automaticControl = nil
            return
        }
        guard uptime < pending.deadline else {
            retirePendingAutomaticWriteAsFailure("terminal_proof_deadline")
            throw pending.failure
        }
        // Fair draining/grant/write/owned polling continues on later pump turns.
        // No blocking wait, fabricated control ACK, or service EOF/cancel here.
    }
    private func writeServicePCM(_ bytes: Data, to child: LiveASRChildProcess) throws {
        let before = packetOffset
        defer { servicePCMBytesWritten += UInt64(packetOffset - before) }
        try child.write(bytes, offset: &packetOffset)
    }
    func diagnostics() async -> Data {
        let value: [String: Any] = ["processID": processID.uuidString, "captureEnabled": captureDiagnostics,
            "ownedChildExitDiagnostics": captureDiagnostics ? [probe, decoder, service].compactMap { $0?.exitDiagnostics } : [],
            "controlReceiptSerial": receiptSerial, "decoderPaused": decoderPaused,
            "firstPipelineWriteFailure": firstPipelineWriteFailure as Any? ?? NSNull(),
            "retiredAutomaticControlWrite": retiredAutomaticWrite as Any? ?? NSNull(),
            "failedAutomaticControlWriteRetirement": failedAutomaticWriteRetirement as Any? ?? NSNull(),
            "automaticControlWritePending": pendingAutomaticWrite != nil,
            "recognizerReady": ready, "setupFinished": setupFinished,
            "servicePCMBytesWritten": servicePCMBytesWritten,
            "unpacedContinuation": unpacedContinuation, "bufferHeld": bufferHeld, "ringSamples": ringSamples,
            "controlReceipts": receipts.map { ["serial": $0.serial, "event": $0.event, "epoch": $0.epoch] as [String: Any] },
            "sourceProbe": capturedSourceProbe as Any? ?? NSNull(),
            "lastError": captureDiagnostics ? (terminalError as Any? ?? NSNull()) : NSNull(),
            "parsedRealSamples": parsedSamples, "actualEpoch": actualEpoch, "desiredEpoch": desiredEpoch,
            "serviceSequence": serviceSequence, "runtimeVerified": runtimeVerified,
            "decoderMediaEOF": decoderMediaEOF, "decoderInputLimitReached": decoderInputLimit,
            "inputLimitReceipt": inputLimitReceipt.map { ["epoch": $0.ticket.epoch, "timingSegment": $0.ticket.timingSegment,
                "itemSerial": $0.ticket.itemSerial, "streamIndex": $0.ticket.streamIndex,
                "maximumSamples": $0.maximumSamples, "decodedSamples": $0.decodedSamples,
                "nextChunkSamplesNotPublished": $0.nextChunkSamplesNotPublished] as [String: Any] } as Any? ?? NSNull(),
            "decoderPID": decoder.map { $0.pid as Any } ?? NSNull(), "servicePID": service.map { $0.pid as Any } ?? NSNull(),
            "pcmHeaders": capturedPCM, "decoderEvents": capturedDecoderEvents, "serviceJSONLines": capturedServiceLines,
            "rangeFirstSample": capturedRangeFirstSample as Any? ?? NSNull(),
            "scope": "actual parsed headers/events; no PCM payload, word-alignment or mpv-clock fabrication"]
        return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
    }

    private struct ProbedSource { let codec: String; let rate: Int; let channels: Int; let formatName: String; let formatStart: Double?; let streamStart: Double? }
    private func prepareWorkDirectory() throws {
        guard workRootURL.isFileURL, workRootURL.path.hasPrefix("/"),
              !["", ".", ".."].contains(workRootURL.lastPathComponent),
              workRootURL.user == nil, workRootURL.password == nil, workRootURL.query == nil,
              workRootURL.fragment == nil else { throw LiveASRFailure("私有识别工作目录无效") }
        let parent = workRootURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let parentFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard parentFD >= 0 else { throw LiveASRFailure("无法打开私有识别工作目录父级") }
        defer { Darwin.close(parentFD) }
        if mkdirat(parentFD, workRootURL.lastPathComponent, mode_t(0o700)) != 0, errno != EEXIST {
            throw LiveASRFailure("无法创建私有识别工作目录")
        }
        let rootFD = openat(parentFD, workRootURL.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard rootFD >= 0 else { throw LiveASRFailure("私有识别工作目录不能是符号链接") }
        defer { Darwin.close(rootFD) }
        var value = stat(), fs = statfs()
        guard fstat(rootFD, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              value.st_uid == geteuid(), value.st_mode & mode_t(0o777) == mode_t(0o700),
              fstatfs(rootFD, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw LiveASRFailure("私有识别工作目录需为当前用户0700本地目录")
        }
        // No overwrite, even for a caller-supplied reused process UUID.
        guard mkdirat(rootFD, workURL.lastPathComponent, mode_t(0o700)) == 0 else { throw LiveASRFailure("此识别工作目录身份已经存在") }
        workCreated = true
    }
    private func inspectSource(_ url: URL, selected: LiveASRTrack, expected: LiveASRFileFingerprint, executable: URL) async throws -> ProbedSource {
        guard url.isFileURL, url.path.hasPrefix("/"), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw LiveASRFailure("只能读取当前本地普通媒体") }
        let opened = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw LiveASRFailure("无法打开当前源文件") }
        defer { Darwin.close(opened) }
        var fs = statfs(), before = stat()
        guard fstatfs(opened, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0,
              fstat(opened, &before) == 0, try fingerprint(before) == expected else { throw LiveASRFailure("当前源文件不是匹配的本地 regular FD") }
        let sourceFD = fcntl(opened, F_DUPFD_CLOEXEC, 20)
        guard sourceFD >= 20 else { throw LiveASRFailure("无法保留媒体 FD") }
        defer { Darwin.close(sourceFD) }
        let child = try LiveASRChildProcess(executable: executable,
            arguments: ["-v", "error", "-hide_banner", "-protocol_whitelist", "fd", "-fd", "3", "-probesize", "4194304",
                "-analyzeduration", "5000000", "-show_streams", "-show_format", "-of", "json", "fd:"], workURL: workURL, sourceFD: sourceFD)
        probe = child; child.closeInput()
        var output = Data(), errors = 0, stderrTail = Data()
        var metadataValidated = false
        let started = uptime, deadline = started + 5
        // Verification-only bounded observations. Normal playback stores no
        // probe stderr or source path; this receipt is not a stream-ID guess.
        defer {
            if captureDiagnostics {
                capturedSourceProbe = ["pid": child.pid, "protocol": "fd", "elapsedSeconds": uptime - started,
                    "naturalExitCode": child.exitCode as Any? ?? NSNull(), "reaped": child.reaped,
                    "forcedTermination": child.forced, "stdoutEOF": child.outputEOF,
                    "stderrEOF": child.diagnosticEOF, "stdoutBytes": output.count, "stderrBytes": errors,
                    "deadlineReached": uptime >= deadline, "metadataValidated": metadataValidated,
                    "stderrTail": String(decoding: stderrTail, as: UTF8.self)]
            }
        }
        while !child.reaped || !child.outputEOF || !child.diagnosticEOF {
            for data in try child.readOutput() { guard output.count + data.count <= 2097152 else { throw LiveASRFailure("ffprobe 元数据超过上限") }; output.append(data) }
            for data in try child.readDiagnostic() {
                errors += data.count
                guard errors <= 131072 else { throw LiveASRFailure("ffprobe 错误输出超过上限") }
                if captureDiagnostics { stderrTail.append(data); stderrTail = Data(stderrTail.suffix(4096)) }
            }
            try child.pollExit(cancel: closeMode != nil || uptime >= deadline, now: uptime)
            if uptime >= deadline + 2 { throw LiveASRFailure("独占 ffprobe 未能确认退出") }
            try await Task.sleep(nanoseconds: 10000000)
        }
        guard closeMode == nil, child.exitCode == 0, !child.forced, uptime < deadline,
              fstat(opened, &before) == 0, try fingerprint(before) == expected else { throw LiveASRFailure("源文件预检失败或身份已改变") }
        let fields = try object(output)
        guard let rows = fields["streams"] as? [[String: Any]], rows.count <= 2000,
              rows.filter({ number($0, "index") == Int64(selected.absoluteFFmpegIndex) }).count == 1,
              let stream = rows.first(where: { number($0, "index") == Int64(selected.absoluteFFmpegIndex) }),
              stream["codec_type"] as? String == "audio", let codec = stream["codec_name"] as? String,
              codec == selected.codec, let rateText = stream["sample_rate"] as? String, let rate = Int(rateText), rate == selected.sampleRate,
              number(stream, "channels") == Int64(selected.channels), let format = fields["format"] as? [String: Any],
              let name = format["format_name"] as? String, !name.isEmpty, name.utf8.count <= 256 else {
            throw LiveASRFailure("lavf 所选 ff-index 与真实文件流元数据不一致")
        }
        if selected.isExternal {
            guard rows.count == 1, selected.absoluteFFmpegIndex == 0,
                  number(stream, "index") == 0, name == "wav", codec.hasPrefix("pcm_") else {
                throw LiveASRFailure("外置音频仅支持真实单音轨 PCM WAV，未按扩展名猜测流索引")
            }
        }
        func optionalTime(_ value: Any?) throws -> Double? {
            guard let value else { return nil }
            guard let text = value as? String else { throw LiveASRFailure("ffprobe 时间字段无效") }
            if text == "N/A" { return nil }
            guard let time = Double(text), time.isFinite, abs(time) <= 86400 else { throw LiveASRFailure("ffprobe 时间起点超过界限") }
            return time
        }
        let validated = ProbedSource(codec: codec, rate: rate, channels: selected.channels, formatName: name,
            formatStart: try optionalTime(format["start_time"]), streamStart: try optionalTime(stream["start_time"]))
        metadataValidated = true
        return validated
    }
    private func fingerprint(_ value: stat) throws -> LiveASRFileFingerprint {
        let sec = Int64(value.st_mtimespec.tv_sec), nanos = Int64(value.st_mtimespec.tv_nsec)
        let product = sec.multipliedReportingOverflow(by: 1000000000), total = product.partialValue.addingReportingOverflow(nanos)
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), value.st_size > 0,
              sec >= 0, (0..<1000000000).contains(nanos), !product.overflow, !total.overflow else { throw LiveASRFailure("源文件 regular 指纹无效") }
        return LiveASRFileFingerprint(device: UInt64(UInt32(truncatingIfNeeded: value.st_dev)), inode: UInt64(value.st_ino),
            byteCount: UInt64(value.st_size), modificationNanoseconds: total.partialValue)
    }
    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LiveASRFailure("辅助进程 JSON 结构无效") }
        return value
    }
    private func string(_ fields: [String: Any], _ key: String) throws -> String {
        guard let value = fields[key] as? String, !value.isEmpty, value.utf8.count <= 256 else { throw LiveASRFailure("辅助进程事件字段无效") }; return value
    }
    private func number(_ fields: [String: Any], _ key: String) -> Int64? {
        guard let value = fields[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              let parsed = Int64(value.stringValue) else { return nil }; return parsed
    }
    private func unsigned(_ fields: [String: Any], _ key: String) -> UInt64? {
        guard let value = fields[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }; return UInt64(value.stringValue)
    }
    private func requiredNumber(_ fields: [String: Any], _ key: String) throws -> Int64 {
        guard let value = number(fields, key) else { throw LiveASRFailure("辅助进程整数字段缺失") }; return value
    }
}
