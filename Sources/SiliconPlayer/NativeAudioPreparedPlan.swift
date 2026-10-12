import Foundation
import PlayerCore

// A prepared segment binds real media inspection and resource fingerprints
// to the logical queue and effective playback configuration.
struct NativeAudioInspection: Sendable {
    struct Fingerprint: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modificationNanoseconds: UInt64
    }
    struct DirectoryStamp: Equatable, Sendable {
        let url: URL
        let value: Fingerprint? // nil records a confirmed ENOENT, not an unreadable directory.
    }
    let originalURL: URL
    let fingerprint: Fingerprint
    let container: String
    let codec: String
    let sampleRate: Int
    let channels: Int
    let channelLayout: String
    let significantBits: Int
    let audioStreamCount: Int
    let nonAudioStreamCount: Int
    let seekable: Bool
    let duration: Double
    let externalDiscoveryProvenEmpty: Bool
    let discoveryStamps: [DirectoryStamp]
}

struct NativeAudioPlanEntry {
    let item: MediaItem
    let inspection: NativeAudioInspection
    let options: [String: String]
}

struct NativeAudioPreparedPlan {
    let id: UUID
    let owner: NativeQueueOwner
    let revision: NativeQueueRevision
    let entries: [NativeAudioPlanEntry]
    let initialItemID: UUID
    let fullLogicalQueue: Bool
    let startPlaying: Bool
}

enum NativeAudioPreparationFailure: Error {
    case ineligible(UUID, String)
    case staleOrIncompleteProof
}

enum NativeAudioPlanBuilder {
    struct Environment {
        let revision: NativeQueueRevision
        let base: PlaybackSettings
        let effective: PlaybackSettings
        let activeSpeed: Double
        let audioDelay: Double
        let subtitleDelay: Double
        let profileBlocked: Bool
        let currentTrackAutomatic: Bool
        let realAudioFilterEmpty: Bool
        let realOutputMatchesSource: Bool
        let mediaDocument: MediaPreferenceDocument
        let observedSampleRate: Int
        let observedChannels: Int
        let observedLayout: String
    }
    /// Conservative first phase: a bounded forward segment beginning at the
    /// current UUID. Middle selection never rotates logical order or pretends
    /// it has the full queue; list wrap remains ordinary at that boundary.
    static func make(logical: Playlist, owner: NativeQueueOwner, environment e: Environment,
                     inspections: [UUID: NativeAudioInspection], resumePositions: [UUID: Double],
                     startPlaying: Bool) throws -> NativeAudioPreparedPlan {
        guard let current = logical.currentItem,
              let start = logical.items.firstIndex(where: { $0.id == current.id }),
              !e.profileBlocked, e.base == e.effective,
              e.activeSpeed == 1, e.audioDelay == 0, e.subtitleDelay == 0,
              e.currentTrackAutomatic, e.realAudioFilterEmpty, e.realOutputMatchesSource else {
            throw NativeAudioPreparationFailure.staleOrIncompleteProof
        }
        let settings = e.effective.sanitized()
        guard !settings.equalizerEnabled, !settings.normalizeAudio,
              !settings.processing.swapChannels, settings.processing.pitchSemitones == 0,
              !settings.processing.crossfeed, settings.processing.audioSampleRate == 0,
              settings.channelMode == "auto-safe" else {
            throw NativeAudioPreparationFailure.ineligible(current.id, "输出或音频处理需要普通切换")
        }
        var entries: [NativeAudioPlanEntry] = []
        var expectedFormat: String?
        for item in logical.items.dropFirst(start).prefix(8) {
            guard item.webMedia == nil, item.url.isFileURL,
                  let inspection = inspections[item.id],
                  inspection.originalURL == item.url,
                  inspection.audioStreamCount == 1, inspection.nonAudioStreamCount == 0,
                  inspection.seekable, inspection.duration.isFinite, inspection.duration > 0,
                  ["wav", "flac"].contains(inspection.container),
                  ["flac", "pcm_s16le", "pcm_s24le", "pcm_s32le"].contains(inspection.codec),
                  inspection.externalDiscoveryProvenEmpty,
                  inspection.sampleRate > 0, inspection.channels > 0,
                  !inspection.channelLayout.isEmpty, inspection.significantBits > 0,
                  resumePositions[item.id] == nil else { break }
            if entries.isEmpty,
               inspection.sampleRate != e.observedSampleRate || inspection.channels != e.observedChannels
                || inspection.channelLayout != e.observedLayout { break }
            // No saved record is silently omitted. The boundary falls back to
            // ordinary load and its existing per-media restoration contract.
            if e.mediaDocument.automaticallyRestore,
               let identity = try? MediaIdentity(originalURL: item.url),
               e.mediaDocument.record(for: identity) != nil { break }
            let format = "\(inspection.sampleRate):\(inspection.channels):\(inspection.channelLayout):\(inspection.significantBits)"
            if let expectedFormat, expectedFormat != format { break }
            expectedFormat = format
            entries.append(NativeAudioPlanEntry(item: item, inspection: inspection,
                options: ["ytdl": "no", "audio-file-auto": "no", "sub-auto": "no"]))
        }
        guard entries.count >= 2 else {
            throw NativeAudioPreparationFailure.ineligible(current.id, "尚无两首经预检且参数相同的本地 WAV/FLAC")
        }
        return NativeAudioPreparedPlan(id: UUID(), owner: owner, revision: e.revision,
            entries: entries, initialItemID: current.id,
            fullLogicalQueue: start == 0 && entries.count == logical.items.count,
            startPlaying: startPlaying)
    }
}
