import Foundation

struct LiveASRFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// Raw source time; negative times remain valid here. SRT validation is later.
struct LiveASRTime: Equatable, Sendable {
    let numerator: Int64
    let denominator: Int64
    init(_ numerator: Int64, _ denominator: Int64) throws {
        guard denominator > 0, numerator != .min else { throw LiveASRFailure("音频时基无效") }
        let divisor = Self.gcd(abs(numerator), denominator)
        self.numerator = numerator / divisor; self.denominator = denominator / divisor
    }
    private static func gcd(_ first: Int64, _ second: Int64) -> Int64 {
        var a = first, b = second
        while b != 0 { let remainder = a % b; a = b; b = remainder }
        return max(1, a)
    }
    var seconds: Double { Double(numerator) / Double(denominator) }
    func adding(_ value: LiveASRTime) throws -> LiveASRTime {
        let divisor = Self.gcd(denominator, value.denominator)
        let scaleA = value.denominator / divisor, scaleB = denominator / divisor
        let a = numerator.multipliedReportingOverflow(by: scaleA)
        let b = value.numerator.multipliedReportingOverflow(by: scaleB)
        let total = a.partialValue.addingReportingOverflow(b.partialValue)
        let base = denominator.multipliedReportingOverflow(by: scaleA)
        guard !a.overflow, !b.overflow, !total.overflow, !base.overflow else {
            throw LiveASRFailure("音频时码超过可处理范围")
        }
        return try LiveASRTime(total.partialValue, base.partialValue)
    }
    func subtracting(_ value: LiveASRTime) throws -> LiveASRTime {
        try adding(LiveASRTime(-value.numerator, value.denominator))
    }
}

struct LiveASRBinding: Equatable, Sendable {
    let coreID: UUID
    let queueItemID: UUID
    let loadToken: UUID
    /// Real current/playing playlist entry readback, not the cached selected row.
    let nativeEntryID: Int64
    let originalURL: URL
}

/// Load/attach receipt for one user-selected local external audio source.
/// This is path-bound pre-open identity, not a claim to mpv's private source FD.
struct LiveASRExternalAudioSource: Equatable, Sendable {
    let url: URL
    let fingerprint: LiveASRFileFingerprint
    let attachmentID: UUID
    let rebaseAtAttachment: Bool
    let audioDemuxerAtAttachment: String
}

struct LiveASRTrack: Equatable, Sendable {
    let runtimeAudioID: Int
    let absoluteFFmpegIndex: Int
    let codec: String
    let sampleRate: Int
    let channels: Int
    let channelLayout: String
    let language: String
    let title: String
    let isExternal: Bool
    // Default preserves the existing embedded-track call sites.
    var externalSource: LiveASRExternalAudioSource? = nil
}

struct LiveASRFileFingerprint: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let byteCount: UInt64
    let modificationNanoseconds: Int64
}

struct LiveASRToolsConfiguration: Sendable {
    let pcmDecoderURL: URL
    let recognizerServiceURL: URL
    let ffprobeURL: URL
    let modelDirectory: URL
    let encoderModelURL: URL
    let decoderModelURL: URL
    let joinerModelURL: URL
    let tokensURL: URL
    let runtimeManifestURL: URL
    let modelManifestURL: URL
    let profileID: String
    /// Populated by the asynchronous full-byte manifest resolver, never inferred
    /// from a helper executable filename. This is the compiled decoder C source.
    let pcmHelperSourceSHA256: String
    let supportsGracefulInputLimit: Bool
    var supportsFirstBlockHold: Bool = false
    var supportsExactSourceRange: Bool = false
}

struct LiveASRSnapshot: Sendable {
    let binding: LiveASRBinding?
    let selectedTrack: LiveASRTrack?
    let loaded: Bool
    let loading: Bool
    let paused: Bool
    let seeking: Bool
    let eof: Bool
    /// Optional actual Core properties: missing must not become numeric zero.
    let corePosition: Double?
    let coreAudioPTS: Double?
    let speed: Double
    let audioDelay: Double
    let currentDemuxer: String
    let rebaseStartTime: Bool
    let demuxerStartTime: Double?
    /// Read before each load request with regular O_NOFOLLOW/nonblocking fstat.
    /// This is a path-bound load fingerprint, not access to mpv's opened FD.
    let loadedSourceFingerprint: LiveASRFileFingerprint?
    let observedUptime: Double
    /// Host advances on an accepted user seek and actual native SEEK events.
    /// Settled is a matching RESTART/actual position receipt, not !seeking alone.
    let seekGeneration: UInt64
    let settledSeekGeneration: UInt64?
}

