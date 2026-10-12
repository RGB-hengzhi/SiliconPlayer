import Foundation
import Darwin
import CoreFoundation
import CryptoKit

/// Prepared concrete I/O actor, not compiled/run/integrated. Factory/resolver
/// must provide fully byte-verified tools; the exact new provider hash is an
/// additional gate, never inferred from an executable name or old capability.
actor LiveASRLinearProcessSession {
    typealias ConfigurationProvider = @Sendable () async throws -> LiveASRToolsConfiguration
    typealias CueConsumer = @Sendable (LiveASRLinearSource, UUID, [LiveASRCue], LiveASRCue?) async -> Void
    typealias CoreProvider = @Sendable () async -> LiveASRSnapshot
    private final class Service {
        let id: LiveASRLinearWindowID
        let child: LiveASRChildProcess
        var lines = LiveASRJSONLines(maximumLine: 262144, maximumTotal: 64 * 1048576)
        var sequence: UInt64 = 0
        var final: LiveASRRecognitionEvent?
        var closed: [String: Any]?
        var inputClosed = false
        var closeBegan: Double?
        var diagnosticsBytes = 0
        var corruptedForClose = false
        var closeSaved = false
        init(id: LiveASRLinearWindowID, child: LiveASRChildProcess) { self.id = id; self.child = child }
    }
    private struct Control {
        let operation: UUID
        let line: Data
        let event: String
        let key: String
        let value: UInt64
        let began: Double
        var offset = 0
        var complete = false
    }
    private struct Journal {
        let fd: Int32
        let serial: UInt64
        var bytes = 0
        var digest = SHA256()
    }
    private let request: LiveASROpenRequest
    private let acceptance: LiveASRLinearAcceptanceGate
    private var acceptanceRetired = false
    private let configurationProvider: ConfigurationProvider
    private let expectedProviderSourceHash: String
    private let cueConsumer: CueConsumer
    private let coreProvider: CoreProvider
    private var workRoot: URL
    private var work: URL
    private let capture: Bool
    private var workCreated = false
    private var setupFinished = false
    private var setupStarted = false
    private var closing = false
    private var closeAttempt: UUID?
    private var closeFlight: (id: UUID, task: Task<LiveASRCloseResult, Never>)?
    private var closeHistory: [[String: Any]] = []
    private var pumpTask: Task<Void, Never>?
    private var handingOver = false
    private var seekWorker: Task<Void,Never>?
    private var seekWorkerID: UUID?
    private var startedReady: LiveASRLinearWindowID?
    private var nativeControlSerial: UInt64 = 0
    private var nativePaused = true
    private var nativeSpeed: Double = 1
    private var confirmedRevision: UInt64 = 0
    private var pendingCueDelivery = false
    private var finalizingCoreEOF = false
    private var coreEOFCompleted = false
    private var config: LiveASRToolsConfiguration?
    private var proof: LiveASRSourceProof?
    private var policy: LiveASRLinearOwnership
    private var snapshot: LiveASRSnapshot
    private var intentRevision: UInt64 = 1
    private var probe: LiveASRChildProcess?
    private var decoder: LiveASRChildProcess?
    private var services: [UUID: Service] = [:]
    private var sourceLines = LiveASRJSONLines(maximumLine: 65536, maximumTotal: 64 * 1048576)
    private var sourceParser = LiveASRSPCMParser()
    private var sourceBacklog: [Data] = []
    private var ring: [LiveASRPCMFrame] = []
    private var ringSamples: UInt64 = 0
    private var packet: LiveASRPCMFrame?
    private var packetOffset = 0
    private var packetBegan: Double?
    private var packetWindow: UUID?
    private var packetPauseBegan: Double?
    private var packetPausedSeconds: Double = 0
    private var packetRetirement: UUID?
    private var writtenPayloadBytes: UInt64 = 0
    private var acceptedPayloadSamples: UInt64 = 0
    private var sourceOpened: [String: Any]?
    private var sourceFingerprint: LiveASRFileFingerprint?
    private var sourceBorn: [String: Any]?
    private var actualPrimed: [String: Any]?
    private var actualStartup: [String: Any]?
    private var actualInitialPauseACK: [String: Any]?
    private var lastActorBudget: [String: Any]?
    private var sourceClosed: [String: Any]?
    private var sourceRuntime: [String: Any]?
    private var prime: LiveASRPCMFrame?
    private var sourceEOF = false
    private var currentTicket: LiveASRWireTicket
    private var currentWindow: UInt64 = 1
    private var control: Control?
    private var receivedControl: [String: Any]?
    private var pendingCredit: (id: LiveASRLinearWindowID, count: UInt64, sequence: UInt64)?
    private var journal: Journal?
    private var journals: [[String: Any]] = []
    private var cueLedger = LiveASRCueLedger()
    private var firstFailure: String?
    private var failureDetails: [String: Any]?
    private var lastBudget: [String: Any]?
    private var callbackOperation = UUID()
    private var closedResources = false
    private var serviceCloseCount:UInt64=0
    private var allNativeServiceZero=true
    private var allServiceNaturalZero=true
    private var anyForced=false
    private var latestMaximumFutureSamples:UInt64=0
    private var discardedControlReceipts:[[String:Any]]=[]
    private var uptime: Double { ProcessInfo.processInfo.systemUptime }
    var hasOwnedResources: Bool { !closedResources }

    init(request: LiveASROpenRequest, workRoot: URL, acceptance: LiveASRLinearAcceptanceGate, capture: Bool = false,
         expectedProviderSourceHash: String, configurationProvider: @escaping ConfigurationProvider,
         coreProvider: @escaping CoreProvider, cueConsumer: @escaping CueConsumer) throws {
        guard let binding = request.snapshot.binding, let track = request.snapshot.selectedTrack,
              let fingerprint = track.externalSource?.fingerprint ?? request.snapshot.loadedSourceFingerprint,
              request.maximumDecodedSeconds == 120, request.initialEpoch > 0, request.itemSerial > 0,
              request.continuationStart == nil,!request.preparedContinuationTransport,!request.exactContinuousSourceRanges,
              expectedProviderSourceHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw LiveASRFailure("长片会话没有真实源/工具输入身份")
        }
        self.request = request; self.workRoot = workRoot; self.acceptance = acceptance; self.capture = capture
        self.configurationProvider = configurationProvider; self.expectedProviderSourceHash = expectedProviderSourceHash
        self.cueConsumer = cueConsumer;self.coreProvider=coreProvider; self.snapshot = request.snapshot
        self.work = workRoot.appendingPathComponent("Linear-" + request.processID.uuidString, isDirectory: true)
        policy = LiveASRLinearOwnership(source: LiveASRLinearSource(binding: binding, fingerprint: fingerprint,
            track: track, seekGeneration: request.snapshot.seekGeneration), providerID: request.processID)
        guard track.absoluteFFmpegIndex >= 0, track.absoluteFFmpegIndex <= 4096 else { throw LiveASRFailure("真实音轨index无效") }
        currentTicket = LiveASRWireTicket(epoch: request.initialEpoch, timingSegment: 0,
            itemSerial: request.itemSerial, streamIndex: UInt32(track.absoluteFFmpegIndex))
    }
    /// isOpen is a cancellation observation only. Every NEW grant/spawn/adopt
    /// uses withPermit so MainActor freeze cannot fall between check and commit.
    @discardableResult private func acceptanceIsCurrent() -> Bool {
        guard acceptance.isOpen else {
            if !acceptanceRetired {
                acceptanceRetired = true
                if !closing {
                    closing = true; _ = policy.retireAll(); callbackOperation = UUID()
                }
                pendingCueDelivery = false
            }
            return false
        }
        return !closing
    }
    private func withAcceptance<T>(_ body: () throws -> T) throws -> T {
        guard let value = try acceptance.withPermit(body) else {
            _ = acceptanceIsCurrent(); throw LiveASRLinearAcceptanceRetired()
        }
        return value
    }
    func start() async throws -> LiveASRSourceProof {
        guard acceptanceIsCurrent() else { throw LiveASRLinearAcceptanceRetired() }
        guard !setupStarted, !closing else { throw LiveASRFailure("长片会话不能重复启动") }
        setupStarted = true; defer { setupFinished = true }
        do {
            let value = try await configurationProvider()
            guard acceptanceIsCurrent() else { throw LiveASRLinearAcceptanceRetired() }
            guard !closing, value.pcmHelperSourceSHA256 == expectedProviderSourceHash else {
                throw LiveASRFailure("当前包不包含所核验持续provider源码")
            }
            config = value; try createWork()
            let metadata = try await inspectSource(value.ffprobeURL)
            guard acceptanceIsCurrent() else { throw LiveASRLinearAcceptanceRetired() }
            guard !closing else { throw LiveASRFailure("长片预检已取消") }
            let sourceURL = policy.source.track.externalSource?.url ?? policy.source.binding.originalURL
            try withAcceptance {
                decoder = try LiveASRChildProcess(executable: value.pcmDecoderURL,
                    arguments: ["--input", sourceURL.path, "--audio-stream", String(policy.source.track.absoluteFFmpegIndex),
                        "--epoch", String(currentTicket.epoch), "--item", String(currentTicket.itemSerial),
                        "--max-seconds", "120", "--persistent-windows", "--paced"], workURL: work)
            }
            try await wait(timeout: 5) { self.sourceOpened != nil && self.sourceFingerprint != nil && self.sourceBorn != nil && self.prime != nil && self.sourceRuntime != nil }
            guard let opened = sourceOpened, let born = sourceBorn, let prime,
                  sourceFingerprint == policy.source.fingerprint,
                  try integer(born,"pid") == Int64(decoder!.pid), try integer(born,"held_fd") >= 0,
                  try unsigned(born,"window")==1,try ticket(born)==currentTicket,
                  try integer(opened,"selected_stream_index") == Int64(policy.source.track.absoluteFFmpegIndex),
                  prime.ticket == currentTicket else { throw LiveASRFailure("持续decoder出生/真实prime/源身份不符") }
            let origin: LiveASRTime
            let originEvidence: String
            let rawStart = try integer(opened,"format_start_time")
            if policy.source.track.isExternal || metadata.formatName == "wav" && rawStart == .min {
                guard metadata.formatName == "wav", metadata.formatStart == nil || metadata.formatStart == 0,
                      metadata.streamStart == nil || metadata.streamStart == 0,
                      try prime.rawTime(atSampleOffset: 0) == LiveASRTime(0,1),
                      policy.source.track.isExternal || snapshot.demuxerStartTime == 0 else {
                    throw LiveASRFailure("WAV未知起点未由真实未发布prime证明零PTS")
                }
                origin = try LiveASRTime(0,1); originEvidence = "heldFD/actual-unpublished-SPCM-prime-zero/ffprobe/Core-rebase"
            } else {
                guard rawStart != .min, let probeStart = metadata.formatStart,
                      let coreStart = snapshot.demuxerStartTime, coreStart.isFinite,
                      abs(probeStart-Double(rawStart)/1e6) <= 0.001,
                      abs(coreStart-Double(rawStart)/1e6) <= 0.001 else { throw LiveASRFailure("真实容器起点与Core不一致") }
                origin = try LiveASRTime(rawStart,1_000_000); originEvidence = "heldFD/ffprobe/native-format-start/Core"
            }
            let p = LiveASRSourceProof(canonicalSourceURL: sourceURL, device: policy.source.fingerprint.device,
                inode: policy.source.fingerprint.inode, byteCount: policy.source.fingerprint.byteCount,
                modificationNanoseconds: policy.source.fingerprint.modificationNanoseconds,
                actualFFmpegIndex: policy.source.track.absoluteFFmpegIndex, actualCodec: metadata.codec,
                actualSampleRate: metadata.rate, actualChannels: metadata.channels, rawOrigin: origin,
                sourceOriginEvidence: originEvidence, helperSourceSHA256: value.pcmHelperSourceSHA256,
                decoderLibraryABI: "avformat63/avcodec63/avutil61/swresample7", sourceDescriptorHeld: true)
            try p.validate(for: snapshot); proof = p
            try withAcceptance { try policy.providerReady(p, snapshot: snapshot, ticket: currentTicket, actualPaused: true) }
            // Warm the recognition service while the unpublished native prime
            // is actually PAUSED. Align from a fresh Core read only after ready;
            // cold model load duration is never guessed as media elapsed time.
            // Verify the C provider's paused state through actual numeric
            // replies before cold service preparation. SPEED first preserves
            // current 0.5...2 user intent without relying on native default1.
            try await pace(.speed,paused:true,speed:snapshot.speed)
            try await pace(.pause,paused:true,speed:snapshot.speed)
            let first=try spawnService();try await wait(timeout:15){self.policy.windows[first.window]?.phase == .ready}
            let fresh=await coreProvider()
            guard acceptanceIsCurrent() else { throw LiveASRLinearAcceptanceRetired() }
            guard !closing,fresh.binding==policy.source.binding,fresh.selectedTrack==policy.source.track,
                  fresh.seekGeneration==policy.source.seekGeneration,!fresh.seeking,!fresh.eof,
                  fresh.observedUptime<=uptime,uptime-fresh.observedUptime<=0.4 else{throw LiveASRFailure("冷启动后真实Core绑定/时钟已改变")}
            snapshot=fresh
            if capture {
                actualStartup = ["kind":"actual-ready-before-core-alignment", "uptime":uptime,
                    "sourcePID":decoder!.pid,"sourceBorn":born,"sourceOpened":opened,
                    "unpublishedPrime":actualPrimed as Any? ?? NSNull(),
                    "serviceWindow":first.window.uuidString,"serviceSerial":first.serial,
                    "serviceReady":policy.windows[first.window]?.phase == .ready,
                    "nativePaused":nativePaused,"actualPauseACK":actualInitialPauseACK as Any? ?? NSNull(),"writtenPayloadBytes":writtenPayloadBytes,
                    "acceptedSamples":acceptedPayloadSamples,"corePosition":fresh.corePosition as Any? ?? NSNull(),
                    "coreObservedUptime":fresh.observedUptime,"corePaused":fresh.paused]
                try record(JSONSerialization.data(withJSONObject:actualStartup!,options:[.sortedKeys]),service:first)
            }
            let target = try rawTarget(snapshot, proof: p)
            guard currentTicket.epoch < .max else { throw LiveASRFailure("源epoch耗尽") }
            let old = currentTicket; let next = old.epoch + 1
            let ack = try await send("LINEAR_SEEK \(old.epoch) \(next) 1 1 \(target.microseconds)", event: "linear_seek_ack", key: "epoch", value: next)
            let receipt = try seekReceipt(ack, old: old, target: target.time)
            try withAcceptance { try policy.alignInitialSource(receipt, current: snapshot, proof: p); currentTicket = receipt.newTicket }
            sourceBacklog.removeAll(); ring.removeAll(); ringSamples = 0; self.prime = nil
            try await pace(.speed, paused: true, speed: snapshot.speed)
            if !snapshot.paused { try await pace(.resume, paused: false, speed: snapshot.speed) }
            try withAcceptance { if snapshot.paused { startedReady=first } else { try policy.adoptInitial(first) } }
            callbackOperation = policy.operation
            pumpTask = Task { await self.runPump() }
            return p
        } catch {
            remember(error); setupFinished = true; _ = await close(); throw error
        }
    }
    /// Host calls with fresh actual Core fields, not cached selected queue row.
    func update(_ value: LiveASRSnapshot, revision: UInt64) async {
        guard acceptanceIsCurrent() else { return }
        guard !closing,revision>=intentRevision,value.observedUptime>=snapshot.observedUptime else { return }
        if packet != nil {
            if value.paused && packetPauseBegan == nil { packetPauseBegan=uptime }
            else if !value.paused,let began=packetPauseBegan { packetPausedSeconds+=uptime-began;packetPauseBegan=nil }
        }
        snapshot = value; intentRevision = revision
        if setupStarted && !setupFinished { return } // start rechecks fresh Core after actual ready
        if value.binding != policy.source.binding || value.selectedTrack != policy.source.track ||
            value.audioDelay != 0 || !value.loaded || value.loading {
            closing = true; _ = policy.retireAll(); callbackOperation = UUID(); return
        }
        if value.seekGeneration > policy.source.seekGeneration {
            do {
                try withAcceptance { _ = try policy.beginSeek(current:value);callbackOperation=UUID() }
                if seekWorker==nil {
                    let worker=UUID();seekWorkerID=worker
                    seekWorker=Task{await self.runSeekWorker(worker)}
                }
            } catch { remember(error); closing=true;_ = policy.retireAll() }
        } else if value.eof { return }
        else if value.speed.isFinite && (0.5...2).contains(value.speed) && control == nil &&
                    (confirmedRevision != revision || nativeSpeed != value.speed || nativePaused != value.paused) {
            // Native ACK and policy revision are settled even if numerical speed
            // repeats; grant cannot retain authorization from an older intent.
            do {
                if nativeSpeed != value.speed { try await pace(.speed,paused: nativePaused,speed: value.speed) }
                try await pace(value.paused ? .pause : .resume, paused: value.paused, speed: value.speed)
                if !snapshot.paused,let id=startedReady,policy.phase == .held,policy.active==nil {
                    try withAcceptance { try policy.adoptInitial(id);startedReady=nil }
                }
            }
            catch { remember(error); closing = true; _ = policy.retireAll() }
        }
    }
    private func pace(_ kind: LiveASRLinearPaceReceipt.Command, paused: Bool, speed: Double) async throws {
        let revision = intentRevision, operation = policy.operation
        let serial = try withAcceptance { try policy.requestPace(revision: revision, command: kind, paused: paused, speed: speed, userPaused: snapshot.paused) }
        let name = kind.rawValue.uppercased()
        let body = kind == .speed ? "CONTROL \(currentTicket.epoch) \(serial) SPEED \(speed)" : "CONTROL \(currentTicket.epoch) \(serial) \(name)"
        let ack = try await send(body,event: "control_ack",key: "control_serial",value: serial)
        guard operation == policy.operation else { return }
        if revision != intentRevision {
            try policy.retirePaceReply(serial:serial,ticket:try ticket(ack),paused:try boolean(ack,"paused"),speed:try real(ack,"speed"))
            return
        }
        try withAcceptance { try policy.receivePace(LiveASRLinearPaceReceipt(provider: policy.providerID, generation: policy.generation,
            operation: operation, child: policy.decoderChildID, ticket: try ticket(ack), intentRevision: revision,
            controlSerial: serial, command: kind, actualPaused: try boolean(ack,"paused"), actualSpeed: try real(ack,"speed")),
            current: snapshot, currentIntentRevision: intentRevision)
        nativeControlSerial = serial; nativePaused = try boolean(ack,"paused"); nativeSpeed = try real(ack,"speed")
        if kind == .pause,actualInitialPauseACK==nil{actualInitialPauseACK=ack}
        confirmedRevision = revision
        }
    }
    private func spawnService() throws -> LiveASRLinearWindowID {
        try withAcceptance {
            guard let config, !closing else { throw LiveASRFailure("服务准备已取消") }
            let id = try policy.reserveWindow()
            do {
                let child = try LiveASRChildProcess(executable: config.recognizerServiceURL,
                    arguments: ["--encoder",config.encoderModelURL.path,"--decoder",config.decoderModelURL.path,
                        "--joiner",config.joinerModelURL.path,"--tokens",config.tokensURL.path,
                        "--input-progress","1","--max-input-samples","1920000"],workURL: work)
                services[id.window] = Service(id: id,child: child)
            } catch { try policy.discardUnspawnedWindow(id); throw error }
            return id
        }
    }
    private func runPump() async {
        while !closedResources && !Task.isCancelled {
            do {
                _ = acceptanceIsCurrent()
                if closing { _ = await joinedClose() }
                else { try step();if !finalizingCoreEOF{try await finishWindowIfReady()} }
                if pendingCueDelivery && !closing {
                    pendingCueDelivery=false; let operation=callbackOperation
                    await cueConsumer(policy.source,operation,cueLedger.completed,cueLedger.partial)
                    guard operation==callbackOperation else { continue }
                }
                if closing { _ = await joinedClose() }
            }
            catch { remember(error); closing = true; _ = policy.retireAll(); callbackOperation = UUID() }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    private func step() throws {
        _ = acceptanceIsCurrent() // closed gate enters the existing fair owned-close path
        if let decoder {
            for data in try decoder.readDiagnostic() {
                for line in try sourceLines.append(data) { try record(line); try receiveSource(line) }
            }
            if closing {
                _ = try decoder.readOutput() // retired binary prefix may be truncated on cooperative cancellation
                sourceBacklog.removeAll();ring.removeAll();ringSamples=0
            } else if sourceBacklog.isEmpty && ring.isEmpty && packet == nil { sourceBacklog = try decoder.readOutput() }
            if !closing,!sourceBacklog.isEmpty && ring.isEmpty && packet == nil {
                let data = sourceBacklog.removeFirst()
                for frame in try sourceParser.append(data) {
                    if frame.ticket != currentTicket { continue } // complete retired record only
                    guard ringSamples+UInt64(frame.sampleCount)<=4096 else { throw LiveASRFailure("长片ring超过4096分区") }
                    ring.append(frame); ringSamples += UInt64(frame.sampleCount)
                }
            }
        }
        for slot in Array(services.values) {if closing{try drainServiceForClose(slot)}else{try receiveService(slot)}}
        if var queued = control, let decoder, !queued.complete {
            // A retired partial line must finish without authorizing new grant;
            // replacing bytes mid-line would corrupt the native control stream.
            try decoder.write(queued.line,offset: &queued.offset)
            guard uptime-queued.began < 3 else { throw LiveASRFailure("控制管道实际提交超过3秒") }
            queued.complete = queued.offset == queued.line.count; control = queued
        }
        if !closing, !handingOver, let proof, let active = policy.active, let slot = services[active],
           uptime-snapshot.observedUptime >= 0, uptime-snapshot.observedUptime <= 0.4 {
            if !finalizingCoreEOF, packet == nil, policy.currentIntentAllowsGrant(intentRevision),let frame = ring.first, !snapshot.paused, !snapshot.seeking,
               let now = snapshot.corePosition {
                let raw = try frame.rawTime(atSampleOffset: 0)
                let normalized = snapshot.rebaseStartTime ? try raw.subtracting(proof.rawOrigin) : raw
                if normalized.seconds < now-2 { throw LiveASRFailure("实际新输入已超过原2秒lag") }
                if normalized.seconds <= now+0.5 {
                    try withAcceptance {
                        try policy.grant(frame,id: slot.id,current: snapshot,proof: proof,intentRevision: intentRevision)
                        packet = frame; packetOffset = 0; packetBegan = uptime;packetWindow=slot.id.window;packetPausedSeconds=0;packetPauseBegan=nil
                        ring.removeFirst(); ringSamples -= UInt64(frame.sampleCount)
                    }
                    if capture {
                        let receipt:[String:Any] = ["kind":"actual-actor-grant","uptime":uptime,
                            "window":slot.id.window.uuidString,"serial":slot.id.serial,
                            "provider":policy.providerID.uuidString,"generation":policy.generation.uuidString,
                            "corePosition":now,"coreObservedUptime":snapshot.observedUptime,
                            "corePaused":snapshot.paused,"coreSeeking":snapshot.seeking,
                            "seekGeneration":snapshot.seekGeneration,"intentRevision":intentRevision,
                            "normalizedStart":normalized.seconds,"rawStartNum":raw.numerator,
                            "rawStartDen":raw.denominator,"headerHex":frame.packet.prefix(112).map{String(format:"%02x",$0)}.joined()]
                        try record(JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys]),service:slot.id)
                    }
                }
            }
            if let packet, packetRetirement == nil {
                let before = packetOffset; try slot.child.write(packet.packet,offset: &packetOffset)
                let priorPayload = max(0,before-112), newPayload = max(0,packetOffset-112)
                writtenPayloadBytes += UInt64(newPayload-priorPayload)
                guard uptime-(packetBegan ?? uptime)-packetPausedSeconds-(packetPauseBegan.map{uptime-$0} ?? 0) < 3 else { throw LiveASRFailure("原SPCM部分写超过3秒") }
                if packetOffset == packet.packet.count { self.packet = nil; packetOffset = 0; packetBegan = nil;packetWindow=nil;packetPauseBegan=nil;packetPausedSeconds=0 }
            }
            if !finalizingCoreEOF, policy.windows.count == 1, let window = policy.windows[active], window.ledger.submittedSamples >= 1440000 {
                _ = try spawnService()
            }
        }
        if !closing, control == nil, let credit = pendingCredit, !sourceEOF {
            try queue("CREDIT \(currentTicket.epoch) \(credit.id.serial) \(credit.count) \(credit.sequence)",
                event:"credit_ack",key:"last_sequence",value:credit.sequence)
        }
        if let queued = control, queued.complete, let receivedControl,
           receivedControl["event"] as? String == queued.event,
           try unsigned(receivedControl,queued.key) == queued.value {
            if queued.event == "credit_ack" {
                if pendingCredit?.sequence == queued.value { pendingCredit=nil }
                control=nil; self.receivedControl=nil
            }
        }
        if !closing {try futureBudget()}
        if !closing,let decoder,decoder.outputEOF,sourceBacklog.isEmpty {try sourceParser.finish()}
        if !closing,decoder?.diagnosticEOF==true {try sourceLines.finish()}
        try decoder?.pollExit(cancel: false,now: uptime)
    }
    private func receiveService(_ slot: Service) throws {
        for data in try slot.child.readDiagnostic() {
            slot.diagnosticsBytes += data.count
            guard slot.diagnosticsBytes <= 131072 else { throw LiveASRFailure("服务stderr超过原边界") }
        }
        for data in try slot.child.readOutput() {
            if slot.corruptedForClose {continue}
            for line in try slot.lines.append(data) {
                try record(line,service:slot.id)
                let fields = try object(line), seq = try unsigned(fields,"sequence")
                guard seq > slot.sequence else { throw LiveASRFailure("服务事件sequence重复或倒退") }
                slot.sequence = seq
                let event = fields["event"] as? String
                if event == "ready", !closing, policy.windows[slot.id.window]?.phase == .reserved {
                    try policy.receiveReady(LiveASRLinearReady(id:slot.id,readyUptime:try real(fields,"monotonic_seconds"),
                        serviceSequence:seq,liveRecognizers:Int(try integer(fields,"live_recognizers")),
                        liveStreams:Int(try integer(fields,"live_streams")),writtenBytes:0,acceptedSamples:try unsigned(fields,"accepted_samples")))
                } else if event == "stream_created", !closing, policy.active == slot.id.window {
                    try policy.streamCreated(slot.id,ticket:try ticket(fields),generation:try unsigned(fields,"stream_generation"),eventSequence:seq)
                } else if event == "input_accepted", !closing, policy.active == slot.id.window {
                    let progress = try LiveASRLinearInputProgress.decode(line,from:slot.id);try progress.apply(to:&policy)
                    acceptedPayloadSamples = progress.acceptedSamples
                    if sourceEOF {
                        // A final accepted receipt may arrive after the actual
                        // decoder EOF in this same fair pipe-drain step. It
                        // still closes the real service prefix; a dead source
                        // has no remaining publication credit to acknowledge.
                        guard let end = policy.sourceEnd, end.window == progress.window,
                              end.ticket == progress.ticket,
                              progress.acceptedSamples <= end.outputSamples,
                              progress.lastInputSequence <= end.lastSequence else {
                            throw LiveASRFailure("源EOF后输入进度未匹配当前真实prefix")
                        }
                        pendingCredit = nil
                    } else {
                        pendingCredit = (slot.id,progress.acceptedSamples,progress.lastInputSequence)
                    }
                } else if ["partial","endpoint_final","eof_final"].contains(event ?? "") {
                    let value = try LiveASRRecognitionEvent.decode(line)
                    guard value.accepted_samples <= 1920000 else { throw LiveASRFailure("窗口预测覆盖超过实际120秒") }
                    if value.event == "eof_final" { slot.final = value }
                    if !closing, policy.active == slot.id.window, let window=policy.windows[slot.id.window], let proof {
                        guard value.ticket==currentTicket, value.stream_generation==window.streamGeneration else {
                            throw LiveASRFailure("旧窗口文本不能覆盖当前namespace")
                        }
                        try cueLedger.accept(value,timeline:window.ledger,proof:proof,rebase:snapshot.rebaseStartTime,processID:slot.id.child)
                        pendingCueDelivery=true
                    }
                } else if event == "closed" { slot.closed = fields }
                else if event == "error" { throw LiveASRFailure("实际识别服务返回错误") }
            }
        }
        if slot.child.outputEOF,!slot.corruptedForClose { try slot.lines.finish() }
    }
    private func receiveSource(_ line: Data) throws {
        let fields=try object(line),event=fields["event"] as? String
        if event=="source_fd_fingerprint" {
            let seconds=try integer(fields,"mtime_seconds"), nanos=try integer(fields,"mtime_nanoseconds")
            let product=seconds.multipliedReportingOverflow(by:1_000_000_000),total=product.partialValue.addingReportingOverflow(nanos)
            guard !product.overflow,!total.overflow,(0..<1_000_000_000).contains(nanos) else { throw LiveASRFailure("FD指纹溢出") }
            sourceFingerprint=LiveASRFileFingerprint(device:try unsigned(fields,"device"),inode:try unsigned(fields,"inode"),
                byteCount:try unsigned(fields,"bytes"),modificationNanoseconds:total.partialValue)
        } else if event=="runtime_versions" {
            guard let compiled=fields["compiled"] as? [NSNumber],compiled.count==4 else { throw LiveASRFailure("缺少真实ABI版本") }
            for (index,key) in ["avformat","avcodec","avutil","swresample"].enumerated() {
                let version=try unsigned(fields,key)
                guard version==compiled[index].uint64Value,version>>16==[63,63,61,7][index] else { throw LiveASRFailure("真实FFmpeg ABI未匹配") }
            }
            sourceRuntime=fields
        } else if event=="media_opened" { sourceOpened=fields }
        else if event=="provider_born" { sourceBorn=fields }
        else if event=="provider_primed" {
            guard try boolean(fields,"published")==false,let hex=fields["record_hex"] as? String,
                  hex.count<=2784,hex.count%2==0 else { throw LiveASRFailure("prime不是有界未发布实际SPCM") }
            var data=Data();var at=hex.startIndex
            while at<hex.endIndex { let end=hex.index(at,offsetBy:2);guard let value=UInt8(hex[at..<end],radix:16) else { throw LiveASRFailure("prime字节无效") };data.append(value);at=end }
            var parser=LiveASRSPCMParser();let records=try parser.append(data);try parser.finish()
            guard records.count==1 else { throw LiveASRFailure("prime必须是一块实际SPCM") };prime=records[0];actualPrimed=fields
        } else if ["control_ack","credit_ack","linear_seek_ack","next_window_ack"].contains(event ?? "") {
            if event=="control_ack",let queued=control,queued.event==event,
               try unsigned(fields,"control_serial")==queued.value {
                let serial=try unsigned(fields,"control_serial")
                guard serial==nativeControlSerial+1 || serial==nativeControlSerial else{throw LiveASRFailure("NativeACK控制序号不连续")}
                nativeControlSerial=serial;nativePaused=try boolean(fields,"paused");nativeSpeed=try real(fields,"speed")
                if policy.phase == .seeking || policy.phase == .retiring {
                    try policy.receiveRetiredControlSerial(serial:serial,ticket:try ticket(fields))
                }
            }
            receivedControl=fields
        } else if event=="provider_budget" {
            guard try unsigned(fields,"reserved_total")<=32000,try unsigned(fields,"external_cap")==11584,
                  try unsigned(fields,"converted_remaining")<=16000,try unsigned(fields,"swr_out_upper")<=16000,
                  try unsigned(fields,"record_copy_samples")<=320,
                  try unsigned(fields,"converted_remaining")+unsigned(fields,"swr_out_upper")+unsigned(fields,"record_copy_samples")<=16000 else {
                throw LiveASRFailure("provider实际未来预算超过原界限")
            };lastBudget=fields
        } else if event=="provider_window_held", !closing, policy.phase != .seeking {
            let nextSamples=try unsigned(fields,"next_samples_held");guard (1...320).contains(nextSamples) else{throw LiveASRFailure("C held样本超界")}
            guard let active=policy.active,let slot=services[active],try unsigned(fields,"window")==slot.id.serial else { throw LiveASRFailure("C held对应旧窗口") }
            try policy.receiveBoundary(LiveASRLinearBoundary(id:slot.id,ticket:try ticket(fields),
                observedUptime:try real(fields,"monotonic_seconds"),outputSamples:try unsigned(fields,"output_samples"),
                lastSequence:try unsigned(fields,"last_sequence"),rawEnd:try time(fields,"raw_end"),
                nextRawStart:try time(fields,"next_start"),nextSamplesHeld:UInt32(nextSamples)))
        } else if event=="provider_source_eof" {
            sourceEOF=true;pendingCredit=nil
            if let c=control,c.event=="credit_ack" {
                discardedControlReceipts.append(["event":"credit-obligation-retired-on-actual-native-EOF","sequence":c.value,"bytesWritten":c.offset,"totalBytes":c.line.count])
                control=nil;receivedControl=nil
            } // retired on actual native EOF, not a fabricated ACK
            if !closing,policy.phase != .seeking,let active=policy.active,let slot=services[active] {
                try policy.receiveSourceEnd(LiveASRLinearSourceEnd(provider:policy.providerID,generation:policy.generation,
                    child:policy.decoderChildID,ticket:try ticket(fields),window:slot.id,
                    observedUptime:try real(fields,"monotonic_seconds"),outputSamples:try unsigned(fields,"output_samples"),
                    lastSequence:try unsigned(fields,"last_sequence"),rawEnd:try time(fields,"raw_end"),
                    codecEOF:try boolean(fields,"codec_eof"),resamplerDrained:try boolean(fields,"resampler_drained")))
            }
        } else if event=="provider_closed" { sourceClosed=fields }
        else if event=="error" { throw LiveASRFailure("持续音频provider实际失败") }
    }
    private func finishWindowIfReady() async throws {
        guard acceptanceIsCurrent() else { return }
        guard !handingOver,!closing,packet==nil,ring.isEmpty,sourceBacklog.isEmpty,control==nil,pendingCredit==nil,
              let active=policy.active,let slot=services[active],let window=policy.windows[active],
              let endSamples=policy.boundary?.outputSamples ?? policy.sourceEnd?.outputSamples,
              window.ledger.submittedSamples==endSamples,window.acceptedSamples==endSamples else { return }
        handingOver=true;defer{handingOver=false};let operation=policy.operation
        if !slot.inputClosed { slot.child.closeInput();slot.inputClosed=true;slot.closeBegan=uptime }
        let deadline=uptime+20
        while !slot.child.reaped || !slot.child.outputEOF || !slot.child.diagnosticEOF {
            try step();try slot.child.pollExit(cancel:uptime-(slot.closeBegan ?? uptime)>5,now:uptime)
            guard policy.operation==operation,!closing else { return }
            if uptime>=deadline { throw LiveASRFailure("窗口强关闭超时，仍保留真实lease") }
            try await Task.sleep(nanoseconds:5_000_000)
        }
        guard policy.operation==operation,!closing,let final=slot.final,let proof else { throw LiveASRFailure("窗口没有实际final") }
        let attempt=try policy.beginWindowClose(slot.id)
        let prefix=LiveASRLinearPrefix(id:slot.id,ticket:final.ticket,acceptedSamples:final.accepted_samples,
            firstSequence:final.first_input_sequence,lastSequence:final.last_input_sequence,streamGeneration:final.stream_generation,
            finalServiceSequence:final.sequence,rawEnd:try window.ledger.rawTime(atSample:final.accepted_samples),
            eofFinal:final.event=="eof_final",paddingSamples:final.padding_samples,
            liveStreamsAtFinal:final.live_streams,liveRecognizersAtFinal:final.live_recognizers)
        _ = try settleReleasedService(slot,attempt:attempt,finalized:prefix)
        if sourceEOF {
            if pendingCueDelivery {
                pendingCueDelivery=false
                await cueConsumer(policy.source,operation,cueLedger.completed,cueLedger.partial)
                guard operation==policy.operation,!closing else{return}
            }
            closing=true;return
        }
        guard let held=policy.boundary,let next=services.values.first(where:{$0.id.serial==slot.id.serial+1}),
              policy.windows[next.id.window]?.phase == .ready else { throw LiveASRFailure("预备窗口没有在实际C held前就绪") }
        let ack=try await send("NEXT_WINDOW \(currentTicket.epoch) \(held.id.serial) \(next.id.serial) \(held.lastSequence) \(held.rawEnd.numerator) \(held.rawEnd.denominator)",event:"next_window_ack",key:"next_window",value:next.id.serial)
        guard policy.operation==operation,!closing else { return }
        try withAcceptance { try policy.adoptNext(next.id,ack:LiveASRLinearNextACK(provider:policy.providerID,generation:policy.generation,
            operation:operation,child:policy.decoderChildID,ticket:try ticket(ack),
            previousWindow:try unsigned(ack,"previous_window"),nextWindow:try unsigned(ack,"next_window"),
            lastSequence:try unsigned(ack,"last_sequence"),previousRawEnd:try time(ack,"previous_end"),
            nextRawStart:try time(ack,"next_start"),nextWindowOutputBeforeRelease:try unsigned(ack,"next_output_before_release")),
            current:snapshot,proof:proof,intentRevision:intentRevision)
            currentWindow=next.id.serial;writtenPayloadBytes=0;acceptedPayloadSamples=0
        }
        try rotateJournal(currentWindow)
    }
    private struct Metadata { let codec: String; let rate: Int; let channels: Int; let formatName: String; let formatStart: Double?; let streamStart: Double? }
    private func createWork() throws {
        let rootLeaf = "SiliconPlayer-LiveASR-Linear"
        let childLeaf = "Linear-" + request.processID.uuidString
        guard workRoot.isFileURL, workRoot.user == nil, workRoot.password == nil,
              workRoot.query == nil, workRoot.fragment == nil,
              workRoot.host == nil || workRoot.host == "",
              workRoot.path.hasPrefix("/"), workRoot.lastPathComponent == rootLeaf,
              work.lastPathComponent == childLeaf, !workCreated else {
            throw LiveASRFailure("长片工作根必须是物理本地路径")
        }
        // Resolve only the EXISTING parent using POSIX. Foundation may keep
        // /var and change a nonexistent directory URL's trailing-slash hint.
        // Reservation/init remain I/O-free; no child/journal exists yet.
        func physicalDirectoryPath(_ path: String) throws -> String {
            guard let resolved = path.withCString({ realpath($0, nil) }) else {
                throw LiveASRFailure("无法核验长片工作根父目录")
            }
            defer { free(resolved) }
            let result = String(cString: resolved)
            guard result.hasPrefix("/"), result.utf8.count <= 4096,
                  !result.split(separator: "/").contains(where: { $0.hasPrefix("._") }) else {
                throw LiveASRFailure("长片工作根父目录路径无效")
            }
            return result
        }
        let suppliedParent = workRoot.deletingLastPathComponent().path
        let physicalParent = try physicalDirectoryPath(suppliedParent)
        // An already physical Root/test parent is valid. The only permitted
        // aliased parent is the actual Foundation temporary directory, bound
        // below to the same existing device/inode; arbitrary aliases fail.
        let temporaryParent = FileManager.default.temporaryDirectory.path
        if suppliedParent != physicalParent {
            guard suppliedParent == temporaryParent,
                  try physicalDirectoryPath(temporaryParent) == physicalParent else {
                throw LiveASRFailure("长片工作根父目录含非临时目录别名")
            }
        }
        let parentFD = Darwin.open(physicalParent, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard parentFD >= 0 else { throw LiveASRFailure("无法打开长片工作根父目录") }
        defer { Darwin.close(parentFD) }
        var heldParent = stat(), namedParent = stat()
        guard fstat(parentFD, &heldParent) == 0,
              lstat(physicalParent, &namedParent) == 0,
              namedParent.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              heldParent.st_dev == namedParent.st_dev, heldParent.st_ino == namedParent.st_ino,
              try physicalDirectoryPath(physicalParent) == physicalParent else {
            throw LiveASRFailure("长片工作根父目录身份已变")
        }
        if suppliedParent != physicalParent {
            var actualTemporary = stat()
            guard Darwin.lstat(temporaryParent, &actualTemporary) == 0,
                  actualTemporary.st_dev == heldParent.st_dev,
                  actualTemporary.st_ino == heldParent.st_ino else {
                throw LiveASRFailure("长片临时父目录身份已变")
            }
        }
        let physicalRoot = physicalParent + "/" + rootLeaf
        let physicalWork = physicalRoot + "/" + childLeaf
        let rootURL = URL(fileURLWithPath: physicalRoot, isDirectory: true)
        let workURL = URL(fileURLWithPath: physicalWork, isDirectory: true)
        guard rootURL.path == physicalRoot, workURL.path == physicalWork else {
            throw LiveASRFailure("长片物理工作路径构造无效")
        }
        try withAcceptance {
            if mkdirat(parentFD, rootLeaf, mode_t(0o700)) != 0 && errno != EEXIST {
                throw LiveASRFailure("无法建立持续解码私有工作根")
            }
            let fd = openat(parentFD, rootLeaf, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
            guard fd >= 0 else { throw LiveASRFailure("无法打开长片私有工作根") }
            defer { Darwin.close(fd) }
            var s = stat(), fs = statfs()
            guard fstat(fd, &s) == 0, s.st_uid == geteuid(),
                  s.st_mode & mode_t(0o777) == mode_t(0o700),
                  fstatfs(fd, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0,
                  mkdirat(fd, childLeaf, mode_t(0o700)) == 0 else {
                throw LiveASRFailure("长片工作目录需独占0700本地目录")
            }
            // Publish both paths together before the first journal/spawn.
            // Every later child, journal and diagnostic reads these fields.
            workRoot = rootURL; work = workURL; workCreated = true
            try rotateJournal(1)
        }
    }
    private func inspectSource(_ executable: URL) async throws -> Metadata {
        let url=policy.source.track.externalSource?.url ?? policy.source.binding.originalURL
        guard url.isFileURL,url.user==nil,url.password==nil,url.query==nil,url.fragment==nil else { throw LiveASRFailure("持续provider只读取当前本地源") }
        let opened=Darwin.open(url.path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC)
        guard opened>=0 else { throw LiveASRFailure("无法打开源FD") };defer{Darwin.close(opened)}
        var s=stat(),fs=statfs()
        guard fstat(opened,&s)==0,try fingerprint(s)==policy.source.fingerprint,
              fstatfs(opened,&fs)==0,fs.f_flags & UInt32(MNT_LOCAL) != 0 else { throw LiveASRFailure("源FD身份已变") }
        let owned=fcntl(opened,F_DUPFD_CLOEXEC,20);guard owned>=20 else { throw LiveASRFailure("无法保留探测FD") };defer{Darwin.close(owned)}
        let child=try withAcceptance {
            let reserved=try LiveASRChildProcess(executable:executable,arguments:["-v","error","-hide_banner","-protocol_whitelist","fd","-fd","3","-probesize","4194304","-analyzeduration","5000000","-show_streams","-show_format","-of","json","fd:"],workURL:work,sourceFD:owned)
            probe=reserved; return reserved
        }
        child.closeInput();var out=Data();var err=0;let deadline=uptime+5
        while !child.reaped || !child.outputEOF || !child.diagnosticEOF {
            _ = acceptanceIsCurrent()
            for d in try child.readOutput(){guard out.count+d.count<=2097152 else{throw LiveASRFailure("探测元数据超界")};out.append(d)}
            for d in try child.readDiagnostic(){err+=d.count;guard err<=131072 else{throw LiveASRFailure("探测stderr超界")}}
            try child.pollExit(cancel:closing || uptime>=deadline,now:uptime)
            guard uptime<deadline+2 else{throw LiveASRFailure("探测强清理未闭合，保留child")}
            try await Task.sleep(nanoseconds:5_000_000)
        }
        guard acceptanceIsCurrent() else { throw LiveASRLinearAcceptanceRetired() }
        guard !closing,child.exitCode==0,!child.forced,uptime<deadline,
              try physicalRelease(child),fstat(opened,&s)==0,try fingerprint(s)==policy.source.fingerprint else{throw LiveASRFailure("探测或FD末身份不符")}
        probe=nil;let fields=try object(out)
        guard let rows=fields["streams"] as? [[String:Any]],rows.count<=2000,
              rows.filter({strictInteger($0["index"])==Int64(policy.source.track.absoluteFFmpegIndex)}).count==1,
              let stream=rows.first(where:{strictInteger($0["index"])==Int64(policy.source.track.absoluteFFmpegIndex)}),
              stream["codec_type"] as? String=="audio",let codec=stream["codec_name"] as? String,codec==policy.source.track.codec,
              let text=stream["sample_rate"] as? String,let rate=Int(text),rate==policy.source.track.sampleRate,
              strictInteger(stream["channels"])==Int64(policy.source.track.channels),
              let format=fields["format"] as? [String:Any],let name=format["format_name"] as? String,!name.isEmpty,name.utf8.count<=256 else{throw LiveASRFailure("实际ff-index/codec/rate/channels不一致")}
        if policy.source.track.isExternal {guard rows.count==1,policy.source.track.absoluteFFmpegIndex==0,name=="wav",codec.hasPrefix("pcm_") else{throw LiveASRFailure("外置源只接受真实单音轨PCM WAV")}}
        func optional(_ v:Any?)throws->Double?{guard let v else{return nil};guard let t=v as? String else{throw LiveASRFailure("探测时间字段无效")};if t=="N/A"{return nil};guard let n=Double(t),n.isFinite,abs(n)<=86400 else{throw LiveASRFailure("探测起点超界")};return n}
        return Metadata(codec:codec,rate:rate,channels:policy.source.track.channels,formatName:name,formatStart:try optional(format["start_time"]),streamStart:try optional(stream["start_time"]))
    }
    private func rawTarget(_ current:LiveASRSnapshot,proof:LiveASRSourceProof)throws->(time:LiveASRTime,microseconds:Int64){
        guard let position=current.corePosition,position.isFinite,abs(position)<=86400,!current.seeking,
              current.settledSeekGeneration==current.seekGeneration else{throw LiveASRFailure("目标不是已settled实际Core读数")}
        let raw=position+(current.rebaseStartTime ? proof.rawOrigin.seconds:0)
        guard raw.isFinite,abs(raw)<=86400 else{throw LiveASRFailure("源seek目标超界")}
        let us=Int64((raw*1_000_000).rounded());return(try LiveASRTime(us,1_000_000),us)
    }
    private func queue(_ body:String,event:String,key:String,value:UInt64)throws{
        guard control==nil,!body.contains("\n"),!body.contains("\r"),!body.utf8.contains(0),body.utf8.count<511 else{throw LiveASRFailure("原子有界控制不能覆盖旧提交")}
        let enqueue = {
            self.receivedControl=nil;self.control=Control(operation:self.policy.operation,line:Data((body+"\n").utf8),event:event,key:key,value:value,began:self.uptime)
        }
        if closing,body.hasPrefix("CANCEL ") { enqueue() } // genuine owned retirement remains callable
        else { try withAcceptance(enqueue) }
    }
    private func send(_ body:String,event:String,key:String,value:UInt64)async throws->[String:Any]{
        guard acceptanceIsCurrent() else { throw LiveASRLinearAcceptanceRetired() }
        let operation=policy.operation
        try await flushControl()
        guard acceptanceIsCurrent() else { throw LiveASRLinearAcceptanceRetired() }
        guard operation==policy.operation,!closedResources else{throw LiveASRFailure("控制排队前所有权已变")}
        try queue(body,event:event,key:key,value:value)
        let deadline=uptime+3
        while true {
            try step()
            guard acceptanceIsCurrent() else { throw LiveASRLinearAcceptanceRetired() }
            guard operation==policy.operation else{throw LiveASRFailure("迟到控制属于旧操作")}
            if let c=control,c.complete,let ack=receivedControl,ack["event"] as? String==event,
               try unsigned(ack,key)==value {
                guard try ticket(ack)==currentTicket || event=="linear_seek_ack" else{throw LiveASRFailure("控制真实ticket不符")}
                control=nil;receivedControl=nil;return ack
            }
            guard uptime<deadline,decoder?.reaped==false else{throw LiveASRFailure("持续provider控制未真实应答")}
            try await Task.sleep(nanoseconds:5_000_000)
        }
    }
    /// Finish an already-started complete line under its original obligation;
    /// its reply can retire that obligation, never authorize a new generation.
    private func flushControl()async throws{
        let deadline=uptime+3
        while let c=control {
            try step()
            if c.complete,let ack=receivedControl,ack["event"] as? String==c.event,
               try unsigned(ack,c.key)==c.value {control=nil;receivedControl=nil;break}
            guard uptime<deadline,decoder?.reaped==false else{throw LiveASRFailure("旧控制义务未闭合")}
            try await Task.sleep(nanoseconds:5_000_000)
        }
    }
    private func wait(timeout:Double,_ ready:()->Bool)async throws{
        let operation=policy.operation,deadline=uptime+timeout
        while !ready(){try step();guard acceptanceIsCurrent() else{throw LiveASRLinearAcceptanceRetired()};guard !closing,operation==policy.operation,uptime<deadline else{throw LiveASRFailure("实际持续源/服务等待已取消或超时")};try await Task.sleep(nanoseconds:5_000_000)}
    }
    private func seekReceipt(_ ack:[String:Any],old:LiveASRWireTicket,target:LiveASRTime)throws->LiveASRLinearSeekReceipt{
        let fresh=try ticket(ack)
        guard try unsigned(ack,"old_epoch")==old.epoch,try integer(ack,"held_fd")>=0,
              try integer(ack,"target_microseconds")==Int64((target.seconds*1_000_000).rounded()) else{throw LiveASRFailure("同FD seek真实目标不符")}
        return LiveASRLinearSeekReceipt(provider:policy.providerID,oldGeneration:policy.generation,operation:policy.operation,
            child:policy.decoderChildID,oldTicket:old,newTicket:fresh,target:target,
            heldSourceFingerprint:try eventFingerprint(ack),sameSourceDescriptor:try integer(ack,"held_fd")==integer(sourceBorn ?? [:],"held_fd"),
            codecFlushed:try boolean(ack,"codec_flushed"),resamplerReset:try boolean(ack,"resampler_reset"),
            actualPaused:try boolean(ack,"paused"),nextWindowSerial:try unsigned(ack,"window"))
    }
    private func runSeekWorker(_ worker:UUID)async {
        defer{if seekWorkerID==worker{seekWorker=nil;seekWorkerID=nil}}
        while !closing,policy.phase == .seeking,seekWorkerID==worker {
            guard acceptanceIsCurrent() else { return }
            let operation=policy.operation
            do{try await userSeek(snapshot,operation:operation)}catch{
                if operation != policy.operation {continue}
                remember(error);closing=true;_ = policy.retireAll();break
            }
        }
    }
    private func userSeek(_ current:LiveASRSnapshot,operation:UUID)async throws{
        guard let proof,!sourceEOF,decoder?.reaped==false else{throw LiveASRFailure("已释放源FD需新provider，不允许伪复用")}
        try await flushControl();guard operation==policy.operation,!closing else{return}
        // Control ACK is physical transport evidence here; the old source binding
        // is not re-authorized while the main renderer seek is unsettled.
        guard nativeControlSerial<UInt64.max else{throw LiveASRFailure("原生控制序号耗尽")}
        let serial=nativeControlSerial+1
        let pause=try await send("CONTROL \(currentTicket.epoch) \(serial) PAUSE",event:"control_ack",key:"control_serial",value:serial)
        guard operation==policy.operation,!closing,try boolean(pause,"paused") else{return}
        nativeControlSerial=serial;nativePaused=true
        for slot in Array(services.values){try await retireService(slot,operation:operation);guard operation==policy.operation,!closing else{return}}
        let deadline=uptime+3
        while snapshot.seeking || snapshot.settledSeekGeneration != snapshot.seekGeneration {
            try step();guard operation==policy.operation,!closing,uptime<deadline else{throw LiveASRFailure("主播放器seek尚未settled")};try await Task.sleep(nanoseconds:5_000_000)
        }
        guard operation==policy.operation,!closing else{return}
        let target=try rawTarget(snapshot,proof:proof);try withAcceptance { try policy.bindSeekTarget(target.time,current:snapshot) }
        guard currentTicket.epoch<UInt64.max,currentWindow<UInt64.max else{throw LiveASRFailure("源epoch/window耗尽")}
        let old=currentTicket,next=old.epoch+1,newWindow=currentWindow+1
        let ack=try await send("LINEAR_SEEK \(old.epoch) \(next) \(currentWindow) \(newWindow) \(target.microseconds)",event:"linear_seek_ack",key:"epoch",value:next)
        guard operation==policy.operation,!closing else{return}
        let receipt=try seekReceipt(ack,old:old,target:target.time)
        try withAcceptance {
            try policy.finishSeek(receipt,current:snapshot,proof:proof)
            currentTicket=receipt.newTicket;currentWindow=newWindow;sourceEOF=false;sourceClosed=nil;pendingCredit=nil
        }
        ring.removeAll();ringSamples=0;packet=nil;packetOffset=0;packetBegan=nil;writtenPayloadBytes=0;acceptedPayloadSamples=0
        // Do not clear parser/backlog: a previously half-published old record
        // still must parse fully; its actual old ticket is then discarded.
        try rotateJournal(newWindow)
        let first=try spawnService();try await wait(timeout:15){self.policy.windows[first.window]?.phase == .ready}
        try await pace(.speed,paused:true,speed:snapshot.speed)
        if !snapshot.paused {try await pace(.resume,paused:false,speed:snapshot.speed);try withAcceptance { try policy.adoptInitial(first) }}else{try withAcceptance { startedReady=first }}
        callbackOperation=policy.operation
    }
    private func retireService(_ slot:Service,operation:UUID)async throws{
        let attempt=try policy.beginWindowClose(slot.id)
        try await finishRetiredPacket(slot,operation:operation)
        guard operation==policy.operation else{return}
        if !slot.inputClosed {
            // Retirement is cancellation, not natural finalization. In
            // particular zero-input standby EOF would be a real error.
            try slot.child.pollExit(cancel:true,now:uptime)
            slot.child.closeInput();slot.inputClosed=true;slot.closeBegan=uptime
        }
        let deadline=uptime+20
        while !slot.child.reaped || !slot.child.outputEOF || !slot.child.diagnosticEOF {
            try drainServiceForClose(slot);try slot.child.pollExit(cancel:uptime-(slot.closeBegan ?? uptime)>5,now:uptime)
            guard operation==policy.operation else{return}
            guard uptime<deadline else{throw LiveASRFailure("退役服务仍有真实资源，保留lease")}
            try await Task.sleep(nanoseconds:5_000_000)
        }
        guard operation==policy.operation else{return}
        _ = try settleReleasedService(slot,attempt:attempt,finalized:nil)
    }
    private func finishRetiredPacket(_ slot:Service,operation:UUID)async throws {
        let deadline=uptime+3
        while packetRetirement != nil {
            guard operation==policy.operation,uptime<deadline else{throw LiveASRFailure("原部分SPCM退役所有权未闭合")}
            try await Task.sleep(nanoseconds:5_000_000)
        }
        guard let frame=packet,packetWindow==slot.id.window else{return}
        let attempt=UUID();packetRetirement=attempt
        defer{if packetRetirement==attempt{packetRetirement=nil}}
        while packetOffset<frame.packet.count {
            let before=packetOffset
            try slot.child.write(frame.packet,offset:&packetOffset)
            writtenPayloadBytes+=UInt64(max(0,packetOffset-112)-max(0,before-112))
            try receiveService(slot)
            guard operation==policy.operation,uptime<deadline else{throw LiveASRFailure("已grant部分SPCM退役未完成，原错误与lease保留")}
            try await Task.sleep(nanoseconds:5_000_000)
        }
        packet=nil;packetWindow=nil;packetOffset=0;packetBegan=nil;packetPauseBegan=nil;packetPausedSeconds=0
    }
    private func futureBudget()throws {
        // Virtual concatenation shares Data storage: no 64KiB payload copy. Start
        // at the parser's retained record boundary and inspect only112B headers.
        let pieces=[sourceParser.retainedWireBytes]+sourceBacklog
        let bytes=pieces.reduce(0){$0+$1.count}
        func byte(_ index:Int)->UInt8 {var at=index;for d in pieces{if at<d.count{return d[d.startIndex+at]};at-=d.count};return 0}
        func word(_ index:Int)->UInt32 {var n:UInt32=0;for j in 0..<4{n |= UInt32(byte(index+j)) << (j*8)};return n}
        var cursor=0,wireSamples:UInt64=0
        while bytes-cursor>=112 {
            guard (0..<4).map({byte(cursor+$0)})==[83,80,67,77] else{throw LiveASRFailure("缓冲SPCM头无效")}
            let count=word(cursor+96),length=Int(word(cursor+8))
            guard (1...320).contains(count),length==112+Int(count)*4 else{throw LiveASRFailure("缓冲SPCM真实长度无效")}
            let stored=min(length-112,max(0,bytes-cursor-112))
            wireSamples+=UInt64((stored+3)/4)
            if bytes-cursor<length{break};cursor+=length
        }
        let partial=UInt64(packet?.sampleCount ?? 0),written=(writtenPayloadBytes+3)/4
        guard written>=acceptedPayloadSamples else{throw LiveASRFailure("实际accepted超过已写payload")}
        let unaccepted=written-acceptedPayloadSamples
        let duplicate=UInt64((max(0,packetOffset-112)+3)/4)
        guard duplicate<=partial,unaccepted>=duplicate,ringSamples<=4096,partial<=320,unaccepted<=4096 else{throw LiveASRFailure("未来物理分区不符")}
        let logicalExternal=wireSamples+ringSamples+partial+unaccepted-duplicate
        // C CREDIT cap includes pipe bytes not yet read here. Its unconditional
        // pre-publication11584 bound plus actual16k allocation guard is the
        // source upper bound;4096 parser scratch +320 duplicated partial packet
        // are separately reserved. No AO/Core count is used as acceptance.
        guard logicalExternal<=11584 else{throw LiveASRFailure("持续provider外部未来超过11584")}
        let maximum:UInt64=16000+11584+4096+320
        guard maximum<=32000 else{throw LiveASRFailure("未来总预算不闭合")}
        latestMaximumFutureSamples=max(latestMaximumFutureSamples,maximum)
        if capture {
            lastActorBudget = ["kind":"actual-actor-future-budget","uptime":uptime,
                "wireSamples":wireSamples,"ringSamples":ringSamples,"partialSamples":partial,
                "unacceptedSamples":unaccepted,"duplicateSamples":duplicate,
                "logicalExternal":logicalExternal,"sourceAllocationCap":16000,
                "sourceExternalCap":11584,"parserScratchReservation":4096,
                "partialDuplicateReservation":320,"jointReservedUpper":maximum]
        }
    }
    private func drainServiceForClose(_ slot:Service)throws {
        do{try receiveService(slot)}catch{slot.corruptedForClose=true;remember(error);_ = try slot.child.readOutput();_ = try slot.child.readDiagnostic()}
    }
    /// Policy may remove a physically released window and then throw because
    /// its final/prefix was invalid. Both registries must retire that same real
    /// child, while preserving the first failure and refusing normal handover.
    @discardableResult private func settleReleasedService(_ slot:Service,attempt:UUID?,finalized:LiveASRLinearPrefix?)throws->Bool {
        let receipt=try childClose(slot)
        guard receipt.resourcesReleased else{return false}
        var original:Error?
        if policy.windows[slot.id.window] != nil {
            guard let attempt else{throw LiveASRFailure("当前服务关闭缺少exact policy ticket")}
            do{_ = try policy.finishWindowClose(slot.id,attempt:attempt,close:receipt,finalized:finalized)}
            catch{original=error;remember(error)}
        } else if !slot.closeSaved {
            // This is cleanup of an already released missing-policy slot,
            // never evidence that its prior final/handover was successful.
            remember(LiveASRFailure("已释放服务缺少policy窗口；只回收真实ownership"))
        }
        guard policy.windows[slot.id.window]==nil else {
            if let original{throw original};return false
        }
        saveServiceClose(slot,receipt:receipt)
        if services[slot.id.window] === slot{services.removeValue(forKey:slot.id.window)}
        if let original{throw original}
        return true
    }
    private func saveServiceClose(_ slot:Service,receipt:LiveASRLinearChildClose) {
        guard !slot.closeSaved else{return}
        slot.closeSaved=true
        let next=serviceCloseCount.addingReportingOverflow(1)
        if next.overflow{remember(LiveASRFailure("关闭计数溢出"))}else{serviceCloseCount=next.partialValue}
        allNativeServiceZero = allNativeServiceZero && receipt.nativeClosedZero
        allServiceNaturalZero = allServiceNaturalZero && receipt.naturalExitCode==0
        anyForced = anyForced || receipt.forced
        closeHistory.append(["kind":"service","window":slot.id.window.uuidString,"serial":slot.id.serial,
            "nativeClosed":slot.closed as Any? ?? NSNull(),"owned":slot.child.exitDiagnostics])
        if closeHistory.count>64{closeHistory.removeFirst(closeHistory.count-64)}
    }
    private func physicalRelease(_ child:LiveASRChildProcess)throws->Bool{
        let d=child.exitDiagnostics
        guard let receipt=d["confirmedQuiescentGroupReceipt"] as? [String:Any] else{return false}
        return child.reaped && child.outputEOF && child.diagnosticEOF &&
            (d["leaderExitedWNOWAIT"] as? Bool)==true &&
            (receipt["complete"] as? Bool)==true && (receipt["allZombie"] as? Bool)==true
    }
    private func childClose(_ slot:Service)throws->LiveASRLinearChildClose{
        let released=try physicalRelease(slot.child)
        let nativeZero:Bool
        if let closed=slot.closed {nativeZero=(try? integer(closed,"live_streams"))==0 && (try? integer(closed,"live_recognizers"))==0}
        else{nativeZero=false}
        return LiveASRLinearChildClose(child:slot.id.child,naturalExitCode:slot.child.exitCode,
            stdoutEOF:slot.child.outputEOF,stderrEOF:slot.child.diagnosticEOF,remainingResources:released ? 0:nil,
            reaped:slot.child.reaped,leaderHeldUntilQuiescent:(slot.child.exitDiagnostics["leaderExitedWNOWAIT"] as? Bool)==true,
            completeExactGroupSnapshot:released,forced:slot.child.forced,nativeClosedZero:nativeZero)
    }
    /// Idempotent retry: failed ownership proof keeps every unknown child object.
    /// A second attempt may finish it; no Task/token is cleared by an older await.
    func close()async->LiveASRCloseResult{
        acceptance.close()
        _ = acceptanceIsCurrent()
        if closedResources{return closeResult()}
        if !closing { closing=true;_ = policy.retireAll();callbackOperation=UUID() }
        return await joinedClose()
    }
    /// Every caller awaits the same real cleanup flight. An in-progress attempt
    /// is not a completed receipt; its task stays owned until its actual result.
    private func joinedClose() async -> LiveASRCloseResult {
        if closedResources { return closeResult() }
        if let flight = closeFlight { return await flight.task.value }
        let id = UUID()
        let task = Task { await self.advanceClose() }
        closeFlight = (id: id, task: task)
        let result = await task.value
        if closeFlight?.id == id { closeFlight = nil }
        return result
    }
    private func advanceClose()async->LiveASRCloseResult{
        if closedResources{return closeResult()}
        if closeAttempt != nil{return closeResult()}
        let attempt=UUID();closeAttempt=attempt
        defer{if closeAttempt==attempt{closeAttempt=nil}}
        let deadline=uptime+20
        var cancelLineSafe=true
        do {
            for slot in Array(services.values) {
                let token=policy.windows[slot.id.window] == nil ? nil : try policy.beginWindowClose(slot.id)
                do{try await finishRetiredPacket(slot,operation:policy.operation)}catch{
                    remember(error)
                    if let packet {discardedControlReceipts.append(["event":"partial-SPCM-retired-only-for-strong-owned-close","sequence":packet.sequence,"packetOffset":packetOffset,"totalBytes":packet.packet.count])}
                    packet=nil;packetWindow=nil;packetOffset=0;packetBegan=nil
                }
                guard closeAttempt==attempt else{return closeResult()}
                if !slot.inputClosed {
                    try slot.child.pollExit(cancel:true,now:uptime)
                    slot.child.closeInput();slot.inputClosed=true;slot.closeBegan=uptime
                }
                while !slot.child.reaped || !slot.child.outputEOF || !slot.child.diagnosticEOF {
                    try drainServiceForClose(slot);try slot.child.pollExit(cancel:uptime-(slot.closeBegan ?? uptime)>5,now:uptime)
                    guard closeAttempt==attempt else{return closeResult()}
                    guard uptime<deadline else{throw LiveASRFailure("服务清理deadline，lease保留")}
                    try await Task.sleep(nanoseconds:5_000_000)
                }
                _ = try settleReleasedService(slot,attempt:token,finalized:nil)
            }
            if let probe {
                while !probe.reaped || !probe.outputEOF || !probe.diagnosticEOF {
                    _ = try probe.readOutput();_ = try probe.readDiagnostic();try probe.pollExit(cancel:true,now:uptime)
                    guard closeAttempt==attempt,uptime<deadline else{throw LiveASRFailure("probe清理未闭合")};try await Task.sleep(nanoseconds:5_000_000)
                }
                guard try physicalRelease(probe) else{throw LiveASRFailure("probe强所有权未知")};self.probe=nil
            }
            if let decoder {
                // Finish any complete old line, then explicit cooperative CANCEL.
                // Failure is retained; reserved ownership cleanup remains callable.
                if !decoder.reaped {
                    do{try await flushControl()}catch{
                        remember(error)
                        if let old=control{discardedControlReceipts.append(["event":"failed-old-control-retired-only-for-owned-close","operation":old.operation.uuidString,"bytesWritten":old.offset,"totalBytes":old.line.count,"error":error.localizedDescription])}
                        control=nil;receivedControl=nil;pendingCredit=nil;cancelLineSafe=false
                        // A partially failed native line cannot safely accept a
                        // new CANCEL. Use only the reserved owned-group cleanup.
                        try decoder.pollExit(cancel:true,now:uptime)
                    }
                    if cancelLineSafe,control==nil,!decoder.reaped,!decoder.forced {try? queue("CANCEL \(currentTicket.epoch)",event:"cancelled",key:"epoch",value:currentTicket.epoch)}
                }
                while !decoder.reaped || !decoder.outputEOF || !decoder.diagnosticEOF {
                    do{try step()}catch{
                        remember(error)
                        if let old=control{discardedControlReceipts.append(["event":"control-failure-retired-during-strong-cleanup","bytesWritten":old.offset,"totalBytes":old.line.count])};control=nil;pendingCredit=nil
                        _ = try decoder.readOutput();_ = try decoder.readDiagnostic()
                    }
                    try decoder.pollExit(cancel:uptime>=deadline-15,now:uptime)
                    guard closeAttempt==attempt,uptime<deadline else{throw LiveASRFailure("provider强清理未闭合，仍持ticket")};try await Task.sleep(nanoseconds:5_000_000)
                }
                guard try physicalRelease(decoder),services.isEmpty else{throw LiveASRFailure("provider或窗口真实资源未知")}
                let token=try policy.beginProviderClose(),native=sourceClosed
                let child=LiveASRLinearChildClose(child:policy.decoderChildID,naturalExitCode:decoder.exitCode,
                    stdoutEOF:decoder.outputEOF,stderrEOF:decoder.diagnosticEOF,remainingResources:0,reaped:decoder.reaped,
                    leaderHeldUntilQuiescent:true,completeExactGroupSnapshot:true,forced:decoder.forced,
                    nativeClosedZero:(try? integer(native ?? [:],"remaining_av_contexts"))==0 && (try? boolean(native ?? [:],"source_fd_closed"))==true && (try? boolean(native ?? [:],"ok"))==true)
                let released=policy.finishProviderClose(attempt:token,receipt:LiveASRLinearProviderClose(provider:policy.providerID,generation:policy.generation,
                    child:child,heldSourceFDClosed:true,sourceFingerprintVerified:(try? boolean(native ?? [:],"source_fingerprint_verified"))==true,remainingAVContexts:0))
                closeHistory.append(["kind":"provider","nativeClosed":native as Any? ?? NSNull(),"releaseProof":"actual-reaped-unreaped-leader-held-until-all-zombie/OS-reclaims-FD-contexts","owned":decoder.exitDiagnostics])
                guard released else{throw LiveASRFailure("provider policy仍持资源")}
            }
            guard services.isEmpty,probe==nil else{throw LiveASRFailure("关闭仍有owned job")}
            if let decoder {guard try physicalRelease(decoder) else{throw LiveASRFailure("关闭仍有owned job")}}
            closedResources=true;pumpTask?.cancel();pumpTask=nil;try finishJournal()
            ring.removeAll();sourceBacklog.removeAll();packet=nil
        }catch{remember(error)}
        return closeResult()
    }
    private func closeResult()->LiveASRCloseResult {
        let nativeProviderZero=(sourceClosed?["remaining_av_contexts"] as? Int)==0 && (sourceClosed?["source_fd_closed"] as? Bool)==true
        // Existing result remains strict-native: missing native close is not0.
        // diagnostics.closedResources separately proves OS physical release.
        return LiveASRCloseResult(decoderNaturalExitCode:decoder?.exitCode,recognizerNaturalExitCode:serviceCloseCount>0 && allServiceNaturalZero ? 0:nil,
            decoderStdoutEOF:decoder?.outputEOF ?? (decoder==nil),recognizerStdoutEOF:services.isEmpty,
            decoderClosedContexts:closedResources && nativeProviderZero ? 0:nil,
            recognizerLiveStreams:closedResources && allNativeServiceZero ? 0:nil,
            recognizerLiveRecognizers:closedResources && allNativeServiceZero ? 0:nil,
            ownedProcessesReaped:closedResources,forcedTermination:anyForced || (decoder?.forced ?? false),
            detail:firstFailure ?? "持续provider与服务真实资源清理")
    }
    private func remember(_ error:Error){if error is LiveASRLinearAcceptanceRetired{return};if firstFailure==nil{firstFailure=error.localizedDescription;failureDetails=(error as? LiveASRChildWriteFailure)?.receipt}}
    private func rotateJournal(_ serial:UInt64)throws{try finishJournal();sourceLines.resetWindowTotalKeepingPartialLine();guard capture else{return};let url=work.appendingPathComponent("raw-window-\(serial).jsonl");let fd=Darwin.open(url.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,mode_t(0o600));guard fd>=0 else{throw LiveASRFailure("原始窗口日志身份已存在")};journal=Journal(fd:fd,serial:serial)}
    private func finishJournal()throws{guard let j=journal else{return};guard fsync(j.fd)==0 else{throw LiveASRFailure("原始窗口日志无法同步")};let result=Darwin.close(j.fd);journal=nil;guard result==0 else{throw LiveASRFailure("日志FD关闭失败")};journals.append(["serial":j.serial,"bytes":j.bytes,"sha256":j.digest.finalize().map{String(format:"%02x",$0)}.joined()])}
    private func record(_ line:Data,service:LiveASRLinearWindowID?=nil)throws{guard capture,var j=journal else{return};let envelope:[String:Any]=["provider":policy.providerID.uuidString,"generation":policy.generation.uuidString,"service":service?.window.uuidString as Any? ?? NSNull(),"hostUptime":uptime,"rawBase64":line.base64EncodedString(),"rawUTF8":String(data:line,encoding:.utf8) as Any? ?? NSNull()];let bytes=try JSONSerialization.data(withJSONObject:envelope,options:[.sortedKeys])+Data([10]);guard j.bytes+bytes.count<=64*1048576 else{throw LiveASRFailure("单窗口原始日志超过64MiB，未提高预算")};var offset=0;while offset<bytes.count{let n=bytes.withUnsafeBytes{Darwin.write(j.fd,$0.baseAddress!.advanced(by:offset),bytes.count-offset)};if n<0 && errno==EINTR{continue};guard n>0 else{throw LiveASRFailure("原始日志写失败")};offset+=n};j.bytes+=bytes.count;j.digest.update(data:bytes);journal=j}
    struct ProductStatus: Sendable {
        let source: LiveASRLinearSource
        let operation: UUID
        let phase: String
        let sourceEOF: Bool
        let coreEOFCompleted: Bool
        let physicallyReleased: Bool
        let failure: String?
    }
    func productStatus()->ProductStatus {
        ProductStatus(source:policy.source,operation:policy.operation,phase:policy.phase.rawValue,
            sourceEOF:sourceEOF,coreEOFCompleted:coreEOFCompleted,physicallyReleased:closedResources,failure:firstFailure ?? policy.firstFailure)
    }
    func presentationIsCurrent(source:LiveASRLinearSource,operation:UUID)->Bool {
        source==policy.source && operation==callbackOperation && acceptance.isOpen && !closing && firstFailure==nil
    }
    /// Main EOF finalizes only the already granted real prefix, including its
    /// original partial packet. It does not invent a full source/window EOF,
    /// accept ungranted future PCM, or make a NEXT handover during termination.
    func finishGrantedForCoreEOF()async throws {
        guard acceptanceIsCurrent() else { return }
        do{try await finishCoreEOFPrefix()}
        catch{
            remember(error);closing=true;callbackOperation=UUID();_ = policy.retireAll()
            throw error
        }
    }
    private func finishCoreEOFPrefix()async throws {
        guard !closing,!finalizingCoreEOF else{return}
        finalizingCoreEOF=true
        let operation=policy.operation
        guard let active=policy.active,let slot=services[active],let window=policy.windows[active] else{return}
        let deadline=uptime+20
        if control != nil{try await flushControl()}
        guard operation==policy.operation,!closing else{return}
        guard nativeControlSerial<UInt64.max else{throw LiveASRFailure("EOF native control serial耗尽")}
        let serial=nativeControlSerial+1
        let ack=try await send("CONTROL \(currentTicket.epoch) \(serial) PAUSE",event:"control_ack",key:"control_serial",value:serial)
        guard try boolean(ack,"paused"),operation==policy.operation,!closing else{return}
        nativeControlSerial=serial;nativePaused=true
        try await finishRetiredPacket(slot,operation:operation)
        guard operation==policy.operation,!closing else{return}
        while policy.windows[active]?.acceptedSamples != window.ledger.submittedSamples {
            try step();guard operation==policy.operation,!closing,uptime<deadline else{throw LiveASRFailure("最终真实input_accepted前缀未闭合")}
            try await Task.sleep(nanoseconds:5_000_000)
        }
        guard let actualWindow=policy.windows[active],actualWindow.ledger.submittedSamples==window.ledger.submittedSamples else{
            throw LiveASRFailure("最终实际服务窗口已变更")
        }
        for other in Array(services.values) where other.id.window != active {
            try await retireService(other,operation:operation)
            guard operation==policy.operation,!closing else{return}
        }
        if window.ledger.submittedSamples>0 {
            if !slot.inputClosed{slot.child.closeInput();slot.inputClosed=true;slot.closeBegan=uptime}
            while !slot.child.reaped || !slot.child.outputEOF || !slot.child.diagnosticEOF {
                try step();try slot.child.pollExit(cancel:false,now:uptime)
                guard operation==policy.operation,!closing,uptime<deadline else{throw LiveASRFailure("最终识别服务强关闭未闭合")}
                try await Task.sleep(nanoseconds:5_000_000)
            }
            guard let final=slot.final,final.event=="eof_final",final.ticket==currentTicket,
                  final.accepted_samples==window.ledger.submittedSamples,final.padding_samples==16000,
                  final.first_input_sequence==window.ledger.firstSequence,final.last_input_sequence==window.ledger.lastSequence,
                  final.stream_generation==actualWindow.streamGeneration,try childClose(slot).clean else{
                throw LiveASRFailure("最终已授权prefix没有实际final/自然closed0")
            }
            if pendingCueDelivery {
                pendingCueDelivery=false
                await cueConsumer(policy.source,callbackOperation,cueLedger.completed,cueLedger.partial)
                guard operation==policy.operation,!closing else{return}
            }
            _ = policy.retireAll()
            let token=try policy.beginWindowClose(slot.id)
            _ = try settleReleasedService(slot,attempt:token,finalized:nil)
        }
        coreEOFCompleted=true
        closing=true;callbackOperation=UUID();_ = policy.retireAll()
        _ = await joinedClose()
    }
    struct ShutdownReceipt: Sendable {
        let result: LiveASRCloseResult
        let actualOwnedResourcesReleased: Bool
        let actualNativeNormalClosure: Bool
    }
    func shutdownReceipt()async->ShutdownReceipt {
        let result=await close()
        return ShutdownReceipt(result:result,actualOwnedResourcesReleased:closedResources,
            actualNativeNormalClosure:result.confirmed && firstFailure==nil && policy.firstFailure==nil &&
            (try? boolean(sourceClosed ?? [:],"ok"))==true &&
            (try? boolean(sourceClosed ?? [:],"source_fingerprint_verified"))==true)
    }
    func diagnostics()throws->Data{
        try JSONSerialization.data(withJSONObject:["status":"actual-runtime-snapshot","providerID":policy.providerID.uuidString,"generation":policy.generation.uuidString,"operation":policy.operation.uuidString,"phase":policy.phase.rawValue,"sourcePID":decoder?.pid as Any? ?? NSNull(),"captureEnabled":capture,"workPath":capture ? work.path:"","actualStartup":actualStartup as Any? ?? NSNull(),"sourceBorn":sourceBorn as Any? ?? NSNull(),"sourceOpened":sourceOpened as Any? ?? NSNull(),"actualActorBudget":lastActorBudget as Any? ?? NSNull(),"currentWindow":currentWindow,"nativeControlSerial":nativeControlSerial,"nativePaused":nativePaused,"nativeSpeed":nativeSpeed,"startedReadyWindow":startedReady?.window.uuidString as Any? ?? NSNull(),"readyServiceCount":policy.windows.values.filter{$0.phase == .ready}.count,"actualWrittenPayloadBytes":writtenPayloadBytes,"actualAcceptedSamples":acceptedPayloadSamples,"ringSamples":ringSamples,"lastNativeBudget":lastBudget as Any? ?? NSNull(),"services":services.values.map{["window":$0.id.window.uuidString,"serial":$0.id.serial,"owned":$0.child.exitDiagnostics]},"closeHistory":closeHistory,"serviceCloseCount":serviceCloseCount,"allNativeServiceZero":allNativeServiceZero,"allServiceNaturalZero":allServiceNaturalZero,"maximumFutureReservedSamples":latestMaximumFutureSamples,"retiredControlObligations":discardedControlReceipts,"closedResources":closedResources,"journals":journals,"firstFailure":firstFailure as Any? ?? NSNull(),"failureDetails":failureDetails as Any? ?? NSNull()],options:[.sortedKeys])
    }
    private func object(_ data:Data)throws->[String:Any]{guard let o=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw LiveASRFailure("实际helper事件不是JSON object")};return o}
    private func strictInteger(_ value:Any?)->Int64?{guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),let v=Int64(n.stringValue) else{return nil};return v}
    private func integer(_ o:[String:Any],_ key:String)throws->Int64{guard let v=strictInteger(o[key]) else{throw LiveASRFailure("缺失整数实际字段：\(key)")};return v}
    private func unsigned(_ o:[String:Any],_ key:String)throws->UInt64{guard let n=o[key] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),let v=UInt64(n.stringValue) else{throw LiveASRFailure("缺失无符号整数实际字段：\(key)")};return v}
    private func real(_ o:[String:Any],_ key:String)throws->Double{guard let n=o[key] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else{throw LiveASRFailure("缺失有限真实字段：\(key)")};return n.doubleValue}
    private func boolean(_ o:[String:Any],_ key:String)throws->Bool{guard let n=o[key] as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{throw LiveASRFailure("缺失布尔实际字段：\(key)")};return n.boolValue}
    private func time(_ o:[String:Any],_ key:String)throws->LiveASRTime{try LiveASRTime(integer(o,key+"_num"),integer(o,key+"_den"))}
    private func ticket(_ o:[String:Any])throws->LiveASRWireTicket{
        let expected=policy.source.track.absoluteFFmpegIndex
        if o["stream_index"] != nil {guard try unsigned(o,"stream_index")==UInt64(expected) else{throw LiveASRFailure("真实流index已换")}}
        else{guard let opened=sourceOpened,try integer(opened,"selected_stream_index")==Int64(expected) else{throw LiveASRFailure("源ticket没有实际流绑定")}}
        let segmentKey=o["event"] as? String == "stream_created" ? "timing_segment":"segment"
        return LiveASRWireTicket(epoch:try unsigned(o,"epoch"),timingSegment:try unsigned(o,segmentKey),itemSerial:try unsigned(o,"item"),streamIndex:UInt32(expected))
    }
    private func eventFingerprint(_ o:[String:Any])throws->LiveASRFileFingerprint{let sec=try integer(o,"mtime_seconds"),ns=try integer(o,"mtime_nanoseconds"),a=sec.multipliedReportingOverflow(by:1_000_000_000),b=a.partialValue.addingReportingOverflow(ns);guard sec>=0,(0..<1_000_000_000).contains(ns),!a.overflow,!b.overflow else{throw LiveASRFailure("事件FD时间溢出")};return LiveASRFileFingerprint(device:try unsigned(o,"device"),inode:try unsigned(o,"inode"),byteCount:try unsigned(o,"bytes"),modificationNanoseconds:b.partialValue)}
    private func fingerprint(_ s:stat)throws->LiveASRFileFingerprint{guard s.st_mode & mode_t(S_IFMT)==mode_t(S_IFREG),s.st_size>0 else{throw LiveASRFailure("源不是regular FD")};let a=Int64(s.st_mtimespec.tv_sec).multipliedReportingOverflow(by:1_000_000_000),b=a.partialValue.addingReportingOverflow(Int64(s.st_mtimespec.tv_nsec));guard s.st_mtimespec.tv_sec>=0,(0..<1_000_000_000).contains(s.st_mtimespec.tv_nsec),!a.overflow,!b.overflow else{throw LiveASRFailure("源mtime溢出")};return LiveASRFileFingerprint(device:UInt64(UInt32(truncatingIfNeeded:s.st_dev)),inode:UInt64(s.st_ino),byteCount:UInt64(s.st_size),modificationNanoseconds:b.partialValue)}
}
