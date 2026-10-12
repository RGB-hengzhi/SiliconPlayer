import AppKit
import CMPV
import Darwin
import Foundation

/// Add one instance as a stored property of PlayerModel. This owns only host
/// receipts and OSD state; decoder/recognizer children belong to the backend.
@MainActor final class LiveASRMPVHostState {
    let coreID = UUID()
    var loadedFingerprint: LiveASRFileFingerprint? {
        didSet { if loadedFingerprint == nil { externalAudioReceipts.removeAll() } }
    }
    private(set) var externalAudioReceipts: [URL: LiveASRExternalAudioSource] = [:]
    var seekGeneration: UInt64 = 0
    var settledSeekGeneration: UInt64?
    var awaitingNativeSeek = false
    var awaitingRestart = false
    var overlayOwner: UUID?
    var overlayPayload: String?
    let overlayID: Int64 = 761_206

    func prepareLoad(_ url: URL) {
        externalAudioReceipts.removeAll()
        loadedFingerprint = Self.fingerprint(url)
        seekGeneration = 0; settledSeekGeneration = nil
        awaitingNativeSeek = false; awaitingRestart = false
    }

    static func localAudioURL(_ text: String) -> URL? {
        guard text.utf8.count <= 8192, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let url: URL?
        if text.hasPrefix("/") { url = URL(fileURLWithPath: text) }
        else { url = URL(string: text) }
        guard let url, url.isFileURL, url.path.hasPrefix("/"),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        return url.standardizedFileURL
    }

    func captureExternalAudio(_ url: URL, rebase: Bool, audioDemuxer: String) -> LiveASRExternalAudioSource? {
        guard let local = Self.localAudioURL(url.absoluteString), local.pathExtension.lowercased() == "wav",
              rebase, ["", "lavf", "+lavf"].contains(audioDemuxer), let fingerprint = Self.fingerprint(local) else { return nil }
        return LiveASRExternalAudioSource(url: local, fingerprint: fingerprint, attachmentID: UUID(),
            rebaseAtAttachment: rebase, audioDemuxerAtAttachment: audioDemuxer)
    }
    func commitExternalAudio(_ receipt: LiveASRExternalAudioSource) {
        guard externalAudioReceipts.count < 2000 || externalAudioReceipts[receipt.url] != nil else { return }
        externalAudioReceipts[receipt.url] = receipt
    }
    func removeExternalAudio(_ url: URL?) {
        if let url { externalAudioReceipts.removeValue(forKey: url.standardizedFileURL) }
        else { externalAudioReceipts.removeAll() }
    }

