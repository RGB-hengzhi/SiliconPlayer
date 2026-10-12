import AppKit
import PlayerCore

/// Opt-in integration exercises the production resolver and real render engine.
/// It never emits native input events or runs in ordinary application launches.
@MainActor
final class WebMediaVerifier {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private let player: PlayerModel
    private let report: URL
    private let resolver = WebMediaResolver()
    private let env = ProcessInfo.processInfo.environment
    private var task: Task<Void, Never>?
    private var result: [String: Any]?
    private var rows: [[String: Any]] = []

    init(player: PlayerModel, report: URL) { self.player = player; self.report = report }
    func tick() -> [String: Any]? {
        if let result { return result }
        guard task == nil else { return nil }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.run(); self.finish(nil) }
            catch { self.finish(error.localizedDescription) }
        }
        return nil
    }
    private func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    private func wait(seconds: Double = 35, label: String, until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            try require(ProcessInfo.processInfo.systemUptime < deadline, "\(label): timeout; \(player.error ?? resolver.error ?? "no error")")
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
    private func page(_ name: String) throws -> URL {
        guard let origin = env["SILICONPLAYER_VERIFY_WEB_ORIGIN"],
              let url = URL(string: origin + "/" + name) else { throw Failure(message: "Missing loopback web origin") }
        return url
    }
    private func resolve(_ url: URL) async throws -> WebMediaDocument {
        resolver.resolve(address: url.absoluteString)
        try await wait(label: "metadata") { !self.resolver.busy }
        guard let document = resolver.document, document.pageURL == url else {
            throw Failure(message: resolver.error ?? "No metadata for requested page")
        }
        return document
    }
    private func snapshot() -> [String: Any] {
        ["loaded": player.loaded, "isLoading": player.isLoading, "modelPaused": player.paused,
         "mpvPaused": player.flag("pause"), "time": player.number("time-pos"),
         "renderFrames": player.renderProgress.frames, "source": player.currentURL?.absoluteString ?? "",
         "enginePath": player.string("path"), "currentID": player.playlist.currentItem?.id.uuidString ?? "",
         "title": player.playlist.currentItem?.title ?? "", "ytdl": player.string("options/ytdl"),
         "format": player.string("options/ytdl-format"), "audioID": player.audioID, "subtitleID": player.subtitleID,
         "videoCodec": player.string("video-codec"), "audioCodec": player.string("audio-codec"),
         "tracks": player.jsonProperty("track-list") ?? []]
    }
    private func row(_ name: String, _ extra: [String: Any] = [:]) {
        var value = snapshot(); value.merge(extra) { _, v in v }
        value["name"] = name; value["passed"] = true; rows.append(value)
    }
    private func observe(_ name: String, url: URL, playing: Bool) async throws {
        try await wait(label: name) {
            self.player.loaded && !self.player.isLoading && self.player.currentURL == url &&
            !self.player.flag("seeking") && self.player.flag("pause") != playing && self.player.paused != playing
        }
        try await Task.sleep(nanoseconds: 175_000_000)
        let before = player.number("time-pos"), frames = player.renderProgress.frames
        let started = ProcessInfo.processInfo.systemUptime
        var samples: [[String: Any]] = []
        repeat {
            samples.append(snapshot())
            try require(player.loaded && !player.isLoading && player.currentURL == url && player.flag("pause") != playing,
                        "\(name): source/pause changed")
            try await Task.sleep(nanoseconds: 50_000_000)
        } while ProcessInfo.processInfo.systemUptime - started < 0.65
        let delta = player.number("time-pos") - before, frameDelta = player.renderProgress.frames &- frames
        try require(playing ? delta >= 0.25 && frameDelta >= 2 : abs(delta) <= 0.06, "\(name): real time/frame progression is incorrect")
        row(name, ["playing": playing, "timeBefore": before, "timeDelta": delta,
                   "renderFrameDelta": frameDelta, "observedSeconds": ProcessInfo.processInfo.systemUptime - started, "samples": samples])
    }
    private func requestStarted(_ name: String) -> Bool {
        guard let value = env["SILICONPLAYER_VERIFY_WEB_REQUEST_LOG"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: value)),
              let values = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return false }
        return values.contains { $0["case"] as? String == name && $0["event"] as? String == "started" && $0["delayed"] as? Bool == true }
    }
    private func run() async throws {
        player.settings.autoplay = false
        player.set("loop-file", "no"); player.set("loop-playlist", "no")
        let mode = env["SILICONPLAYER_VERIFY_MODE"] ?? "web-media"
        if mode == "web-public" {
            guard let address = env["SILICONPLAYER_VERIFY_WEB_PUBLIC"] else { throw Failure(message: "Missing public page") }
            let url = try WebMediaDocument.validatedPageURL(address)
            let document = try await resolve(url)
            try require(player.openWebMedia(pageURL: url, selection: try document.selection()), "Public page request rejected")
            try await wait(seconds: 65, label: "public playback load") { self.player.loaded && !self.player.isLoading }
            try require(player.error == nil && player.currentIsWebMedia, "Public page failed to play")
            player.seek(5, remember: false)
            try await wait(label: "public seek") { !self.player.flag("seeking") && self.player.position >= 4.9 }
            let before = player.number("time-pos"), frames = player.renderProgress.frames
            var samples: [[String: Any]] = []
            let started = ProcessInfo.processInfo.systemUptime
            repeat {
                try require(player.loaded && !player.flag("pause") && player.error == nil, "Public playback stopped during observation")
                samples.append(["time": player.number("time-pos"), "renderFrames": player.renderProgress.frames,
                                "avsync": player.number("avsync"), "decoderDrops": player.number("decoder-frame-drop-count"),
                                "rendererDrops": player.number("frame-drop-count")])
                try await Task.sleep(nanoseconds: 100_000_000)
            } while ProcessInfo.processInfo.systemUptime - started < 8
            let delta = player.number("time-pos") - before, frameDelta = player.renderProgress.frames &- frames
            try require(delta >= 6 && frameDelta >= 24 && player.tracks.contains { $0.type == "video" } && player.tracks.contains { $0.type == "audio" },
                        "Public source lacks real video/audio/time/render progress")
            let image = report.deletingLastPathComponent().appendingPathComponent("public-video.png")
            player.command(["screenshot-to-file", image.path, "video"])
            try require(FileManager.default.fileExists(atPath: image.path), "Public video image missing")
            // Never persist extracted media paths, track request headers or CDN
            // signatures. All metadata here is an explicit display whitelist.
            rows.append(["name": "public-web-playback", "passed": true, "page": url.absoluteString,
                         "title": document.title, "formatCount": document.formats.count, "duration": player.duration,
                         "videoCodec": player.string("video-codec"), "audioCodec": player.string("audio-codec"),
                         "width": player.number("video-params/w"), "height": player.number("video-params/h"),
                         "decoder": player.decoder, "timeBefore": before, "timeDelta": delta, "renderFrameDelta": frameDelta,
                         "observedSeconds": ProcessInfo.processInfo.systemUptime - started, "screenshot": image.path, "samples": samples])
            return
        }
        if mode == "web-quit-resolver" {
            resolver.resolve(address: try page("slow-resolver/progressive.html").absoluteString)
            try await wait(seconds: 12, label: "quit resolver request") { self.requestStarted("slow-resolver") }
            try require(resolver.busy && WebMediaResolver.hasActiveJobs, "Quit did not occur during actual parser process")
            row("quit-with-preparser-active", ["resolverBusy": true, "resolverJobsActive": true])
            return
        }
        let progressive = try page("progressive.html")
        let document = try await resolve(progressive)
        try require(document.formats.count == 2 && document.subtitleLanguages.contains("zh"), "Real HTML5 formats/subtitle missing")
        let first = try document.selection(formatID: "H264_360p", subtitleLanguage: "zh")
        try require(!first.separateAudio, "Unknown HTML5 codecs misclassified as video-only")
        row("real-html-metadata", ["page": progressive.absoluteString, "formats": document.formats.map(\.formatID), "subtitleLanguages": document.subtitleLanguages])
        if mode == "web-quit-hook" {
            let slow = try page("slow-quit/progressive.html")
            try require(player.openWebMedia(pageURL: slow, selection: first), "Hook quit request rejected")
            try await wait(seconds: 12, label: "quit hook request") { self.requestStarted("slow-quit") }
            try require(player.isLoading && !player.loaded, "Quit did not occur during actual hook process")
            row("quit-with-hook-active", ["requestStarted": true])
            return
        }
        let unknownURL = try page("unknown.html"), unknown = try await resolve(unknownURL)
        try require(unknown.formats.count == 1 && unknown.formats[0].height == nil, "Unknown-size HTML metadata was discarded")
        try require(player.openWebMedia(pageURL: unknownURL, selection: try unknown.selection()), "Unknown-size page rejected")
        try await observe("unknown-size-auto-video", url: unknownURL, playing: true)
        try require(player.tracks.contains { $0.type == "video" }, "Automatic fallback selected only audio")
        try require(player.openWebMedia(pageURL: progressive, selection: first), "Progressive request rejected")
        try await observe("progressive-explicit-play", url: progressive, playing: true)
        try require(player.tracks.contains { $0.type == "audio" } && player.tracks.contains { $0.type == "video" }, "Progressive video/audio missing")
        try await wait(label: "web subtitle") { self.player.tracks.contains { $0.type == "sub" } && self.player.subtitleID > 0 }
        let identity = player.playlist.currentItem?.id
        player.set("pause", "yes"); player.seek(3.3, remember: false)
        try await wait(label: "paused origin") { self.player.paused && !self.player.flag("seeking") && abs(self.player.position - 3.3) < 0.08 }
        let subtitleImage = report.deletingLastPathComponent().appendingPathComponent("web-subtitle.png")
        player.command(["screenshot-to-file", subtitleImage.path, "subtitles"])
        try require(FileManager.default.fileExists(atPath: subtitleImage.path), "Real subtitle screenshot missing")
        row("manual-subtitle-and-original-queue", ["screenshot": subtitleImage.path, "queueURLs": player.playlist.items.map { $0.url.absoluteString }])
        try require(player.playlist.items.count == 1 && player.playlist.currentItem?.url == progressive && player.playlist.currentItem?.webMedia == first,
                    "Queue did not retain original page/preferences")
        let second = try document.selection(formatID: "HEVC_720p", subtitleLanguage: "zh")
        try require(player.openWebMedia(pageURL: progressive, selection: second), "Paused format change rejected")
        try await observe("paused-format-switch", url: progressive, playing: false)
        try require(player.playlist.currentItem?.id == identity && abs(player.number("time-pos") - 3.3) < 0.10 && player.string("video-codec").lowercased().contains("hevc"),
                    "Paused format switch lost identity/position or selected wrong codec")
        try require(player.openWebMedia(pageURL: progressive, selection: first), "First rapid switch rejected")
        try require(player.isLoading && !player.loaded, "Rapid switch did not enter real pending state")
        try require(player.openWebMedia(pageURL: progressive, selection: second), "Replacement rapid switch rejected")
        try await observe("rapid-paused-format-replacement", url: progressive, playing: false)
        try require(player.playlist.currentItem?.id == identity && abs(player.number("time-pos") - 3.3) < 0.10 && player.string("video-codec").lowercased().contains("hevc"),
                    "Pending format replacement lost resume/pause/identity")
        player.set("pause", "no")
        try await observe("resume-switched-format", url: progressive, playing: true)
        let position = player.position
        try require(player.openWebMedia(pageURL: progressive, selection: first), "Playing format change rejected")
        try await observe("playing-format-switch", url: progressive, playing: true)
        try require(player.playlist.currentItem?.id == identity && abs(player.number("time-pos") - position) < 1.2 && player.string("video-codec").lowercased().replacingOccurrences(of: ".", with: "").contains("h264"),
                    "Playing format switch lost position/intent or selected wrong codec")
        let dashURL = try page("dash.html"), dash = try await resolve(dashURL)
        let dashSelection = try dash.selection(formatID: "0")
        try require(dashSelection.separateAudio, "Actual DASH video-only was not recognized")
        try require(player.openWebMedia(pageURL: dashURL, selection: dashSelection), "DASH request rejected")
        try await observe("dash-separate-video-audio", url: dashURL, playing: true)
        try require(player.tracks.contains { $0.type == "video" } && player.tracks.contains { $0.type == "audio" } && player.audioID > 0,
                    "DASH selection failed to attach real audio")
        // Existing recents/bookmarks/named lists call this ordinary URL API.
        // Reload the actual saved catalog first, rather than trusting memory.
        player.webMediaCatalog = WebMediaCatalog()
        player.restoreWebMediaPreferences()
        try require(player.webMediaCatalog.selection(for: progressive) == first, "Original page preference did not restore from actual saved file")
        player.open([progressive])
        try await observe("known-web-url-reopens-from-library-path", url: progressive, playing: false)
        try require(player.currentIsWebMedia && player.playlist.currentItem?.webMedia == first && player.string("video-codec").lowercased().replacingOccurrences(of: ".", with: "").contains("h264"),
                    "Known web URL reopened as HTML or lost format/subtitle preference")
        // A rollback to build 9 saves the URL-only schema. Existing page
        // preferences must be restored before that legacy queue is played.
        player.stopPlayback()
        let legacyQueue = try JSONSerialization.data(withJSONObject: ["urls": [progressive.absoluteString], "selectedIndex": 0])
        try legacyQueue.write(to: PlayerModel.supportDirectory.appendingPathComponent("queue.json"), options: .atomic)
        player.playlist = Playlist()
        player.restoreQueue()
        try require(player.playlist.currentItem?.webMedia == first, "Legacy queue lost saved page preferences")
        player.playSelected()
        try await observe("legacy-queue-restores-known-web-preferences", url: progressive, playing: false)
        let slow = try page("slow-stop/progressive.html")
        try require(player.openWebMedia(pageURL: slow, selection: first), "Slow Stop request rejected")
        try await wait(seconds: 12, label: "slow hook started") { self.requestStarted("slow-stop") }
        try require(player.isLoading && !player.loaded, "No actual loading window before Stop")
        let stopAt = ProcessInfo.processInfo.systemUptime
        player.stopPlayback()
        try await wait(seconds: 10, label: "hook cancelled") { !self.player.loaded && !self.player.isLoading && self.player.flag("idle-active") }
        try await Task.sleep(nanoseconds: 6_500_000_000)
        try require(!player.loaded && !player.isLoading && player.flag("idle-active"), "Stopped hook resurrected media")
        row("stop-cancels-hook-without-resurrection", ["requestStarted": true, "observedAfterStopSeconds": 6.5, "stopAtSystemUptime": stopAt])
        let replace = try page("slow-replace/progressive.html")
        try require(player.openWebMedia(pageURL: replace, selection: first), "Replacement request rejected")
        try await wait(seconds: 12, label: "replace hook started") { self.requestStarted("slow-replace") }
        guard let local = env["SILICONPLAYER_VERIFY_WEB_LOCAL"], local.hasPrefix("/") else { throw Failure(message: "Missing local control") }
        let localURL = URL(fileURLWithPath: local)
        player.open([localURL])
        try await observe("local-replaces-pending-web", url: localURL, playing: false)
        try require(!player.currentIsWebMedia && player.string("options/ytdl") == "no", "Web extractor leaked into ordinary local file")
        try await Task.sleep(nanoseconds: 6_500_000_000)
        try require(player.loaded && player.currentURL == localURL && player.flag("pause"), "Late hook result replaced local media")
        resolver.resolve(address: try page("slow-resolver/progressive.html").absoluteString)
        try await wait(seconds: 12, label: "slow parser started") { self.requestStarted("slow-resolver") }
        resolver.cancel()
        try await wait(seconds: 5, label: "parser cancelled") { !WebMediaResolver.hasActiveJobs }
        try require(!resolver.busy && resolver.document == nil, "Cancelled parser retained stale document")
        _ = try await resolve(progressive)
        row("cancel-preparser-and-resolve-again", ["resolverBusy": resolver.busy, "activeJobs": WebMediaResolver.hasActiveJobs])
        let config = player.string("options/config-dir")
        try require(config.contains("siliconplayer-mpv-config-") && !config.contains(".config/mpv"), "mpv did not use private config directory")
        row("private-mpv-config-directory", ["configDirectory": config, "scriptOptions": player.string("options/script-opts")])
    }
    private func finish(_ failure: String?) {
        result = ["webMediaPassed": failure == nil, "webMediaObservations": rows,
                  "webMediaObservationCount": rows.count,
                  "scope": env["SILICONPLAYER_VERIFY_MODE"] == "web-public"
                    ? "Real bundled parser/mpv/renderer against this public page; no native input-event, site-wide or physical audio acceptance"
                    : "Real bundled parser/mpv/renderer/HTTP; no native input-event, public-site or physical audio acceptance"]
        if let failure {
            result?["failure"] = env["SILICONPLAYER_VERIFY_MODE"] == "web-public"
                ? "Public playback verification did not complete; inspect redacted application diagnostics."
                : failure
        }
    }
}
