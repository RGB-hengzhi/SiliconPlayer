import AppKit
import PlayerCore

/// Internal APIs drive the actual installed-framework panel and original mpv
/// surface. This is separate from physical mouse/keyboard/system-chrome review.
@MainActor
final class SystemPiPVerifier {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private final class Ticket { var result: Result<URL, Error>? }
    private let player: PlayerModel
    private let report: URL
    private let mode: String
    private let finishImmediately: @MainActor ([String: Any]) -> Void
    private let initialCore: OpaquePointer?
    private var host: MPVVideoHost?
    private var task: Task<Void, Never>?
    private var quitTimer: Timer?
    private var result: [String: Any]?
    private var checks: [[String: Any]] = []
    private var samples: [[String: Any]] = []
    private var images: [[String: Any]] = []
    private var stage = "setup"
    private var pip: SystemPiPController { player.systemPiP }

    init(player: PlayerModel, report: URL, mode: String,
         finishImmediately: @escaping @MainActor ([String: Any]) -> Void) {
        self.player = player; self.report = report; self.mode = mode; initialCore = player.handle
        self.finishImmediately = finishImmediately
    }
    func tick() -> [String: Any]? {
        if let result { return result }
        guard task == nil else { return nil }
        task = Task { [weak self] in
            guard let self else { return }
            do { try await self.run() }
            catch {
                _ = await self.pip.exitAndWait(timeout: 2)
                self.result = self.payload(passed: false, extra: ["failure": error.localizedDescription, "systemPiPFailureStage": self.stage])
            }
        }
        return nil
    }
    private func check(_ id: String, _ passed: Bool) throws {
        checks.append(["id": id, "passed": passed])
        if !passed { throw Failure(message: "System PiP check failed: " + id) }
    }
    private func wait(_ label: String, seconds: Double = 12, until predicate: () -> Bool) async throws {
        stage = label
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate() {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure(message: "System PiP timeout: " + label) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    private func count(_ key: String) -> Int { (pip.diagnosticsSnapshot[key] as? NSNumber)?.intValue ?? 0 }
    private func fixture(_ key: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[key], path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: path) else { throw Failure(message: "Existing absolute PiP fixture required") }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    private func sameSurface() -> Bool {
        guard let host, player.videoHost === host, initialCore != nil, player.handle == initialCore else { return false }
        // An entering surface may temporarily have no window. Its registered
        // identity still exists; count it while also detecting any extra view.
        var identities: Set<ObjectIdentifier> = [ObjectIdentifier(host.video)]
        func collect(_ view: NSView) {
            if view is any MPVVideoDisplay { identities.insert(ObjectIdentifier(view)) }
            for child in view.subviews { collect(child) }
        }
        for window in NSApp.windows { if let root = window.contentView { collect(root) } }
        // Include the actual panel root even if the private framework does not
        // place that window in NSApplication.windows on this OS.
        if let root = host.video.window?.contentView { collect(root) }
        return identities.count == 1 && identities.contains(ObjectIdentifier(host.video))
    }
    private func nativePanelActive() -> Bool {
        guard let host, let window = host.video.window else { return false }
        return pip.active && window !== host.window && window.isVisible && host.video.superview !== host
            && NSStringFromClass(type(of: window)).contains("PIPPanel")
            && (pip.diagnosticsSnapshot["observedSystemWindowClass"] as? String)?.contains("PIPPanel") == true
            && count("startedCallbacks") > 0 && sameSurface()
    }
    private func mainSurfaceReady() -> Bool {
        guard let host, let window = host.window else { return false }
        let video = host.video, backing = video.convertToBacking(video.bounds).size
        return sameSurface() && window.isVisible && !window.isMiniaturized
            && video.window === window && video.superview === host
            && !video.isHiddenOrHasHiddenAncestor && !host.isHiddenOrHasHiddenAncestor
            && video.bounds.width > 1 && video.bounds.height > 1
            && video.visibleRect.width > 1 && video.visibleRect.height > 1
            && backing.width > 1 && backing.height > 1
    }
    private func sample(_ label: String, extra: [String: Any] = [:]) {
        var value: [String: Any] = ["stage": label, "uptime": ProcessInfo.processInfo.systemUptime,
            "controller": pip.diagnosticsSnapshot, "sameCoreAndVideoIdentity": sameSurface(),
            "loaded": player.loaded, "loading": player.isLoading, "paused": player.flag("pause"),
            "position": player.number("time-pos"), "renderFrames": player.renderProgress.frames,
            "audioID": player.audioID, "selectedAudio": player.string("aid"),
            "audioTrackCount": player.tracks.filter { $0.type == "audio" }.count,
            "videoCodec": player.tracks.first { $0.type == "video" }?.codec ?? "",
            "modelItemID": player.playlist.currentItem?.id.uuidString ?? "", "mpvEntryID": player.string("playlist/0/id")]
        if let video = host?.video {
            let backing = video.convertToBacking(video.bounds).size
            value["videoBounds"] = ["width": video.bounds.width, "height": video.bounds.height]
            value["backingBounds"] = ["width": backing.width, "height": backing.height]
            value["backingScale"] = video.window?.backingScaleFactor ?? 0
            value["originWindowVisible"] = host?.window?.isVisible == true
            value["surfaceMountedInOriginalHost"] = video.superview === host && video.window === host?.window
            if let window = video.window {
                func dimensions(_ size: NSSize) -> [String: CGFloat] { ["width": size.width, "height": size.height] }
                value["windowFrameSize"] = dimensions(window.frame.size)
                value["windowContentBounds"] = dimensions(window.contentView?.bounds.size ?? .zero)
                value["windowContentLayoutSize"] = dimensions(window.contentLayoutRect.size)
                value["windowMinSize"] = dimensions(window.minSize)
                value["windowContentMinSize"] = dimensions(window.contentMinSize)
                value["windowMaxSize"] = dimensions(window.maxSize)
                value["windowContentMaxSize"] = dimensions(window.contentMaxSize)
            }
        }
        value.merge(extra) { _, new in new }; samples.append(value)
    }
    private func payload(passed: Bool, extra: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["systemPiPPassed": passed, "systemPiPChecks": checks,
            "systemPiPSamples": samples, "systemPiPImages": images, "systemPiPFinal": pip.diagnosticsSnapshot,
            "physicalNativeUIAcceptance": false, "systemChromeControlsAcceptance": false,
            "lateCallbackScope": "Actual entering cancellation and post-close stability; synthetic generation-model tests are separate.",
            "scope": "Installed private system PIP framework on the actual tested OS; same mpv engine/video, no all-format or HDR display claim."]
        value.merge(extra) { _, new in new }; return value
    }
    private func load(_ url: URL, codec: String, id: String) async throws {
        try await player.openAndWaitForCommit([url])
        try await wait("fixture load") { self.player.loaded && self.player.currentURL == url && self.player.videoHost != nil }
        if host == nil { host = player.videoHost }
        try await wait("visible original video surface") { self.mainSurfaceReady() }
        let initialFrames = player.renderProgress.frames, initialTime = player.number("time-pos")
        player.set("pause", "no")
        try await wait("24 real frames and clock growth on original surface", seconds: 15) {
            self.player.loaded && self.player.currentURL == url && self.mainSurfaceReady()
                && !self.player.flag("seeking") && self.player.renderProgress.frames >= initialFrames + 24
                && self.player.number("time-pos") >= initialTime + 0.35
        }
        try check(id, sameSurface() && player.number("video-params/w") >= 3840 && player.number("video-params/h") >= 2160
                  && player.tracks.contains { $0.type == "video" && $0.codec == codec }
                  && player.audioID > 0 && player.error == nil)
        sample(id + "-ready", extra: ["loadRenderFramesBefore": initialFrames,
            "loadRenderFramesAfter": player.renderProgress.frames, "minimumNewRenderedFrames": 24,
            "loadPositionBefore": initialTime, "loadPositionAfter": player.number("time-pos"),
            "minimumTimeAdvanceSeconds": 0.35, "mainSurfaceReady": mainSurfaceReady()])
    }
    private func advance(_ label: String, seconds: Double = 0.65) async throws {
        let startTime = player.number("time-pos"), frames = player.renderProgress.frames, audio = player.string("aid")
        player.set("pause", "no")
        try await wait(label, seconds: 10) {
            self.player.number("time-pos") >= startTime + seconds && self.player.renderProgress.frames >= frames + 24
        }
        guard player.loaded, sameSurface(), !player.flag("pause"), !audio.isEmpty, audio != "no", player.string("aid") == audio else {
            throw Failure(message: "Original core/surface/audio selection changed during PiP playback")
        }
    }
    private func enterActive(_ id: String) async throws {
        guard mainSurfaceReady() else { throw Failure(message: "Original visible surface not ready for PiP") }
        guard pip.enter() else { throw Failure(message: "System PiP request rejected") }
        try await wait("actual visible native panel", seconds: 6) { self.nativePanelActive() }
        try check(id, count("forcedDetachCount") == 0)
        sample(id)
    }
    private func closeNormally(_ id: String) async throws {
        let closed = count("closedCallbacks"), normal = count("normalCloseCount"), willClose = count("willCloseCallbacks")
        let confirmed = await pip.exitAndWait(timeout: 2.5)
        try check(id, confirmed && count("closedCallbacks") == closed + 1 && count("normalCloseCount") == normal + 1
                  && count("willCloseCallbacks") >= willClose + 1 && count("forcedDetachCount") == 0
                  && pip.state == .idle && host?.video.superview === host && pip.safeToReleaseVideoView && sameSurface())
        sample(id)
    }
    private func stablePausedGeometry(_ label: String, minimumDuration: Double) async throws {
        guard let host, let window = host.video.window,
              let generation = (pip.diagnosticsSnapshot["ownershipTicket"] as? NSNumber)?.uint64Value else {
            throw Failure(message: "Native PiP ownership missing before geometry observation")
        }
        let pausedAt = player.number("time-pos")
        var previous: [NSSize]?, stableSince: Double?, observations = 0
        try await wait(label, seconds: 8) {
            guard self.nativePanelActive(), self.player.flag("pause"),
                  (self.pip.diagnosticsSnapshot["ownershipTicket"] as? NSNumber)?.uint64Value == generation,
                  abs(self.player.number("time-pos") - pausedAt) < 0.03 else {
                previous = nil; stableSince = nil; observations = 0; return false
            }
            let sizes = [window.frame.size, window.contentView?.bounds.size ?? .zero,
                window.contentLayoutRect.size, host.video.bounds.size, host.video.convertToBacking(host.video.bounds).size]
            guard sizes.allSatisfy({ $0.width > 1 && $0.height > 1 }) else {
                previous = nil; stableSince = nil; observations = 0; return false
            }
            let now = ProcessInfo.processInfo.systemUptime
            if previous != sizes {
                previous = sizes; stableSince = now; observations = 1; return false
            }
            observations += 1
            return stableSince.map { now - $0 >= minimumDuration } ?? false
        }
        sample(label + "-stable", extra: ["geometryStabilityMinimumSeconds": minimumDuration,
            "geometryStableObservedSeconds": ProcessInfo.processInfo.systemUptime - (stableSince ?? ProcessInfo.processInfo.systemUptime),
            "geometryConsecutiveObservations": observations, "geometryOwnershipTicket": generation])
    }
    private func capture(_ label: String) async throws {
        guard let host, nativePanelActive() else { throw Failure(message: "Native PiP surface not active for capture") }
        let video = host.video, bounds = video.bounds.size, backing = video.convertToBacking(video.bounds).size
        let folder = report.deletingPathExtension().appendingPathExtension("images")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent(label + ".png"), ticket = Ticket()
        guard let id = player.saveScreenshotAsync(to: path, mode: .window, completion: { ticket.result = $0 }) else {
            throw Failure(message: "PiP async window screenshot rejected")
        }
        try await wait("async PiP window screenshot", seconds: 25) { ticket.result != nil }
        guard case .success(let saved) = ticket.result, saved == path,
              let trace = player.screenshotDiagnostics.first(where: { $0.id == id }),
              trace.replyStatus == 0, trace.replyAt != nil, trace.imageIOOffMain, trace.published, trace.tempRemoved,
              player.pendingScreenshotCount == 0, let width = trace.width, let height = trace.height,
              abs(Double(width) - backing.width) <= 2, abs(Double(height) - backing.height) <= 2,
              width > 100, height > 100 else { throw Failure(message: "PiP PNG did not match actual renderer backing bounds or reply") }
        images.append(["id": label, "path": saved.path, "width": width, "height": height,
            "expectedBackingWidth": backing.width, "expectedBackingHeight": backing.height,
            "videoWidth": bounds.width, "videoHeight": bounds.height, "backingScale": video.window?.backingScaleFactor ?? 0,
            "paused": player.flag("pause"), "position": player.number("time-pos"), "requestID": id,
            "actualCommandReply": true, "imageIOOffMain": true, "renderCaptureMode": "window"])
    }
    private func runMain(first: URL, second: URL) async throws {
        try await load(first, codec: "h264", id: "h264-native-4k-load")
        // The fixture's opening sky has little detail. A separately decoded
        // 15-second reference contains a landscape, making output review useful.
        let framesBeforeSeek = player.renderProgress.frames
        player.seek(15)
        try await wait("H264 reference scene seek and actual render", seconds: 10) {
            !self.player.flag("seeking") && abs(self.player.number("time-pos") - 15) < 0.15
                && self.player.renderProgress.frames >= framesBeforeSeek + 1 && self.mainSurfaceReady()
        }
        sample("h264-reference-scene-settled", extra: ["referencePositionSeconds": 15,
            "renderFramesBeforeSeek": framesBeforeSeek, "renderFramesAfterSeek": player.renderProgress.frames,
            "runtimePixelMatch": false])
        try check("original-surface-and-single-core", sameSurface() && pip.available && player.systemPiPAvailable == pip.available)
        try await enterActive("h264-native-panel-active")
        guard let originalHost = host else { throw Failure(message: "Original host missing during PiP ownership check") }
        let originalVideo = originalHost.video
        let replacementHost = MPVVideoHost(player: player)
        try check("active-host-recreation-rejected", replacementHost == nil && player.videoHost === originalHost
                  && originalHost.video === originalVideo && pip.ownsRegistration(videoView: originalVideo, host: originalHost)
                  && nativePanelActive() && sameSurface())
        sample("active-host-recreation-rejected", extra: ["replacementHostRejected": replacementHost == nil,
            "originalRegistrationRetained": pip.ownsRegistration(videoView: originalVideo, host: originalHost)])
        try await advance("H264 PiP clock and frames")
        try check("h264-pip-clock-frames-audio", nativePanelActive()); sample("h264-playing")
        // Deliberate observation interval for root CUA, never external input injection.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        try await capture("h264-playing-pip"); try check("h264-pip-window-png", true)
        try await closeNormally("h264-normal-close-restores-host")
        try await load(second, codec: "hevc", id: "hevc-main10-native-4k-load")
        try await enterActive("hevc-native-panel-active")
        try await advance("HEVC PiP clock and frames"); sample("hevc-playing")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        try await capture("hevc-playing-pip"); try check("hevc-pip-clock-frames-window-png", nativePanelActive())
        try await closeNormally("hevc-normal-close-restores-host")
        player.set("pause", "yes"); player.seek(4)
        try await wait("paused HEVC seek") { self.player.flag("pause") && !self.player.flag("seeking") && abs(self.player.number("time-pos") - 4) < 0.15 }
        let pausedAt = player.number("time-pos")
        try await enterActive("paused-enter-preserves-state")
        guard player.flag("pause"), abs(player.number("time-pos") - pausedAt) < 0.03 else { throw Failure(message: "Paused PiP changed playback state") }
        try await stablePausedGeometry("paused-enter-geometry", minimumDuration: 0.6)
        for (label, size, id) in [("paused-small-pip", NSSize(width: 320, height: 180), "paused-small-resize-redraw-png"),
                                   ("paused-large-pip", NSSize(width: 640, height: 360), "paused-large-resize-redraw-png")] {
            guard let window = host?.video.window else { throw Failure(message: "PiP panel disappeared during resize") }
            let before = host?.video.bounds.size ?? .zero
            sample(id + "-before-set-content-size", extra: ["requestedWidth": size.width, "requestedHeight": size.height])
            window.setContentSize(size)
            sample(id + "-after-set-content-size", extra: ["requestedWidth": size.width, "requestedHeight": size.height])
            try await wait("system panel resize") { self.host?.video.bounds.size != before }
            try await stablePausedGeometry(id + "-geometry", minimumDuration: 0.3)
            host?.video.requestRedraw()
            try await capture(label)
            try check(id, player.flag("pause") && abs(player.number("time-pos") - pausedAt) < 0.03 && nativePanelActive())
            sample(id, extra: ["requestedWidth": size.width, "requestedHeight": size.height, "pausedRedrawRequested": true])
        }
        try await closeNormally("paused-normal-close-restores-host")
        try check("all-cycles-normal-no-forced-detach", count("enterCount") == 3 && count("normalCloseCount") == 3 && count("forcedDetachCount") == 0)
        result = payload(passed: true)
    }
    private func runRace(first: URL, second: URL) async throws {
        try await load(first, codec: "h264", id: "race-h264-native-4k-load")
        let firstClosed = count("closedCallbacks")
        guard pip.enter() else { throw Failure(message: "Race enter rejected") }
        try check("stop-intervenes-while-entering", pip.state == .entering)
        sample("before-stop-entering"); player.stopPlayback()
        try await wait("stop normal PiP closure", seconds: 6) { self.pip.state == .idle && self.count("closedCallbacks") > firstClosed }
        try check("stop-normal-close-restores-surface", !player.loaded && count("forcedDetachCount") == 0 && host?.video.superview === host && sameSurface())
        try await Task.sleep(nanoseconds: 750_000_000)
        try check("stop-post-close-stability", pip.state == .idle && !player.loaded && count("closedCallbacks") == firstClosed + 1)
        sample("after-stop-post-close-watch")
        try await load(first, codec: "h264", id: "race-reopen-original-core")
        try await advance("reopened main video"); try check("race-reopen-real-render-progress", sameSurface())
        let oldModelID = player.playlist.currentItem?.id, oldEntryID = player.string("playlist/0/id"), oldClosed = count("closedCallbacks")
        guard pip.enter() else { throw Failure(message: "Switch race enter rejected") }
        try check("switch-intervenes-while-entering", pip.state == .entering)
        sample("before-switch-entering"); try await player.openAndWaitForCommit([second])
        try await wait("replacement video and close", seconds: 20) { self.player.loaded && self.player.currentURL == second && self.pip.state == .idle && self.count("closedCallbacks") > oldClosed }
        try check("switch-new-file-id-same-core", sameSurface() && player.playlist.currentItem?.id != oldModelID
                  && !oldEntryID.isEmpty && !player.string("playlist/0/id").isEmpty && player.string("playlist/0/id") != oldEntryID)
        try check("switch-normal-close-restores-surface", count("forcedDetachCount") == 0 && host?.video.superview === host && pip.safeToReleaseVideoView)
        try await Task.sleep(nanoseconds: 750_000_000)
        try check("switch-post-close-stability", pip.state == .idle && player.currentURL == second && count("closedCallbacks") == oldClosed + 1)
        try await advance("replacement HEVC video"); sample("replacement-playing")
        try check("switch-hevc-real-render-progress", player.tracks.contains { $0.type == "video" && $0.codec == "hevc" })
        try await enterActive("race-reenter-native-panel")
        try await advance("reentered native PiP video")
        try await closeNormally("race-final-normal-close")
        result = payload(passed: true)
    }
    private func armQuitTimer() throws {
        guard quitTimer == nil else { throw Failure(message: "Duplicate PiP quit timer") }
        stage = "normal AppKit quit from main run loop"
        let timer = Timer(timeInterval: 0.001, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.quitTimer = nil
                do { try self.finishQuitFromRunLoop() }
                catch {
                    self.result = self.payload(passed: false, extra: ["failure": error.localizedDescription,
                        "systemPiPFailureStage": self.stage])
                }
            }
        }
        quitTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func finishQuitFromRunLoop() throws {
        let fromSwiftTask = withUnsafeCurrentTask { $0 != nil }
        guard Thread.isMainThread, !fromSwiftTask, player.loaded, sameSurface() else {
            throw Failure(message: "PiP quit must originate from the main run loop with the original loaded surface")
        }
        if mode == "system-pip-quit-enter" {
            // Enter and terminate in this same non-task call stack; scheduling
            // a Timer after entering would let the native state become active.
            guard mainSurfaceReady(), pip.enter() else { throw Failure(message: "Quit entering request rejected") }
            try check("quit-during-real-entering", pip.state == .entering && count("enterCount") == 1)
        } else {
            guard mode == "system-pip-quit-active", nativePanelActive() else {
                throw Failure(message: "Native panel no longer active when normal quit was requested")
            }
        }
        sample("quit-requested", extra: ["quitFromSwiftTask": fromSwiftTask, "quitOnMainThread": Thread.isMainThread])
        try check("normal-appkit-quit-requested-with-attachment", !pip.safeToReleaseVideoView
                  && (pip.diagnosticsSnapshot["hasPendingJobs"] as? Bool) == true && count("forcedDetachCount") == 0)
        // SessionVerifier writes and requests normal AppKit termination. Do not
        // call terminate twice or return a duplicate completion via tick().
        finishImmediately(payload(passed: true, extra: ["systemPiPQuitRequestedUptime": ProcessInfo.processInfo.systemUptime,
            "systemPiPShutdownEvidenceRequired": true, "systemPiPJobsActiveAtQuit": true,
            "systemPiPQuitFromSwiftTask": fromSwiftTask, "systemPiPQuitOnMainThread": Thread.isMainThread]))
    }
    private func run() async throws {
        let first = try fixture("SILICONPLAYER_VERIFY_PIP_FIRST"), second = try fixture("SILICONPLAYER_VERIFY_PIP_SECOND")
        switch mode {
        case "system-pip": try await runMain(first: first, second: second)
        case "system-pip-race": try await runRace(first: first, second: second)
        case "system-pip-quit-enter", "system-pip-quit-active":
            try await load(first, codec: "h264", id: "quit-native-4k-load")
            if mode == "system-pip-quit-active" {
                try await enterActive("quit-native-panel-active")
                try await advance("quit active PiP renderer")
                try check("quit-active-clock-frame-progress", nativePanelActive())
            }
            try armQuitTimer()
        default: throw Failure(message: "Unknown System PiP verification mode")
        }
    }
}
