import AppKit
import PlayerCore

/// Opt-in tests run the real player clock, helper processes and OSD commands.
/// No synthesized PCM, recognition events or native seek receipts are supplied.
@MainActor final class LiveASRVerifier {
    static let modes: Set<String> = ["live-asr-follow", "live-asr-pause-seek", "live-asr-reload", "live-asr-quit"]
    private struct Failure: LocalizedError { let text: String; var errorDescription: String? { text } }
    private let player: PlayerModel
    private let report: URL
    private let mode: String
    private var task: Task<Void, Never>?
    private var result: [String: Any]?
    private var samples: [[String: Any]] = []
    private var checks: [[String: Any]] = []
    private var backendActual: Any?
    private var shotRequested = false
    private var shotResult: String?
    private var source: URL?
    private var initialDuration = 0.0
    private var dailyShortcut: Data?
    init(player: PlayerModel, report: URL, mode: String) { self.player = player; self.report = report; self.mode = mode }
    func tick() -> [String: Any]? {
        if let result { return result }
        if task != nil { sample(); return nil }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try self.configure()
                try await self.wait("real-media-loaded", seconds: 20) { self.player.loaded && !self.player.isLoading }
                self.source = self.player.currentURL; self.initialDuration = self.player.number("duration")
                self.player.set("pause", "yes"); self.player.seek(0, remember: false)
                try await self.wait("real-native-seek-settled", seconds: 6) {
                    let s = self.player.liveASRSnapshot()
                    return !s.seeking && s.settledSeekGeneration == s.seekGeneration && (s.corePosition ?? 99) < 0.25
                }
                let accepted = await self.player.startLiveASR()
                try self.check("actual-pair-start-accepted", accepted,
                    ["error":self.player.liveASR.error ?? "", "host":self.snapshot()])
                try await self.waitForNativeControl("actual-transition-ack", seconds: 8, event: "speed_changed", after: nil)
                if self.mode == "live-asr-quit" {
                    try self.check("live-owned-pair-at-quit", LiveASRController.hasActiveJobs && self.player.liveASR.isActive)
                    await self.captureBackend()
                    self.finish(true, scope: "actual active helper pair; AppDelegate shutdown evidence required")
                    return
                }
                self.player.set("pause", "no")
                try await self.wait("actual-chinese-partial", seconds: 12) { self.hasChinese(self.player.liveASR.partialText) }
                try self.check("partial-before-actual-player-eof", !self.player.flag("eof-reached"))
                try await self.wait("real-chinese-overlay-command", seconds: 3) {
                    let owner = self.player.liveASR.diagnosticsSnapshot["owner"] as? String
                    let payload = self.player.liveASRHostState.overlayPayload ?? ""
                    return self.hasChinese(self.player.liveASR.partialText)
                        && self.player.liveASRHostState.overlayOwner?.uuidString == owner
                        && owner != nil && self.hasChinese(payload)
                }
                let png = self.report.deletingPathExtension().appendingPathExtension("asr-window.png")
                try await self.wait("real-asr-window-screenshot", seconds: 5) {
                    self.shotResult == png.path && FileManager.default.fileExists(atPath: png.path)
                }

                if self.mode == "live-asr-reload" {
                    let old = self.player.mediaPreferenceToken
                    guard let source = self.source else { throw Failure(text: "Source missing") }
                    try await self.player.openAndWaitForCommit([source])
                    try self.check("same-url-reload-new-binding", self.player.mediaPreferenceToken != old)
                    try self.check("old-partial-invalidated-synchronously", self.player.liveASR.partialText.isEmpty && self.player.liveASRHostState.overlayOwner == nil)
                    try await self.wait("retired-owned-pair-released", seconds: 6) { !LiveASRController.hasActiveJobs }
                } else {
                    if self.mode == "live-asr-pause-seek" {
                        let pauseSerial = try await self.actualControlSerial()
                        self.player.set("pause", "yes")
                        try await self.waitForNativeControl("pause-control-observed", seconds: 3, event: "paused", after: pauseSerial)
                        let pausedAt = self.player.number("time-pos")
                        try await Task.sleep(nanoseconds: 600_000_000)
                        try self.check("actual-clock-stayed-paused", abs(self.player.number("time-pos") - pausedAt) < 0.05)
                        let previous = self.player.liveASRHostState.seekGeneration
                        guard let oldEpoch = (self.player.liveASR.diagnosticsSnapshot["epoch"] as? NSNumber)?.uint64Value,
                              oldEpoch > 0 else { throw Failure(text: "Current recognition epoch missing before seek") }
                        let beforeSeekControlSerial = try await self.actualControlSerial()
                        self.player.seek(4, remember: false)
                        try self.check("seek-retired-old-partial-before-yield", self.player.liveASR.partialText.isEmpty && self.player.liveASRHostState.seekGeneration > previous)
                        try await self.wait("new-native-seek-and-restart", seconds: 6) {
                            let s = self.player.liveASRSnapshot()
                            return s.seekGeneration > previous && s.settledSeekGeneration == s.seekGeneration && !s.seeking
                                && s.corePosition.map { $0.isFinite && abs($0 - 4) <= 0.2 } == true
                        }
                        self.player.set("pause", "no")
                        let resumedEpoch = try await self.waitForPostSeekNativeResume(seconds: 5,
                            after: beforeSeekControlSerial, previousEpoch: oldEpoch)
                        try await self.wait("post-seek-new-epoch-chinese-partial", seconds: 12) {
                            self.hasCurrentPostSeekPartial(epoch: resumedEpoch)
                        }
                    }
                    try await self.wait("actual-eof-finalization", seconds: max(20, self.initialDuration + 10)) {
                        self.player.flag("eof-reached") && !self.player.liveASR.isActive && !LiveASRController.hasActiveJobs
                    }
                    let cues = self.player.liveASR.finalCues
                    try self.check("actual-chinese-final-cues", !cues.isEmpty && cues.contains { self.hasChinese($0.text) },
                        ["cues":self.cueRows()])
                    try self.check("cues-in-actual-source-clock", cues.allSatisfy {
                        $0.start.seconds.isFinite && $0.end.seconds.isFinite && $0.start.seconds >= 0
                        && $0.end.seconds > $0.start.seconds && $0.end.seconds <= self.initialDuration + 0.15
                    })
                    let destination = self.report.deletingPathExtension().appendingPathExtension("srt")
                    try await self.player.liveASR.export(to: destination)
                    let parsed = try SubtitleDocument.parse(String(contentsOf: destination, encoding: .utf8))
                    try self.check("real-srt-export-reparse", parsed.cues.count == cues.count && zip(parsed.cues, cues).allSatisfy {
                        abs($0.0.start - $0.1.start.seconds) <= 0.0011 && abs($0.0.end - $0.1.end.seconds) <= 0.0011
                        && $0.0.text.trimmingCharacters(in: .whitespacesAndNewlines) == $0.1.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }, ["path":destination.path])
                }
                try self.check("owned-registry-empty", !LiveASRController.hasActiveJobs)
                try self.check("real-overlay-owner-cleared", self.player.liveASRHostState.overlayOwner == nil)
                try self.check("daily-shortcuts-unchanged", UserDefaults.standard.data(forKey: "SiliconPlayer.shortcuts.v1") == self.dailyShortcut)
                await self.captureBackend()
                self.finish(true, scope: "actual App clock, recognition, owned cleanup and SRT; word-end alignment not certified")
            } catch {
                _ = await self.player.liveASR.stop()
                await self.captureBackend()
                self.finish(false, scope: error.localizedDescription)
            }
        }
        return nil
    }
    private func configure() throws {
        let env = ProcessInfo.processInfo.environment
        guard Self.modes.contains(mode), env["SILICONPLAYER_VERIFY_REPORT"] == report.path,
              InputController.verificationSuiteName(environment: env) != nil,
              let storage = env["SILICONPLAYER_VERIFY_STORAGE"], storage.hasPrefix("/"),
              report.path.hasPrefix("/") else { throw Failure(text: "Owned isolated verification storage required") }
        dailyShortcut = UserDefaults.standard.data(forKey: "SiliconPlayer.shortcuts.v1")
    }
    private func hasChinese(_ text: String) -> Bool { text.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) } }
    private func check(_ name: String, _ passed: Bool, _ detail: [String: Any] = [:]) throws {
        checks.append(["id":name,"passed":passed,"uptime":ProcessInfo.processInfo.systemUptime,"detail":detail])
        if !passed { throw Failure(text: name + ": " + (player.liveASR.error ?? player.error ?? "failed")) }
    }
    private func wait(_ name: String, seconds: Double, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            sample()
            if player.liveASR.state == .failed || ProcessInfo.processInfo.systemUptime >= deadline {
                try check(name, false, ["snapshot":snapshot()])
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try check(name, true, ["snapshot":snapshot()])
    }
    private func backendObject() async throws -> [String: Any] {
        guard let raw = await player.liveASR.backendDiagnostics(),
              let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw Failure(text: "Actual backend diagnostics missing")
        }
        return object
    }
    private func actualControlSerial() async throws -> UInt64 {
        let object = try await backendObject()
        guard let serial = object["controlReceiptSerial"] as? NSNumber else {
            throw Failure(text: "Actual decoder ACK serial missing")
        }
        return serial.uint64Value
    }
    private func waitForNativeControl(_ name: String, seconds: Double, event: String, after: UInt64?) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while true {
            let object = try await backendObject()
            let epoch = (player.liveASR.diagnosticsSnapshot["epoch"] as? NSNumber)?.uint64Value
            let actualEpoch = (object["actualEpoch"] as? NSNumber)?.uint64Value
            let receipts = object["controlReceipts"] as? [[String: Any]] ?? []
            let receipt = receipts.last { row in
                row["event"] as? String == event && (row["epoch"] as? NSNumber)?.uint64Value == epoch
                    && (after == nil || (row["serial"] as? NSNumber).map { $0.uint64Value > after! } == true)
            }
            if player.liveASR.state == .paused, let epoch, epoch > 0, actualEpoch == epoch,
               object["decoderPaused"] as? Bool == true, let receipt {
                try check(name, true, ["actualDecoderACK":receipt,"actualEpoch":epoch,"snapshot":snapshot()])
                return
            }
            sample()
            if player.liveASR.state == .failed || ProcessInfo.processInfo.systemUptime >= deadline {
                try check(name, false, ["actualBackend":object,"snapshot":snapshot()])
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    // This is a distinct follow-state receipt; the existing paused transition
    // and user-pause waits deliberately retain their original conditions.
    private func waitForPostSeekNativeResume(seconds: Double, after: UInt64, previousEpoch: UInt64) async throws -> UInt64 {
        let name = "post-seek-native-resume-ack"
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while true {
            let object = try await backendObject()
            let epoch = (player.liveASR.diagnosticsSnapshot["epoch"] as? NSNumber)?.uint64Value
            let actualEpoch = (object["actualEpoch"] as? NSNumber)?.uint64Value
            let backendDesiredEpoch = (object["desiredEpoch"] as? NSNumber)?.uint64Value
            let receipts = object["controlReceipts"] as? [[String: Any]] ?? []
            let receipt = receipts.last { row in
                row["event"] as? String == "resumed" && (row["epoch"] as? NSNumber)?.uint64Value == epoch
                    && (row["serial"] as? NSNumber).map { $0.uint64Value > after } == true
            }
            let host = player.liveASRSnapshot()
            if player.liveASR.state == .following, !host.paused, !host.seeking,
               host.settledSeekGeneration == host.seekGeneration,
               let epoch, epoch > previousEpoch, actualEpoch == epoch,
               let backendDesiredEpoch, backendDesiredEpoch == epoch,
               object["decoderPaused"] as? Bool == false, let receipt {
                try check(name, true, ["actualDecoderACK":receipt,"actualEpoch":epoch,
                    "actualDesiredEpoch":backendDesiredEpoch,"actualDecoderPaused":false,
                    "previousEpoch":previousEpoch,"minimumControlSerial":after,"snapshot":snapshot()])
                return epoch
            }
            sample()
            if player.liveASR.state == .failed || ProcessInfo.processInfo.systemUptime >= deadline {
                try check(name, false, ["actualBackend":object,"previousEpoch":previousEpoch,
                    "minimumControlSerial":after,"snapshot":snapshot()])
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    private func hasCurrentPostSeekPartial(epoch: UInt64) -> Bool {
        let actual = player.liveASR.diagnosticsSnapshot
        guard let ticket = actual["ticket"] as? [String: Any],
              (actual["epoch"] as? NSNumber)?.uint64Value == epoch,
              (ticket["epoch"] as? NSNumber)?.uint64Value == epoch,
              let stream = (actual["streamGeneration"] as? NSNumber)?.uint64Value, stream > 0,
              let granted = (actual["grantedSamples"] as? NSNumber)?.uint64Value, granted > 0,
              let first = (actual["firstGrantedSequence"] as? NSNumber)?.uint64Value, first > 0,
              let last = (actual["lastGrantedSequence"] as? NSNumber)?.uint64Value, last >= first,
              let index = player.liveASRSnapshot().selectedTrack?.absoluteFFmpegIndex, index >= 0,
              (ticket["streamIndex"] as? NSNumber)?.intValue == index,
              actual["partial"] as? String == player.liveASR.partialText else { return false }
        return player.liveASR.state == .following && hasChinese(player.liveASR.partialText)
    }
    private func snapshot() -> [String: Any] {
        let s = player.liveASRSnapshot()
        return ["uptime":s.observedUptime,"corePosition":(s.corePosition).map { $0 as Any } ?? NSNull(),
            "coreAudioPTS":(s.coreAudioPTS).map { $0 as Any } ?? NSNull(),"seeking":s.seeking,"paused":s.paused,"eof":s.eof,
            "speed":s.speed.isFinite ? s.speed as Any : NSNull(),"demuxer":s.currentDemuxer,
            "demuxerStartTime":(s.demuxerStartTime).map { $0 as Any } ?? NSNull(),"rebaseStartTime":s.rebaseStartTime,
            "loadToken":s.binding?.loadToken.uuidString ?? "", "nativeEntryID":(s.binding?.nativeEntryID).map { $0 as Any } ?? NSNull(),
            "runtimeAid":(s.selectedTrack?.runtimeAudioID).map { $0 as Any } ?? NSNull(),"ffIndex":(s.selectedTrack?.absoluteFFmpegIndex).map { $0 as Any } ?? NSNull(),
            "selectedTrackCodec":s.selectedTrack?.codec ?? "", "seekGeneration":s.seekGeneration,
            "settledSeekGeneration":(s.settledSeekGeneration).map { $0 as Any } ?? NSNull(),
            "controllerState":player.liveASR.state.rawValue,"controllerError":player.liveASR.error ?? "",
            "partial":player.liveASR.partialText,"finalCueCount":player.liveASR.finalCues.count,
            "overlayOwner":player.liveASRHostState.overlayOwner?.uuidString ?? "","overlayPayload":player.liveASRHostState.overlayPayload ?? "",
            "ownedJobs":LiveASRController.hasActiveJobs,"controllerActual":player.liveASR.diagnosticsSnapshot,
            "actualNativeTracks":player.jsonProperty("track-list") ?? NSNull(),
            "actualNativePlaylist":player.jsonProperty("playlist") ?? NSNull()]
    }
    private func cueRows() -> [[String: Any]] { player.liveASR.finalCues.map {
        ["id":$0.id.uuidString,"epoch":$0.epoch,"streamGeneration":$0.streamGeneration,"engineSegment":$0.engineSegment,
         "revision":$0.revision,"startNumerator":$0.start.numerator,"startDenominator":$0.start.denominator,
         "endNumerator":$0.end.numerator,"endDenominator":$0.end.denominator,"text":$0.text,"timingQuality":$0.timingQuality.rawValue]
    } }
    private func sample() {
        if samples.count < 2400 { samples.append(snapshot()) }
        if !shotRequested, hasChinese(player.liveASR.partialText), player.tracks.contains(where: { $0.type == "video" }),
           player.liveASRHostState.overlayOwner != nil,
           player.liveASRHostState.overlayOwner?.uuidString == (player.liveASR.diagnosticsSnapshot["owner"] as? String),
           hasChinese(player.liveASRHostState.overlayPayload ?? "") {
            shotRequested = true
            let png = report.deletingPathExtension().appendingPathExtension("asr-window.png")
            _ = player.saveScreenshotAsync(to: png, mode: .window) { [weak self] r in
                switch r { case .success(let url): self?.shotResult = url.path; case .failure(let error): self?.shotResult = error.localizedDescription }
            }
        }
    }
    private func captureBackend() async {
        if let raw = await player.liveASR.backendDiagnostics() { backendActual = try? JSONSerialization.jsonObject(with: raw) }
    }
    private func finish(_ passed: Bool, scope: String) {
        result = ["succeeded":passed,"asrChecks":checks,"asrSamples":samples,"finalCues":cueRows(),
            "asrSnapshot":snapshot(),"asrScreenshotResult":shotResult ?? "not completed/applicable","asrScope":scope,
            "backendActual":backendActual ?? NSNull(),"fixtureDuration":initialDuration,"synthesizedPCM":false,"synthesizedNativeReceipts":false,
            "wordEndAlignmentVerified":false,"realUIAutomationVerified":false]
    }
}
