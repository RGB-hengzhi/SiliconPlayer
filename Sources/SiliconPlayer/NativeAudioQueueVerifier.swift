import AppKit
import CMPV
import PlayerCore

// Isolated actual-App local audio verification modes.
// Four App groups; observations, metadata probes and sampled properties are
// not separate groups and don't demonstrate physical output continuity.
@MainActor final class NativeAudioQueueVerifier {
    static let modes: Set<String> = ["native-audio-continuation", "native-audio-intent-lifecycle",
        "native-audio-history-preferences", "native-audio-loops-disable"]
    private static weak var live: NativeAudioQueueVerifier?
    private struct Failure: LocalizedError { let text: String; var errorDescription: String? { text } }
    private let player: PlayerModel
    private let report: URL
    private let mode: String
    private var task: Task<Void, Never>?
    private var result: [String: Any]?
    private var observations: [[String: Any]] = []
    private var samples: [[String: Any]] = []
    private var fixtures: [URL] = []
    private var armedEnd: Int64?
    private var heldEnd: (id: Int64, reason: mpv_end_file_reason, error: Int32)?
    private var heldAt = 0.0
    private var standardShortcutBytes: Data?
    private var stage = "setup"
    init(player: PlayerModel, report: URL, mode: String) { self.player = player; self.report = report; self.mode = mode }
    func tick() -> [String: Any]? {
        if let result { return result }
        guard task == nil else { return nil }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try self.configure(); Self.live = self
                switch self.mode {
                case "native-audio-continuation": try await self.continuation()
                case "native-audio-intent-lifecycle": try await self.intentLifecycle()
                case "native-audio-history-preferences": try await self.historyPreferences()
                case "native-audio-loops-disable": try await self.loopsDisable()
                default: throw Failure(text: "Unknown native audio mode")
                }
                try self.check("owned-inspector-job-registry-empty", !NativeLocalAudioInspector.hasActiveJobs)
                try self.check("daily-shortcut-key-unchanged", UserDefaults.standard.data(forKey: "SiliconPlayer.shortcuts.v1") == self.standardShortcutBytes)
                self.finish(true)
            } catch { self.finish(false, error.localizedDescription) }
            Self.live = nil
        }
        return nil
    }
    // Delay exactly ONE copied real mpv EOF in one isolated verification mode.
    // Fields are copied before next wait_event; no fabricated event is supplied.
    // Normal launch/live nil is inert. Report explicitly describes this controlled
    // dispatch permutation; it isn't a claim that libmpv naturally reorders EOF.
    static func captureRealEnd(player: PlayerModel, id: Int64, reason: mpv_end_file_reason, error: Int32) -> Bool {
        guard let live, live.player === player, live.mode == "native-audio-history-preferences",
              live.armedEnd == id, live.heldEnd == nil, reason == MPV_END_FILE_REASON_EOF else { return false }
        live.heldEnd = (id, reason, error); live.armedEnd = nil
        live.heldAt = ProcessInfo.processInfo.systemUptime
        return true
    }
    private func releaseRealEnd() throws {
        guard let end = heldEnd else { throw Failure(text: "No copied real EOF captured") }
        heldEnd = nil
        let handled = player.nativeAudioQueue.receive(.end(end.id, end.reason, end.error))
        try check("copied-real-late-eof-dispatched", handled,
            ["entryID": end.id, "reason": Int(end.reason.rawValue), "heldAt": heldAt,
             "releasedAt": ProcessInfo.processInfo.systemUptime, "scope": "actual raw EOF with controlled delayed dispatch"])
    }
    private func configure() throws {
        let env = ProcessInfo.processInfo.environment
        guard Self.modes.contains(mode), let storage = env["SILICONPLAYER_VERIFY_STORAGE"], storage.hasPrefix("/"),
              env["SILICONPLAYER_VERIFY_REPORT"] == report.path,
              InputController.verificationSuiteName(environment: env) != nil,
              let root = env["SILICONPLAYER_VERIFY_NATIVE_AUDIO_ROOT"], root.hasPrefix("/") else {
            throw Failure(text: "Private verification profile/report and owned fixture root required")
        }
        let directory = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard let manifest = try BoundedProfileFile.read(directory.appendingPathComponent("manifest.json"), maximumBytes: 128 * 1024),
              let data = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let paths = data["files"] as? [String], paths.count == 10 else { throw Failure(text: "Owned fixture manifest required") }
        fixtures = try paths.map { path in
            guard path.hasPrefix("/") else { throw Failure(text: "Absolute fixture path required") }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(directory.path + "/"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  ["wav", "flac"].contains(url.pathExtension.lowercased()) else { throw Failure(text: "Owned regular local audio required") }
            return url
        }
        guard Set(fixtures).count == 10 else { throw Failure(text: "Unique fixture originals required") }
        guard PlayerModel.supportDirectory.resolvingSymlinksInPath().standardizedFileURL
            == URL(fileURLWithPath: storage, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL else {
            throw Failure(text: "Private storage identity mismatch")
        }
        let defaultOff = !player.continuousAudioEnabled && !player.nativeAudioQueue.ownsEvents
        standardShortcutBytes = UserDefaults.standard.data(forKey: "SiliconPlayer.shortcuts.v1")
        let defaultBase = PlaybackSettings()
        var verificationBase = defaultBase
        // Owned verification profile explicitly selects an unprocessed audio
        // path. Product defaults and daily preferences remain authoritative.
        verificationBase.processing.limiter = false
        player.installGlobalBaseSettings(verificationBase); player.applySettings()
        player.loopPlaylist = false
        if player.loopFile { player.toggleLoop() }
        player.nativeAudioQueue.setEnabled(true)
        try check("private-profile-and-default-off-opt-in", defaultOff && player.continuousAudioEnabled && !player.profileRecoveryBlocked
            && defaultBase.processing.limiter && !player.mediaPreferences.baseSnapshot.processing.limiter,
            ["productDefaultLimiterEnabled": defaultBase.processing.limiter,
             "privateVerificationLimiterEnabled": player.mediaPreferences.baseSnapshot.processing.limiter])
    }
    private func snapshot() -> [String: Any] {
        ["stage": stage, "uptime": ProcessInfo.processInfo.systemUptime,
         "currentUUID": player.playlist.currentItem?.id.uuidString ?? "", "loaded": player.loaded,
         "loading": player.isLoading, "position": player.number("time-pos"), "duration": player.number("duration"),
         "pause": player.string("pause"), "speed": player.number("speed"), "loopPlaylist": player.string("loop-playlist"),
         "loopFile": player.string("loop-file"), "abLoopA": player.string("ab-loop-a"),
         "abLoopB": player.string("ab-loop-b"), "abLoopCount": player.string("ab-loop-count"), "audioParams": player.jsonProperty("audio-params") ?? [:],
         "audioOutParams": player.jsonProperty("audio-out-params") ?? [:],
         "queueUUIDs": player.playlist.items.map { $0.id.uuidString }, "queueOriginals": player.playlist.items.map { $0.url.absoluteString },
         "nativeRows": player.nativeAudioPlaylistReadback()?.map {
             ["entryID": $0.entryID, "originalURL": $0.url.absoluteString, "current": $0.current, "playing": $0.playing] as [String: Any]
         } ?? [], "native": player.nativeAudioQueue.diagnosticsSnapshot]
    }
    private func check(_ id: String, _ value: Bool, _ extra: [String: Any] = [:]) throws {
        guard !observations.contains(where: { $0["id"] as? String == id }) else { throw Failure(text: "Duplicate check ID: " + id) }
        var row = extra; row["id"] = id; row["passed"] = value; row["snapshot"] = snapshot()
        observations.append(row)
        if !value { throw Failure(text: id) }
    }
    private func wait(_ name: String, timeout: Double = 12, until condition: () -> Bool) async throws {
        stage = name; let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            if Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline { throw Failure(text: "Timeout: " + name) }
            if let error = player.error { throw Failure(text: name + ": " + error) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        samples.append(snapshot())
    }
    private func loaded(_ item: MediaItem) async throws {
        try await wait("loaded-" + item.id.uuidString) {
            self.player.loaded && !self.player.isLoading && self.player.playlist.currentItem?.id == item.id
                && self.player.nativeAudioPlaylistReadback()?.first(where: { $0.playing })?.url == item.url
        }
    }
    private func confirmed(_ count: Int) async throws {
        try await wait("confirmed-\(count)") {
            let state = self.player.nativeAudioQueue.diagnosticsSnapshot
            return state["confirmed"] as? Bool == true && state["entryCount"] as? Int == count
                && state["owner"] as? String != "" && self.player.nativeAudioPlaylistReadback()?.count == count
                && !self.player.nativeAudioQueue.isAssembling
        }
    }
    private func audioWindow(_ id: String, paused: Bool, seconds: Double = 0.8) async throws {
        let item = player.playlist.currentItem?.id
        let initial = player.number("time-pos"); let started = ProcessInfo.processInfo.systemUptime
        var positions: [Double] = []
        while ProcessInfo.processInfo.systemUptime - started < seconds {
            positions.append(player.number("time-pos")); samples.append(snapshot())
            guard player.loaded && !player.isLoading, player.playlist.currentItem?.id == item,
                  player.flag("pause") == paused,
                  let decoded = player.jsonProperty("audio-params") as? [String: Any],
                  let output = player.jsonProperty("audio-out-params") as? [String: Any],
                  decoded["samplerate"] as? Int == 48_000, decoded["channel-count"] as? Int == 2,
                  output["samplerate"] as? Int == 48_000, output["channel-count"] as? Int == 2 else {
                throw Failure(text: id + ": identity/pause/actual audio parameters changed")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let delta = player.number("time-pos") - initial
        try check(id, paused ? positions.allSatisfy({ abs($0-initial) <= 0.06 }) && abs(delta) <= 0.06 : delta >= 0.35,
            ["positionStart": initial, "positionEnd": player.number("time-pos"), "sampledSeconds": ProcessInfo.processInfo.systemUptime-started,
             "positions": positions, "scope": "actual audio time/pause/output properties; not physical device capture"])
    }
    private func nearEnd(_ item: MediaItem) async throws {
        try await loaded(item)
        let target = max(0, player.duration - 1.0)
        player.seek(target, remember: false)
        try await wait("near-end-seek-settled", timeout: 2) {
            self.player.loaded && self.player.playlist.currentItem?.id == item.id
                && !self.player.flag("seeking") && self.player.number("time-pos") >= target - 0.15
                && self.player.position >= target - 0.15
        }
        // Explicit seek acceleration tests transition correctness only. Waiting
        // for the actual near-end position prevents a file-loop check from
        // passing on the old pre-seek position. Never an uninterrupted PCM proof.
    }
    private func continuation() async throws {
        try await player.openAndWaitForCommit(fixtures)
        let items = player.playlist.items
        try await loaded(items[0]); try await confirmed(8)
        let originalOwner = player.nativeAudioQueue.diagnosticsSnapshot["owner"] as? String
        try await audioWindow("initial-a-real-audio-progress", paused: false)
        try await wait("natural-b", timeout: 25) { self.player.loaded && self.player.playlist.currentItem?.id == items[1].id }
        try await audioWindow("natural-b-real-audio-progress", paused: false)
        try await wait("natural-c", timeout: 35) { self.player.loaded && self.player.playlist.currentItem?.id == items[2].id }
        try await audioWindow("natural-c-real-audio-progress", paused: false)
        try check("actual-natural-a-b-c-preserves-native-session", originalOwner != nil && originalOwner != ""
            && player.nativeAudioQueue.diagnosticsSnapshot["owner"] as? String == originalOwner
            && player.playlist.items.map(\.id) == items.map(\.id))
        for index in 2..<8 {
            try await nearEnd(items[index])
            try await wait("next-\(index+1)") { self.player.loaded && self.player.playlist.currentItem?.id == items[index+1].id }
        }
        try await confirmed(2)
        let audit = player.nativeAudioQueue.diagnosticsSnapshot["audit"] as? [[String: Any]] ?? []
        try check("ninth-item-ordinary-boundary-next-controlled-window", audit.contains {
            $0["kind"] as? String == "ordinary-boundary" && $0["nextUUID"] as? String == items[8].id.uuidString
        } && player.playlist.items.count == 10 && player.playlist.currentItem?.id == items[8].id)
        try await audioWindow("ninth-item-actual-audio-progress", paused: false)
        try await nearEnd(items[8]); try await loaded(items[9]); try await nearEnd(items[9])
        try await wait("tail-eof") { self.player.flag("eof-reached") }
        try await Task.sleep(nanoseconds: 500_000_000)
        try check("nonloop-tail-never-reloads-initial-uuid", player.playlist.currentItem?.id == items[9].id && player.playlist.items.map(\.id) == items.map(\.id))
        player.togglePause()
        try await wait("terminal-eof-explicit-play-restart", timeout: 8) {
            self.player.loaded && !self.player.flag("eof-reached") && !self.player.flag("pause")
                && self.player.playlist.currentItem?.id == items[9].id
                && self.player.number("time-pos") > 0.05 && self.player.number("time-pos") < 5
        }
        try await audioWindow("terminal-eof-explicit-play-restarts-same-uuid-real-audio", paused: false)
    }
    private func intentLifecycle() async throws {
        player.updateSettings { $0.autoplay = false }
        try await player.openAndWaitForCommit(Array(fixtures.prefix(3)))
        let items = player.playlist.items
        try await loaded(items[0]); try await confirmed(3)
        try await audioWindow("autoplay-false-native-assembly-stays-paused", paused: true)
        try await player.openAndWaitForCommit([fixtures[3]], append: true)
        let extra = player.playlist.items.last!
        try await confirmed(4)
        _ = player.movePlaylistItems([items[1].id], to: .end)
        try await wait("reorder-actual-future-map") {
            self.player.nativeAudioPlaylistReadback()?.map(\.url) == self.player.playlist.items.map(\.url)
                && self.player.nativeAudioQueue.diagnosticsSnapshot["confirmed"] as? Bool == true
        }
        player.removePlaylistItems([items[2].id])
        try await confirmed(3)
        try check("paused-append-reorder-delete-keeps-current-and-latest-uuids", player.playlist.currentItem?.id == items[0].id
            && player.playlist.items.map(\.id) == [items[0].id, extra.id, items[1].id]
            && player.nativeAudioPlaylistReadback()?.map(\.url) == player.playlist.items.map(\.url))
        try await audioWindow("paused-queue-mutations-do-not-start-audio", paused: true)
        player.togglePause(); try await audioWindow("explicit-play-overrides-initial-autoplay-false", paused: false)
        player.next(); try await loaded(extra)
        try await audioWindow("manual-next-keeps-real-playing-intent", paused: false)
        player.set("pause", "yes"); player.seek(0, remember: false)
        try await wait("previous-origin-settled") { !self.player.flag("seeking") && self.player.number("time-pos") < 0.2 }
        player.previous(); try await loaded(items[0])
        try await audioWindow("manual-previous-keeps-real-pause-intent", paused: true)
        let old = player.nativeAudioQueue.diagnosticsSnapshot["owner"] as? String
        player.stopPlayback(); try await Task.sleep(nanoseconds: 700_000_000)
        try check("stop-retires-session-without-late-resurrection", !player.loaded && !player.isLoading
            && !player.nativeAudioQueue.ownsEvents && player.playlist.currentItem?.id == items[0].id)
        player.togglePause(); try await loaded(items[0]); try await confirmed(3)
        try await audioWindow("stop-then-explicit-play-actually-rebuilds-and-advances", paused: false)
        try check("stop-play-new-session-same-logical-uuid", player.nativeAudioQueue.diagnosticsSnapshot["owner"] as? String != old
            && player.playlist.currentItem?.id == items[0].id && player.playlist.items.count == 3)
    }
    private func historyPreferences() async throws {
        try await player.openAndWaitForCommit(Array(fixtures.prefix(3)))
        let items = player.playlist.items
        try await loaded(items[0]); try await confirmed(3)
        guard let id = player.nativeAudioQueue.diagnosticsSnapshot["activeEntryID"] as? Int64 else { throw Failure(text: "Native entry ID required") }
        armedEnd = id
        try await nearEnd(items[0]); try await loaded(items[1])
        try await audioWindow("b-loaded-while-real-old-a-eof-held", paused: false)
        try check("actual-real-eof-copied-and-held", heldEnd?.id == id && heldEnd?.reason == MPV_END_FILE_REASON_EOF)
        player.stopPlayback()
        let history = player.history.recentEntries
        try check("stop-settles-all-loaded-own-duration-not-successor-duration",
            abs((history.first(where: { $0.url == items[0].url })?.duration ?? 0) - 12) < 0.02
            && abs((history.first(where: { $0.url == items[1].url })?.duration ?? 0) - 18) < 0.02)
        player.select(items[0].id); try await loaded(items[0]); try await confirmed(3)
        try await audioWindow("same-original-reload-new-session-real-progress", paused: false)
        player.saveHistory(); player.history.flush()
        let before = player.history.recentEntries.first { $0.url == items[0].url }?.position
        try releaseRealEnd(); player.history.flush()
        try check("old-real-eof-does-not-overwrite-newer-original-url-history", before != nil
            && before == player.history.recentEntries.first(where: { $0.url == items[0].url })?.position && before! < 5)
        player.stopPlayback()
        var document = player.mediaPreferences.document
        var record = MediaPreferenceRecord(identity: try MediaIdentity(originalURL: fixtures[2]))
        var geometry = MediaGeometryPreference(); geometry.zoom = 0.25; record.geometry = geometry; record.audioDelay = 0.15
        try document.save(record)
        let store = MediaPreferenceStore(fileURL: PlayerModel.supportDirectory.appendingPathComponent("media-preferences.json"))
        try store.save(document); try check("typed-owned-saved-preference-installed", player.mediaPreferences.loadDocument())
        player.nativeAudioQueue.configurationChanged()
        player.history.record(url: fixtures[3], position: 8, duration: 40); player.history.flush()
        try await player.openAndWaitForCommit(Array(fixtures.prefix(4)))
        let next = player.playlist.items
        try await loaded(next[0]); try await confirmed(2)
        try await nearEnd(next[0]); try await loaded(next[1]); try await nearEnd(next[1]); try await loaded(next[2])
        try await wait("saved-pref-ordinary-restoration") { abs(self.player.number("audio-delay")-0.15)<0.01 && abs(self.player.number("video-zoom")-0.25)<0.01 }
        try check("saved-pref-boundary-uses-ordinary-load-without-dropping-overlay", !player.nativeAudioQueue.ownsEvents
            && player.mediaPreferences.document.record(for: record.identity)?.geometry?.zoom == 0.25)
        player.next(); try await loaded(next[3])
        try await wait("ordinary-resume-position") { self.player.number("time-pos") >= 8 && self.player.number("time-pos") < 10 }
        try check("successor-resume-boundary-restores-position-and-base", abs(player.number("audio-delay"))<0.01
            && abs(player.number("video-zoom"))<0.01 && player.mediaPreferences.baseSnapshot.zoom == 0)
        try await audioWindow("ordinary-boundaries-still-play-real-audio", paused: false)
    }
    private func loopsDisable() async throws {
        try await player.openAndWaitForCommit(Array(fixtures.prefix(3))); let items = player.playlist.items
        try await loaded(items[0]); try await confirmed(3)
        player.loopPlaylist = true
        try await wait("native-list-loop-confirmed") { self.player.string("loop-playlist") == "inf" }
        let firstID = player.nativeAudioQueue.diagnosticsSnapshot["activeEntryID"] as? Int64
        for index in 0..<3 { try await nearEnd(items[index]); try await loaded(items[(index+1)%3]) }
        try check("actual-list-loop-wrap-preserves-entry-and-new-cycle", player.playlist.currentItem?.id == items[0].id
            && player.nativeAudioQueue.diagnosticsSnapshot["activeEntryID"] as? Int64 == firstID
            && (player.nativeAudioQueue.diagnosticsSnapshot["activeCycle"] as? UInt64 ?? 0) > 1)
        player.toggleLoop()
        try await wait("file-loop-disables-native-list-wrap") { self.player.string("loop-file") == "inf" && self.player.string("loop-playlist") == "no" }
        try await nearEnd(items[0])
        try await wait("file-loop-returned-current-time", timeout: 5) { self.player.loaded && self.player.number("time-pos") < 2 && !self.player.flag("seeking") }
        try check("actual-file-loop-keeps-original-uuid", player.playlist.currentItem?.id == items[0].id)
        player.toggleLoop(); player.loopPlaylist = false
        player.seek(2, remember: false)
        try await wait("a-only-settled") { !self.player.flag("seeking") && self.player.number("time-pos") >= 2 && self.player.number("time-pos") <= 2.3 && self.player.position >= 2 && self.player.position <= 2.3 }
        player.cycleAB()
        try check("actual-a-only-mark-is-not-complete-ab", player.abStart != nil && player.abEnd == nil && !player.nativeAudioCompleteAB)
        try await nearEnd(items[0]); try await loaded(items[1])
        try check("actual-a-only-clears-after-different-native-media", player.abStart == nil && player.abEnd == nil
            && player.string("ab-loop-a") == "no" && player.string("ab-loop-b") == "no" && player.nativeAudioQueue.ownsEvents)
        player.select(items[0].id); try await loaded(items[0]); try await confirmed(3)
        player.seek(2, remember: false)
        try await wait("a-settled") { !self.player.flag("seeking") && self.player.number("time-pos") >= 2 && self.player.number("time-pos") <= 2.3 && self.player.position >= 2 && self.player.position <= 2.3 }
        player.cycleAB(); player.seek(4, remember: false)
        try await wait("b-settled") { !self.player.flag("seeking") && self.player.number("time-pos") >= 4 && self.player.number("time-pos") <= 4.3 && self.player.position >= 4 && self.player.position <= 4.3 }
        player.cycleAB()
        try await wait("complete-ab-disables-native-list-wrap") { self.player.nativeAudioCompleteAB && self.player.string("loop-playlist") == "no" }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try check("actual-complete-ab-keeps-current-media", player.playlist.currentItem?.id == items[0].id && player.number("time-pos") <= 4.3)
        // Actual mpv command induces the forbidden successor, rather than a
        // synthetic START. Production must fail closed, not restore fake AB.
        player.command(["playlist-next", "force"])
        try await wait("unexpected-successor-with-ab-stops", timeout: 5) { !self.player.loaded && !self.player.isLoading }
        try check("actual-unexpected-ab-successor-fails-closed", !player.nativeAudioQueue.ownsEvents && player.abStart == nil && player.abEnd == nil)
        try await player.openAndWaitForCommit(Array(fixtures.prefix(3))); let reopened = player.playlist.items
        try await loaded(reopened[0]); try await confirmed(3)
        player.loopPlaylist = true
        try await wait("before-disable-list-loop-confirmed") { self.player.string("loop-playlist") == "inf" }
        player.updateSettings { $0.autoplay = false }; player.nativeAudioQueue.setEnabled(false)
        try await wait("disabled-native-loop-reset") { !self.player.nativeAudioQueue.ownsEvents && self.player.string("loop-playlist") == "no"
            && self.player.nativeAudioPlaylistReadback()?.count == 1 }
        try check("disable-mode-resets-native-list-loop-preserving-current", player.playlist.currentItem?.id == reopened[0].id && !player.flag("pause"))
        player.next(); try await loaded(reopened[1]); try await audioWindow("ordinary-next-again-obeys-autoplay-false", paused: true)
        try check("ordinary-load-after-disable-cannot-inherit-native-loop", player.string("loop-playlist") == "no" && !player.nativeAudioQueue.ownsEvents)
    }
    private func finish(_ passed: Bool, _ failure: String? = nil) {
        result = ["nativeAudioVerification": ["passed": passed, "mode": mode,
            "observations": observations, "observationCount": observations.count, "samples": samples,
            "controller": player.nativeAudioQueue.diagnosticsSnapshot,
            "stage": stage, "heldRealEOFStillPending": heldEnd != nil,
            "failure": failure ?? "", "physicalGaplessVerified": false,
            "scope": "actual App API-driven local audio/session/history/preference/lifecycle behavior; output buffering not physically captured"]]
    }
}
