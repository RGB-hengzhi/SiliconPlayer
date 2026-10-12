import Foundation

/// Field names match Root's frozen spcm-online-service repair1; raw JSON is kept
/// only in bounded memory for independent parser validation, not diagnostic logs.
struct LiveASRRecognitionEvent: Decodable, Sendable {
    let sequence: UInt64
    let event: String
    let epoch: UInt64
    let timing_segment: UInt64
    let item: UInt64
    let stream_index: UInt32
    let stream_generation: UInt64
    let accepted_samples: UInt64
    let padding_samples: UInt64
    let first_input_sequence: UInt64
    let last_input_sequence: UInt64
    let revision: UInt64
    let final: Bool
    let text: String
    let tokens: [String]
    let timestamps: [Double]?
    let engine_result_json: String
    let engine_start_time_seconds: Double
    let engine_segment: Int
    let recognizer_sample_origin: Int
    let live_recognizers: Int
    let live_streams: Int
    var ticket: LiveASRWireTicket {
        LiveASRWireTicket(epoch: epoch, timingSegment: timing_segment, itemSerial: item, streamIndex: stream_index)
    }
    static func decode(_ line: Data) throws -> LiveASRRecognitionEvent {
        guard !line.isEmpty, line.count < 262_144 else { throw LiveASRFailure("识别事件超过输入上限") }
        let value = try JSONDecoder().decode(Self.self, from: line)
        struct Engine: Decodable { let text: String; let start_time: Double; let segment: Int }
        guard value.epoch > 0, value.item > 0, value.stream_generation > 0,
              value.stream_index <= 4096, value.sequence > 0, value.revision > 0,
              value.accepted_samples > 0, value.accepted_samples <= 16000 * 21600,
              value.padding_samples <= 16000, value.first_input_sequence > 0,
              value.last_input_sequence >= value.first_input_sequence,
              value.live_recognizers == 1, value.live_streams == 1,
              value.recognizer_sample_origin == 0,
              value.engine_segment >= 0, value.engine_segment <= 1_000_000,
              value.engine_start_time_seconds.isFinite,
              value.engine_start_time_seconds >= 0, value.engine_start_time_seconds <= 21600,
              value.text.utf8.count < 16_384, value.tokens.count <= 4096,
              value.tokens.allSatisfy({ $0.utf8.count < 2048 }),
              value.engine_result_json.utf8.count < 131_072,
              ["partial", "endpoint_final", "eof_final"].contains(value.event),
              value.final == (value.event != "partial"),
              !value.text.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 10 && $0.value != 9 }) else {
            throw LiveASRFailure("识别事件身份或正文边界无效")
        }
        if let timestamps = value.timestamps {
            guard timestamps.count == value.tokens.count, timestamps.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  zip(timestamps, timestamps.dropFirst()).allSatisfy({ $0.0 <= $0.1 }) else {
                throw LiveASRFailure("模型 token 时码无效")
            }
        }
        let engine = try JSONDecoder().decode(Engine.self, from: Data(value.engine_result_json.utf8))
        guard engine.text == value.text, engine.segment == value.engine_segment,
              engine.start_time.isFinite,
              abs(engine.start_time - value.engine_start_time_seconds) <= max(0.000001, abs(engine.start_time) * 0.0000001) else {
            throw LiveASRFailure("原始引擎 JSON 与识别事件不一致")
        }
        return value
    }
}

enum LiveASRFeedDecision: Sendable { case grant, hold, dropRetired, stop }
enum LiveASRCloseMode: Sendable { case cancel, finalizeGrantedPCM }

enum LiveASRSourceRangeKind: String, Equatable, Sendable {
    case sourceFloor, confirmedContinuation
}

struct LiveASRTransition: Sendable {
    let requestID: UUID
    let controlRevision: UInt64
    let targetEpoch: UInt64
    let rawTargetMicroseconds: Int64
    let paused: Bool
    let speed: Double
    // Exact source target for fresh-history continuation; nil keeps ordinary SEEK.
    var exactRawRangeStart: LiveASRTime? = nil
    var exactRangeKind: LiveASRSourceRangeKind = .sourceFloor
}

