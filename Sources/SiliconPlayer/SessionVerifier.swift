import AppKit
import PlayerCore
import MediaPlayer

/// Explicitly enabled local integration verification. Inert in normal launches.
@MainActor
final class SessionVerifier {
    private let player: PlayerModel
    private let report: URL
    private var timer: Timer?
    private var phase = 0
    private var attempts = 0
    private var firstURL: URL?
    private var queueOpenRequest: UUID?
    private var queueRemoveAfterOpen = false
    private var checks: [String: Any] = [:]
    private var originalSettings: PlaybackSettings?
    private var playbackStarted: TimeInterval?
    private var maxFootprint: UInt64 = 0
    private var initialFrames = 0.0
    private var benchmarkSamples: [[String: Any]] = []
    private var switchCount = 0
    private var lastProgressAt = 0.0
    private var metadataWaitStarted: TimeInterval?
    private var userFilterIndex = 0
    private var userFilterResults: [[String: Any]] = []
    private var filterTransitionPhaseAt: TimeInterval?
    private var filterTransitionRequest: UUID?
    private var filterTransitionEpoch: UUID?
    private var filterTransitionCount: UInt64 = 0
    private var filterTransitionFrames: UInt64 = 0
    private var filterTransitionPosition = 0.0
    private var filterQuitSavedSHA = ""
    private var asyncScreenshotVerifier: AsyncScreenshotVerifier?
    private var playbackIntentVerifier: PlaybackIntentVerifier?
    private var webMediaVerifier: WebMediaVerifier?
    private var epgVerifier: EPGVerifier?
    private var diagnosticPrivacyVerifier: DiagnosticPrivacyVerifier?
    private var systemPiPVerifier: SystemPiPVerifier?
    private var nativeAudioQueueVerifier: NativeAudioQueueVerifier?
    private var liveASRVerifier: LiveASRVerifier?
    private var externalWAVASRVerifier: ExternalWAVASRVerifier?
    private var continuousLocalASRVerifier: ContinuousLocalASRVerifier?
    private var linearProviderASRVerifier: LinearProviderASRVerifier?
    private var metalAppSmokeVerifier: MetalAppSmokeVerifier?
    private var mediaProfileVerifier: MediaProfileVerifier?
    private let mediaProfileModes: Set<String> = ["media-preferences", "media-profile-backup", "media-profile-journal-prepare", "media-profile-recovery", "media-profile-malformed-startup", "media-profile-lifecycle"]
    private struct TSSeekStep {
        enum Action { case seek, open, bookmark }
        let label: String
        let action: Action
        let url: URL
        let target: Double
        let direction: String
        let expectedOffset: Double
    }
    private var tsSeekSteps: [TSSeekStep] = []
    private var tsSeekResults: [[String: Any]] = []
    private var tsSeekIndex = 0
    private var tsSeekStarted: TimeInterval?
    private var tsSeekRunStarted = ProcessInfo.processInfo.systemUptime
    private var tsSeekFramesBefore: UInt64 = 0
    private var tsSeekOrigin = 0.0
    private var tsSeekStablePosition: Double?
    private var tsSeekStableSamples = 0
    private var tsSeekObservedSeeking = false
    private var hasVideo: Bool { player.tracks.contains { $0.type == "video" } }
    private let mode = ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_MODE"] ?? "controls"
    private var screenshot: URL { report.deletingPathExtension().appendingPathExtension("png") }
    init(player: PlayerModel, report: URL) {
        self.player = player; self.report = report; firstURL = player.ordinaryMediaOpen.busy ? nil : player.playlist.currentItem?.url
        timer = Timer.scheduledTimer(withTimeInterval: NativeAudioQueueVerifier.modes.contains(mode) || LiveASRVerifier.modes.contains(mode) || ExternalWAVASRVerifier.modes.contains(mode) || ContinuousLocalASRVerifier.modes.contains(mode) || LinearProviderASRVerifier.modes.contains(mode) || MetalAppSmokeVerifier.modes.contains(mode) || mediaProfileModes.contains(mode) || ["ts-seek", "playback-intent", "web-media", "web-quit-hook", "web-quit-resolver", "web-public", "epg", "epg-quit-load", "epg-quit-logo", "diagnostic-privacy", "system-pip", "system-pip-race", "system-pip-quit-enter", "system-pip-quit-active", "filter-transition-quit"].contains(mode) ? 0.05 : 1.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    private func tick() {
        if firstURL == nil, !player.ordinaryMediaOpen.busy, player.loaded { firstURL = player.currentURL }
        attempts += 1
        if MetalAppSmokeVerifier.modes.contains(mode) {
            if metalAppSmokeVerifier == nil { metalAppSmokeVerifier = MetalAppSmokeVerifier(player: player, report: report, mode: mode) }
            if let values = metalAppSmokeVerifier?.tick() { finish(extra: values) }
            return
        }
        if LinearProviderASRVerifier.modes.contains(mode) {
            if linearProviderASRVerifier == nil { linearProviderASRVerifier = LinearProviderASRVerifier(player:player,report:report,mode:mode) }
            if let values=linearProviderASRVerifier?.tick(){finish(extra:values)}
            return
        }
        if ContinuousLocalASRVerifier.modes.contains(mode) {
            if continuousLocalASRVerifier == nil { continuousLocalASRVerifier = ContinuousLocalASRVerifier(player: player, report: report, mode: mode) }
            if let values = continuousLocalASRVerifier?.tick() { finish(extra: values) }
            return
        }
        if ExternalWAVASRVerifier.modes.contains(mode) {
            if externalWAVASRVerifier == nil { externalWAVASRVerifier = ExternalWAVASRVerifier(player: player, report: report, mode: mode) }
            if let values = externalWAVASRVerifier?.tick() { finish(extra: values) }
            return
        }
        if LiveASRVerifier.modes.contains(mode) {
            if liveASRVerifier == nil { liveASRVerifier = LiveASRVerifier(player: player, report: report, mode: mode) }
            if let values = liveASRVerifier?.tick() { finish(extra: values) }
            return
        }
        if NativeAudioQueueVerifier.modes.contains(mode) {
            if nativeAudioQueueVerifier == nil { nativeAudioQueueVerifier = NativeAudioQueueVerifier(player: player, report: report, mode: mode) }
            if let values = nativeAudioQueueVerifier?.tick() { finish(extra: values) }
            return
        }
        if mediaProfileModes.contains(mode) {
            if mediaProfileVerifier == nil { mediaProfileVerifier = MediaProfileVerifier(player: player, report: report, mode: mode) }
            if let values = mediaProfileVerifier?.tick() { finish(extra: values) }
            return
        }
        if ["system-pip", "system-pip-race", "system-pip-quit-enter", "system-pip-quit-active"].contains(mode) {
            if systemPiPVerifier == nil {
                systemPiPVerifier = SystemPiPVerifier(player: player, report: report, mode: mode,
                    finishImmediately: { [weak self] values in self?.finish(extra: values) })
            }
            if let values = systemPiPVerifier?.tick() { finish(extra: values) }
            return
        }
        if mode == "diagnostic-privacy" {
            if diagnosticPrivacyVerifier == nil { diagnosticPrivacyVerifier = DiagnosticPrivacyVerifier(player: player, report: report) }
            if let values = diagnosticPrivacyVerifier?.tick() { finish(extra: values) }
            return
        }
        if ["epg", "epg-quit-load", "epg-quit-logo"].contains(mode) {
            if epgVerifier == nil { epgVerifier = EPGVerifier(player: player, report: report, mode: mode) }
            if let values = epgVerifier?.tick() { finish(extra: values) }
            return
        }
        if ["web-media", "web-quit-hook", "web-quit-resolver", "web-public"].contains(mode) {
            if webMediaVerifier == nil { webMediaVerifier = WebMediaVerifier(player: player, report: report) }
            if let values = webMediaVerifier?.tick() { finish(extra: values) }
            return
        }
        if mode == "playback-intent" {
            if playbackIntentVerifier == nil { playbackIntentVerifier = PlaybackIntentVerifier(player: player, report: report) }
            if let values = playbackIntentVerifier?.tick() { finish(extra: values) }
            return
        }
        if mode == "async-screenshots" {
            if asyncScreenshotVerifier == nil { asyncScreenshotVerifier = AsyncScreenshotVerifier(player: player, report: report) }
            if let values = asyncScreenshotVerifier?.tick() { finish(extra: values) }
            return
        }
        if mode == "ts-seek" { verifyTSSeek(); return }
        if mode == "persistence-write" || mode == "persistence-read" || mode == "corrupt-profile" { verifyPersistence(); return }
        if mode == "failure-recovery" { verifyRecovery(); return }
        if mode == "navigation", phase >= 6 { verifyNavigation(); return }
        if mode == "screenshots", phase >= 2 { verifyScreenshots(); return }
        if mode == "queue-batch", phase >= 3 { verifyQueueBatch(); return }
        if mode == "frame-navigation", phase >= 4 { verifyFrameNavigation(); return }
        if mode == "filter-transition" { verifyFilterTransition(); return }
        if mode == "filter-transition-quit" { verifyFilterTransitionQuit(); return }
        guard player.loaded else {
            if attempts > 25 || player.error != nil { finish(extra: ["failure": player.error ?? "load timeout"]) }
            return
        }
        if mode == "advanced" { verifyAdvanced(); return }
        if mode == "processing" { verifyProcessing(); return }
        if mode == "benchmark" { verifyBenchmark(); return }
        if mode == "switch-stress" { verifySwitchStress(); return }
        if mode == "multi-track" { verifyMultiTrack(); return }
        if mode == "screenshots" { verifyScreenshots(); return }
        if mode == "user-filters" { verifyUserFilters(); return }
        if mode == "queue-batch" { verifyQueueBatch(); return }
        if mode == "frame-navigation" { verifyFrameNavigation(); return }
        if mode == "system" { verifySystem(); return }
        if mode == "navigation" { verifyNavigation(); return }
        if mode == "shutdown-recording" {
            if phase == 0, let source = player.currentURL {
                MediaTools.shared.recordStream(source: source, output: report.deletingPathExtension().appendingPathExtension("mkv")); phase = 1
            } else { finish(extra: ["recordingAtExit": MediaTools.shared.isRecording]) }
            return
        }
        if mode == "playlist" {
            switch phase {
            case 0: player.seek(max(0, player.duration - 0.4)); player.setSpeed(4); player.set("pause", "no"); phase = 1
            default:
                if player.playlist.currentIndex == 1 { player.set("pause", "yes"); finish(extra: ["advancedToNext": true]) }
                else if attempts > 10 { finish(extra: ["advancedToNext": false]) }
            }
            return
        }
        if mode == "rapid", phase == 0, let firstURL {
            player.open([URL(fileURLWithPath: "/tmp/siliconplayer-missing-media.mp4")])
            player.open([firstURL]); phase = 1; return
        }
        switch phase {
        case 0:
            player.set("pause", "yes")
            if mode == "chapters" { player.goToChapter(1) }
        case 1:
            if mode == "chapters" {
                checks["chapterSeekPosition"] = player.position
                checks["chapterTitles"] = player.chapters.map(\.title)
                checks["chapterID"] = player.chapterID
            }
            player.set("pause", "yes")
            player.seek(min(2, player.duration / 2))
            player.setSpeed(1.5); player.setVolume(43)
            player.setSubtitleDelay(0.3); player.setAudioDelay(-0.2)
            if let subtitle = ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_SUBTITLE"] {
                player.addSubtitle(URL(fileURLWithPath: subtitle))
            }
        case 2:
            if hasVideo { player.command(["screenshot-to-file", screenshot.path, "subtitles"]) }
            player.cycleAB()
            player.seek(3)
        case 3:
            player.cycleAB()
            checks["abStart"] = player.number("ab-loop-a")
            checks["abEnd"] = player.number("ab-loop-b")
            player.cycleAB()
            checks["abCleared"] = player.string("ab-loop-a") == "no" && player.string("ab-loop-b") == "no"
            player.seek(3)
            if hasVideo { player.frameStep() }
        default:
            if player.hasPendingFrameSteps { if attempts > 30 { finish(extra: ["failure": "frame-step completion timeout"]) }; return }
            finish(extra: [:]); return
        }
        phase += 1
    }
    /// Uses the real render-queue counter and settled mpv properties. The fast
    /// verifier poll changes no production polling or playback behavior.
    private func verifyTSSeek() {
        let now = ProcessInfo.processInfo.systemUptime
        func end(_ failure: String? = nil) {
            checks["tsSeekResults"] = tsSeekResults
            checks["tsSeekPlannedSteps"] = tsSeekSteps.count
            checks["tsSeekToleranceSeconds"] = 0.06
            checks["tsSeekScope"] = "Seekable local MPEG-2 TS fixtures; network TS, long GOP and discontinuous timestamps are not certified"
            checks["tsSeekPassed"] = failure == nil && tsSeekIndex == tsSeekSteps.count && !tsSeekSteps.isEmpty
            finish(extra: failure.map { ["failure": $0] } ?? [:])
        }
        guard now - tsSeekRunStarted <= 120 else { end("TS seek verification exceeded 120 seconds"); return }
        if let error = player.error { end(error); return }
        if tsSeekSteps.isEmpty {
            guard player.loaded else {
                if now - tsSeekRunStarted > 20 { end("Initial TS load timed out") }
                return
            }
            guard let source = firstURL, source.isFileURL,
                  let path = ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_SECOND"], path.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: path) else {
                end("TS seek requires local TS and an existing absolute MP4 control path"); return
            }
            originalSettings = player.settings
            player.settings = PlaybackSettings(); player.settings.autoplay = false
            player.applySettings(); player.set("pause", "yes"); player.setSpeed(1)
            player.setAudioDelay(0); player.setSubtitleDelay(0)
            player.set("loop-file", "no"); player.set("ab-loop-a", "no"); player.set("ab-loop-b", "no")
            guard player.flag("seekable"), player.duration > 23.85,
                  player.string("file-format").split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "mpegts" }),
                  (player.jsonProperty("vf") as? [Any])?.isEmpty == true else {
                end("TS fixture must be seekable MPEG-TS, at least 24 seconds, and unfiltered"); return
            }
            let control = URL(fileURLWithPath: path)
            let targets = [0.1, 1.9, 2.0, 2.37, 3.0, 7.37, 23.5]
            func seek(_ label: String, _ target: Double, _ direction: String = "auxiliary") {
                tsSeekSteps.append(TSSeekStep(label: label, action: .seek, url: source, target: target, direction: direction, expectedOffset: 0.5))
            }
            func open(_ label: String, _ url: URL, _ target: Double, _ offset: Double) {
                tsSeekSteps.append(TSSeekStep(label: label, action: .open, url: url, target: target, direction: "load", expectedOffset: offset))
            }
            seek("forward-anchor", 0)
            for target in targets { seek("forward-\(target)", target, "forward") }
            seek("backward-anchor", 23.85)
            for target in targets.reversed() { seek("backward-\(target)", target, "backward") }
            open("switch-to-mp4", control, 0, 0)
            open("return-to-ts", source, 0, 0.5)
            seek("seek-after-return", 2.37)
            seek("resume-origin", 7.37)
            open("resume-switch-to-mp4", control, 0, 0)
            open("history-resume", source, 7.37, 0.5)
            tsSeekSteps.append(TSSeekStep(label: "bookmark-after-resume", action: .bookmark, url: source, target: 2.37, direction: "load", expectedOffset: 0.5))
            checks["tsSeekSource"] = source.path
            checks["tsSeekControl"] = control.path
            checks["tsSeekInitialFormat"] = player.string("file-format")
            checks["tsSeekInitialSeekable"] = player.flag("seekable")
            checks["tsSeekInitialLocal"] = source.isFileURL
        }
        guard tsSeekIndex < tsSeekSteps.count else {
            player.command(["screenshot-to-file", screenshot.path, "video"])
            end(); return
        }
        let step = tsSeekSteps[tsSeekIndex]
        if tsSeekStarted == nil {
            // Wait for the production model's position before it records history
            // in open(). The assertions still use unthrottled engine time-pos.
            guard abs(player.position - player.number("time-pos")) < 0.005 else { return }
            tsSeekStarted = now; tsSeekFramesBefore = player.renderProgress.frames
            tsSeekOrigin = player.number("time-pos")
            tsSeekStablePosition = nil; tsSeekStableSamples = 0; tsSeekObservedSeeking = false
            switch step.action {
            case .seek: player.seek(step.target, remember: false)
            case .open: player.open([step.url])
            case .bookmark: player.openBookmark(PlaybackBookmark(url: step.url, position: step.target, title: "TS exact seek verification"))
            }
            return
        }
        guard let started = tsSeekStarted else { return }
        let elapsed = now - started
        let seeking = player.flag("seeking")
        tsSeekObservedSeeking = tsSeekObservedSeeking || seeking
        let frames = player.renderProgress.frames
        let actual = player.number("time-pos")
        let enginePath = player.string("path")
        let sameFile = URL(fileURLWithPath: enginePath).standardizedFileURL == step.url.standardizedFileURL
        // A queued seek can initially expose its requested timestamp. Require a
        // new rendered frame, seeking=no, and three stable samples after 150ms.
        let settled = player.loaded && sameFile && !seeking && frames > tsSeekFramesBefore && elapsed >= 0.15
        if settled {
            if let previous = tsSeekStablePosition, abs(previous - actual) < 0.0001 { tsSeekStableSamples += 1 }
            else { tsSeekStablePosition = actual; tsSeekStableSamples = 1 }
        } else { tsSeekStablePosition = nil; tsSeekStableSamples = 0 }
        guard tsSeekStableSamples >= 3 || elapsed > 10 else { return }
        let rawOffset = player.string("hr-seek-demuxer-offset")
        let localOffset = player.string("file-local-options/hr-seek-demuxer-offset")
        let format = player.string("file-format")
        let isTS = format.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "mpegts" }
        let directionMatches = step.direction == "forward" ? tsSeekOrigin < step.target : step.direction == "backward" ? tsSeekOrigin > step.target : true
        let passed = settled && tsSeekStableSamples >= 3 && abs(actual - step.target) <= 0.06 &&
            Double(rawOffset).map { abs($0 - step.expectedOffset) < 0.00001 } == true &&
            Double(localOffset).map { abs($0 - step.expectedOffset) < 0.00001 } == true &&
            player.flag("seekable") && step.url.isFileURL && isTS == (step.expectedOffset > 0) &&
            player.flag("pause") && abs(player.number("speed") - 1) < 0.00001 &&
            abs(player.number("audio-delay")) < 0.00001 && abs(player.number("sub-delay")) < 0.00001 && directionMatches
        tsSeekResults.append(["label": step.label, "direction": step.direction, "target": step.target,
            "origin": tsSeekOrigin, "actual": actual, "absoluteErrorSeconds": abs(actual - step.target),
            "latencySeconds": elapsed, "path": enginePath, "local": step.url.isFileURL,
            "seekable": player.flag("seekable"), "fileFormat": format,
            "offsetReadback": rawOffset, "fileLocalOffsetReadback": localOffset, "expectedOffset": step.expectedOffset,
            "seeking": seeking, "observedSeeking": tsSeekObservedSeeking,
            "renderFramesBefore": tsSeekFramesBefore, "renderFramesAfter": frames,
            "stableSamples": tsSeekStableSamples, "directionMatches": directionMatches, "passed": passed])
        guard passed else { end("TS step failed: \(step.label), target \(step.target), actual \(actual), offset \(rawOffset), rendered \(frames > tsSeekFramesBefore)"); return }
        if step.label == "resume-origin" {
            guard abs(player.position - actual) < 0.005 else { end("History source position was not published"); return }
            player.saveHistory(); player.history.flush()
            checks["tsSeekHistorySavedPosition"] = player.history.resumePosition(for: step.url) ?? -1
            checks["tsSeekHistorySaved"] = player.history.lastError == nil && player.history.resumePosition(for: step.url).map { abs($0 - actual) < 0.005 } == true
        }
        if step.label == "bookmark-after-resume" { checks["tsSeekBookmarkPendingCleared"] = player.pendingBookmarkPosition == nil && player.pendingBookmarkURL == nil }
        tsSeekIndex += 1; tsSeekStarted = nil
    }
    private func verifyFrameNavigation() {
        if player.hasPendingFrameSteps { if attempts > 30 { finish(extra: ["failure": "frame navigation timed out"]) }; return }
        switch phase {
        case 0:
            player.set("pause", "yes"); player.seek(7)
            player.frameStep(); player.frameStep()
        case 1:
            checks["forwardTwoAfterSeek"] = player.number("time-pos")
            player.seek(2); player.frameStep(backward: true)
        case 2:
            checks["reverseAfterSeek"] = player.number("time-pos")
            player.seek(4); player.frameStep(); player.seek(6)
        case 3:
            checks["newSeekCancelsQueuedStep"] = abs(player.number("time-pos") - 6) < 0.02 && !player.hasPendingFrameSteps
            player.frameStep(); player.stopPlayback()
        default:
            checks["stopCancelsQueuedStep"] = !player.loaded && !player.hasPendingFrameSteps && player.frameStepRequests.isEmpty
            finish(extra: [:]); return
        }
        phase += 1
    }

    private func verifyQueueBatch() {
        if let request = queueOpenRequest {
            guard let result = player.ordinaryMediaOpen.completion(for: request) else {
                if attempts > 25 { finish(extra: ["failure": "queue-batch actual open commit timeout"]) }
                return
            }
            guard result == .committed else { finish(extra: ["failure": "queue-batch actual open failed: \(result)"]); return }
            queueOpenRequest = nil
            if queueRemoveAfterOpen {
                queueRemoveAfterOpen = false
                player.removePlaylistItems(Set(player.playlist.items.prefix(2).map(\.id)))
                return
            }
        }
        switch phase {
        case 0:
            player.set("pause", "yes"); player.seek(2)
            checks["originalID"] = player.playlist.currentItem?.id.uuidString ?? ""
            checks["originalEntryID"] = player.string("playlist/0/id")
            let folder = firstURL?.deletingLastPathComponent() ?? report.deletingLastPathComponent()
            queueOpenRequest = player.open([folder.appendingPathComponent("中文 测试 HEVC.mp4"), folder.appendingPathComponent("中文 测试 MKV.mkv")], append: true)
            guard queueOpenRequest != nil else { finish(extra: ["failure": "queue-batch open rejected"]); return }
        case 1:
            let items = player.playlist.items
            guard items.count == 3 else { finish(extra: ["failure": "queue-batch fixture count"]); return }
            let current = items[0].id
            checks["batchMoveAccepted"] = player.movePlaylistItems(Set([items[1].id, items[2].id]), to: .before(current))
            checks["movePreservesCurrent"] = player.playlist.currentItem?.id == current && player.loaded && player.position >= 1.9 && player.string("playlist/0/id") == checks["originalEntryID"] as? String
            player.removePlaylistItems(Set([items[1].id, items[2].id]))
            checks["nonCurrentBatchRemovalPreservesPlayback"] = player.playlist.items.count == 1 && player.playlist.currentItem?.id == current && player.loaded && player.string("playlist/0/id") == checks["originalEntryID"] as? String
        case 2:
            let folder = firstURL?.deletingLastPathComponent() ?? report.deletingLastPathComponent()
            queueOpenRequest = player.open([folder.appendingPathComponent("中文 测试 HEVC.mp4"), folder.appendingPathComponent("中文 测试 MKV.mkv")], append: true)
            guard queueOpenRequest != nil else { finish(extra: ["failure": "queue-batch open rejected"]); return }
            queueRemoveAfterOpen = true
        case 3:
            guard player.loaded else { if attempts > 25 { finish(extra: ["failure": "batch successor timed out"]) }; return }
            checks["currentBatchRemovalLoadsSurvivingSuccessor"] = player.playlist.items.count == 1 && player.playlist.currentItem?.title == "中文 测试 MKV.mkv" && player.error == nil && player.string("playlist/0/id") != checks["originalEntryID"] as? String
            player.set("pause", "yes")
        case 4:
            player.removePlaylistItems(Set(player.playlist.items.map(\.id)))
        default:
            checks["removeAllStopsAndClears"] = player.playlist.items.isEmpty && !player.loaded && player.flag("idle-active")
            if let data = try? Data(contentsOf: PlayerModel.supportDirectory.appendingPathComponent("queue.json")),
               let document = try? JSONDecoder().decode(PlaybackQueueDocument.self, from: data) {
                checks["emptyQueuePersisted"] = document.items.isEmpty && document.selectedIndex == nil
                checks["persistedQueueBytes"] = data.count
            }
            finish(extra: [:]); return
        }
        phase += 1
    }

    private func verifyUserFilters() {
        let controller = player.userVideoFilters
        let folder = report.deletingPathExtension().appendingPathExtension("images")
        func capture(_ label: String) {
            let output = folder.appendingPathComponent("\(label).png")
            let saved = player.saveScreenshot(to: output, mode: .video)
            userFilterResults.append(["name": label, "saved": saved != nil, "path": output.path,
                "width": player.number("dwidth"), "height": player.number("dheight"),
                "output": player.jsonProperty("video-out-params") ?? [:], "vf": player.jsonProperty("vf") ?? [],
                "graph": (try? controller.chain.lavfiFragments().joined(separator: ",")) ?? "", "decoder": player.string("hwdec-current")])
        }
        guard attempts <= 95 else { finish(extra: ["failure": "filter acceptance timeout"]); return }
        switch phase {
        case 0:
            originalSettings = player.settings; player.set("pause", "yes"); player.seek(2)
            phase = 1
        case 1:
            if userFilterIndex < UserVideoFilterKind.allCases.count {
                let filter = UserVideoFilter(kind: UserVideoFilterKind.allCases[userFilterIndex])
                guard controller.commit(UserVideoFilterChain(filters: [filter])) else { finish(extra: ["failure": controller.errorText ?? "filter commit rejected"]); return }
                phase = 2
            } else {
                var crop = UserVideoFilter(kind: .crop); crop.values["width"] = 0.5; crop.values["height"] = 1
                _ = controller.commit(UserVideoFilterChain(filters: [crop, UserVideoFilter(kind: .transpose)])); phase = 3
            }
        case 2:
            if controller.isApplying { return }
            guard controller.errorText == nil else { finish(extra: ["failure": controller.errorText!]); return }
            capture(UserVideoFilterKind.allCases[userFilterIndex].rawValue)
            userFilterIndex += 1; phase = 1
        case 3:
            if controller.isApplying { return }
            guard controller.errorText == nil else { finish(extra: ["failure": controller.errorText!]); return }
            capture("crop-then-transpose")
            if let id = controller.chain.filters.last?.id { controller.move(id: id, to: 0) }; phase = 4
        case 4:
            if controller.isApplying { return }
            capture("transpose-then-crop")
            if let id = controller.chain.filters.first?.id { controller.setEnabled(id: id, enabled: false) }; phase = 5
        case 5:
            if controller.isApplying { return }
            capture("transpose-disabled")
            let url = PlayerModel.supportDirectory.appendingPathComponent("user-video-filters.json")
            let before = try? Data(contentsOf: url)
            var bad = controller.chain
            bad.filters[0].values["direction"] = 99
            checks["invalidCandidatePreservesChainAndDisk"] = !controller.commit(bad) && (try? Data(contentsOf: url)) == before
            checks["storeReloadMatches"] = (try? UserVideoFilterStore(fileURL: url).load()) == controller.chain
            controller.clearError(); controller.removeAll(); phase = 6
        default:
            if controller.isApplying { return }
            checks["filters"] = userFilterResults
            checks["clearedChainAndDecoder"] = controller.chain.filters.isEmpty && player.string("hwdec-current") == "videotoolbox" && (player.jsonProperty("vf") as? [Any])?.isEmpty == true
            checks["controllerError"] = controller.errorText ?? ""
            finish(extra: [:]); return
        }
    }

    private func verifyScreenshots() {
        let folder = report.deletingPathExtension().appendingPathExtension("images")
        switch phase {
        case 0:
            originalSettings = player.settings
            player.set("pause", "yes"); player.seek(2)
            if let path = ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_SUBTITLE"] { player.addSubtitle(URL(fileURLWithPath: path)) }
        case 1:
            var files: [String: String] = [:]
            for mode in ScreenshotMode.allCases {
                let target = folder.appendingPathComponent("\(mode.rawValue).png")
                if player.saveScreenshot(to: target, mode: mode) != nil { files[mode.rawValue] = target.path }
            }
            for format in ["jpg", "webp"] {
                let target = folder.appendingPathComponent("encoded.\(format)")
                if player.saveScreenshot(to: target) != nil { files[format] = target.path }
            }
            checks["files"] = files
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("SiliconPlayer-verify-\(UUID().uuidString)"))
            checks["copiedPNGAndTIFF"] = player.copyScreenshot(pasteboard: pasteboard) && pasteboard.data(forType: .png)?.isEmpty == false && pasteboard.data(forType: .tiff)?.isEmpty == false
            let sentinel = Data("keep old screenshot".utf8)
            let protected = folder.appendingPathComponent("protected.png")
            try? sentinel.write(to: protected)
            checks["existingDestinationPreserved"] = player.saveScreenshot(to: protected) == nil && (try? Data(contentsOf: protected)) == sentinel
            player.error = nil
            checks["approvedReplacementWorks"] = player.saveScreenshot(to: protected, allowReplacement: true) != nil && (try? Data(contentsOf: protected)) != sentinel
            let blocker = folder.appendingPathComponent("not-a-directory")
            try? sentinel.write(to: blocker)
            checks["writeFailurePreservesParent"] = player.saveScreenshot(to: blocker.appendingPathComponent("image.png")) == nil && (try? Data(contentsOf: blocker)) == sentinel
            player.error = nil
            player.settings.screenshot.directory = folder.appendingPathComponent("自定义 截图").path
            player.settings.screenshot.mode = .video; player.settings.screenshotFormat = "png"
            player.applySettings(); player.persistSettings()
            let saved = player.saveScreenshot()
            checks["customDirectoryWorks"] = saved?.deletingLastPathComponent() == player.selectedScreenshotDirectory
            checks["settingsRoundTrip"] = (try? JSONDecoder().decode(PlaybackSettings.self, from: Data(contentsOf: PlayerModel.preferenceURL))) == player.settings
            player.stopPlayback()
            let previousClipboard = pasteboard.data(forType: .png)
            checks["stoppedCapturePreservesClipboard"] = !player.copyScreenshot(pasteboard: pasteboard) && pasteboard.data(forType: .png) == previousClipboard
            pasteboard.releaseGlobally()
        default:
            finish(extra: [:]); return
        }
        phase += 1
    }

    private func verifyPersistence() {
        if mode == "persistence-write" {
            guard player.loaded else { if attempts > 25 { finish(extra: ["failure": "persistence media load timed out"]) }; return }
            if phase == 0 {
                player.settings.theme = "light"; player.settings.cacheMB = 256; player.settings.subtitleSize = 42
                player.settings.equalizer = EqualizerPreset.voice.gains; player.settings.equalizerEnabled = true
                player.applySettings(); player.set("pause", "yes"); player.seek(8)
                phase = 1; return
            }
            player.addBookmark(); player.toggleFavorite()
            _ = player.library.savePlaylist(name: "完整测试课程", urls: player.playlist.items.map(\.url))
            player.saveHistory(); player.history.flush(); player.library.flush(); player.persistSettings(); player.persistQueue()
            finish(extra: ["persistenceWritten": true, "savedPosition": player.position]); return
        }
        if phase == 0 {
            if mode == "corrupt-profile" {
                checks["corruptSettingsDefaulted"] = player.settings == PlaybackSettings()
                checks["corruptQueueEmpty"] = player.playlist.items.isEmpty
                checks["corruptLibraryReported"] = player.library.lastError != nil && player.library.bookmarks.isEmpty
                checks["corruptHistoryReported"] = player.history.lastError != nil
                if let path = ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_SECOND"] { player.open([URL(fileURLWithPath: path)]) }
            } else {
                checks["queueRestoredWithoutAutoplay"] = !player.loaded && !player.isLoading && player.playlist.items.count == 2
                checks["preferencesRestored"] = player.settings.theme == "light" && player.settings.cacheMB == 256 && player.settings.subtitleSize == 42 && player.settings.equalizerEnabled && player.settings.equalizer == EqualizerPreset.voice.gains
                checks["libraryRestored"] = player.library.bookmarks.count == 1 && player.library.favorites.count == 1 && player.library.savedPlaylists.first?.name == "完整测试课程" && abs((player.library.bookmarks.first?.position ?? 0) - 8) < 0.1
                player.playSelected()
            }
            phase = 1; return
        }
        guard player.loaded else { if attempts > 25 { finish(extra: ["failure": "restored profile could not play"]) }; return }
        checks["resumePosition"] = player.position
        checks["restoredEqualizerFilters"] = player.jsonProperty("af") ?? []
        player.set("pause", "yes"); finish(extra: ["profilePlayable": true])
    }
    private func verifyRecovery() {
        guard let good = ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_SECOND"] else { finish(extra: ["failure": "missing recovery fixture"]); return }
        let goodURL = URL(fileURLWithPath: good)
        switch phase {
        case 0:
            guard player.error != nil else { if attempts > 20 { finish(extra: ["failure": "missing-file error not reported"]) }; return }
            checks["missingFileRejected"] = !player.loaded && !player.isLoading
            player.open([goodURL]); phase = 1
        case 1:
            guard player.loaded else { if attempts > 25 { finish(extra: ["failure": "first recovery timed out"]) }; return }
            checks["recoveredFromMissing"] = player.error == nil
            if let bad = ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_CORRUPT"] {
                player.open([URL(fileURLWithPath: bad)]); phase = 2
            } else { finish(extra: ["failure": "missing corrupt fixture"]) }
        case 2:
            guard player.error != nil else { if attempts > 30 { finish(extra: ["failure": "corrupt error not reported"]) }; return }
            checks["corruptFileRejected"] = !player.loaded && !player.isLoading
            player.open([goodURL]); player.stopPlayback(); phase = 3
        case 3:
            checks["stopDuringLoad"] = !player.loaded && !player.isLoading && player.flag("idle-active")
            player.open([goodURL]); phase = 4
        default:
            guard player.loaded else { if attempts > 35 { finish(extra: ["failure": "second recovery timed out"]) }; return }
            player.seek(3); player.set("pause", "yes")
            checks["recoveredFromCorrupt"] = player.error == nil
            finish(extra: [:])
        }
    }
    private func verifySwitchStress() {
        guard let firstURL, let second = ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_SECOND"] else { finish(extra: ["failure": "missing switch fixtures"]); return }
        if switchCount >= 30 {
            checks["switchCount"] = switchCount; checks["finalStateConsistent"] = player.currentURL == firstURL && player.error == nil
            player.set("pause", "yes"); finish(extra: [:]); return
        }
        // Exercise pending loads and old-error isolation, then a real loaded seek.
        player.seek(min(1 + Double(switchCount % 3), max(1, player.duration - 1)))
        player.set("pause", switchCount.isMultiple(of: 2) ? "yes" : "no")
        let target = switchCount.isMultiple(of: 2) ? URL(fileURLWithPath: second) : firstURL
        player.open([URL(fileURLWithPath: "/tmp/siliconplayer-fulltest-missing.mp4")])
        player.open([target]); switchCount += 1
        maxFootprint = max(maxFootprint, physicalFootprint())
        checks["physicalFootprintBytes"] = maxFootprint
    }
    private func verifyMultiTrack() {
        switch phase {
        case 0:
            player.set("pause", "yes"); player.seek(3)
            checks["initialAudioIDs"] = player.tracks.filter { $0.type == "audio" }.map(\.id)
            checks["initialSubtitleIDs"] = player.tracks.filter { $0.type == "sub" }.map(\.id)
            if let audio = player.tracks.last(where: { $0.type == "audio" }) { player.selectAudio(audio.id) }
            if let subtitle = player.tracks.first(where: { $0.type == "sub" }) { player.selectSubtitle(subtitle.id) }
            if let secondary = player.tracks.last(where: { $0.type == "sub" }) { player.settings.secondarySubtitleID = secondary.id; player.applySettings() }
        case 1:
            checks["selectedAudioID"] = player.audioID; checks["selectedSubtitleID"] = player.subtitleID
            checks["secondarySubtitleID"] = player.string("secondary-sid")
            player.command(["screenshot-to-file", screenshot.path, "subtitles"])
            if let path = ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_SUBTITLE"] { player.addSubtitle(URL(fileURLWithPath: path)) }
        case 2:
            checks["externalSubtitleSelected"] = player.subtitleID
            checks["subtitleCountWithExternal"] = player.tracks.filter { $0.type == "sub" }.count
            player.settings.secondarySubtitleID = 0; player.applySettings()
            player.selectAudio(0); player.selectSubtitle(0)
        default:
            checks["audioDisabled"] = player.string("aid") == "no"
            checks["subtitleDisabled"] = player.string("sid") == "no" && player.string("secondary-sid") == "no"
            finish(extra: [:]); return
        }
        phase += 1
    }
    private func verifyNavigation() {
        switch phase {
        case 0:
            player.set("pause", "yes"); player.seek(2.2, remember: false)
        case 1:
            checks["beforeSeek"] = player.number("time-pos")
            player.seek(7.37)
        case 2:
            checks["afterSeek"] = player.number("time-pos")
            player.revertSeek()
        case 3:
            checks["afterUndo"] = player.number("time-pos")
            player.revertSeek()
        case 4:
            checks["afterRedo"] = player.number("time-pos")
            player.jumpKeyframe(-5)
        case 5:
            checks["keyframePosition"] = player.number("time-pos")
            player.command(["screenshot-to-file", screenshot.path, "video"])
            player.stopPlayback()
        case 6:
            checks["stopClearedState"] = !player.loaded && !player.isLoading && player.position == 0 && player.duration == 0 && player.tracks.isEmpty && player.seekReturnPosition == nil
            checks["stopClearedEngine"] = player.flag("idle-active") && (player.jsonProperty("track-list") as? [Any])?.isEmpty == true
            checks["stopReleasedSystem"] = player.sleepActivity == nil && MPNowPlayingInfoCenter.default().nowPlayingInfo == nil
            checks["stopPreservedQueue"] = player.playlist.items.count == 1
            player.togglePause()
        case 7:
            guard player.loaded else { if attempts > 25 { finish(extra: ["failure": "restart timed out"]) }; return }
            checks["restartedAfterStop"] = player.loaded
            player.set("pause", "yes"); player.seek(6)
        case 8:
            if let second = ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_SECOND"] { player.open([URL(fileURLWithPath: second)]) }
        default:
            guard player.loaded else { if attempts > 25 { finish(extra: ["failure": "second file timed out"]) }; return }
            checks["seekUndoClearedOnSwitch"] = player.seekReturnPosition == nil
            player.set("pause", "yes"); finish(extra: [:]); return
        }
        phase += 1
    }
    private func verifySystem() {
        switch phase {
        case 0:
            originalSettings = player.settings
            player.set("pause", "no"); player.sleepDeadline = Date().addingTimeInterval(0.3)
        case 1:
            checks["sleepTimerPaused"] = player.paused
        case 2:
            checks["sleepAssertionReleased"] = player.sleepActivity == nil
            player.toggleMiniMode(); player.settings.brightness = 1; player.applySettings()
        case 3:
            checks["miniMode"] = player.miniMode
            checks["miniFloating"] = player.playerWindow?.level == .floating
            checks["miniWidth"] = player.playerWindow?.frame.width ?? 0
            player.toggleMiniMode()
            if let firstURL, let second = ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_SECOND"] {
                player.openBookmark(PlaybackBookmark(url: firstURL, position: 8, title: "race-test"))
                player.open([URL(fileURLWithPath: second)])
                metadataWaitStarted = ProcessInfo.processInfo.systemUptime
            }
        default:
            // The production metadata refresh is throttled to one second and
            // can precede FILE_LOADED on the first poll after a rapid switch.
            // Wait for its asynchronous publication, with a real failure bound.
            let title = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String ?? ""
            let waited = ProcessInfo.processInfo.systemUptime - (metadataWaitStarted ?? ProcessInfo.processInfo.systemUptime)
            if title != player.playlist.currentItem?.title, waited < 3 { return }
            checks["metadataWaitSeconds"] = waited
            checks["bookmarkRacePosition"] = player.position
            checks["miniRestored"] = !player.miniMode
            checks["nowPlayingTitle"] = title
            player.set("pause", "yes"); finish(extra: [:]); return
        }
        phase += 1
    }
    private func verifyProcessing() {
        switch phase {
        case 0:
            originalSettings = player.settings
            player.settings = PlaybackSettings(); player.set("pause", "yes"); player.seek(2)
            player.settings.processing.stereoInput = "sbsl"; player.settings.processing.stereoOutput = "ml"
            player.settings.processing.pitchSemitones = 3; player.settings.processing.crossfeed = true
            player.settings.processing.swapChannels = true; player.settings.channelMode = "stereo"
            player.applySettings()
        case 1:
            checks["stereoWidth"] = player.number("video-out-params/w")
            checks["stereoHeight"] = player.number("video-out-params/h")
            checks["stereoFilters"] = player.jsonProperty("vf") ?? []
            checks["audioProcessingFilters"] = player.jsonProperty("af") ?? []
            player.command(["screenshot-to-file", report.deletingPathExtension().path + "-stereo.png", "video"])
            player.settings.processing.stereoInput = "off"; player.settings.processing.projection = "equirect"
            player.settings.processing.deband = true; player.settings.processing.scaler = "lanczos"
            player.applySettings(); player.seek(2)
        case 2:
            checks["projectionWidth"] = player.number("video-out-params/w")
            checks["projectionHeight"] = player.number("video-out-params/h")
            checks["deband"] = player.flag("deband"); checks["scaler"] = player.string("scale")
            player.command(["screenshot-to-file", report.deletingPathExtension().path + "-front.png", "video"])
            player.settings.processing.yaw = 90; player.applySettings(); player.seek(2)
        case 3:
            checks["projectionFilters"] = player.jsonProperty("vf") ?? []
            player.command(["screenshot-to-file", screenshot.path, "video"])
        default: finish(extra: [:]); return
        }
        phase += 1
    }
    private func verifyFilterTransition() {
        let now = ProcessInfo.processInfo.systemUptime
        func nextPhase() { phase += 1; filterTransitionPhaseAt = now }
        func ready(width: Int, height: Int) -> Bool {
            guard let request = filterTransitionRequest, let result = player.videoConfigurationResult else { return false }
            return result.requestID == request && result.epoch == player.videoConfigurationEpoch
                && result.executed && result.status >= 0 && player.pendingVideoConfiguration == nil
                && player.string("hwdec-current") == "videotoolbox-copy" && !player.flag("seeking")
                && player.renderProgress.frames > result.renderedBefore
                && Int(player.number("video-out-params/w")) == width && Int(player.number("video-out-params/h")) == height
        }
        func waitOrFail(_ label: String) {
            if now - (filterTransitionPhaseAt ?? now) >= 4 {
                checks[label] = false; finish(extra: ["failure": "filter transition timed out: \(label)"])
            }
        }
        switch phase {
        case 0:
            guard player.loaded else { if attempts > 25 { finish(extra: ["failure": "transition fixture load timeout"]) }; return }
            originalSettings = player.settings
            player.settings = PlaybackSettings(); player.applySettings()
            player.set("pause", "yes"); player.seek(2)
            player.settings.processing.stereoInput = "sbsl"; player.settings.processing.stereoOutput = "ml"
            player.applySettings()
            filterTransitionRequest = player.videoConfigurationRequestID
            checks["transitionImmediateQueued"] = player.pendingVideoConfiguration?.requestID == filterTransitionRequest
            nextPhase()
        case 1:
            guard ready(width: 320, height: 360) else { waitOrFail("transitionImmediateExecuted"); return }
            checks["transitionImmediateExecuted"] = true
            checks["transitionPauseAndTargetPreserved"] = player.flag("pause") && abs(player.number("time-pos") - 2) < 0.1
            player.command(["screenshot-to-file", report.deletingPathExtension().path + "-stereo.png", "video"])
            player.settings = PlaybackSettings(); player.applySettings()
            player.seek(3.4)
            player.settings.flipHorizontal = true; player.applySettings()
            let superseded = player.videoConfigurationRequestID
            filterTransitionCount = player.videoConfigurationApplyCount
            player.settings.flipHorizontal = false; player.settings.processing.projection = "equirect"
            player.settings.processing.yaw = 90; player.applySettings()
            filterTransitionRequest = player.videoConfigurationRequestID
            checks["transitionLatestReplaced"] = superseded != filterTransitionRequest
                && player.pendingVideoConfiguration?.requestID == filterTransitionRequest
            nextPhase()
        case 2:
            guard ready(width: 1280, height: 720) else { waitOrFail("transitionLatestAppliedOnce"); return }
            checks["transitionLatestAppliedOnce"] = player.videoConfigurationApplyCount == filterTransitionCount + 1
                && player.flag("pause") && abs(player.number("time-pos") - 3.4) < 0.1
            checks["transitionLatestGraph"] = player.jsonProperty("vf") ?? []
            player.command(["screenshot-to-file", report.deletingPathExtension().path + "-projection.png", "video"])
            player.settings = PlaybackSettings(); player.applySettings()
            player.seek(4.2); player.settings.flipHorizontal = true; player.applySettings()
            filterTransitionRequest = player.videoConfigurationRequestID
            filterTransitionEpoch = player.videoConfigurationEpoch
            let wasPending = player.pendingVideoConfiguration?.requestID == filterTransitionRequest
            player.stopPlayback(); player.settings = PlaybackSettings(); player.applySettings()
            checks["transitionStopCancelled"] = wasPending && player.pendingVideoConfiguration == nil
                && player.videoConfigurationEpoch != filterTransitionEpoch
                && player.videoConfigurationResult?.requestID != filterTransitionRequest
            nextPhase()
        case 3:
            checks["transitionStopStayedCleared"] = !player.loaded && !player.isLoading && player.flag("idle-active")
                && player.pendingVideoConfiguration == nil && player.string("hwdec") == "videotoolbox"
                && (player.jsonProperty("vf") as? [[String: Any]])?.isEmpty == true
            guard let firstURL else { finish(extra: ["failure": "missing transition source"]); return }
            player.open([firstURL]); nextPhase()
        case 4:
            guard player.loaded else { waitOrFail("transitionSameURLReloadCancelled"); return }
            player.set("pause", "yes"); player.seek(5.2)
            player.settings.flipHorizontal = true; player.applySettings()
            filterTransitionRequest = player.videoConfigurationRequestID
            filterTransitionEpoch = player.videoConfigurationEpoch
            let wasPending = player.pendingVideoConfiguration?.requestID == filterTransitionRequest
            player.settings = PlaybackSettings()
            guard let firstURL else { finish(extra: ["failure": "missing transition source"]); return }
            player.open([firstURL])
            checks["transitionSameURLReloadCancelled"] = wasPending && player.pendingVideoConfiguration == nil
                && player.videoConfigurationEpoch != filterTransitionEpoch
            nextPhase()
        case 5:
            guard player.loaded, player.string("hwdec-current") == "videotoolbox", !player.flag("seeking") else {
                waitOrFail("transitionReloadStayedDefault"); return
            }
            checks["transitionReloadStayedDefault"] = player.pendingVideoConfiguration == nil
                && player.videoConfigurationResult?.requestID != filterTransitionRequest
                && (player.jsonProperty("vf") as? [[String: Any]])?.isEmpty == true
            player.setSpeed(4); player.set("pause", "no"); player.seek(1)
            player.settings.processing.stereoInput = "sbsl"; player.settings.processing.stereoOutput = "ml"
            player.applySettings(); filterTransitionRequest = player.videoConfigurationRequestID
            filterTransitionFrames = player.renderProgress.frames; filterTransitionPosition = player.number("time-pos")
            nextPhase()
        case 6:
            guard ready(width: 320, height: 360), player.renderProgress.frames >= filterTransitionFrames + 24,
                  player.number("time-pos") >= max(1.25, filterTransitionPosition + 0.25) else {
                waitOrFail("transitionPlaying4xPreserved"); return
            }
            checks["transitionPlaying4xPreserved"] = !player.flag("pause") && player.number("speed") == 4
            checks["transitionFinalTime"] = player.number("time-pos")
            checks["transitionFinalRenderUpdates"] = player.renderProgress.frames - filterTransitionFrames
            checks["transitionRenderCounterScope"] = "render updates may include redraws; time/core/decoder/output checks are also required"
            player.set("pause", "yes"); player.setSpeed(1)
            player.command(["screenshot-to-file", screenshot.path, "video"])
            nextPhase()
        case 7:
            guard player.paused, player.speed == 1 else { waitOrFail("transitionFinalPaused"); return }
            finish(extra: [:])
        default: finish(extra: ["failure": "unexpected transition phase"])
        }
    }

    private func verifyFilterTransitionQuit() {
        let now = ProcessInfo.processInfo.systemUptime
        func nextPhase() { phase += 1; filterTransitionPhaseAt = now }
        func executed(_ decoder: String) -> Bool {
            guard let result = player.videoConfigurationResult, result.requestID == filterTransitionRequest else { return false }
            return result.epoch == player.videoConfigurationEpoch && result.executed && result.status >= 0
                && player.pendingVideoConfiguration == nil && player.string("hwdec-current") == decoder
                && player.renderProgress.frames > result.renderedBefore && !player.flag("seeking")
        }
        func failIfLate(_ label: String) {
            if now - (filterTransitionPhaseAt ?? now) > 5 { checks[label] = false; finish(extra: ["failure": "quit transition timed out: \(label)"]) }
        }
        func savedSHA() -> String { player.videoConfigurationTerminationSnapshot()["filterStoreSHA256"] as? String ?? "" }
        switch phase {
        case 0:
            guard player.loaded else { if attempts > 600 { finish(extra: ["failure": "quit fixture load timeout"]) }; return }
            guard !player.hasUsedWebPlayback else { finish(extra: ["failure": "quit case requires local non-web playback"]); return }
            player.settings = PlaybackSettings(); player.applySettings(); player.set("pause", "yes"); player.seek(2)
            player.settings.processing.stereoInput = "sbsl"; player.settings.processing.stereoOutput = "ml"
            player.applySettings(); filterTransitionRequest = player.videoConfigurationRequestID
            nextPhase()
        case 1:
            // Observe the first batch immediately at 50ms cadence, before its
            // internal delayed relative refresh necessarily finishes.
            guard let result = player.videoConfigurationResult, result.requestID == filterTransitionRequest,
                  result.executed, result.status >= 0 else { failIfLate("quitRefreshWindowQueued"); return }
            let refreshBefore = player.videoSeekBarrier
            filterTransitionCount = player.videoConfigurationApplyCount
            player.settings.processing.stereoInput = "off"; player.applySettings()
            filterTransitionRequest = player.videoConfigurationRequestID
            checks["quitRefreshWindowQueued"] = refreshBefore != nil && player.pendingVideoConfiguration?.requestID == filterTransitionRequest
                && player.videoConfigurationApplyCount == filterTransitionCount
            nextPhase()
        case 2:
            guard executed("videotoolbox") else { failIfLate("quitRefreshWindowExecuted"); return }
            checks["quitRefreshWindowExecuted"] = player.videoConfigurationApplyCount == filterTransitionCount + 1
                && player.flag("pause") && abs(player.number("time-pos") - 2) < 0.1
            _ = player.userVideoFilters.add(.horizontalFlip); nextPhase()
        case 3:
            guard !player.userVideoFilters.isApplying, player.userVideoFilters.chain.filters.count == 1,
                  player.string("hwdec-current") == "videotoolbox-copy", !player.flag("seeking") else {
                failIfLate("quitCandidateExecutedBeforeCancel"); return
            }
            filterQuitSavedSHA = savedSHA()
            let accepted = player.userVideoFilters.add(.verticalFlip) != nil
            checks["quitCandidateExecutedBeforeCancel"] = accepted && player.userVideoFilters.isApplying
                && player.videoConfigurationResult?.executed == true && player.videoConfigurationResult?.status == 0
                && player.pendingVideoConfiguration == nil && filterQuitSavedSHA.count == 64
            filterTransitionCount = player.videoConfigurationApplyCount
            let begin = player.beginVideoConfigurationTermination()
            let before = begin["before"] as? [String: Any] ?? [:]
            checks["quitReversibleBegin"] = before["candidateApplying"] as? Bool == true
                && player.videoConfigurationClosing && !player.userVideoFilters.isApplying && player.candidateVideoFilters == nil
            checks["quitClosedGateRejected"] = player.applyVideoFilterProperties(settings: player.settings, userFragments: []) < 0
                && player.videoConfigurationApplyCount == filterTransitionCount
            nextPhase()
        case 4:
            guard now - (filterTransitionPhaseAt ?? now) >= 0.6 else { return }
            checks["quitNoLateCommitOrApply"] = player.videoConfigurationClosing && player.pendingVideoConfiguration == nil
                && !player.userVideoFilters.isApplying && player.videoConfigurationApplyCount == filterTransitionCount
                && savedSHA() == filterQuitSavedSHA && player.userVideoFilters.chain.filters.count == 1
            checks["quitCancelReopenedAcceptance"] = player.resumeVideoConfigurationAfterCancelledTermination(previouslyAccepting: true) >= 0
                && !player.videoConfigurationClosing
            filterTransitionRequest = player.videoConfigurationRequestID; nextPhase()
        case 5:
            guard executed("videotoolbox-copy") else { failIfLate("quitSavedChainRuntimeRestored"); return }
            let rows = player.jsonProperty("vf") as? [[String: Any]]
            checks["quitSavedChainRuntimeRestored"] = rows?.count == 1
                && (rows?.first?["params"] as? [String: Any])?["graph"] as? String == "hflip"
                && savedSHA() == filterQuitSavedSHA && !player.userVideoFilters.isApplying
            player.command(["screenshot-to-file", screenshot.path, "video"])
            player.seek(3); player.settings.hardwareDecoder = "no"
            _ = player.userVideoFilters.add(.verticalFlip)
            checks["quitAppExitStartedPending"] = player.pendingVideoConfiguration != nil && player.userVideoFilters.isApplying
            checks["quitSavedFilterSHA256"] = filterQuitSavedSHA
            checks["quitPendingRequest"] = player.pendingVideoConfiguration?.requestID.uuidString ?? ""
            checks["quitApplyCountBeforeTermination"] = player.videoConfigurationApplyCount
            finish(extra: [:])
        default: finish(extra: ["failure": "unexpected quit transition phase"])
        }
    }

    private func verifyBenchmark() {
        let now = ProcessInfo.processInfo.systemUptime
        if playbackStarted == nil {
            originalSettings = player.settings
            if let decoder = ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_HWDEC"] { player.set("hwdec", decoder) }
            if ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_FILTER"] == "denoise" {
                player.settings.denoise = 1; player.applySettings()
            }
            playbackStarted = now; initialFrames = 0
            let start = Double(ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_START"] ?? "0") ?? 0
            player.seek(start, remember: false); player.set("loop-file", "inf"); player.set("pause", "no")
            initialFrames = player.number("estimated-frame-number")
        }
        maxFootprint = max(maxFootprint, physicalFootprint())
        guard let playbackStarted else { return }
        benchmarkSamples.append(["wallSeconds": now - playbackStarted, "position": player.number("time-pos"), "fps": player.number("estimated-vf-fps"), "decoderDrops": player.number("decoder-frame-drop-count"), "renderDrops": player.number("frame-drop-count"), "avsync": player.number("avsync"), "physicalFootprintBytes": physicalFootprint(), "decoder": player.string("hwdec-current"), "thermalState": ProcessInfo.processInfo.thermalState.rawValue])
        let requested = Double(ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_SECONDS"] ?? "18") ?? 18
        let seconds = requested.isFinite ? min(900, max(18, requested)) : 18
        if now - lastProgressAt >= 15, let sample = benchmarkSamples.last {
            lastProgressAt = now
            if let data = try? JSONSerialization.data(withJSONObject: sample, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: report.deletingPathExtension().appendingPathExtension("progress.json"), options: .atomic)
            }
        }
        guard now - playbackStarted >= seconds else { return }
        checks["playedWallSeconds"] = now - playbackStarted
        checks["frames"] = max(0, player.number("estimated-frame-number") - initialFrames)
        checks["fps"] = player.number("estimated-vf-fps")
        checks["decoderDrops"] = player.number("decoder-frame-drop-count")
        checks["renderDrops"] = player.number("frame-drop-count")
        checks["avsync"] = player.number("avsync")
        checks["cacheSeconds"] = player.number("demuxer-cache-duration")
        checks["physicalFootprintBytes"] = maxFootprint
        checks["samples"] = benchmarkSamples
        checks["videoParams"] = player.jsonProperty("video-params") ?? [:]
        checks["videoOutputParams"] = player.jsonProperty("video-out-params") ?? [:]
        checks["videoFilters"] = player.jsonProperty("vf") ?? []
        player.set("pause", "yes")
        if hasVideo { player.command(["screenshot-to-file", screenshot.path, "video"]) }
        finish(extra: [:])
    }
    private func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
    private func verifyAdvanced() {
        switch phase {
        case 0:
            originalSettings = player.settings
            player.set("pause", "yes"); player.seek(2)
            if let path = ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_SUBTITLE"] {
                player.addSubtitle(URL(fileURLWithPath: path))
            }
        case 1:
            player.command(["screenshot-to-file", report.deletingPathExtension().path + "-original.png", "subtitles"])
            player.settings.rotation = 180; player.settings.brightness = 15; player.settings.contrast = 10
            player.settings.equalizerEnabled = true; player.settings.equalizer[5] = 3; player.settings.normalizeAudio = true
            let subs = player.tracks.filter { $0.type == "sub" }
            if subs.count > 1 { player.selectSubtitle(subs[0].id); player.settings.secondarySubtitleID = subs[1].id }
            player.settings.subtitleSize = 48; player.settings.subtitlePosition = 85
            player.applySettings()
        case 2:
            checks["rotation"] = player.number("video-rotate")
            checks["brightness"] = player.number("brightness")
            checks["contrast"] = player.number("contrast")
            checks["subtitleSize"] = player.number("sub-font-size")
            checks["secondarySubtitleID"] = player.string("secondary-sid")
            checks["audioFilters"] = player.jsonProperty("af") ?? []
            checks["statistics"] = player.statistics
            player.command(["screenshot-to-file", report.deletingPathExtension().path + "-adjusted.png", "subtitles"])
            player.settings.flipHorizontal = true; player.settings.denoise = 1
            player.applySettings(); player.seek(2)
        case 3:
            checks["videoFilters"] = player.jsonProperty("vf") ?? []
            checks["filterDecoder"] = player.string("hwdec-current")
            checks["devices"] = player.audioDevices.map(\.id)
            player.command(["screenshot-to-file", screenshot.path, "subtitles"])
        default:
            finish(extra: [:]); return
        }
        phase += 1
    }
    private func finish(extra: [String: Any]) {
        timer?.invalidate(); timer = nil
        var values: [String: Any] = [
            "loaded": player.loaded, "duration": player.duration, "position": player.position,
            "mode": mode, "playlistCount": player.playlist.items.count, "currentTitle": player.playlist.currentItem?.title ?? "",
            "paused": player.flag("pause"), "speed": player.speed, "volume": player.volume,
            "decoder": player.decoder, "video": player.videoInfo,
            "subtitleDelay": player.number("sub-delay"), "audioDelay": player.number("audio-delay"),
            "audioID": player.audioID, "subtitleID": player.subtitleID,
            "tracks": player.tracks.map { ["id": $0.id, "type": $0.type, "codec": $0.codec, "title": $0.title] as [String: Any] },
            "screenshot": screenshot.path, "screenshotExists": FileManager.default.fileExists(atPath: screenshot.path),
            "frameApplicable": hasVideo, "screenshotApplicable": hasVideo,
            "error": player.error ?? "", "mpv": player.string("mpv-version")
        ]
        if ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_RENDERER"] == "metal-sdr",
           InputController.verificationSuiteName(environment: ProcessInfo.processInfo.environment) != nil {
            let host = player.videoHost
            let metal = host?.video as? MPVMetalVideoView
            // Raw actual Metal evidence is separate from the original case's
            // gates. Neither API return zero nor a GL counter proves display.
            values["privateMetalRoute"] = [
                "requestedOutput":"sdr", "emptyShaderStartupRequired":true,
                "actualSelectedBackend":host?.effectiveBackend as Any? ?? NSNull(),
                "actualFallbackReason":host?.fallbackReason as Any? ?? NSNull(),
                "actualMetalView":metal != nil,
                "actualRendererID":metal?.rendererIdentity?.uuidString as Any? ?? NSNull(),
                "actualConsumer":metal?.metalDiagnostics as Any? ?? NSNull(),
                "actualGPUNextValidation":(player.jsonProperty("vo-passes") as? [String:Any])?["gpu-next-validation"] ?? NSNull(),
                "observedUptime":ProcessInfo.processInfo.systemUptime,
                "renderProgressIsMetalEvidence":false, "physicalHDRClaim":false]
        }
        values.merge(checks) { _, new in new }
        values.merge(extra) { _, new in new }
        if ["web-public", "diagnostic-privacy"].contains(mode) {
            // Public runs persist only the WebMediaVerifier's explicit fields.
            // Common track titles and engine diagnostics are not a safe URL
            // whitelist and can contain transient signed CDN addresses.
            values = extra
            values["mode"] = mode
        }
        if let originalSettings { player.settings = originalSettings; player.applySettings(); player.persistSettings() }
        do {
            try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        } catch { NSLog("Verification report failed: %@", error.localizedDescription) }
        if ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_EXIT"] == "1" { NSApp.terminate(nil) }
    }
}
