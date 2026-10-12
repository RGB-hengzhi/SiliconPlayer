import AppKit
import PlayerCore

/// Opt-in actual renderer checks. Sensitive fixture URLs remain in memory only;
/// SessionVerifier must persist this verifier's explicit fields, not common URL metadata.
@MainActor
final class DiagnosticPrivacyVerifier {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private let player: PlayerModel
    private var task: Task<Void, Never>?
    private var result: [String: Any]?
    private var observations: [[String: Any]] = []
    private var snapshots: [[String: Any]] = []
    private var stage = "setup"

    init(player: PlayerModel, report: URL) {
        self.player = player
        // The shared SessionVerifier owns publication of this report.
        _ = report
    }
    func tick() -> [String: Any]? {
        if let result { return result }
        guard task == nil else { return nil }
        task = Task { [weak self] in
            guard let self else { return }
            do { try await self.run() }
            catch {
                self.result = ["diagnosticPassed": false, "diagnosticChecks": self.observations,
                               "diagnosticSnapshots": self.snapshots, "diagnosticFailureStage": self.stage,
                               "failure": MediaDiagnosticRedactor.redact(error.localizedDescription),
                               "physicalNativeUIAcceptance": false]
            }
        }
        return nil
    }
    private func check(_ id: String, _ passed: Bool) throws {
        observations.append(["id": id, "passed": passed])
        if !passed { throw Failure(message: "Diagnostic check failed: " + id) }
    }
    private func wait(_ label: String, seconds: Double = 12, until predicate: () -> Bool) async throws {
        stage = label
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate() {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw Failure(message: "Diagnostic condition timeout: " + label)
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
    private func hasFixtureCodecs() -> Bool {
        player.tracks.contains { $0.type == "video" && $0.codec.lowercased() == "h264" }
            && player.tracks.contains { $0.type == "audio" && $0.codec.lowercased() == "aac" }
    }
    private func sample(_ label: String) {
        snapshots.append(["stage": label, "loaded": player.loaded, "loading": player.isLoading,
                          "paused": player.flag("pause"), "position": player.number("time-pos"),
                          "renderFrames": player.renderProgress.frames,
                          "videoCodecs": player.tracks.filter { $0.type == "video" }.map(\.codec),
                          "audioCodecs": player.tracks.filter { $0.type == "audio" }.map(\.codec)])
    }
    private func run() async throws {
        let raw = ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_DIAGNOSTIC_ORIGIN"] ?? ""
        guard let parts = URLComponents(string: raw), parts.scheme == "http", parts.host == "127.0.0.1",
              let port = parts.port, (1...65535).contains(port), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              let origin = parts.url else { throw Failure(message: "Owned loopback origin required") }
        func source(_ name: String) throws -> URL {
            let base = origin.appendingPathComponent("DIAG_PRIVATE_PATH_6F43").appendingPathComponent(name)
            guard var value = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
                throw Failure(message: "Invalid owned fixture address")
            }
            value.queryItems = [URLQueryItem(name: "token", value: "DIAG_PRIVATE_QUERY_8A72"),
                                URLQueryItem(name: "password", value: "DIAG_PRIVATE_PASSWORD_3C91")]
            guard let url = value.url else { throw Failure(message: "Invalid owned fixture address") }
            return url
        }
        let good = try source("good.mp4"), bad = try source("bad.mp4")
        let framesBefore = player.renderProgress.frames
        try await player.openAndWaitForCommit([good])
        try await wait("initial media load") { self.player.loaded && self.player.currentURL == good }
        try check("private-original-url-retained-in-memory", player.currentURL == good && player.string("path") == good.absoluteString)
        try check("real-video-audio-load", hasFixtureCodecs() && player.duration > 8 && player.error == nil)
        // Play is explicit so this check does not depend on an autoplay preference.
        player.set("pause", "no")
        try await wait("initial frame and time growth") {
            self.player.renderProgress.frames >= framesBefore + 24 && self.player.number("time-pos") > 0.3
        }
        try check("real-render-frame-time-growth", !player.flag("pause") && player.renderProgress.frames >= framesBefore + 24)
        sample("initial-playing")

        let seekFrames = player.renderProgress.frames
        player.seek(4)
        try await wait("exact seek renderer progress", seconds: 8) {
            let time = self.player.number("time-pos")
            return !self.player.flag("seeking") && time >= 3.85 && time <= 6
                && self.player.renderProgress.frames >= seekFrames + 6
        }
        try check("exact-seek-advances-renderer", player.currentURL == good && hasFixtureCodecs())
        sample("seek-completed")

        try await player.openAndWaitForCommit([bad])
        try await wait("bad media rejection") { self.player.error != nil && !self.player.loaded && !self.player.isLoading }
        let badError = MediaDiagnosticRedactor.redact(player.error ?? "")
        try check("bad-media-rejected-with-category", badError.contains("无法播放媒体") && !badError.contains("omitted"))
        sample("bad-media-rejected")

        let recoveryFrames = player.renderProgress.frames
        try await player.openAndWaitForCommit([good])
        try await wait("recovery load") { self.player.loaded && self.player.currentURL == good && self.player.error == nil }
        try check("recovery-original-url-retained", player.string("path") == good.absoluteString)
        player.set("pause", "no")
        try await wait("recovery renderer progress", seconds: 8) {
            self.player.renderProgress.frames >= recoveryFrames + 24 && self.player.number("time-pos") > 0.2
        }
        try check("recovery-codec-and-frame-growth", hasFixtureCodecs() && !player.flag("pause"))
        sample("recovery-playing")

        player.stopPlayback()
        try check("stopped-before-normal-quit", !player.loaded && !player.isLoading && player.paused && player.position == 0)
        sample("stopped")
        result = ["diagnosticPassed": true, "diagnosticChecks": observations, "diagnosticSnapshots": snapshots,
                  "diagnosticBadMediaError": badError, "diagnosticFramesAdvanced": player.renderProgress.frames - framesBefore,
                  "diagnosticNormalQuitExpected": true, "physicalNativeUIAcceptance": false,
                  "scope": "Owned loopback synthetic markers; real libmpv renderer, seek and bad-media recovery. No physical input acceptance."]
    }
}
