import AppKit
import PlayerCore

/// Opt-in isolated actual-App checks. Uses real external file/track/PCM/ASR;
/// never supplies synthetic audio, helper ACKs, recognition or seek receipts.
@MainActor final class ExternalWAVASRVerifier {
    static let modes: Set<String> = ["live-asr-external-wav-replay", "live-asr-external-wav-identity"]
    private struct Failure: LocalizedError { let text: String; var errorDescription: String? { text } }
    private let player: PlayerModel
    private let report: URL
    private let mode: String
    private var task: Task<Void, Never>?
    private var result: [String: Any]?
    private var checks: [[String: Any]] = []
    private var samples: [[String: Any]] = []
    private var backend: [String: Any]?
    private var wav: URL!
    private var shortWAV: URL!
    private var edgeReceipts: [[String: Any]] = []
    private var source: URL!
    private var wavDuration = 0.0
    private var mainDuration = 0.0
    private var initialBinding: LiveASRBinding?
    private var daily: Data?
    private var screenshotResult: Result<URL, Error>?
    init(player: PlayerModel, report: URL, mode: String) { self.player = player; self.report = report; self.mode = mode }
    func tick() -> [String: Any]? {
        if let result { return result }
        if task != nil { sample(); return nil }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try self.configure()
                try await self.wait("main-video-loaded", seconds: 20) { self.player.loaded && !self.player.isLoading && self.player.tracks.contains { $0.type == "video" } }
                self.source = self.player.currentURL; self.mainDuration = self.player.number("duration")
                try self.check("main-longer-than-external", self.mainDuration > self.wavDuration + 4 && self.wavDuration >= 5 && self.wavDuration <= 15,
                    ["mainDuration": self.mainDuration, "externalDuration": self.wavDuration])
                self.player.set("pause", "yes"); self.player.seek(0, remember: false)
                try await self.wait("native-initial-seek-settled", seconds: 6) { self.settledZero() }
                self.initialBinding = self.player.liveASRSnapshot().binding
                try self.check("external-add-accepted", self.player.executeCommand(["audio-add", self.wav.path, "select"]) >= 0)
                try await self.wait("selected-external-wav-row", seconds: 5) { self.selectedWAV() }
                try self.check("external-pair-start-accepted", await self.player.startLiveASR(), ["host": self.snapshot()])
                try await self.nativeControl("initial-paused-speed-ack", event: "speed_changed", paused: true)
                let heldActual = try await self.actualBackend()
                let heldStart = try self.heldStartupReceipt(heldActual)
                try self.check("external-held-source-proof", self.externalProofValid(), ["actual": self.player.liveASR.diagnosticsSnapshot, "actualBackend": heldActual, "heldStart": heldStart])
                let initialSerial = try await self.controlSerial()
                self.player.set("pause", "no")
                try await self.nativeControl("actual-native-resume-ack", event: "resumed", paused: false, after: initialSerial)
                try await self.wait("external-current-chinese-partial", seconds: 12) { self.hasCurrentChinese() }
                try await self.wait("matching-real-chinese-overlay", seconds: 3) { self.hasOwnedChineseOverlay() }
                try await self.screenshot()
                if self.mode == "live-asr-external-wav-replay" { try await self.replay() }
                else { try await self.identity() }
                try await self.shortSourceBoundary()
                _ = await self.player.liveASR.stop()
                try await self.wait("final-owned-cleanup", seconds: 6) { !LiveASRController.hasActiveJobs && self.player.liveASRHostState.overlayOwner == nil }
                try self.check("daily-shortcuts-unchanged", UserDefaults.standard.data(forKey: "SiliconPlayer.shortcuts.v1") == self.daily)
                self.backend = try await self.actualBackend()
                self.finish(true, "Actual selected local sole PCM WAV/primary binding; accepted source ranges, not word alignment")
            } catch {
                _ = await self.player.liveASR.stop()
                self.backend = try? await self.actualBackend()
                self.finish(false, error.localizedDescription)
            }
        }
        return nil
    }
    private func configure() throws {
        let env = ProcessInfo.processInfo.environment
        guard Self.modes.contains(mode), env["SILICONPLAYER_VERIFY_REPORT"] == report.path,
              InputController.verificationSuiteName(environment: env) != nil,
              let storagePath = env["SILICONPLAYER_VERIFY_STORAGE"], storagePath.hasPrefix("/"),
              let path = env["SILICONPLAYER_VERIFY_EXTERNAL_WAV"], path.hasPrefix("/"),
              let shortPath = env["SILICONPLAYER_VERIFY_SHORT_WAV"], shortPath.hasPrefix("/"),
              let durationText = env["SILICONPLAYER_VERIFY_EXTERNAL_WAV_DURATION"], let duration = Double(durationText),
              duration.isFinite, (5...15).contains(duration), report.path.hasPrefix("/") else { throw Failure(text: "Owned external verification fixture/storage required") }
        let storage = URL(fileURLWithPath: storagePath).resolvingSymlinksInPath().standardizedFileURL
        let local = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard local.path.hasPrefix(storage.path + "/"), local.pathExtension.lowercased() == "wav",
              LiveASRMPVHostState.fingerprint(local) != nil else { throw Failure(text: "Owned local regular WAV required") }
        let short = URL(fileURLWithPath: shortPath).resolvingSymlinksInPath().standardizedFileURL
        guard short.path.hasPrefix(storage.path + "/"), short.pathExtension.lowercased() == "wav", short != local,
              LiveASRMPVHostState.fingerprint(short) != nil else { throw Failure(text: "Owned separate short regular WAV required") }
        shortWAV = short
        wav = local; wavDuration = duration; daily = UserDefaults.standard.data(forKey: "SiliconPlayer.shortcuts.v1")
        try check("isolated-storage-valid", true, ["wav": local.path, "scope": "only this private copied fixture may be replaced"])
    }
    private func replay() async throws {
        let old = player.liveASR.diagnosticsSnapshot
        try await wait("external-source-completed-before-main-eof", seconds: wavDuration + 8) {
            self.player.liveASR.state == .sourceCompleted && !self.player.liveASR.isActive && !LiveASRController.hasActiveJobs && !self.player.flag("eof-reached")
        }
        try check("external-natural-close-exact", strongClose(), ["snapshot": snapshot(), "actualBackend": try await actualBackend()])
        let firstCues = player.liveASR.finalCues
        try check("external-final-cues-in-source-clock", validCues(firstCues), ["cues": cueRows()])
        try await wait("external-final-visible-tail", seconds: 1.5) { self.hasOwnedChineseOverlay() && self.player.liveASR.state == .sourceCompleted }
        let token = player.mediaPreferenceToken, generation = player.liveASRHostState.seekGeneration
        player.set("pause", "yes"); player.seek(1, remember: false)
        try await wait("replay-native-seek-settled", seconds: 6) { self.player.liveASRHostState.seekGeneration > generation && self.settled(at: 1) }
        try await wait("replay-new-owned-pair", seconds: 12) {
            let current = self.player.liveASR.diagnosticsSnapshot
            return self.player.liveASR.isActive && (current["processID"] as? String) != (old["processID"] as? String)
                && (current["owner"] as? String) != (old["owner"] as? String) && self.player.mediaPreferenceToken == token
                && self.player.liveASRSnapshot().binding == self.initialBinding
        }
        try await nativeControl("replay-paused-native-ack", event: "speed_changed", paused: true)
        let fresh = player.liveASR.diagnosticsSnapshot
        let oldSerial = (old["ticket"] as? [String: Any])?["itemSerial"] as? NSNumber
        let replaySerial = try await controlSerial()
        player.set("pause", "no")
        try await nativeControl("replay-resumed-native-ack", event: "resumed", paused: false, after: replaySerial)
        try await wait("replay-current-chinese-prefix", seconds: 12) {
            let actual = self.player.liveASR.diagnosticsSnapshot
            let serial = (actual["ticket"] as? [String: Any])?["itemSerial"] as? NSNumber
            return self.hasCurrentChinese() && (actual["processID"] as? String) == (fresh["processID"] as? String)
                && serial.map { value in oldSerial.map { value.uint64Value > $0.uint64Value } ?? false } == true
        }
        try await wait("replay-source-natural-complete", seconds: wavDuration + 8) {
            self.player.liveASR.state == .sourceCompleted && !self.player.liveASR.isActive && !LiveASRController.hasActiveJobs && !self.player.flag("eof-reached")
        }
        try check("replay-close-and-source-cues", strongClose() && validCues(player.liveASR.finalCues), ["snapshot": snapshot(), "cues": cueRows(), "actualBackend": try await actualBackend()])
        let output = report.deletingPathExtension().appendingPathExtension("srt")
        try await player.liveASR.export(to: output)
        let parsed = try SubtitleDocument.parse(String(contentsOf: output, encoding: .utf8)), cues = player.liveASR.finalCues
        try check("replay-real-srt-reparse", parsed.cues.count == cues.count && zip(parsed.cues, cues).allSatisfy {
            abs($0.0.start - $0.1.start.seconds) <= 0.0011 && abs($0.0.end - $0.1.end.seconds) <= 0.0011
                && $0.0.text.trimmingCharacters(in: .whitespacesAndNewlines) == $0.1.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }, ["path": output.path, "cues": cueRows(), "snapshot": snapshot()])
        try await self.zeroPrefixBoundary()
    }
    private func identity() async throws {
        let before = player.liveASR.diagnosticsSnapshot
        guard let embedded = (player.jsonProperty("track-list") as? [[String: Any]])?.first(where: {
            $0["type"] as? String == "audio" && $0["external"] as? Bool != true
        }), let embeddedID = embedded["id"] as? Int,
              let externalID = player.liveASRSnapshot().selectedTrack?.runtimeAudioID else { throw Failure(text: "Actual primary and external audio tracks required") }
        player.selectAudio(embeddedID)
        // Poll provides native track-list change confirmation; no fake immediate
        // callback is supplied as a substitute for the actual selected row.
        try await wait("selected-track-change-cancels-old-pair", seconds: 6) {
            !LiveASRController.hasActiveJobs && !self.player.liveASR.isActive && self.player.liveASRHostState.overlayOwner == nil && self.player.liveASR.partialText.isEmpty
        }
        try check("old-track-close-exact", strongClose(), ["snapshot": snapshot(), "old": before])
        player.set("pause", "yes"); player.selectAudio(externalID); player.seek(0, remember: false)
        try await wait("original-external-reselected-and-settled", seconds: 6) { self.selectedWAV() && self.settled(at: 0) }
        try check("external-restart-accepted", await player.startLiveASR())
        try await nativeControl("identity-restart-paused-ack", event: "speed_changed", paused: true)
        guard let original = LiveASRMPVHostState.fingerprint(wav) else { throw Failure(text: "External fingerprint missing") }
        // Only the separately copied owned fixture from configure can change.
        let bytes = try Data(contentsOf: wav)
        guard bytes.count <= 16 * 1024 * 1024 else { throw Failure(text: "Private WAV replacement exceeds bound") }
        try bytes.write(to: wav, options: .atomic)
        let replacement = LiveASRMPVHostState.fingerprint(wav)
        try check("same-path-external-identity-replaced", replacement != nil && replacement != original,
            ["beforeInode": original.inode, "afterInode": replacement?.inode as Any? ?? NSNull()])
        try await wait("replaced-path-old-pair-retired", seconds: 6) {
            !self.player.liveASR.isActive && !LiveASRController.hasActiveJobs && self.player.liveASRHostState.overlayOwner == nil && self.player.liveASR.partialText.isEmpty
        }
        try check("replaced-source-close-exact", strongClose(), ["snapshot": snapshot()])
        try check("replacement-cannot-reuse-original-attachment", !(await player.startLiveASR()) && !LiveASRController.hasActiveJobs,
            ["snapshot": snapshot()])
    }
    /// Extra edge receipts remain inside the existing two groups. They are
    /// mandatory real subprocess/clock proofs, not extra asrChecks or groups.
    private func boundaryWait(_ seconds: Double, allowFailed: Bool = false, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            if (!allowFailed && player.liveASR.state == .failed) || ProcessInfo.processInfo.systemUptime >= deadline {
                throw Failure(text: "External edge boundary did not settle: " + (player.liveASR.error ?? "deadline"))
            }
            sample(); try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    private func heldStartupReceipt(_ actual: [String: Any]) throws -> [String: Any] {
        let events = actual["decoderEvents"] as? [[String: Any]] ?? []
        let headers = actual["pcmHeaders"] as? [[String: Any]] ?? []
        guard let holdIndex = events.firstIndex(where: { $0["event"] as? String == "first_block_waiting" }),
              let firstPause = events[..<holdIndex].firstIndex(where: { $0["event"] as? String == "paused" }),
              let firstResume = events[..<holdIndex].firstIndex(where: { $0["event"] as? String == "resumed" }),
              let firstPCM = events[..<holdIndex].firstIndex(where: { $0["event"] as? String == "pcm" }),
              firstPause < firstResume, firstResume < firstPCM, firstPCM < holdIndex,
              let secondPause = events.indices.first(where: { $0 > holdIndex && events[$0]["event"] as? String == "paused" }),
              let confirmed = events.indices.first(where: { $0 > secondPause && events[$0]["event"] as? String == "first_block_pause_confirmed" }),
              let epoch = (events[holdIndex]["epoch"] as? NSNumber)?.uint64Value,
              let sequence = (events[holdIndex]["sequence"] as? NSNumber)?.uint64Value,
              let item = (events[holdIndex]["item"] as? NSNumber)?.uint64Value,
              let segment = (events[holdIndex]["segment"] as? NSNumber)?.uint64Value,
              let header = headers.first(where: { ($0["epoch"] as? NSNumber)?.uint64Value == epoch && ($0["sequence"] as? NSNumber)?.uint64Value == sequence }),
              (header["item"] as? NSNumber)?.uint64Value == item, (header["segment"] as? NSNumber)?.uint64Value == segment,
              (header["streamIndex"] as? NSNumber)?.intValue == 0, (header["pcmPTS"] as? NSNumber)?.int64Value == 0,
              (header["flags"] as? NSNumber).map({ $0.intValue & 1 == 1 }) == true,
              (header["sourceBestEffortTimestamp"] as? NSNumber)?.int64Value == 0,
              (header["samples"] as? NSNumber)?.intValue == (events[holdIndex]["samples"] as? NSNumber)?.intValue,
              (events[holdIndex]["header_bytes"] as? NSNumber)?.intValue == 112,
              (events[holdIndex]["record_bytes"] as? NSNumber)?.intValue == 112 + ((header["samples"] as? NSNumber)?.intValue ?? -1) * 4,
              [firstPause, firstResume, secondPause, confirmed].allSatisfy({ (events[$0]["epoch"] as? NSNumber)?.uint64Value == epoch }) else {
            throw Failure(text: "Actual held birth/two native pauses/first SPCM proof missing")
        }
        let controlNames: Set<String> = ["paused", "resumed", "speed_changed", "epoch_changed", "cancel_acknowledged", "control_rejected"]
        let firstSerial = events[...firstPause].filter { controlNames.contains($0["event"] as? String ?? "") }.count
        let secondSerial = events[...secondPause].filter { controlNames.contains($0["event"] as? String ?? "") }.count
        guard secondSerial > firstSerial, firstSerial > 0 else { throw Failure(text: "Actual native PAUSE receipts not distinct") }
        return ["firstPauseObservedControlSerial": firstSerial, "secondPauseObservedControlSerial": secondSerial,
                "firstPauseEventOrdinal": firstPause, "secondPauseEventOrdinal": secondPause, "firstBlockEventOrdinal": holdIndex,
                "firstRealHeader": header, "epoch": epoch, "sequence": sequence, "originIsActualPTS": true]
    }
    private func boundaryControl(event: String, paused: Bool, after: UInt64 = 0, allowCompleted: Bool = false, allowExpectedEmptyFailure: Bool = false) async throws -> [String: Any] {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while true {
            let actual = try await actualBackend(), controller = player.liveASR.diagnosticsSnapshot, host = player.liveASRSnapshot()
            let epoch = (controller["epoch"] as? NSNumber)?.uint64Value
            let receipts = actual["controlReceipts"] as? [[String: Any]] ?? []
            let receipt = receipts.last { $0["event"] as? String == event && ($0["epoch"] as? NSNumber)?.uint64Value == epoch && ($0["serial"] as? NSNumber).map { $0.uint64Value > after } == true }
            let phaseOK = player.liveASR.state == (paused ? .paused : .following) || (!paused && allowCompleted && player.liveASR.state == .sourceCompleted)
                || (!paused && allowExpectedEmptyFailure && player.liveASR.state == .failed)
            if host.paused == paused, !host.seeking, host.settledSeekGeneration == host.seekGeneration,
               host.binding == initialBinding, selectedWAV(), phaseOK,
               actual["processID"] as? String == controller["processID"] as? String,
               let epoch, epoch > 0, (actual["actualEpoch"] as? NSNumber)?.uint64Value == epoch,
               (actual["desiredEpoch"] as? NSNumber)?.uint64Value == epoch, actual["decoderPaused"] as? Bool == paused, let receipt {
                return ["actualDecoderACK": receipt, "actualBackend": actual, "snapshot": snapshot(), "minimumSerial": after]
            }
            if (!allowExpectedEmptyFailure && player.liveASR.state == .failed) || ProcessInfo.processInfo.systemUptime >= deadline { throw Failure(text: "Actual short-source native control missing") }
            sample(); try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    private func zeroPrefixBoundary() async throws {
        let target = wavDuration + 0.75, old = player.liveASR.diagnosticsSnapshot
        guard target + 1 < mainDuration else { throw Failure(text: "Main fixture cannot cover external source-tail boundary") }
        player.set("pause", "yes"); player.seek(target, remember: false)
        try await boundaryWait(6) { self.player.flag("pause") && self.settled(at: target) }
        try await boundaryWait(6) { !LiveASRController.hasActiveJobs && !self.player.liveASR.isActive }
        guard await player.startLiveASR() else { throw Failure(text: "Zero-prefix case did not reach real owned source/pair setup") }
        let initialPause = try await boundaryControl(event: "speed_changed", paused: true)
        let resumeBaseline = try await controlSerial()
        player.set("pause", "no")
        // A paused decoder cannot read to source EOF. This receipt permits the
        // expected empty-input failure to race ACK observation, but it still
        // requires a real fresh same-epoch RESUME and actual unpaused Core.
        let resume = try await boundaryControl(event: "resumed", paused: false, after: resumeBaseline, allowExpectedEmptyFailure: true)
        try await boundaryWait(20, allowFailed: true) { self.player.liveASR.state == .failed && !LiveASRController.hasActiveJobs }
        let controller = player.liveASR.diagnosticsSnapshot, actual = try await actualBackend()
        let wire = actual["serviceJSONLines"] as? [String] ?? []
        let rows = try wire.map { line -> [String: Any] in
            guard let data = line.data(using: .utf8), let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure(text: "Actual zero-prefix service JSON missing") }
            return row
        }
        let close = controller["close"] as? [String: Any] ?? [:]
        let trueEOF = (actual["decoderEvents"] as? [[String: Any]] ?? []).contains { $0["event"] as? String == "media_eof" && ($0["epoch"] as? NSNumber)?.uint64Value == (actual["actualEpoch"] as? NSNumber)?.uint64Value }
        guard controller["processID"] as? String != old["processID"] as? String,
              (controller["grantedSamples"] as? NSNumber)?.uint64Value == 0,
              self.player.liveASRSnapshot().binding == self.initialBinding,
              sameDiagnosticBinding(controller, old),
              player.liveASR.finalCues.isEmpty, player.liveASRHostState.overlayOwner == nil, !player.flag("eof-reached"),
              !player.flag("pause"), !player.liveASRSnapshot().paused,
              trueEOF, actual["decoderMediaEOF"] as? Bool == true,
              rows.contains(where: { $0["event"] as? String == "error" && $0["reason"] as? String == "no_actual_PCM_input" }),
              !rows.contains(where: { $0["event"] as? String == "eof_final" }),
              close["confirmed"] as? Bool == false, close["resourcesReleased"] as? Bool == true,
              close["ownedReaped"] as? Bool == true, close["forced"] as? Bool == false,
              (close["decoderExit"] as? NSNumber)?.intValue == 0, (close["recognizerExit"] as? NSNumber)?.intValue == 1,
              actual.keys.contains("lastError"), !(actual["lastError"] is NSNull) else { throw Failure(text: "Zero-prefix source-tail did not preserve exact real empty-input failure") }
        edgeReceipts.append(["kind": "zero-prefix-beyond-source-end", "expectedFailureObserved": true,
            "target": target, "before": old, "initialPausedACK": initialPause, "resumeBaselineSerial": resumeBaseline,
            "actualResumedACK": resume, "controllerActual": controller, "actualBackend": actual, "snapshot": snapshot()])
        _ = await player.liveASR.stop()
    }
    private func shortSourceBoundary() async throws {
        _ = await player.liveASR.stop()
        let originalSource = wav
        wav = shortWAV
        player.set("pause", "yes"); player.seek(0, remember: false)
        try await boundaryWait(6, allowFailed: true) { self.settledZero() }
        guard player.executeCommand(["audio-add", shortWAV.path, "select"]) >= 0 else { throw Failure(text: "Actual short WAV attach failed") }
        try await boundaryWait(6, allowFailed: true) { self.selectedWAV() }
        guard await player.startLiveASR() else { throw Failure(text: "Actual short WAV held setup failed") }
        let pause = try await boundaryControl(event: "speed_changed", paused: true)
        let firstActual = try await actualBackend(), heldStart = try heldStartupReceipt(firstActual)
        let first = player.liveASR.diagnosticsSnapshot
        guard externalProofValid(), ((heldStart["firstRealHeader"] as? [String: Any])?["samples"] as? NSNumber)?.intValue == 80,
              ((heldStart["firstRealHeader"] as? [String: Any])?["inputRate"] as? NSNumber)?.intValue == 16000,
              (first["grantedSamples"] as? NSNumber)?.uint64Value == 0,
              LiveASRController.hasActiveJobs else { throw Failure(text: "Short WAV paused source proof unavailable") }
        let serial = try await controlSerial()
        player.set("pause", "no")
        let resume = try await boundaryControl(event: "resumed", paused: false, after: serial, allowCompleted: true)
        try await boundaryWait(12) { self.player.liveASR.state == .sourceCompleted && !LiveASRController.hasActiveJobs && !self.player.flag("eof-reached") }
        let complete = player.liveASR.diagnosticsSnapshot, actual = try await actualBackend()
        let serviceLines = actual["serviceJSONLines"] as? [String] ?? []
        let serviceRows = try serviceLines.map { line -> [String: Any] in
            guard let data = line.data(using: .utf8), let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure(text: "Short source actual service JSON missing") }; return row
        }
        guard strongClose(), (complete["grantedSamples"] as? NSNumber)?.uint64Value == 80,
              let final = serviceRows.last(where: { $0["event"] as? String == "eof_final" }),
              (final["accepted_samples"] as? NSNumber)?.uint64Value == 80,
              (final["padding_samples"] as? NSNumber)?.uint64Value == 16000,
              actual["decoderMediaEOF"] as? Bool == true, !serviceRows.contains(where: { $0["event"] as? String == "error" }) else {
            throw Failure(text: "Short source failed genuine 80-sample EOF/final/strong-close boundary")
        }
        let generation = player.liveASRHostState.seekGeneration
        player.set("pause", "yes"); player.seek(0, remember: false)
        try await boundaryWait(6) { self.player.liveASRHostState.seekGeneration > generation && self.settledZero() }
        try await boundaryWait(12) {
            let current = self.player.liveASR.diagnosticsSnapshot
            return self.player.liveASR.isActive && current["processID"] as? String != first["processID"] as? String
                && current["owner"] as? String != first["owner"] as? String && self.player.liveASRSnapshot().binding == self.initialBinding
        }
        let replayPause = try await boundaryControl(event: "speed_changed", paused: true)
        let replay = player.liveASR.diagnosticsSnapshot, replayBackend = try await actualBackend()
        let replayHeld = try heldStartupReceipt(replayBackend)
        guard (replay["grantedSamples"] as? NSNumber)?.uint64Value == 0,
              let newItem = ((replayHeld["firstRealHeader"] as? [String: Any])?["item"] as? NSNumber)?.uint64Value,
              let oldItem = ((complete["ticket"] as? [String: Any])?["itemSerial"] as? NSNumber)?.uint64Value,
              newItem > oldItem else { throw Failure(text: "Short backseek reused an old source ticket") }
        let stop = await player.liveASR.stop()
        try await boundaryWait(6) { !LiveASRController.hasActiveJobs && self.player.liveASRHostState.overlayOwner == nil }
        let stopped = player.liveASR.diagnosticsSnapshot, stoppedActual = try await actualBackend()
        let stopService = stoppedActual["serviceJSONLines"] as? [String] ?? []
        let stopRows = try stopService.map { line -> [String: Any] in
            guard let data = line.data(using: .utf8), let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure(text: "Actual short cancellation JSON missing") }; return row
        }
        guard stop.confirmed, stop.resourcesReleased, !stop.forcedTermination,
              strongClose(), (stopped["grantedSamples"] as? NSNumber)?.uint64Value == 0,
              stoppedActual.keys.contains("lastError"), stoppedActual["lastError"] is NSNull,
              stopRows.contains(where: { $0["event"] as? String == "cancel_acknowledged" }),
              stopRows.contains(where: { $0["event"] as? String == "closed" && $0["ok"] as? Bool == true && $0["cancelled"] as? Bool == true }),
              !stopRows.contains(where: { $0["event"] as? String == "error" }) else {
            throw Failure(text: "Paused short backseek did not actually cancel the zero-PCM pair")
        }
        edgeReceipts.append(["kind": "short-80-samples-held-eof-backseek-cancel", "expectedFailureObserved": false,
            "sourcePath": shortWAV.path, "sourceSamples": 80, "sourceRate": 16000, "pause": pause, "heldStart": heldStart,
            "before": first, "resume": resume, "completion": complete, "completedBackend": actual,
            "backseek": replay, "backseekPausedACK": replayPause, "backseekBackend": replayBackend, "backseekHeldStart": replayHeld,
            "cancelled": stopped, "cancelledBackend": stoppedActual, "snapshot": snapshot(), "semanticRecognitionClaim": false])
        wav = originalSource
    }
    private func sameDiagnosticBinding(_ left: [String: Any], _ right: [String: Any]) -> Bool {
        guard let a = left["binding"] as? [String: Any], let b = right["binding"] as? [String: Any],
              !a.isEmpty, !b.isEmpty else { return false }
        return NSDictionary(dictionary: a).isEqual(to: b)
    }
    private func settledZero() -> Bool {
        let host = player.liveASRSnapshot()
        return host.paused && player.flag("pause") && !host.seeking && host.settledSeekGeneration == host.seekGeneration
            && host.corePosition.map { $0.isFinite && $0 >= 0 && $0 <= 0.001 } == true
    }
    private func selectedWAV() -> Bool {
        guard let wav else { return false }
        let s = player.liveASRSnapshot()
        return s.selectedTrack?.isExternal == true && s.selectedTrack?.absoluteFFmpegIndex == 0
            && s.selectedTrack?.externalSource?.url.standardizedFileURL == wav.standardizedFileURL
            && s.selectedTrack?.externalSource?.fingerprint == LiveASRMPVHostState.fingerprint(wav)
            && s.binding == initialBinding && s.rebaseStartTime && s.currentDemuxer == "lavf"
    }
    private func settled(at target: Double) -> Bool {
        let s = player.liveASRSnapshot()
        return !s.seeking && s.settledSeekGeneration == s.seekGeneration && s.corePosition.map { abs($0-target) <= 0.15 } == true
    }
    private func externalProofValid() -> Bool {
        let actual = player.liveASR.diagnosticsSnapshot, proof = actual["sourceProof"] as? [String: Any] ?? [:]
        guard let fp = LiveASRMPVHostState.fingerprint(wav) else { return false }
        return proof["sourceKind"] as? String == "externalPCM_WAV" && (proof["ffIndex"] as? NSNumber)?.intValue == 0
            && (proof["rawOriginNumerator"] as? NSNumber)?.int64Value == 0 && proof["attachmentID"] is String
            && (proof["inode"] as? NSNumber)?.uint64Value == fp.inode && (proof["device"] as? NSNumber)?.uint64Value == fp.device
            && (proof["bytes"] as? NSNumber)?.uint64Value == fp.byteCount && (proof["mtimeNanoseconds"] as? NSNumber)?.int64Value == fp.modificationNanoseconds
    }
    private func strongClose() -> Bool {
        let close = player.liveASR.diagnosticsSnapshot["close"] as? [String: Any] ?? [:]
        return close["confirmed"] as? Bool == true && close["resourcesReleased"] as? Bool == true && close["ownedReaped"] as? Bool == true
            && close["forced"] as? Bool == false && (close["decoderExit"] as? NSNumber)?.intValue == 0 && (close["recognizerExit"] as? NSNumber)?.intValue == 0
            && close["decoderStdoutEOF"] as? Bool == true && close["recognizerStdoutEOF"] as? Bool == true
            && (close["decoderContexts"] as? NSNumber)?.intValue == 0 && (close["recognizerStreams"] as? NSNumber)?.intValue == 0 && (close["recognizers"] as? NSNumber)?.intValue == 0
    }
    private func validCues(_ cues: [LiveASRCue]) -> Bool {
        !cues.isEmpty && cues.contains { chinese($0.text) } && cues.allSatisfy {
            $0.start.seconds.isFinite && $0.end.seconds.isFinite && $0.start.seconds >= 0 && $0.end.seconds > $0.start.seconds && $0.end.seconds <= wavDuration + 0.15
        }
    }
    private func chinese(_ text: String) -> Bool { text.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) } }
    private func hasCurrentChinese() -> Bool {
        let actual = player.liveASR.diagnosticsSnapshot, ticket = actual["ticket"] as? [String: Any] ?? [:]
        return chinese(player.liveASR.partialText) && ((actual["grantedSamples"] as? NSNumber)?.uint64Value ?? 0) > 0
            && (ticket["epoch"] as? NSNumber) == (actual["epoch"] as? NSNumber) && (ticket["streamIndex"] as? NSNumber)?.intValue == 0
            && ((actual["binding"] as? [String: Any])?["loadToken"] as? String) == initialBinding?.loadToken.uuidString && selectedWAV()
    }
    private func hasOwnedChineseOverlay() -> Bool {
        player.liveASRHostState.overlayOwner?.uuidString == (player.liveASR.diagnosticsSnapshot["owner"] as? String)
            && player.liveASRHostState.overlayOwner != nil && chinese(player.liveASRHostState.overlayPayload ?? "")
    }
    private func actualBackend() async throws -> [String: Any] {
        guard let data = await player.liveASR.backendDiagnostics(), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure(text: "Actual backend diagnostics absent") }
        return object
    }
    private func controlSerial() async throws -> UInt64 {
        let object = try await actualBackend()
        guard let value = object["controlReceiptSerial"] as? NSNumber, value.uint64Value > 0 else { throw Failure(text: "Actual control serial absent") }
        return value.uint64Value
    }
    private func nativeControl(_ id: String, event: String, paused: Bool, after: UInt64? = nil) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while true {
            let object = try await actualBackend(), actual = player.liveASR.diagnosticsSnapshot
            let epoch = (actual["epoch"] as? NSNumber)?.uint64Value
            let receipts = object["controlReceipts"] as? [[String: Any]] ?? []
            let receipt = receipts.last { row in
                row["event"] as? String == event && (row["epoch"] as? NSNumber)?.uint64Value == epoch
                    && (row["serial"] as? NSNumber).map { $0.uint64Value > (after ?? 0) } == true
            }
            let host = player.liveASRSnapshot()
            if host.paused == paused, !host.seeking, host.settledSeekGeneration == host.seekGeneration,
               (object["processID"] as? String) == (actual["processID"] as? String),
               let epoch, epoch > 0, (object["actualEpoch"] as? NSNumber)?.uint64Value == epoch,
               (object["desiredEpoch"] as? NSNumber)?.uint64Value == epoch, object["decoderPaused"] as? Bool == paused,
               player.liveASR.state == (paused ? .paused : .following), let receipt {
                try check(id, true, ["actualDecoderACK": receipt, "minimumSerial": after as Any? ?? NSNull(), "actualBackend": object, "snapshot": snapshot()]); return
            }
            if player.liveASR.state == .failed || ProcessInfo.processInfo.systemUptime >= deadline { try check(id, false, ["actualBackend": object]) }
            sample(); try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    private func screenshot() async throws {
        let png = report.deletingPathExtension().appendingPathExtension("external-asr-window.png")
        _ = player.saveScreenshotAsync(to: png, mode: .window) { [weak self] value in self?.screenshotResult = value }
        try await wait("real-external-chinese-window-png", seconds: 5) {
            if case .success(let url) = self.screenshotResult { return url == png && FileManager.default.fileExists(atPath: png.path) }; return false
        }
    }
    private func wait(_ id: String, seconds: Double, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            if player.liveASR.state == .failed || ProcessInfo.processInfo.systemUptime >= deadline { try check(id, false, ["snapshot": snapshot()]) }
            sample(); try await Task.sleep(nanoseconds: 50_000_000)
        }
        try check(id, true, ["snapshot": snapshot()])
    }
    private func check(_ id: String, _ ok: Bool, _ detail: [String: Any] = [:]) throws {
        checks.append(["id": id, "passed": ok, "uptime": ProcessInfo.processInfo.systemUptime, "detail": detail])
        if !ok { throw Failure(text: id + ": " + (player.liveASR.error ?? "failed")) }
    }
    private func snapshot() -> [String: Any] {
        let s = player.liveASRSnapshot()
        return ["uptime": s.observedUptime, "corePosition": s.corePosition as Any? ?? NSNull(), "eof": s.eof, "paused": s.paused,
            "seekGeneration": s.seekGeneration, "settledSeekGeneration": s.settledSeekGeneration as Any? ?? NSNull(),
            "controllerActual": player.liveASR.diagnosticsSnapshot, "overlayOwner": player.liveASRHostState.overlayOwner?.uuidString ?? "",
            "overlayPayload": player.liveASRHostState.overlayPayload ?? "", "selectedWAV": selectedWAV(),
            "externalSource": s.selectedTrack?.externalSource?.url.path as Any? ?? NSNull(), "nativeTracks": player.jsonProperty("track-list") ?? NSNull()]
    }
    private func cueRows() -> [[String: Any]] { player.liveASR.finalCues.map {
        ["id": $0.id.uuidString, "epoch": $0.epoch, "streamGeneration": $0.streamGeneration, "startNumerator": $0.start.numerator,
         "startDenominator": $0.start.denominator, "endNumerator": $0.end.numerator, "endDenominator": $0.end.denominator, "text": $0.text]
    } }
    private func sample() { if samples.count < 2600 { samples.append(snapshot()) } }
    private func finish(_ ok: Bool, _ scope: String) {
        result = ["succeeded": ok, "asrChecks": checks, "asrSamples": samples, "backendActual": backend as Any? ?? NSNull(),
            "asrSnapshot": snapshot(), "finalCues": cueRows(), "externalDuration": wavDuration, "fixtureDuration": mainDuration,
            "asrScope": scope, "asrEdgeReceipts": edgeReceipts, "shortSourceSamples": 80, "shortSourceRate": 16000, "synthesizedPCM": false, "synthesizedNativeReceipts": false, "wordEndAlignmentVerified": false,
            "realUIAutomationVerified": false]
    }
}
