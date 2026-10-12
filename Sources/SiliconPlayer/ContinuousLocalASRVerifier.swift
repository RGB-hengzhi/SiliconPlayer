import AppKit
import PlayerCore

/// Opt-in actual-App verifier. The composed-repeat recording tests lifecycle
/// and source continuity; it is not held-out speech accuracy or word alignment.
@MainActor final class ContinuousLocalASRVerifier {
    static let modes: Set<String> = ["live-asr-continuous-local", "live-asr-continuous-cancel"]
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private let player: PlayerModel
    private let report: URL
    private let mode: String
    private var expectedPairs = 5
    private var expectedDuration = 525.4
    private var expectedAudioCodec = "pcm_s16le"
    private var expectedAudioRate = 16_000
    private var task: Task<Void, Never>?
    private var result: [String: Any]?
    private var checks: [[String: Any]] = []
    private var samples: [[String: Any]] = []
    private var lastSampleUptime = -Double.infinity
    private var initial: LiveASRBinding?
    private var daily: Data?
    private var rawPairs: [String: Any] = [:]
    private var preparedRawPairs: [String: Any] = [:]
    private var preparedRawBytes = 0
    private var rawBytes = 0
    private var stagedRawBytes = 0
    private var staged: [[String: Any]] = []
    private var actualControls: [[String: Any]] = []
    private var screenshotResult: Result<URL, Error>?
    init(player: PlayerModel, report: URL, mode: String) { self.player = player; self.report = report; self.mode = mode }
    func tick() -> [String: Any]? {
        if let result { return result }
        if task != nil { sample(); return nil }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let env = ProcessInfo.processInfo.environment
                guard Self.modes.contains(self.mode), env["SILICONPLAYER_VERIFY_REPORT"] == self.report.path,
                      InputController.verificationSuiteName(environment: env) != nil else { throw Failure(message: "Private verification suite required") }
                let sourceCase = env["SILICONPLAYER_VERIFY_CONTINUOUS_CASE"] ?? "pcm25"
                guard ["pcm25", "aac7"].contains(sourceCase), self.mode != "live-asr-continuous-cancel" || sourceCase == "pcm25" else { throw Failure(message: "Explicit continuous fixture case required") }
                self.expectedPairs = sourceCase == "pcm25" ? 5 : 2
                self.expectedDuration = sourceCase == "pcm25" ? 525.4 : 147.112
                self.expectedAudioCodec = sourceCase == "pcm25" ? "pcm_s16le" : "aac"
                self.expectedAudioRate = sourceCase == "pcm25" ? 16_000 : 48_000
                self.daily = UserDefaults.standard.data(forKey: "SiliconPlayer.shortcuts.v1")
                try self.check("isolated-storage", true)
                try await self.wait("loaded-real-long-source", seconds: 25) {
                    self.player.loaded && !self.player.isLoading && abs(self.player.number("duration") - self.expectedDuration) < 0.1
                        && self.player.tracks.contains { $0.type == "video" }
                }
                self.player.set("pause", "yes")
                try await self.selectEmbeddedAudio("selected-embedded-audio-initial")
                self.player.seek(0, remember: false)
                try await self.wait("native-paused-zero", seconds: 6) { self.settled(0) && self.player.flag("pause") }
                self.initial = self.player.liveASRSnapshot().binding
                self.player.setSpeed(2)
                try self.check("initial-pair-accepted", await self.player.startLiveASR())
                try await self.ack(event: "speed_changed", paused: true)
                try self.check("initial-native-paused-ack", (self.player.liveASR.diagnosticsSnapshot["grantedSamples"] as? NSNumber)?.uint64Value == 0)
                let serial = try await self.controlSerial()
                self.player.set("pause", "no"); try await self.ack(event: "resumed", paused: false, minimumSerial: serial)
                try await self.wait("initial-chinese-real-prefix", seconds: 12) { self.chinese() }
                let png = self.report.deletingPathExtension().appendingPathExtension("continuous-window.png")
                _ = self.player.saveScreenshotAsync(to: png, mode: .window) { self.screenshotResult = $0 }
                try await self.wait("actual-chinese-window-png", seconds: 6) {
                    if case .success(let path) = self.screenshotResult { return path == png && FileManager.default.fileExists(atPath: path.path) }; return false
                }
                if self.mode == "live-asr-continuous-local" { try await self.natural() }
                else { try await self.cancel() }
                try self.collectPreparedWire()
                try self.check("daily-shortcut-unchanged", UserDefaults.standard.data(forKey: "SiliconPlayer.shortcuts.v1") == self.daily)
                self.finish(true, "actual composed-repeat lifecycle/source ranges; not held-out quality or word-aligned endpoints")
            } catch {
                _ = await self.player.liveASR.stop()
                self.finish(false, error.localizedDescription)
            }
        }
        return nil
    }
    private func natural() async throws {
        var preserved: [UUID: LiveASRCue] = [:]
        for index in 1..<expectedPairs {
            let old = player.liveASR.diagnosticsSnapshot
            try await wait("actual-input-bound-\(index)", seconds: 85) {
                (self.player.liveASR.diagnosticsSnapshot["completedPairs"] as? [[String: Any]] ?? []).count >= index
            }
            try collectWire()
            let receipts = player.liveASR.diagnosticsSnapshot["completedPairs"] as? [[String: Any]] ?? []
            guard receipts.count == index, let observedReceipt = receipts.last,
                  observedReceipt["kind"] as? String == "input_limit_reached", observedReceipt["confirmed"] as? Bool == true,
                  let completedProcess = observedReceipt["processID"] as? String, rawPairs[completedProcess] != nil,
                  !player.flag("eof-reached") else { throw Failure(message: "Actual input-bound completion/raw missing") }
            preserved.merge(Dictionary(uniqueKeysWithValues: player.liveASR.finalCues.map { ($0.id, $0) })) { first, _ in first }
            try await wait("new-pair-real-prefix-\(index)", seconds: 12) {
                let current = self.player.liveASR.diagnosticsSnapshot
                return current["processID"] as? String != completedProcess && self.player.liveASR.state == .following
                    && ((current["grantedSamples"] as? NSNumber)?.uint64Value ?? 0) > 0
            }
            let next = player.liveASR.diagnosticsSnapshot
            // Handover enriches the value dictionary after the real prefix
            // wait. Reread the same exact old receipt, never the earlier copy.
            guard let updated = next["completedPairs"] as? [[String: Any]], updated.count == index,
                  let receipt = updated.last(where: { $0["processID"] as? String == completedProcess }),
                  receipt["kind"] as? String == "input_limit_reached", receipt["confirmed"] as? Bool == true,
                  receipt["owner"] as? String == observedReceipt["owner"] as? String,
                  (receipt["acceptedSamples"] as? NSNumber)?.uint64Value == (observedReceipt["acceptedSamples"] as? NSNumber)?.uint64Value,
                  (receipt["endNumerator"] as? NSNumber)?.int64Value == (observedReceipt["endNumerator"] as? NSNumber)?.int64Value,
                  (receipt["endDenominator"] as? NSNumber)?.int64Value == (observedReceipt["endDenominator"] as? NSNumber)?.int64Value else {
                throw Failure(message: "Completed receipt namespace/prefix changed during handover")
            }
            try collectPreparedWire()
            guard let nextID = next["processID"] as? String,
                  let prepared = preparedRawPairs[nextID] as? [String: Any],
                  prepared["setupFinished"] as? Bool == true, prepared["recognizerReady"] as? Bool == true,
                  prepared["decoderPaused"] as? Bool == true,
                  (prepared["servicePCMBytesWritten"] as? NSNumber)?.uint64Value == 0,
                  (prepared["actualEpoch"] as? NSNumber)?.uint64Value == 1,
                  (prepared["desiredEpoch"] as? NSNumber)?.uint64Value == 1,
                  let ready = receipt["preparedReadyUptime"] as? Double,
                  let bound = receipt["inputLimitObservedUptime"] as? Double,
                  let handover = receipt["handoverUptime"] as? Double,
                  ready <= bound, bound <= handover else {
                throw Failure(message: "Real paused/zero-input readiness before old input bound absent")
            }
            try check("retained-cues-and-primary-binding-\(index)", player.liveASRSnapshot().binding == initial
                && preserved.values.allSatisfy { original in self.player.liveASR.finalCues.contains { $0.id == original.id && $0.start == original.start && $0.end == original.end && $0.text == original.text } }
                && next["owner"] as? String != receipt["owner"] as? String,
                ["previousProcessID": old["processID"] as Any? ?? NSNull(), "completion": receipt, "next": next])
            if index == 1 {
                let serial = try await controlSerial()
                player.set("pause", "yes"); try await ack(event: "paused", paused: true, minimumSerial: serial)
                try check("continuation-native-paused-ack", player.flag("pause"))
                let held = player.liveASR.diagnosticsSnapshot
                let position = player.number("time-pos"), grant = (held["grantedSamples"] as? NSNumber)?.uint64Value
                let end = ProcessInfo.processInfo.systemUptime + 3.6
                while ProcessInfo.processInfo.systemUptime < end {
                    guard player.flag("pause"), abs(player.number("time-pos") - position) <= 0.05,
                          player.liveASR.error == nil, player.liveASR.state == .paused,
                          (player.liveASR.diagnosticsSnapshot["grantedSamples"] as? NSNumber)?.uint64Value == grant else {
                        throw Failure(message: "Continuation user pause changed actual clock/prefix or failed")
                    }
                    sample(); try await Task.sleep(nanoseconds: 50_000_000)
                }
                try check("continuation-buffer-held-over-three-seconds", player.liveASR.error == nil,
                    ["actualPauseSeconds": 3.6, "grantedBefore": grant as Any? ?? NSNull(),
                        "grantedAfter": player.liveASR.diagnosticsSnapshot["grantedSamples"] as Any? ?? NSNull(),
                        "corePositionBefore": position, "corePositionAfter": player.number("time-pos")])
                let resumeSerial = try await controlSerial()
                player.set("pause", "no"); try await ack(event: "resumed", paused: false, minimumSerial: resumeSerial)
                try check("continuation-real-resume-ack", !player.flag("pause"))
            }
        }
        try await wait("real-player-eof-after-final-pair", seconds: 40) { self.player.flag("eof-reached") && !self.player.liveASR.isActive && !LiveASRController.hasActiveJobs }
        try collectWire()
        let controller = player.liveASR.diagnosticsSnapshot
        try check("all-complete-real-pairs", rawPairs.count == expectedPairs && controller["completedPairWireOverflow"] as? Bool == false
            && (controller["close"] as? [String: Any])?["confirmed"] as? Bool == true && player.liveASR.error == nil)
        let cues = player.liveASR.finalCues
        try check("old-and-post-120-source-cues", cues.contains { $0.end.seconds < 120 } && cues.contains { $0.start.seconds >= 120 }
            && cues.allSatisfy { $0.start.seconds >= 0 && $0.end.seconds > $0.start.seconds && $0.end.seconds <= player.number("duration") + 0.001 })
        let path = report.deletingPathExtension().appendingPathExtension("srt")
        try await player.liveASR.export(to: path)
        let parsed = try SubtitleDocument.parse(String(contentsOf: path, encoding: .utf8))
        try check("full-session-srt-reparse", parsed.cues.count == cues.count && zip(parsed.cues, cues).allSatisfy {
            $0.0.text.trimmingCharacters(in: .whitespacesAndNewlines) == $0.1.text.trimmingCharacters(in: .whitespacesAndNewlines)
                && abs($0.0.start - $0.1.start.seconds) <= 0.0011 && abs($0.0.end - $0.1.end.seconds) <= 0.0011
        })
        try check("real-eof-cleanup", player.liveASRHostState.overlayOwner == nil && !LiveASRController.hasActiveJobs)
    }
    private func cancel() async throws {
        // Observe the validated real C receipt synchronously on the same Actor.
        // User actions are real mpv operations; no artificial delay keeps a
        // short input-bound window alive and no synthetic receipt is generated.
        defer { player.liveASR.onInputLimitObserved = nil }
        for (index, action) in ["seek", "reload", "stop", "quit"].enumerated() {
            var triggered: [String: Any]?
            var reloadRequest: UUID?
            player.liveASR.onInputLimitObserved = { [weak self] limit in
                guard let self, triggered == nil,
                      self.player.liveASR.diagnosticsSnapshot["processID"] as? String == limit.processID.uuidString else { return }
                triggered = ["action": action, "controller": self.player.liveASR.diagnosticsSnapshot,
                    "receipt": ["processID": limit.processID.uuidString, "epoch": limit.ticket.epoch,
                        "itemSerial": limit.ticket.itemSerial, "decodedSamples": limit.decodedSamples,
                        "maximumSamples": limit.maximumSamples, "nextChunkSamplesNotPublished": limit.nextChunkSamplesNotPublished],
                    "uptime": ProcessInfo.processInfo.systemUptime]
                if action == "seek" { self.player.set("pause", "yes"); self.player.seek(3, remember: false) }
                else if action == "reload", let url = self.player.currentURL { reloadRequest = self.player.open([url]) }
                else if action == "stop" { Task { _ = await self.player.liveASR.stop() } }
            }
            if index > 0 {
                player.set("pause", "yes")
                try await selectEmbeddedAudio("selected-embedded-audio-" + action)
                player.seek(0, remember: false)
                try await wait("reset-native-\(action)", seconds: 6) { self.settled(0) && self.player.flag("pause") }
                try check("restart-pair-\(action)", await player.startLiveASR())
                try await ack(event: "speed_changed", paused: true)
                let serial = try await controlSerial()
                player.set("pause", "no"); try await ack(event: "resumed", paused: false, minimumSerial: serial)
            }
            try await wait("real-bound-before-\(action)", seconds: 85) { triggered != nil }
            guard let trigger = triggered else { throw Failure(message: "Real bound callback unavailable") }
            if action == "reload" {
                guard let request = reloadRequest else { throw Failure(message: "Actual reload request rejected") }
                try await player.ordinaryMediaOpen.waitForCommit(request)
            }
            staged.append(trigger)
            player.liveASR.onInputLimitObserved = nil
            if action == "quit" {
                try check("owned-real-bound-at-quit", player.liveASR.isActive || LiveASRController.hasActiveJobs,
                    ["actualBound": trigger])
                return // Real AppDelegate termination supplies actual strong close.
            }
            try await wait("owned-retired-\(action)", seconds: 15) { !LiveASRController.hasActiveJobs && !self.player.liveASR.isActive && self.player.liveASRHostState.overlayOwner == nil }
            let cancelled = player.liveASR.diagnosticsSnapshot
            let receipt = cancelled["close"] as? [String: Any] ?? [:]
            try check("strong-close-no-revival-\(action)", receipt["confirmed"] as? Bool == true && receipt["resourcesReleased"] as? Bool == true
                && receipt["forced"] as? Bool == false)
            let end = ProcessInfo.processInfo.systemUptime + 0.6
            while ProcessInfo.processInfo.systemUptime < end {
                guard !LiveASRController.hasActiveJobs, !player.liveASR.isActive, player.liveASRHostState.overlayOwner == nil else { throw Failure(message: "Retired rollover revived after user action") }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let raw = await player.liveASR.backendDiagnostics(), raw.count <= 32 * 1_048_576,
                  stagedRawBytes + raw.count <= 160 * 1_048_576,
                  let value = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw Failure(message: "Actual cancelled pair raw unavailable") }
            stagedRawBytes += raw.count
            staged[index]["after"] = cancelled; staged[index]["backendAfter"] = value
            try collectPreparedWire() // Save actual warm cancellation before the next start resets its cache.
        }
    }
    private func selectEmbeddedAudio(_ id: String) async throws {
        // The fixture directory intentionally retains the original composition
        // WAV. mpv may discover and prefer it; this case measures the MOV stream.
        // Resolve the actual native ID, then require native and Host readback.
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        var requestedID: Int?
        while true {
            let rows = player.jsonProperty("track-list") as? [[String: Any]] ?? []
            let eligible = rows.filter {
                ($0["type"] as? String) == "audio" && ($0["external"] as? Bool) != true
                    && ($0["ff-index"] as? Int) == 1 && ($0["codec"] as? String) == expectedAudioCodec
                    && ($0["demux-samplerate"] as? Int) == expectedAudioRate
                    && ($0["demux-channel-count"] as? Int) == 1
            }
            if player.loaded && !player.isLoading, eligible.count == 1,
               let nativeID = eligible.first?["id"] as? Int, nativeID > 0 {
                if requestedID != nativeID {
                    player.selectAudio(nativeID)
                    requestedID = nativeID
                }
                let snapshot = player.liveASRSnapshot()
                let selected = rows.filter { ($0["type"] as? String) == "audio" && ($0["selected"] as? Bool) == true }
                if let track = snapshot.selectedTrack, snapshot.currentDemuxer == "lavf",
                   player.liveASRProperty("aid") == String(nativeID), player.audioID == nativeID,
                   selected.count == 1, (selected.first?["id"] as? Int) == nativeID,
                   (selected.first?["external"] as? Bool) != true,
                   track.runtimeAudioID == nativeID, !track.isExternal, track.externalSource == nil,
                   track.absoluteFFmpegIndex == 1, track.codec == expectedAudioCodec,
                   track.sampleRate == expectedAudioRate, track.channels == 1 {
                    try check(id, true, ["requestedNativeID": nativeID, "actualAid": player.liveASRProperty("aid") ?? "",
                        "actualPublishedAid": player.audioID, "actualNativeTracks": rows,
                        "actualFFmpegIndex": track.absoluteFFmpegIndex, "codec": track.codec,
                        "sampleRate": track.sampleRate, "channels": track.channels,
                        "external": track.isExternal, "currentDemuxer": snapshot.currentDemuxer])
                    return
                }
            }
            if ProcessInfo.processInfo.systemUptime >= deadline || player.liveASR.state == .failed {
                try check(id, false, ["actualNativeTracks": rows,
                    "actualAid": player.liveASRProperty("aid") ?? "", "actualPublishedAid": player.audioID])
            }
            sample(); try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    private func collectWire() throws {
        for (id, raw) in player.liveASR.completedPairDiagnostics() where rawPairs[id.uuidString] == nil {
            guard raw.count <= 32 * 1_048_576, rawBytes + raw.count <= 160 * 1_048_576,
                  let value = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  value["captureEnabled"] as? Bool == true, value["processID"] as? String == id.uuidString else {
                throw Failure(message: "Required pair wire overflow or wrong owned identity")
            }
            rawPairs[id.uuidString] = value; rawBytes += raw.count
        }
    }
    private func collectPreparedWire() throws {
        for (id, raw) in player.liveASR.preparedPairDiagnostics() {
            guard raw.count <= 32 * 1_048_576,
                  let value = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  value["captureEnabled"] as? Bool == true, value["processID"] as? String == id.uuidString else {
                throw Failure(message: "Actual prepared pair capture identity missing")
            }
            preparedRawPairs[id.uuidString] = value
        }
        let encoded = try JSONSerialization.data(withJSONObject: preparedRawPairs)
        guard encoded.count <= 8 * 1_048_576 else { throw Failure(message: "Prepared pair capture overflow") }
        preparedRawBytes = encoded.count
    }
    private func controlSerial() async throws -> UInt64 {
        guard let data = await player.liveASR.backendDiagnostics(),
              let actual = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serial = (actual["controlReceiptSerial"] as? NSNumber)?.uint64Value else {
            throw Failure(message: "Actual control baseline missing")
        }
        return serial
    }
    private func ack(event: String, paused: Bool, minimumSerial: UInt64 = 0) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while true {
            let host = player.liveASRSnapshot(), current = player.liveASR.diagnosticsSnapshot
            if let data = await player.liveASR.backendDiagnostics(), let actual = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let epoch = (current["epoch"] as? NSNumber)?.uint64Value,
               actual["processID"] as? String == current["processID"] as? String,
               (actual["actualEpoch"] as? NSNumber)?.uint64Value == epoch, (actual["desiredEpoch"] as? NSNumber)?.uint64Value == epoch,
               actual["decoderPaused"] as? Bool == paused, host.paused == paused,
               (actual["controlReceipts"] as? [[String: Any]] ?? []).contains(where: { $0["event"] as? String == event && ($0["epoch"] as? NSNumber)?.uint64Value == epoch && (($0["serial"] as? NSNumber)?.uint64Value ?? 0) > minimumSerial }),
               player.liveASR.state == (paused ? .paused : .following), !host.seeking,
               host.settledSeekGeneration == host.seekGeneration {
                let receipts = actual["controlReceipts"] as? [[String: Any]] ?? []
                let matching = receipts.filter { $0["event"] as? String == event
                    && ($0["epoch"] as? NSNumber)?.uint64Value == epoch
                    && (($0["serial"] as? NSNumber)?.uint64Value ?? 0) > minimumSerial }
                guard let receipt = matching.last else { throw Failure(message: "Actual ACK selection missing") }
                actualControls.append(["processID": actual["processID"] as Any? ?? NSNull(),
                    "event": event, "epoch": epoch, "actualEpoch": actual["actualEpoch"] as Any? ?? NSNull(),
                    "desiredEpoch": actual["desiredEpoch"] as Any? ?? NSNull(), "paused": paused,
                    "receipt": receipt, "minimumSerial": minimumSerial, "hostPaused": host.paused,
                    "hostSeekGeneration": host.seekGeneration, "hostSettledSeekGeneration": host.settledSeekGeneration as Any? ?? NSNull(),
                    "hostSeeking": host.seeking, "uptime": ProcessInfo.processInfo.systemUptime])
                return
            }
            if ProcessInfo.processInfo.systemUptime >= deadline || player.liveASR.state == .failed { throw Failure(message: "Real owned native control missing") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    private func settled(_ target: Double) -> Bool {
        let s = player.liveASRSnapshot()
        return !s.seeking && s.seekGeneration == s.settledSeekGeneration && (s.corePosition.map { abs($0 - target) <= 0.001 } ?? false)
    }
    private func chinese() -> Bool {
        player.liveASR.partialText.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }
            && player.liveASRHostState.overlayOwner?.uuidString == player.liveASR.diagnosticsSnapshot["owner"] as? String
            && !(player.liveASRHostState.overlayPayload ?? "").isEmpty
    }
    private func check(_ id: String, _ ok: Bool, _ detail: [String: Any] = [:]) throws {
        checks.append(["id": id, "passed": ok, "detail": detail, "uptime": ProcessInfo.processInfo.systemUptime])
        if !ok { throw Failure(message: id + ": " + (player.liveASR.error ?? "failed")) }
    }
    private func wait(_ id: String, seconds: Double, condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            if player.liveASR.state == .failed || ProcessInfo.processInfo.systemUptime >= end { try check(id, false) }
            sample(); try await Task.sleep(nanoseconds: 50_000_000)
        }
        try check(id, true)
    }
    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSampleUptime >= 0.5, samples.count < 1024 else { return }
        lastSampleUptime = now
        let s = player.liveASRSnapshot(), d = player.liveASR.diagnosticsSnapshot
        samples.append(["uptime": now, "position": s.corePosition as Any? ?? NSNull(), "paused": s.paused,
            "processID": d["processID"] as Any? ?? NSNull(), "epoch": d["epoch"] as Any? ?? NSNull(),
            "state": player.liveASR.state.rawValue, "inputLimit": d["inputLimitReached"] as Any? ?? NSNull(),
            "cueCount": player.liveASR.finalCues.count, "renderUpdateCount": player.renderProgress.frames])
    }
    private func finish(_ ok: Bool, _ scope: String) {
        result = ["succeeded": ok, "asrScope": scope, "asrChecks": checks, "asrSamples": samples,
            "preparedPairWire": preparedRawPairs, "preparedPairWireBytes": preparedRawBytes,
            "stageReceipts": staged, "actualControlReceipts": actualControls, "completedPairWire": rawPairs, "completedPairWireBytes": rawBytes, "stagedPairWireBytes": stagedRawBytes,
            "controllerActual": player.liveASR.diagnosticsSnapshot,
            "screenshotPath": report.deletingPathExtension().appendingPathExtension("continuous-window.png").path,
            "expectedPairs": expectedPairs, "expectedSourceSeconds": expectedDuration,
            "compositionQualityClaim": false, "wordEndAlignmentVerified": false]
    }
}