/// External source completion is distinct from the primary player's EOF.
/// The final event was actually granted by the current consumer before this
/// receipt. Both real children must have reached natural zero exits, drained
/// their pipes and reported zero owned resources; this is never a cancel ACK.
struct LiveASRExternalSourceCompletion: Sendable {
    let processID: UUID
    let sourceEOFTicket: LiveASRWireTicket
    let acceptedFinal: LiveASRRecognitionEvent
    let closeResult: LiveASRCloseResult
    /// Atomic actual post-close snapshot. Normal factories include counters
    /// only; transcript/header wire remains opt-in private capture.
    let diagnosticSnapshot: Data
}

/// Real process input bound; cumulative decoded samples include retired startup
/// packets. This is distinct from media EOF and from the current accepted prefix.
struct LiveASRInputLimitReceipt: Sendable {
    let processID: UUID
    let ticket: LiveASRWireTicket
    let maximumSamples: UInt64
    let decodedSamples: UInt64
    let nextChunkSamplesNotPublished: UInt32
}
struct LiveASRInputLimitCompletion: Sendable {
    let limit: LiveASRInputLimitReceipt
    let acceptedFinal: LiveASRRecognitionEvent
    let closeResult: LiveASRCloseResult
    /// Full actual final/close wire only for an opt-in private capture factory.
    /// Carried synchronously with the receipt, never recovered by timing a poll.
    var diagnosticCapture: Data? = nil
}

enum LiveASRPipelineEvent: Sendable {
    case pcmBeforeForward(LiveASRPCMFrame)
    case recognizerStreamCreated(ticket: LiveASRWireTicket, generation: UInt64, serviceSequence: UInt64)
    case recognition(LiveASRRecognitionEvent)
    case decoderReachedEOF
    case externalDecoderReachedEOF(ticket: LiveASRWireTicket)
    case externalSourceCompleted(LiveASRExternalSourceCompletion)
    case decoderInputLimitReached(LiveASRInputLimitReceipt)
    case inputLimitSourceCompleted(LiveASRInputLimitCompletion)
    case failure(String)
}

/// Typed interface shared with the separately drafted real owned process pair.
protocol LiveASROwnedSession: AnyObject, Sendable {
    var processID: UUID { get }
    /// Reserved before spawn. start must return with PCM forwarding still held.
    /// Failure/close during setup closes all partially created owned resources.
    func start(emit: @escaping @Sendable (LiveASRPipelineEvent) async -> LiveASRFeedDecision) async throws -> LiveASRSourceProof
    /// One co-owned decoder + recognizer pair. Numeric decoder controls only;
    /// actual ACK/current epoch tracked internally, latest request wins. A
    /// decoder process restart ALWAYS replaces the recognizer process as well.
    func transition(_ request: LiveASRTransition) async throws
    func setPaused(_ paused: Bool, epoch: UInt64, controlRevision: UInt64) async throws
    /// Idempotent bounded close; cancel can upgrade an ongoing EOF finalization.
    /// Must drain both stderr streams and stdout, waitpid exact owned children,
    /// and return actual closed/resource counts. Never global process killing.
    func close(_ mode: LiveASRCloseMode) async -> LiveASRCloseResult
    /// Bounded actual saved-wire capture only when explicitly opted in by host.
    /// No raw source URL/headers; transcript data stays in memory until requested.
    func diagnostics() async -> Data
}

@MainActor protocol LiveASRBackendFactory {
    /// Synchronous reservation enables cancellation while async setup awaits.
    /// No HOME/home/CODEX_HOME override; private work URL + optional TMPDIR only.
    func reserve(_ request: LiveASROpenRequest) throws -> any LiveASROwnedSession
}