    static func fingerprint(_ url: URL) -> LiveASRFileFingerprint? {
        guard url.isFileURL, url.path.utf8.count <= 8192 else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        var filesystem = statfs()
        guard Darwin.fstatfs(descriptor, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { return nil }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_size > 0 else { return nil }
        let seconds = Int64(value.st_mtimespec.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
        let time = seconds.partialValue.addingReportingOverflow(Int64(value.st_mtimespec.tv_nsec))
        guard !seconds.overflow, !time.overflow else { return nil }
        return LiveASRFileFingerprint(device: UInt64(bitPattern: Int64(value.st_dev)), inode: UInt64(value.st_ino),
            byteCount: UInt64(value.st_size), modificationNanoseconds: time.partialValue)
    }
}

extension PlayerModel: LiveASRHost {
    func liveASRSnapshot() -> LiveASRSnapshot {
        func scalar(_ name: String) -> Double? {
            guard let text = liveASRProperty(name), let value = Double(text), value.isFinite else { return nil }
            return value
        }
        let rows = jsonProperty("playlist") as? [[String: Any]] ?? []
        let playing = rows.filter { ($0["playing"] as? Bool) == true }
        let native = playing.count == 1 ? playing.first : nil
        let item = playlist.currentItem
        let nativeID = native?["id"] as? Int64 ?? (native?["id"] as? Int).map(Int64.init)
        let nativePath = native?["filename"] as? String
        let samePath = item.map { nativePath == $0.url.path || nativePath == $0.url.absoluteString } ?? false
        let binding: LiveASRBinding?
        if let item, let nativeID, samePath, item.url.isFileURL {
            binding = LiveASRBinding(coreID: liveASRHostState.coreID, queueItemID: item.id,
                loadToken: mediaPreferenceToken, nativeEntryID: nativeID, originalURL: item.url.standardizedFileURL)
        } else { binding = nil }

        let demuxer = liveASRProperty("current-demuxer") ?? ""
        let aid = liveASRProperty("aid").flatMap(Int.init)
        let selected = (jsonProperty("track-list") as? [[String: Any]] ?? []).filter {
            ($0["type"] as? String) == "audio" && ($0["selected"] as? Bool) == true
                && ($0["id"] as? Int) == aid
        }
        var track: LiveASRTrack?
        if demuxer == "lavf", selected.count == 1, let row = selected.first,
           let id = row["id"] as? Int, let index = row["ff-index"] as? Int,
           index >= 0, index <= 4096, let codec = row["codec"] as? String,
           let rate = row["demux-samplerate"] as? Int, let channels = row["demux-channel-count"] as? Int,
           rate >= 8000, rate <= 96000, channels > 0, channels <= 16 {
            track = LiveASRTrack(runtimeAudioID: id, absoluteFFmpegIndex: index, codec: codec,
                sampleRate: rate, channels: channels, channelLayout: row["demux-channels"] as? String ?? "",
                language: row["lang"] as? String ?? "", title: row["title"] as? String ?? "",
                isExternal: (row["external"] as? Bool) == true)
            if track?.isExternal == true {
                // The primary demuxer property does not identify an external
                // demuxer. This phase accepts only a receipt-bound, sole PCM
                // WAV stream; the actual held-FD ffprobe proves that structure.
                if index == 0, codec.hasPrefix("pcm_"), (row["main-selection"] as? Int) == 0,
                   let path = row["external-filename"] as? String,
                   let url = LiveASRMPVHostState.localAudioURL(path),
                   let receipt = liveASRHostState.externalAudioReceipts[url],
                   receipt.rebaseAtAttachment, liveASRProperty("options/rebase-start-time") == "yes",
                   let currentAudioDemuxer = liveASRProperty("options/audio-demuxer"),
                   receipt.audioDemuxerAtAttachment == currentAudioDemuxer,
                   LiveASRMPVHostState.fingerprint(url) == receipt.fingerprint {
                    track?.externalSource = receipt
                } else { track = nil }
            }
        } else { track = nil }
        return LiveASRSnapshot(binding: binding, selectedTrack: track, loaded: loaded, loading: isLoading,
            paused: liveASRProperty("pause") != "no", seeking: liveASRProperty("seeking") == "yes",
            eof: liveASRProperty("eof-reached") == "yes", corePosition: scalar("time-pos"),
            coreAudioPTS: scalar("audio-pts"), speed: scalar("speed") ?? .nan,
            audioDelay: scalar("audio-delay") ?? .nan, currentDemuxer: demuxer,
            rebaseStartTime: liveASRProperty("options/rebase-start-time") == "yes",
            demuxerStartTime: scalar("demuxer-start-time"), loadedSourceFingerprint: liveASRHostState.loadedFingerprint,
            observedUptime: ProcessInfo.processInfo.systemUptime, seekGeneration: liveASRHostState.seekGeneration,
            settledSeekGeneration: liveASRHostState.settledSeekGeneration)
    }

    func liveASRCaptureExternalAudio(_ url: URL) -> LiveASRExternalAudioSource? {
        guard let audioDemuxer = liveASRProperty("options/audio-demuxer") else { return nil }
        return liveASRHostState.captureExternalAudio(url, rebase: liveASRProperty("options/rebase-start-time") == "yes",
            audioDemuxer: audioDemuxer)
    }
    func liveASRExternalAudioCandidate(_ args: [String]) -> LiveASRExternalAudioSource? {
        guard args.first == "audio-add", args.count >= 2,
              let url = LiveASRMPVHostState.localAudioURL(args[1]) else { return nil }
        // Never manufacture an attach-before-open receipt for an already-open
        // external source. Its original receipt stays authoritative.
        let alreadyLoaded = (jsonProperty("track-list") as? [[String: Any]] ?? []).contains {
            ($0["type"] as? String) == "audio" && ($0["external"] as? Bool) == true &&
            ($0["external-filename"] as? String).flatMap(LiveASRMPVHostState.localAudioURL) == url
        }
        return alreadyLoaded ? nil : liveASRCaptureExternalAudio(url)
    }

    func liveASRProperty(_ name: String) -> String? {
        guard let handle, let value = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(value) }
        guard strnlen(value, 8193) <= 8192 else { return nil }
        return String(cString: value)
    }

    /// Call after a command has actually been accepted, before the MainActor
    /// can deliver queued ASR events. A second outstanding seek is ambiguous
    /// because native mpv SEEK/RESTART events have no per-command userdata.
    func liveASRAcceptedSeek() {
        let state = liveASRHostState
        if state.awaitingNativeSeek || state.awaitingRestart {
            liveASR.invalidate(reason: .seek)
        }
        guard state.seekGeneration < .max else { liveASR.invalidate(reason: .discontinuity); return }
        state.seekGeneration += 1; state.settledSeekGeneration = nil
        state.awaitingNativeSeek = true; state.awaitingRestart = false
        liveASR.willSeek(generation: state.seekGeneration)
    }

    func liveASRNativeSeekReceipt() {
        let state = liveASRHostState
        if !state.awaitingNativeSeek {
            guard state.seekGeneration < .max else { liveASR.invalidate(reason: .discontinuity); return }
            state.seekGeneration += 1
            liveASR.willSeek(generation: state.seekGeneration)
        }
        state.settledSeekGeneration = nil; state.awaitingNativeSeek = false; state.awaitingRestart = true
    }

    func liveASRNativeRestartReceipt() {
        let state = liveASRHostState
        // Initial load can settle generation zero. Accepted seeks require an
        // actual native SEEK followed by RESTART and a finite Core position.
        guard !state.awaitingNativeSeek, state.awaitingRestart || state.seekGeneration == 0,
              liveASRProperty("seeking") == "no",
              let time = liveASRProperty("time-pos").flatMap(Double.init), time.isFinite else { return }
        state.settledSeekGeneration = state.seekGeneration; state.awaitingRestart = false
    }

    func setLiveASROverlay(_ overlay: LiveASROverlay?, owner: UUID, binding: LiveASRBinding) throws {
        guard liveASRSnapshot().binding == binding else { throw LiveASRFailure("字幕所属媒体已变更") }
        guard let overlay, !overlay.plainText.isEmpty else {
            guard clearLiveASROverlay(owner: owner) else { throw LiveASRFailure("实时字幕层未能清除") }; return
        }
        if let old = liveASRHostState.overlayOwner, old != owner, !clearLiveASROverlay(owner: old) {
            throw LiveASRFailure("上次实时字幕层未能清除，请重试")
        }
        guard overlay.plainText.utf8.count <= 16_384,
              !overlay.plainText.contains("\u{0000}"),
              let width = Int(liveASRProperty("osd-width") ?? ""),
              let height = Int(liveASRProperty("osd-height") ?? ""),
              width > 0, width <= 16384, height > 0, height <= 16384 else {
            throw LiveASRFailure("字幕画布或文字超过范围")
        }
        let escaped = try executeLiveASREscapeASS(overlay.plainText)
        let size = max(18, min(48, height / 28))
        let text = "{\\an8\\pos(\(width / 2),\(max(16,height / 16)))\\fs\(size)\\bord2\\shad1\\1c&HFFFFFF&\\3c&H000000&}" + escaped
        let payload = "\(width):\(height):\(text)"
        if liveASRHostState.overlayOwner == owner && liveASRHostState.overlayPayload == payload { return }
        let status = executeLiveASROSD(id: liveASRHostState.overlayID, text: text, width: width, height: height)
        guard status >= 0 else { throw LiveASRFailure("实时字幕显示失败：\(String(cString: mpv_error_string(status)))") }
        liveASRHostState.overlayOwner = owner; liveASRHostState.overlayPayload = payload
    }

    @discardableResult func clearLiveASROverlay(owner: UUID) -> Bool {
        guard liveASRHostState.overlayOwner == owner else { return true }
        if liveASRCoreClosed {
            liveASRHostState.overlayOwner = nil; liveASRHostState.overlayPayload = nil; return true
        }
        let status = executeLiveASROSD(id: liveASRHostState.overlayID, text: nil, width: 0, height: 0)
        guard status >= 0 else { return false }
        liveASRHostState.overlayOwner = nil; liveASRHostState.overlayPayload = nil
        return true
    }
}
