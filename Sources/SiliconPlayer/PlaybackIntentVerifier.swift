import Foundation
import PlayerCore

/// Opt-in API regression. A prepared fixture exercises the production pending-
/// renderer path; AppKit subsequently creates its real renderer normally.
/// Actual time and render-frame progression are required, not just `loaded`.
@MainActor
final class PlaybackIntentVerifier {
    private struct CheckFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private static var startupEvidence: [String: Any] = [:]
    private static var startupPlayer: ObjectIdentifier?
    private let player: PlayerModel
    private let report: URL
    private var task: Task<Void, Never>?
    private var result: [String: Any]?
    private var rows: [[String: Any]] = []
    private let env = ProcessInfo.processInfo.environment

    static func prepareInitialRendererRequest(player: PlayerModel) {
        let env = ProcessInfo.processInfo.environment
        guard env["SILICONPLAYER_VERIFY_MODE"] == "playback-intent",
              let report = env["SILICONPLAYER_VERIFY_REPORT"], report.hasPrefix("/") else { return }
        startupPlayer = ObjectIdentifier(player)
        startupEvidence = ["report": report, "autoplayBefore": player.settings.autoplay]
        guard let path = env["SILICONPLAYER_VERIFY_INTENT_FIRST"], path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: path) else {
            startupEvidence["failure"] = "Playback intent requires an existing absolute initial fixture"
            return
        }
        let source = URL(fileURLWithPath: path).standardizedFileURL
        startupEvidence["source"] = source.path
        guard player.preparePlaybackIntentRendererFixture(source) else {
            startupEvidence["failure"] = "Prepared renderer fixture rejected"; return
        }
        startupEvidence["requestPreparationScope"] = "explicit fixture -> real pending load; ordinary async open tested separately"
        let id = player.playlist.currentItem?.id.uuidString ?? ""
        startupEvidence["itemIDBeforePlay"] = id
        startupEvidence["rendererPendingBeforePlay"] = player.hasPendingRendererLoad
        startupEvidence["loadingBeforePlay"] = player.isLoading && !player.loaded
        player.togglePause()
        player.togglePause() // Repeated Play must upgrade the same request.
        startupEvidence["itemIDAfterPlay"] = player.playlist.currentItem?.id.uuidString ?? ""
        startupEvidence["rendererPendingAfterPlay"] = player.hasPendingRendererLoad
        startupEvidence["autoplayAfterPlay"] = player.settings.autoplay
    }

    init(player: PlayerModel, report: URL) {
        self.player = player; self.report = report
    }

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
        if !value { throw CheckFailure(message: message) }
    }
    private func wait(seconds: Double = 15, until predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate() {
            try require(ProcessInfo.processInfo.systemUptime < deadline, "Timed out waiting for playback intent state")
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
    private func source(_ key: String, local: Bool = false) throws -> URL {
        guard let value = env[key],
              let url = local ? (value.hasPrefix("/") ? URL(fileURLWithPath: value).standardizedFileURL : nil) : URL(string: value) else {
            throw CheckFailure(message: "Missing valid \(key)")
        }
        return url
    }
    private func sameSource(_ url: URL) -> Bool {
        guard player.currentURL == url else { return false }
        let path = player.string("path")
        return url.isFileURL ? URL(fileURLWithPath: path).standardizedFileURL == url.standardizedFileURL : path == url.absoluteString
    }
    private func snapshot() -> [String: Any] {
        ["loaded": player.loaded, "isLoading": player.isLoading,
         "modelPaused": player.paused, "mpvPaused": player.flag("pause"),
         "time": player.number("time-pos"), "renderFrames": player.renderProgress.frames,
         "source": player.currentURL?.absoluteString ?? "", "enginePath": player.string("path"),
         "entryID": player.string("playlist/0/id"), "idle": player.flag("idle-active"),
         "seeking": player.flag("seeking"), "autoplay": player.settings.autoplay,
         "rendererPending": player.hasPendingRendererLoad]
    }
    private func observe(_ label: String, source: URL, playing: Bool, seconds: Double = 0.65,
                         extra: [String: Any] = [:]) async throws {
        try await wait {
            self.player.loaded && !self.player.isLoading && self.sameSource(source)
                && !self.player.flag("seeking") && self.player.flag("pause") != playing
                && self.player.paused != playing && self.player.duration > 22
        }
        // Pause or resume restoration can have one in-flight update. Start the
        // measured interval only after the real seek flag has stayed clear.
        try await Task.sleep(nanoseconds: 175_000_000)
        try require(!player.flag("seeking") && sameSource(source), "\(label): source/seek did not settle")
        let beforeTime = player.number("time-pos"), beforeFrames = player.renderProgress.frames
        let start = ProcessInfo.processInfo.systemUptime
        var samples: [[String: Any]] = []
        repeat {
            let value = snapshot(); samples.append(value)
            try require(player.loaded && !player.isLoading && sameSource(source), "\(label): media changed during observation")
            try require(player.flag("pause") != playing && player.paused != playing, "\(label): wrong pause state")
            try await Task.sleep(nanoseconds: 50_000_000)
        } while ProcessInfo.processInfo.systemUptime - start < seconds
        let delta = player.number("time-pos") - beforeTime
        let frameDelta = player.renderProgress.frames &- beforeFrames
        if playing {
            try require(delta >= 0.25 && frameDelta >= 2, "\(label): explicit Play did not advance actual time/render frames")
        } else {
            try require(abs(delta) <= 0.06 && samples.allSatisfy { abs(($0["time"] as? Double ?? -.infinity) - beforeTime) <= 0.06 },
                        "\(label): ordinary autoplay=false load advanced")
        }
        var row = snapshot()
        row.merge(extra) { _, new in new }
        row.merge(["name": label, "kind": playing ? "playing" : "paused", "passed": true,
                   "observedSeconds": ProcessInfo.processInfo.systemUptime - start,
                   "timeBefore": beforeTime, "timeDelta": delta,
                   "renderFramesBefore": beforeFrames, "renderFrameDelta": frameDelta,
                   "samples": samples]) { _, new in new }
        rows.append(row)
    }
    private func stopped(_ label: String, seconds: Double = 0.4) async throws {
        try await wait { !self.player.loaded && !self.player.isLoading && self.player.flag("idle-active") }
        let start = ProcessInfo.processInfo.systemUptime
        var samples: [[String: Any]] = []
        repeat {
            samples.append(snapshot())
            try require(!player.loaded && !player.isLoading && player.position == 0 && player.duration == 0,
                        "\(label): cancelled request resumed or kept media state")
            try require(!player.hasPendingRendererLoad && player.flag("idle-active"), "\(label): load survived Stop")
            try await Task.sleep(nanoseconds: 50_000_000)
        } while ProcessInfo.processInfo.systemUptime - start < seconds
        var row = snapshot(); row["name"] = label; row["kind"] = "cancelled"; row["passed"] = true
        row["observedSeconds"] = ProcessInfo.processInfo.systemUptime - start; row["samples"] = samples
        rows.append(row)
    }
    private func requestHasStarted(_ name: String) -> Bool {
        guard let path = env["SILICONPLAYER_VERIFY_INTENT_REQUEST_LOG"], path.hasPrefix("/"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return false }
        return rows.contains { ($0["case"] as? String) == name && ($0["event"] as? String) == "started" }
    }
    private func loadingPlay(_ url: URL, label: String, request: String) async throws {
        try await player.openAndWaitForCommit([url])
        try await wait(seconds: 10) { self.requestHasStarted(request) }
        try require(player.isLoading && !player.loaded, "\(label): no real slow-source loading window")
        let id = player.playlist.currentItem?.id, entry = player.string("playlist/0/id")
        let before = snapshot()
        player.togglePause(); player.togglePause()
        try require(player.isLoading && !player.loaded && player.playlist.currentItem?.id == id
                    && player.string("playlist/0/id") == entry, "\(label): repeated Play reopened the request")
        var row = snapshot(); row["name"] = label; row["kind"] = "loading"; row["passed"] = true
        row["beforePlay"] = before; row["requestStarted"] = true; row["sameRequestAfterRepeatedPlay"] = true
        rows.append(row)
    }

    private func run() async throws {
        let first = try source("SILICONPLAYER_VERIFY_INTENT_FIRST", local: true)
        let second = try source("SILICONPLAYER_VERIFY_SECOND", local: true)
        let slow = try source("SILICONPLAYER_VERIFY_INTENT_SLOW")
        let stale = try source("SILICONPLAYER_VERIFY_INTENT_STALE")
        let stop = try source("SILICONPLAYER_VERIFY_INTENT_STOP")
        let sleep = try source("SILICONPLAYER_VERIFY_INTENT_SLEEP")
        try require(first != second, "Two different local inputs are required")
        try require(Self.startupPlayer == ObjectIdentifier(player)
                    && Self.startupEvidence["report"] as? String == report.path
                    && Self.startupEvidence["source"] as? String == first.path, "Startup fixture/report identity differs")
        try require(Self.startupEvidence["failure"] == nil
                    && Self.startupEvidence["autoplayBefore"] as? Bool == false
                    && Self.startupEvidence["autoplayAfterPlay"] as? Bool == false
                    && Self.startupEvidence["rendererPendingBeforePlay"] as? Bool == true
                    && Self.startupEvidence["rendererPendingAfterPlay"] as? Bool == true
                    && Self.startupEvidence["loadingBeforePlay"] as? Bool == true
                    && Self.startupEvidence["itemIDBeforePlay"] as? String == Self.startupEvidence["itemIDAfterPlay"] as? String,
                    "No genuine same-request explicit Play before renderer readiness")
        try await observe("pre-render-explicit-play", source: first, playing: true, extra: ["startup": Self.startupEvidence])
        player.togglePause()
        try await observe("loaded-toggle-pause", source: first, playing: false)
        player.togglePause()
        try await observe("loaded-toggle-play", source: first, playing: true)
        player.set("pause", "yes"); player.seek(8.5, remember: false)
        try await wait { !self.player.flag("seeking") && abs(self.player.position - 8.5) <= 0.06 }
        player.stopPlayback()
        try await stopped("stop-clears-media-preserves-selection")
        try require(player.playlist.currentItem?.url == first, "Stop lost the selected media")
        player.togglePause() // A single user Play, not playSelected or pause=no.
        try await observe("explicit-play-after-stop-resume", source: first, playing: true)
        guard var last = rows.popLast() else { throw CheckFailure(message: "Missing resume observation") }
        let resumed = last["timeBefore"] as? Double ?? 0
        try require(resumed >= 8.44 && resumed < 10, "Explicit Play failed to restore the saved position")
        last["expectedResumePosition"] = 8.5; last["resumeVerified"] = true; rows.append(last)

        try await player.openAndWaitForCommit([second])
        try await observe("ordinary-open-autoplay-false", source: second, playing: false)
        player.playSelected()
        try await observe("ordinary-play-selected-autoplay-false", source: second, playing: false)
        try await player.openAndWaitForCommit([first, second])
        try await observe("ordinary-queue-open-autoplay-false", source: first, playing: false)
        player.next()
        try await observe("queue-next-autoplay-false", source: second, playing: false)
        try await player.openAndWaitForCommit([first, second])
        try await wait { self.player.loaded && !self.player.isLoading && self.sameSource(first) }
        if let id = player.playlist.currentItem?.id { player.removePlaylistItems([id]) }
        try await observe("queue-remove-successor-autoplay-false", source: second, playing: false)

        player.settings.autoplay = true
        try await player.openAndWaitForCommit([second])
        try await observe("ordinary-open-autoplay-true", source: second, playing: true)
        player.stopPlayback()
        try await player.openAndWaitForCommit([sleep])
        try await wait(seconds: 10) { self.requestHasStarted("sleep") }
        try require(player.isLoading && !player.loaded, "No genuine slow-source sleep window")
        player.sleepDeadline = Date().addingTimeInterval(0.2)
        try await wait(seconds: 2.5) { self.player.sleepDeadline == nil }
        try require(player.isLoading && !player.loaded && player.flag("pause"), "Sleep did not pause the pending load before reply")
        var sleepRow = snapshot()
        sleepRow.merge(["name": "sleep-deadline-pauses-loading-request", "kind": "loading-pause",
                        "passed": true, "requestStarted": true, "sleepDeadlineCleared": true]) { _, new in new }
        rows.append(sleepRow)
        try await observe("sleep-deadline-preserved-after-load", source: sleep, playing: false,
                          extra: ["sleepDeadlineCleared": player.sleepDeadline == nil])
        player.settings.autoplay = false
        player.stopPlayback()
        try await loadingPlay(slow, label: "loading-play-upgrades-same-request", request: "upgrade")
        try await observe("loading-explicit-play-advances", source: slow, playing: true)
        player.stopPlayback()
        try await loadingPlay(stale, label: "loading-play-before-replacement", request: "stale")
        try await player.openAndWaitForCommit([second])
        try await observe("new-open-invalidates-old-play-intent", source: second, playing: false, seconds: 2.0)
        player.stopPlayback()
        try await loadingPlay(stop, label: "loading-play-before-stop", request: "stop")
        player.stopPlayback()
        try await stopped("stop-invalidates-loading-play-intent", seconds: 2.0)
        try await player.openAndWaitForCommit([second])
        try await observe("ordinary-open-after-cancellation-remains-paused", source: second, playing: false)
        try require(!player.settings.autoplay && player.error == nil, "Explicit Play altered autoplay or left a media error")
        player.persistSettings()
    }
    private func finish(_ failure: String?) {
        var values: [String: Any] = [
            "playbackIntentSchemaVersion": 1, "playbackIntentPassed": failure == nil,
            "playbackIntentChecks": rows, "playbackIntentStartup": Self.startupEvidence,
            "settingsAutoplayUnchanged": !player.settings.autoplay,
            "pendingRendererLoad": player.hasPendingRendererLoad,
            "playbackIntentScope": "Real production APIs and renderer frames; initial fixture is preloaded during opt-in init before AppKit rendering, not the GUI command-line-open path. No physical UI certification."
        ]
        if let failure { values["failure"] = failure }
        result = values
    }
}