@MainActor protocol LiveASRHost: AnyObject {
    /// Reads current Core playing/current entry and selected track on each call.
    /// It must not assemble these values exclusively from @Published snapshots.
    func liveASRSnapshot() -> LiveASRSnapshot
    func setLiveASROverlay(_ overlay: LiveASROverlay?, owner: UUID, binding: LiveASRBinding) throws
    /// Compare owner before clearing so late old teardown cannot erase new OSD.
    /// true only if this owner is absent, the Core is actually closed, or the
    /// real none-command succeeded. Failed removal retains host ownership.
    func clearLiveASROverlay(owner: UUID) -> Bool
}

struct LiveASRCueLedger {
    private(set) var completed: [LiveASRCue] = []
    private(set) var partial: LiveASRCue?
    private var lastRevisions: [String: UInt64] = [:]
    private let maximumCues = 8192
    private let maximumTextBytes = 8 * 1_048_576
    mutating func clearPartial() { partial = nil }
    mutating func accept(_ event: LiveASRRecognitionEvent, timeline: LiveASRTimelineLedger,
                         proof: LiveASRSourceProof, rebase: Bool, processID: UUID? = nil) throws {
        let key = "\(processID?.uuidString ?? "legacy"):\(event.epoch):\(event.stream_generation):\(event.engine_segment)"
        guard event.revision > (lastRevisions[key] ?? 0) else { throw LiveASRFailure("识别版本重复或迟到") }
        lastRevisions[key] = event.revision
        if lastRevisions.count > 16384 { throw LiveASRFailure("识别版本 ledger 达到会话上限，请先导出") }
        guard !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if event.final { partial = nil }; return
        }
        try timeline.verifyAccepted(event.accepted_samples, first: event.first_input_sequence, last: event.last_input_sequence)
        let timestamp = event.timestamps?.first
        let engineStart = event.engine_start_time_seconds + (timestamp ?? 0)
        let sample = try timeline.sampleIndex(engineSeconds: engineStart, accepted: event.accepted_samples)
        let start = try timeline.normalizedTime(atSample: sample, proof: proof, rebase: rebase)
        let end = try timeline.normalizedTime(atSample: event.accepted_samples, proof: proof, rebase: rebase)
        guard start.seconds >= 0, end.seconds > start.seconds, end.seconds <= 999_999_999 else {
            throw LiveASRFailure("保留原始 PTS 后此段无法写成有效 SRT，未猜测或裁剪时间")
        }
        let cue = LiveASRCue(id: UUID(), epoch: event.epoch, streamGeneration: event.stream_generation,
            engineSegment: event.engine_segment, revision: event.revision, start: start, end: end,
            text: event.text, final: event.final,
            timingQuality: timestamp == nil ? .engineSegmentAndAcceptedInputRange : .tokenStartAndAcceptedInputEnd,
            processID: processID)
        if !event.final { partial = cue; return }
        var candidate = completed
        /// Seek/A–B repeated passes replace a substantially identical source range;
        /// arbitrary overlapping cues are not merged or assigned fake word ends.
        candidate.removeAll { old in
            let overlap = min(old.end.seconds, end.seconds) - max(old.start.seconds, start.seconds)
            let shorter = min(old.end.seconds - old.start.seconds, end.seconds - start.seconds)
            return overlap > 0 && shorter > 0 && overlap / shorter >= 0.8
                && abs(old.start.seconds - start.seconds) <= 0.5
        }
        candidate.append(cue)
        guard candidate.count <= maximumCues, candidate.reduce(0, { $0 + $1.text.utf8.count }) <= maximumTextBytes else {
            throw LiveASRFailure("已识别字幕达到会话容量，请导出后重新开始")
        }
        completed = candidate.sorted { $0.start.seconds < $1.start.seconds }; partial = nil
    }
    func overlay(at position: Double) -> LiveASROverlay? {
        guard position.isFinite else { return nil }
        if let cue = partial, cue.start.seconds <= position, position < cue.end.seconds {
            return LiveASROverlay(plainText: cue.text, isPartial: true)
        }
        if let cue = completed.last(where: { $0.start.seconds <= position && position < $0.end.seconds }) {
            return LiveASROverlay(plainText: cue.text, isPartial: false)
        }
        return nil
    }
}
