import Foundation

/// Exact SPCM v1 contract pinned by protocol SHA 2a92a61d13a0daa303c0bfd4f5709d0b9f4ecdbc732bfbdf0a915d9cbeaa1582.
struct LiveASRPCMFrame: Sendable {
    let ticket: LiveASRWireTicket
    let flags: UInt32
    let streamTimeBaseNumerator: UInt32
    let streamTimeBaseDenominator: UInt32
    let sourceBestEffortTimestamp: Int64
    let pcmStartTimestamp: Int64
    let pcmTimeDenominator: Int64
    let delayBeforeConvert: Int64
    let sequence: UInt64
    let sampleCount: UInt32
    let inputSampleRate: UInt32
    let decodedFrameOrdinal: UInt32
    let offsetInConvertedFrameSamples: UInt32
    let packet: Data
    var ptsKnown: Bool { flags & 1 != 0 }
    var isDrain: Bool { flags & 4 != 0 }
    func rawTime(atSampleOffset offset: UInt32) throws -> LiveASRTime {
        guard ptsKnown, offset <= sampleCount else { throw LiveASRFailure("此音频块没有可定位的 PTS") }
        let amount = Int64(offset).multipliedReportingOverflow(by: Int64(inputSampleRate))
        let time = pcmStartTimestamp.addingReportingOverflow(amount.partialValue)
        guard !amount.overflow, !time.overflow else { throw LiveASRFailure("PCM 时码溢出") }
        return try LiveASRTime(time.partialValue, pcmTimeDenominator)
    }
}

struct LiveASRSPCMParser {
    private var pending = Data()
    private var lastSequence: UInt64 = 0
    /// Conservative physical payload upper bound; header bytes can only overcount.
    var retainedWireBytes: Data { pending }
    static let maximumReadBytes = 16_384
    static let maximumRecordBytes = 1_392
    mutating func append(_ chunk: Data) throws -> [LiveASRPCMFrame] {
        guard !chunk.isEmpty, chunk.count <= Self.maximumReadBytes,
              pending.count + chunk.count <= Self.maximumReadBytes + Self.maximumRecordBytes else {
            throw LiveASRFailure("PCM 输入缓冲超过上限")
        }
        pending.append(chunk)
        var frames: [LiveASRPCMFrame] = []
        while pending.count >= 112 {
            let header = Array(pending.prefix(112))
            func u(_ offset: Int, _ count: Int) -> UInt64 {
                var result: UInt64 = 0
                for index in 0..<count { result |= UInt64(header[offset + index]) << (index * 8) }
                return result
            }
            guard Array(header[0..<4]) == [83, 80, 67, 77], u(4,2) == 1, u(6,2) == 112 else {
                throw LiveASRFailure("PCM 协议版本或帧头无效")
            }
            let record = Int(u(8,4)), flags = UInt32(u(12,4)), samples = UInt32(u(96,4))
            guard samples >= 1, samples <= 320, record == 112 + Int(samples) * 4,
                  record <= Self.maximumRecordBytes else { throw LiveASRFailure("PCM 样本边界无效") }
            guard pending.count >= record else { break }
            let epoch = u(16,8), segment = u(24,8), item = u(32,8), index = UInt32(u(40,4))
            let tbNumerator = UInt32(u(44,4)), tbDenominator = UInt32(u(48,4))
            let sourcePTS = Int64(bitPattern: u(56,8)), pcmPTS = Int64(bitPattern: u(64,8))
            let denominator = Int64(bitPattern: u(72,8)), delay = Int64(bitPattern: u(80,8))
            let sequence = u(88,8), rate = UInt32(u(100,4)), ordinal = UInt32(u(104,4))
            guard flags & ~UInt32(7) == 0, epoch > 0, item > 0, index <= 4096,
                  tbNumerator > 0, tbDenominator > 0, u(52,4) == 16000,
                  rate >= 8000, rate <= 96000, denominator == Int64(rate) * 16000,
                  delay >= 0, sequence > lastSequence, ordinal > 0,
                  (flags & 1 != 0) == (pcmPTS != .min),
                  (flags & 2 != 0) == (pcmPTS != .min && pcmPTS < 0) else {
                throw LiveASRFailure("PCM 时基、代次或序号无效")
            }
            let packet = pending.prefix(record)
            let bytes = Array(packet)
            for offset in stride(from: 112, to: record, by: 4) {
                let bits = UInt32(bytes[offset]) | UInt32(bytes[offset+1]) << 8
                    | UInt32(bytes[offset+2]) << 16 | UInt32(bytes[offset+3]) << 24
                guard Float(bitPattern: bits).isFinite else { throw LiveASRFailure("PCM 中存在非有限样本") }
            }
            frames.append(LiveASRPCMFrame(ticket: LiveASRWireTicket(epoch: epoch, timingSegment: segment,
                itemSerial: item, streamIndex: index), flags: flags,
                streamTimeBaseNumerator: tbNumerator, streamTimeBaseDenominator: tbDenominator,
                sourceBestEffortTimestamp: sourcePTS, pcmStartTimestamp: pcmPTS,
                pcmTimeDenominator: denominator, delayBeforeConvert: delay, sequence: sequence,
                sampleCount: samples, inputSampleRate: rate, decodedFrameOrdinal: ordinal,
                offsetInConvertedFrameSamples: UInt32(u(108,4)), packet: Data(packet)))
            lastSequence = sequence; pending.removeFirst(record)
        }
        return frames
    }
    func finish() throws {
        guard pending.isEmpty else { throw LiveASRFailure("PCM 流在完整块之前结束") }
    }
}