struct LiveASRSourceProof: Sendable {
    let canonicalSourceURL: URL
    let device: UInt64
    let inode: UInt64
    let byteCount: UInt64
    let modificationNanoseconds: Int64
    let actualFFmpegIndex: Int
    let actualCodec: String
    let actualSampleRate: Int
    let actualChannels: Int
    /// Independently proved file clock origin; never startup time-pos minus count.
    let rawOrigin: LiveASRTime
    let sourceOriginEvidence: String
    let helperSourceSHA256: String
    let decoderLibraryABI: String
    let sourceDescriptorHeld: Bool
    var fingerprint: LiveASRFileFingerprint {
        LiveASRFileFingerprint(device: device, inode: inode, byteCount: byteCount,
            modificationNanoseconds: modificationNanoseconds)
    }
    func validate(for snapshot: LiveASRSnapshot) throws {
        guard let binding = snapshot.binding, let track = snapshot.selectedTrack,
              binding.originalURL.isFileURL, canonicalSourceURL.isFileURL,
              (track.externalSource?.url ?? binding.originalURL).standardizedFileURL == canonicalSourceURL.standardizedFileURL,
              snapshot.currentDemuxer == "lavf",
              track.isExternal == (track.externalSource != nil),
              !track.isExternal || (snapshot.rebaseStartTime && track.externalSource?.rebaseAtAttachment == true
                  && ["", "lavf", "+lavf"].contains(track.externalSource?.audioDemuxerAtAttachment ?? "invalid")
                  && track.absoluteFFmpegIndex == 0 && track.codec.hasPrefix("pcm_") && rawOrigin.numerator == 0),
              snapshot.loadedSourceFingerprint != nil,
              track.absoluteFFmpegIndex == actualFFmpegIndex, actualFFmpegIndex >= 0,
              actualFFmpegIndex <= 4096, track.codec == actualCodec,
              track.sampleRate == actualSampleRate, track.channels == actualChannels,
              actualSampleRate >= 8000, actualSampleRate <= 96000, actualChannels >= 1,
              actualChannels <= 16, device > 0, inode > 0, byteCount > 0,
              (track.externalSource?.fingerprint ?? snapshot.loadedSourceFingerprint) == fingerprint,
              sourceDescriptorHeld, !sourceOriginEvidence.isEmpty,
              rawOrigin.seconds.isFinite, abs(rawOrigin.seconds) <= 86_400,
              helperSourceSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              decoderLibraryABI == "avformat63/avcodec63/avutil61/swresample7" else {
            throw LiveASRFailure("当前本地音轨缺少可核实的流索引或源时间轴，未开始识别")
        }
    }
}

struct LiveASRWireTicket: Equatable, Sendable {
    let epoch: UInt64
    let timingSegment: UInt64
    let itemSerial: UInt64
    let streamIndex: UInt32
}

struct LiveASROpenRequest: Sendable {
    let sessionID: UUID
    let processID: UUID
    let itemSerial: UInt64
    let initialEpoch: UInt64
    let snapshot: LiveASRSnapshot
    let maximumDecodedSeconds: Double
    // Typed startup target only for a confirmed prior prefix; never overwrites
    // the actual Host snapshot or manufactures a Core seek receipt.
    var continuationStart: LiveASRTime? = nil
    // Preparation can select transport without claiming a future source time.
    // Only the prior real final/close receipt later supplies the exact target.
    var preparedContinuationTransport: Bool = false
    // Continuous-local reconstruction; requests without this flag retain ordinary SEEK.
    var exactContinuousSourceRanges: Bool = false
}

enum LiveASRInvalidation: String, Sendable {
    case seek, speedChange, trackChange, load, stop, queueAdvance, eof, quit, discontinuity
}

enum LiveASRTimingQuality: String, Sendable {
    case tokenStartAndAcceptedInputEnd, engineSegmentAndAcceptedInputRange
}

struct LiveASRCue: Identifiable, Sendable {
    let id: UUID
    let epoch: UInt64
    let streamGeneration: UInt64
    let engineSegment: Int
    let revision: UInt64
    let start: LiveASRTime
    let end: LiveASRTime
    let text: String
    let final: Bool
    let timingQuality: LiveASRTimingQuality
    // Pair namespace is required because epoch/stream/revision restart per pair.
    var processID: UUID? = nil
}

struct LiveASROverlay: Sendable {
    let plainText: String
    let isPartial: Bool
    /// Host supplies an exclusive owned osd-overlay ID and current OSD viewport.
    /// No sid/sub-add/sub-reload or user preference mutation is permitted.
}

struct LiveASRCloseResult: Sendable {
    let decoderNaturalExitCode: Int32?
    let recognizerNaturalExitCode: Int32?
    let decoderStdoutEOF: Bool
    let recognizerStdoutEOF: Bool
    let decoderClosedContexts: Int?
    let recognizerLiveStreams: Int?
    let recognizerLiveRecognizers: Int?
    let ownedProcessesReaped: Bool
    let forcedTermination: Bool
    let detail: String
    var resourcesReleased: Bool {
        decoderStdoutEOF && recognizerStdoutEOF && decoderClosedContexts == 0
        && recognizerLiveStreams == 0 && recognizerLiveRecognizers == 0
        && ownedProcessesReaped
    }
    var confirmed: Bool {
        decoderNaturalExitCode == 0 && recognizerNaturalExitCode == 0
        && resourcesReleased && !forcedTermination
    }
}