struct LiveASRTimelineLedger {
    struct Span {
        let firstSample: UInt64
        let endSample: UInt64
        let frame: LiveASRPCMFrame
    }
    private(set) var ticket: LiveASRWireTicket?
    private(set) var submittedSamples: UInt64 = 0
    private(set) var firstSequence: UInt64 = 0
    private(set) var lastSequence: UInt64 = 0
    private var spans: [Span] = []
    private let maximumSpans = 16384
    /// Called before forwarding the complete unchanged packet to the recognizer.
    /// It grants a frame; it does not claim C API has accepted its samples yet.
    mutating func grant(_ frame: LiveASRPCMFrame) throws {
        if ticket != frame.ticket { self = LiveASRTimelineLedger(); ticket = frame.ticket }
        guard frame.sequence > lastSequence else { throw LiveASRFailure("PCM ledger 序号重复") }
        let end = submittedSamples.addingReportingOverflow(UInt64(frame.sampleCount))
        guard !end.overflow else { throw LiveASRFailure("PCM ledger 样本计数溢出") }
        if let previous = spans.last, frame.ptsKnown && previous.frame.ptsKnown {
            let expected = try previous.frame.rawTime(atSampleOffset: previous.frame.sampleCount)
            let actual = try frame.rawTime(atSampleOffset: 0)
            /// A discontinuity must carry a new actual timingSegment.
            let previousTick = Double(previous.frame.streamTimeBaseNumerator) / Double(previous.frame.streamTimeBaseDenominator)
            let currentTick = Double(frame.streamTimeBaseNumerator) / Double(frame.streamTimeBaseDenominator)
            let tolerance = 2 * max(previousTick, currentTick) + 1.0 / Double(frame.inputSampleRate) + 1.0 / 16000.0
            guard abs(expected.seconds - actual.seconds) <= tolerance else {
                throw LiveASRFailure("源时间轴跳变未提供新的 timingSegment")
            }
        }
        guard spans.count < maximumSpans else { throw LiveASRFailure("PCM 源区间凭据达到有界容量") }
        spans.append(Span(firstSample: submittedSamples, endSample: end.partialValue, frame: frame))
        submittedSamples = end.partialValue; lastSequence = frame.sequence
        if firstSequence == 0 { firstSequence = frame.sequence }
    }
    func verifyAccepted(_ count: UInt64, first: UInt64, last: UInt64) throws {
        guard count > 0, count <= submittedSamples, first == firstSequence,
              spans.contains(where: { $0.frame.sequence == last && $0.endSample == count }) else {
            throw LiveASRFailure("识别器接受范围没有相同 PCM 块凭据")
        }
    }
    func rawTime(atSample sample: UInt64) throws -> LiveASRTime {
        guard sample <= submittedSamples else { throw LiveASRFailure("识别时码超出真实音频范围") }
        if let span = spans.first(where: { $0.firstSample <= sample && sample < $0.endSample }) {
            return try span.frame.rawTime(atSampleOffset: UInt32(sample - span.firstSample))
        }
        if let span = spans.last, sample == span.endSample {
            return try span.frame.rawTime(atSampleOffset: span.frame.sampleCount)
        }
        throw LiveASRFailure("此时码已超过有界 PTS ledger，未生成定位字幕")
    }
    func normalizedTime(atSample sample: UInt64, proof: LiveASRSourceProof, rebase: Bool) throws -> LiveASRTime {
        let time = try rawTime(atSample: sample)
        return rebase ? try time.subtracting(proof.rawOrigin) : time
    }
    /// Float timestamps have finite precision; round only the model sample index.
    /// No fabricated media timestamp or missing-PTS substitute is introduced.
    func sampleIndex(engineSeconds: Double, accepted: UInt64) throws -> UInt64 {
        guard engineSeconds.isFinite, engineSeconds >= 0, engineSeconds <= 21600,
              engineSeconds * 16000 <= Double(accepted) + 1 else {
            throw LiveASRFailure("模型时码位于真实 PCM 范围之外（含 EOF padding）")
        }
        return min(accepted, UInt64((engineSeconds * 16000).rounded()))
    }
}
