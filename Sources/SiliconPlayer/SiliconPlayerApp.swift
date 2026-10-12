import SwiftUI
import AppKit

@main
struct SiliconPlayerApp: App {
    @NSApplicationDelegateAdaptor(PlayerAppDelegate.self) var delegate
    @StateObject private var player = PlayerModel.shared
    var body: some Scene {
        Window("SiliconPlayer", id: "player") { PlayerView(player: player) }
            .defaultSize(width: 1100, height: 690)
            .commands {
                PlayerMenus(player: player)
                CommandGroup(replacing: .appTermination) {
                    Button("退出SiliconPlayer") { delegate.requestUserTermination(source: "menu") }.keyboardShortcut("q")
                }
                CommandGroup(replacing: .newItem) {
                    Button("打开媒体…") { player.openPanel() }.keyboardShortcut("o")
                    Button("添加到播放列表…") { player.openPanel(append: true) }.keyboardShortcut("o", modifiers: [.command, .shift])
                    Button("打开网络地址…") { player.openURLPanel() }.keyboardShortcut("u")
                    if AppCapabilities.current.hasWebMediaExtractor {
                        Button("解析网页视频…") { player.showWebMedia = true }.keyboardShortcut("u", modifiers: [.command, .shift])
                    }
                    Button("加载字幕…") { player.openPanel(subtitles: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
                }
                CommandMenu("播放") {
                    Button(player.paused ? "播放" : "暂停") { player.togglePause() }
                    Button("停止并清空画面") { player.stopPlayback() }.disabled(!player.loaded && !player.isLoading)
                    Button("后退 5 秒") { player.jump(-5) }
                    Button("快进 5 秒") { player.jump(5) }
                    Divider()
                    Button("上一个") { player.previous() }
                    Button("下一个") { player.next() }
                    Button("设置 A / B / 清除循环") { player.cycleAB() }
                    Button("单文件循环") { player.toggleLoop() }
                    Divider()
                    Button("截图") { player.screenshot() }.keyboardShortcut("s").disabled(player.screenshotBusy || !player.loaded)
                    Button("在 Finder 中显示截图") { NSWorkspace.shared.open(player.selectedScreenshotDirectory) }
                }
                CommandGroup(after: .sidebar) {
                    Button("显示 / 隐藏播放列表") { player.showPlaylist.toggle() }.keyboardShortcut("l")
                    Button("媒体与同步设置") { player.showInspector = true }.keyboardShortcut("i")
                }
            }
    }
}

@MainActor
final class PlayerAppDelegate: NSObject, NSApplicationDelegate {
    private var keyboardMonitor: Any?
    private var temporarySpeedFocusObservers: [NSObjectProtocol] = []
    private var verifier: SessionVerifier?
    private var shuttingDown = false
    private var userTerminationTimer: Timer?
    private var userTerminationAttempt: UInt64 = 0
    private var userTerminationDeadline: TimeInterval = 0
    private var userTerminationTickCount = 0
    private var userTerminationLastTopology: String?

    // Keep request delivery on AppKit's native main RunLoop. Cleanup continues
    // to use the existing terminateLater delegate and its resource barriers.
    func requestUserTermination(source: String = "unspecified") {
        traceUserTermination("request-received", values: ["source": source])
        if SubtitleAuthoringWindow.appTerminationReviewIsActive {
            traceUserTermination("subtitle-dirty-review-coalesced")
            return // Repeated Cmd-Q must not end its own review/save sheet.
        }
        guard userTerminationTimer == nil, !shuttingDown else {
            traceUserTermination("request-coalesced")
            return
        }
        userTerminationAttempt &+= 1
        userTerminationTickCount = 0
        userTerminationLastTopology = nil
        userTerminationDeadline = ProcessInfo.processInfo.systemUptime + 2.0
        traceUserTermination("request-accepted", values: ["source": source])
        let player = PlayerModel.shared
        if !player.finishTemporarySpeed(reason: "user-quit") {
            traceUserTermination("temporary-speed-restore-failed-continuing-quit")
        }
        player.showInspector = false; player.showAdvanced = false
        player.showLibrary = false; player.showShortcuts = false
        player.showTools = false; player.showCapture = false
        player.showTranslation = false; player.showLiveASR = false
        player.showThumbnails = false; player.showNetwork = false
        player.showWebMedia = false; player.showMediaPreferences = false
        player.showProfileBackup = false; player.showScriptExtensions = false
        DirectoryLibraryWindow.cancelPanelsForTermination()
        FTPBrowserWindow.beginUserTermination()
        // Preserve the existing cancellation policy for attached sheets;
        // do not abort arbitrary application-modal sessions or force exit.
        let sheets = NSApp.windows.filter { $0.sheetParent != nil }
        for sheet in sheets {
            guard let parent = sheet.sheetParent else { continue }
            traceUserTermination("sheet-end-request", values: ["sheet": sheet.windowNumber, "parent": parent.windowNumber])
            parent.endSheet(sheet, returnCode: .cancel)
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollUserTermination() }
        }
        timer.tolerance = 0.005
        timer.fireDate = Date()
        userTerminationTimer = timer
        for mode in [RunLoop.Mode.default, .common, .modalPanel, .eventTracking] {
            RunLoop.main.add(timer, forMode: mode)
        }
        traceUserTermination("native-timer-scheduled", values: ["deadlineUptime": userTerminationDeadline])
    }

    private func pollUserTermination() {
        guard let timer = userTerminationTimer else { return }
        userTerminationTickCount += 1
        let topology = userTerminationWindows()
        let topologyKey = String(data: (try? JSONSerialization.data(withJSONObject: topology, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? "unavailable"
        if userTerminationTickCount == 1 || topologyKey != userTerminationLastTopology || userTerminationTickCount % 10 == 0 {
            traceUserTermination("native-timer-poll")
            userTerminationLastTopology = topologyKey
        }
        if shuttingDown {
            timer.invalidate(); userTerminationTimer = nil
            traceUserTermination("native-timer-cleanup-already-active")
            return
        }
        // Both public relationship directions must be clear. Removing only
        // sheetParent does not certify that the parent's attachedSheet is nil.
        let sheetAttached = NSApp.windows.contains { $0.sheetParent != nil || $0.attachedSheet != nil }
        if !sheetAttached, NSApp.modalWindow == nil {
            timer.invalidate(); userTerminationTimer = nil
            traceUserTermination("native-terminate-call")
            NSApp.terminate(nil)
            // terminateNow may not return; terminateCancel/terminateLater can.
            traceUserTermination("native-terminate-returned")
            return
        }
        if ProcessInfo.processInfo.systemUptime >= userTerminationDeadline {
            timer.invalidate(); userTerminationTimer = nil
            traceUserTermination("native-timer-timeout")
            SubtitleAuthoringWindow.cancelAppTerminationReview()
            DirectoryLibraryWindow.resumeAfterCancelledTermination()
            FTPBrowserWindow.resumeAfterCancelledTermination()
            PlayerModel.shared.toast("请先关闭当前系统对话框，再退出播放器。")
        }
    }

    private func userTerminationWindows() -> [[String: Any]] {
        NSApp.windows.prefix(64).map { window in
            ["number": window.windowNumber, "class": String(describing: type(of: window)),
             "sheetParent": window.sheetParent?.windowNumber ?? -1,
             "attachedSheet": window.attachedSheet?.windowNumber ?? -1,
             "visible": window.isVisible]
        }
    }

    private func traceUserTermination(_ stage: String, values: [String: Any] = [:]) {
        var record: [String: Any] = ["stage": stage, "attempt": userTerminationAttempt,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "uptime": ProcessInfo.processInfo.systemUptime, "mainThread": Thread.isMainThread,
            "runLoopMode": RunLoop.current.currentMode?.rawValue ?? "none",
            "shuttingDown": shuttingDown, "timerPresent": userTerminationTimer != nil,
            "timerTickCount": userTerminationTickCount,
            "modalWindow": NSApp.modalWindow?.windowNumber ?? -1,
            "windows": userTerminationWindows()]
        for (key, value) in values { record[key] = value }
        // Deliberately omit window titles, media URLs, file paths and credentials.
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        NSLog("SPUserTerminationTrace %@", text)
    }

    private func tracedUserTerminationCleanup<Result>(_ name: String,
        operation: @MainActor () async -> Result) async -> Result {
        traceUserTermination("cleanup-operation-begin", values: ["operation": name])
        let result = await operation()
        var values: [String: Any] = ["operation": name]
        if let confirmed = result as? Bool { values["confirmed"] = confirmed }
        traceUserTermination("cleanup-operation-completed", values: values)
        return result
    }

    func applicationWillTerminate(_ notification: Notification) {
        userTerminationTimer?.invalidate(); userTerminationTimer = nil
        temporarySpeedFocusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        temporarySpeedFocusObservers = []
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor); self.keyboardMonitor = nil }
        traceUserTermination("application-will-terminate")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if !arch(arm64)
        let alert = NSAlert(); alert.messageText = "SiliconPlayer 仅支持 Apple Silicon"; alert.runModal(); NSApp.terminate(nil)
        #endif
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        temporarySpeedFocusObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { _ = PlayerModel.shared.finishTemporarySpeed(reason: "application-deactivated") }
            })
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            temporarySpeedFocusObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notice in
                MainActor.assumeIsolated {
                    if let window = notice.object as? NSWindow {
                        PlayerModel.shared.temporaryPlaybackSpeed.windowResigned(window.windowNumber)
                    }
                }
            })
        }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated {
                let player = PlayerModel.shared
                // Key-up owns the captured physical code even after focus or
                // modifiers have changed; never gate restoration on text focus.
                if event.type == .keyUp {
                    return player.temporaryPlaybackSpeed.keyUp(code: event.keyCode) ? nil : event
                }
                if event.type == .flagsChanged {
                    player.temporaryPlaybackSpeed.flagsChanged(modifiers:
                        event.modifierFlags.intersection([.command, .control, .option, .shift]).rawValue)
                    return event
                }
                if event.keyCode == 12,
                   event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
                    self?.requestUserTermination(source: "key-equivalent")
                    return nil
                }
                if OrdinaryMediaOpenWindow.ownsPlaybackInput(event) { return event }
                if DirectoryLibraryWindow.ownsPlaybackInput(event) || FTPBrowserWindow.ownsPlaybackInput(event) { return event }
                if AdvancedWindowDiagnosticPresenter.enabled,
                   AdvancedWindowDiagnosticPresenter.shared.ownsPlaybackInput(event) { return event }
                if NSApp.keyWindow?.firstResponder is NSTextView || NSApp.keyWindow?.firstResponder is NSTextField || NSApp.keyWindow?.sheetParent != nil || NSApp.modalWindow != nil { return event }
                if let table = NSApp.keyWindow?.firstResponder as? NSTableView, table.identifier?.rawValue == "playlist-queue",
                   [36, 76, 51, 117, 123, 124, 125, 126, 115, 119, 116, 121, 48, 49].contains(event.keyCode) {
                    // The focused queue owns Space and its navigation keys.
                    return event
                }
                return InputController.shared.handle(event, player: PlayerModel.shared) ? nil : event
            }
        }
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if !paths.isEmpty { PlayerModel.shared.open(paths.map { path in
            if let url = URL(string: path), url.scheme != nil, !path.hasPrefix("/") { return url }
            return URL(fileURLWithPath: path)
        }) }
        SystemMediaController.shared.install(player: PlayerModel.shared)
        MediaTools.shared.onSubtitlesReady = { output in
            let player = PlayerModel.shared
            guard player.currentURL == MediaTools.shared.lastSubtitleSource else { player.toast("语音字幕已保存，当前媒体已切换"); return }
            player.addSubtitle(output)
        }
        if let report = ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_REPORT"] {
            let environment = ProcessInfo.processInfo.environment
            // Explicit isolated physical UI sessions leave playback under the
            // tester's control. They carry no automatic acceptance result.
            if environment["SILICONPLAYER_VERIFY_MODE"] != "native-ui-manual"
                || InputController.verificationSuiteName(environment: environment) == nil {
                verifier = SessionVerifier(player: PlayerModel.shared, report: URL(fileURLWithPath: report))
            }
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) { PlayerModel.shared.open(urls) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    private func prepareVerificationTermination(environment: [String: String], phase: String) async -> Bool {
        guard InputController.verificationSuiteName(environment: environment) != nil else { return true }
        let input = InputController.shared
        guard let cleanup = input.closeVerificationWritesAndClear(environment: environment, phase: phase),
              let report = environment["SILICONPLAYER_VERIFY_REPORT"] else { return false }
        let disk = cleanup.succeeded ? await input.awaitVerificationDomainDiskClear(environment: environment) : nil
        let confirmed = cleanup.succeeded && disk?.diskDomainEmpty == true
        var rollbackSucceeded: Bool?
        if !confirmed {
            rollbackSucceeded = input.resumeVerificationWritesAfterCancelledTermination(environment: environment)
        }
        do {
            var evidence = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cleanup)) as! [String: Any]
            evidence["mode"] = environment["SILICONPLAYER_VERIFY_MODE"] ?? ""
            evidence["terminationAllowed"] = confirmed
            evidence["succeeded"] = confirmed
            if let disk {
                evidence["diskBarrier"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(disk))
                evidence["finishedUptime"] = disk.finishedUptime
            }
            if !confirmed { evidence["cancellationReason"] = cleanup.succeeded ? "private-domain-disk-not-cleared" : "private-domain-memory-cleanup-failed" }
            if let rollbackSucceeded { evidence["cancelledExitRollbackSucceeded"] = rollbackSucceeded }
            let sidecar = URL(fileURLWithPath: report).deletingPathExtension().appendingPathExtension("suite-termination.json")
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: sidecar, options: .atomic)
        } catch {
            if confirmed { rollbackSucceeded = input.resumeVerificationWritesAfterCancelledTermination(environment: environment) }
            PlayerModel.shared.toast(rollbackSucceeded == false
                ? "验证会话的退出记录与偏好恢复未确认，本次退出已取消；写入保持关闭，可再次尝试退出。"
                : "验证会话的退出记录无法保存，本次退出已取消。")
            return false
        }
        if !confirmed { PlayerModel.shared.toast(rollbackSucceeded == false
            ? "验证会话的偏好恢复未确认，本次退出已取消；写入保持关闭，可再次尝试退出。"
            : "验证会话的快捷键磁盘清理尚未确认，本次退出已取消。") }
        return confirmed
    }
    private func writeVideoTerminationEvidence(player: PlayerModel, begin: [String: Any], environment: [String: String]) -> Bool {
        guard environment["SILICONPLAYER_VERIFY_MODE"] == "filter-transition-quit",
              InputController.verificationSuiteName(environment: environment) != nil,
              let path = environment["SILICONPLAYER_VERIFY_REPORT"] else { return true }
        let before = begin["before"] as? [String: Any] ?? [:]
        let after = player.videoConfigurationTerminationSnapshot()
        let count = player.videoConfigurationApplyCount
        let rejected = player.applyVideoFilterProperties(settings: player.settings.sanitized(), userFragments: player.userVideoFilters.effectiveFragments) < 0
        let stable = (before["applyCount"] as? UInt64) == count && player.videoConfigurationApplyCount == count
        let sameDisk = (before["filterStoreSHA256"] as? String) == (after["filterStoreSHA256"] as? String)
        let succeeded = player.videoConfigurationClosing && player.pendingVideoConfiguration == nil
            && !player.userVideoFilters.isApplying && rejected && stable && sameDisk && !player.hasUsedWebPlayback
        let evidence: [String: Any] = ["mode": "filter-transition-quit", "begin": begin, "afterCleanup": after,
            "nonWeb": !player.hasUsedWebPlayback, "closedRequestRejected": rejected, "applyCountUnchanged": stable,
            "savedFilterBytesUnchanged": sameDisk, "succeeded": succeeded, "observedUptime": ProcessInfo.processInfo.systemUptime]
        do {
            let destination = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("video-termination.json")
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
            return succeeded
        } catch { return false }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        traceUserTermination("delegate-entered")
        if !PlayerModel.shared.finishTemporarySpeed(reason: "delegate-quit") {
            traceUserTermination("temporary-speed-restore-failed-continuing-quit")
        }
        userTerminationTimer?.invalidate(); userTerminationTimer = nil
        if shuttingDown {
            traceUserTermination("delegate-repeat-terminate-later")
            return .terminateLater
        }
        guard SubtitleAuthoringWindow.allowAppTermination(onApproval: { [weak self] in
            self?.requestUserTermination(source: "subtitle-dirty-review-approved")
        }) else {
            traceUserTermination("subtitle-dirty-review-terminate-cancel")
            DirectoryLibraryWindow.resumeAfterCancelledTermination()
            FTPBrowserWindow.resumeAfterCancelledTermination()
            return .terminateCancel
        }
        let tools = MediaTools.shared, capture = CaptureController.shared
        let player = PlayerModel.shared
        player.liveASR.beginTermination()
        player.nativeAudioQueue.beginTermination()
        MetalRenderOwnership.beginTermination()
        let videoTermination = player.beginVideoConfigurationTermination()
        let wasAcceptingVideo = (videoTermination["before"] as? [String: Any])?["accepting"] as? Bool == true
        let webLoadActive = player.currentIsWebMedia && player.isLoading
        let webCoreUsed = player.hasUsedWebPlayback
        let pip = player.systemPiP
        let env = ProcessInfo.processInfo.environment
        let metalSmokeClose = MetalSmokeCloseCapture.begin(player: player)
        let pipEvidenceURL: URL? = {
            guard InputController.verificationSuiteName(environment: env) != nil,
                  let requested = env["SILICONPLAYER_VERIFY_PIP_SHUTDOWN_REPORT"], requested.hasPrefix("/"),
                  let report = env["SILICONPLAYER_VERIFY_REPORT"] else { return nil }
            let path = URL(fileURLWithPath: requested).standardizedFileURL
            let parent = URL(fileURLWithPath: report).standardizedFileURL.deletingLastPathComponent()
            guard path.deletingLastPathComponent() == parent, path.pathExtension == "json" else { return nil }
            return path
        }()
        let verificationExit = InputController.verificationSuiteName(environment: env) != nil
        // Close profile preview/export/commit acceptance in both Now and Later paths.
        player.profileBackup.beginTermination()
        OrdinaryMediaOpenController.beginTermination()
        DirectoryLibraryController.beginTermination()
        FTPBrowserController.beginTermination()
        guard tools.busy || capture.isBusy || capture.isRecording || capture.isPreviewing || ThumbnailTools.shared.busy || player.pendingScreenshotCount > 0 || WebMediaResolver.hasActiveJobs || NativeLocalAudioInspector.hasActiveJobs || LiveASRController.hasActiveJobs || player.liveASRHostState.overlayOwner != nil || OrdinaryMediaOpenController.hasActiveJobs || DirectoryLibraryController.hasActiveJobs || FTPBrowserController.hasActiveJobs || EPGService.hasActiveJobs || VideoAssetsService.hasActiveJobs || player.profileBackup.hasActiveJobs || webCoreUsed || pip.hasPendingJobs || MetalRenderOwnership.hasOwnedResources || pipEvidenceURL != nil || verificationExit else {
            traceUserTermination("delegate-terminate-now")
            return .terminateNow
        }
        let asrBefore = player.liveASR.diagnosticsSnapshot
        let pipBefore = pip.diagnosticsSnapshot
        let pipRequestedAt = ProcessInfo.processInfo.systemUptime
        shuttingDown = true
        if webLoadActive { player.stopPlayback() }
        player.cancelScreenshotsForShutdown()
        ThumbnailTools.shared.cancel(); SubtitleSpeechController.shared.stop()
        traceUserTermination("cleanup-task-scheduled")
        Task { @MainActor in
            self.traceUserTermination("cleanup-task-entered")
            async let mediaCleanup: Void = self.tracedUserTerminationCleanup("media-tools") { await tools.shutdown() }
            async let captureCleanup: Void = self.tracedUserTerminationCleanup("capture") { await capture.shutdown() }
            async let screenshotCleanup: Void = self.tracedUserTerminationCleanup("screenshots") { await player.shutdownScreenshots() }
            async let webCleanup: Void = self.tracedUserTerminationCleanup("web-resolver") { await WebMediaResolver.shutdownAll() }
            async let audioProbeCleanup: Bool = self.tracedUserTerminationCleanup("native-audio-inspector") { await NativeLocalAudioInspector.shutdownAll() }
            async let asrCleanup: Bool = self.tracedUserTerminationCleanup("live-asr") {
                let controllerReleased = await player.liveASR.shutdown()
                let allReleased = await LiveASRController.shutdownAll()
                return controllerReleased && allReleased
            }
            async let directoryCleanup: Bool = self.tracedUserTerminationCleanup("ordinary-directory-and-ftp") {
                // Ordinary workers retain descriptor/cache ownership until their
                // real return; FTP retirement then observes exact open completion.
                let opensReleased = await OrdinaryMediaOpenController.shutdownAll()
                let monitorsReleased = await DirectoryLibraryController.shutdownAll()
                let ftpReleased = await FTPBrowserController.shutdownAll()
                return opensReleased && monitorsReleased && ftpReleased
            }
            async let guideCleanup: Bool = self.tracedUserTerminationCleanup("epg") { await EPGService.shutdownAll() }
            async let profileCleanup: Bool = self.tracedUserTerminationCleanup("profile-import") { await player.profileBackup.shutdown() }
            async let assetsCleanup: Bool = self.tracedUserTerminationCleanup("video-assets") { await VideoAssetsService.shutdownAll() }
            async let pipCleanup: Bool = self.tracedUserTerminationCleanup("system-pip") { await pip.shutdown(timeout: 2.5) }
            let (_, _, _, _, audioProbesStopped, asrStopped, guideStopped, pipStopped, assetsStopped, profileStopped, directoriesStopped) = await
                (mediaCleanup, captureCleanup, screenshotCleanup, webCleanup, audioProbeCleanup, asrCleanup, guideCleanup, pipCleanup, assetsCleanup, profileCleanup, directoryCleanup)
            // PiP closes before exact renderer/color-owner retirement.
            let metalSmokeCapturesStopped = await MetalAppSmokeVerifier.shutdownForTermination(timeout: 2.5)
            let metalStopped = await MetalRenderOwnership.shutdownForTermination(timeout: 2.5)
            let metalSmokeReceiptSaved = MetalSmokeCloseCapture.save(metalSmokeClose, stopped: metalStopped, environment: env)
            self.traceUserTermination("cleanup-await-completed", values: ["audioProbesStopped": audioProbesStopped,
                "asrStopped": asrStopped, "guideStopped": guideStopped, "pipStopped": pipStopped, "metalStopped": metalStopped])
            if verificationExit && (LiveASRVerifier.modes.contains(env["SILICONPLAYER_VERIFY_MODE"] ?? "")
                || ExternalWAVASRVerifier.modes.contains(env["SILICONPLAYER_VERIFY_MODE"] ?? "")
                || ContinuousLocalASRVerifier.modes.contains(env["SILICONPLAYER_VERIFY_MODE"] ?? "")
                || LinearProviderASRVerifier.modes.contains(env["SILICONPLAYER_VERIFY_MODE"] ?? "")),
               let reportPath = env["SILICONPLAYER_VERIFY_REPORT"] {
                let destination = URL(fileURLWithPath: reportPath).deletingPathExtension().appendingPathExtension("asr-termination.json")
                var evidence: [String: Any] = ["before": asrBefore, "after": player.liveASR.diagnosticsSnapshot,
                    "asrStopped": asrStopped, "ownedJobs": LiveASRController.hasActiveJobs,
                    "overlayOwner": player.liveASRHostState.overlayOwner?.uuidString ?? "",
                    "coreWasStillLive": !player.liveASRCoreClosed,
                    "succeeded": asrStopped && !LiveASRController.hasActiveJobs && player.liveASRHostState.overlayOwner == nil,
                    "uptime": ProcessInfo.processInfo.systemUptime]
                if let raw = await player.liveASR.backendDiagnostics(), let decoded = try? JSONSerialization.jsonObject(with: raw) {
                    evidence["backendActual"] = decoded
                }
                do {
                    if ContinuousLocalASRVerifier.modes.contains(env["SILICONPLAYER_VERIFY_MODE"] ?? "") {
                        // Explicit private capture after both real shutdowns.
                        // Preserve the original bounded Data, not an invented
                        // close receipt or a summary substituted for pipe wire.
                        let rawPairs = player.liveASR.preparedPairDiagnostics()
                        guard rawPairs.count <= 256 else { throw LiveASRFailure("Private warm-pair capture overflow") }
                        var encodedPairs: [String: String] = [:]
                        var rawByteCounts: [String: Int] = [:]
                        var rawBytes = 0
                        for (id, raw) in rawPairs {
                            guard !raw.isEmpty, raw.count <= 32 * 1_048_576,
                                  rawBytes + raw.count <= 8 * 1_048_576,
                                  let decoded = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                                  decoded["captureEnabled"] as? Bool == true,
                                  decoded["processID"] as? String == id.uuidString else {
                                throw LiveASRFailure("Actual warm-pair private wire identity or bound invalid")
                            }
                            encodedPairs[id.uuidString] = raw.base64EncodedString()
                            rawByteCounts[id.uuidString] = raw.count; rawBytes += raw.count
                        }
                        evidence["preparedPairRawJSONBase64"] = encodedPairs
                        evidence["preparedPairRawByteCounts"] = rawByteCounts
                        evidence["preparedPairRawBytes"] = rawBytes
                    }
                    let encoded = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                    guard encoded.count <= 64 * 1_048_576 else { throw LiveASRFailure("Private ASR termination capture overflow") }
                    try encoded.write(to: destination, options: .withoutOverwriting)
                }
                catch { NSLog("ASR termination evidence unavailable: %@", error.localizedDescription) }
            }
            if let pipEvidenceURL {
                let evidence: [String: Any] = ["succeeded": pipStopped, "before": pipBefore,
                    "after": pip.diagnosticsSnapshot, "requestedUptime": pipRequestedAt,
                    "finishedUptime": ProcessInfo.processInfo.systemUptime,
                    "mode": env["SILICONPLAYER_VERIFY_MODE"] ?? ""]
                do { try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: pipEvidenceURL, options: .atomic) }
                catch { NSLog("PiP verification cleanup report unavailable") }
            }
            guard audioProbesStopped && asrStopped && guideStopped && pipStopped && metalStopped && metalSmokeReceiptSaved && metalSmokeCapturesStopped && assetsStopped && profileStopped && directoriesStopped else {
                shuttingDown = false
                _ = pip.cancelShutdownIfSafe()
                player.nativeAudioQueue.resumeAfterCanceledTermination()
                player.resumeVideoConfigurationAfterCancelledTermination(previouslyAccepting: wasAcceptingVideo)
                player.profileBackup.resumeAfterCancelledTermination()
                player.videoAssets.resumeAfterCancelledTermination()
                player.liveASR.resumeAfterCancelledTermination()
                MetalRenderOwnership.resumeAfterCancelledTermination()
                MetalAppSmokeVerifier.resumeAfterCancelledTermination()
                player.toast(!metalStopped ? "视频输出恢复或释放尚未确认，请稍后再次退出。" : !directoriesStopped ? "本地打开、目录或 FTP 请求尚未确认释放，请稍后再次退出。" : !assetsStopped ? "视频资源仍在取消与恢复，请稍后再次退出。" : !asrStopped ? "实时字幕尚未确认清理，请稍后再次退出。"
                    : !profileStopped ? "设置备份仍在写入或回滚，请稍后再次退出。"
                    : !audioProbesStopped ? "连续音频预检仍在收尾，请稍后再次退出。"
                    : guideStopped ? "画中画尚未确认清理，请稍后再次退出。" : "节目单请求仍在收尾，请稍后再次退出。")
                self.traceUserTermination("delegate-reply-false", values: ["reason": "owned-cleanup-not-confirmed"])
                SubtitleAuthoringWindow.cancelAppTerminationReview()
                OrdinaryMediaOpenController.resumeAfterCancelledTermination()
                DirectoryLibraryController.resumeAfterCancelledTermination()
                FTPBrowserController.resumeAfterCancelledTermination()
                DirectoryLibraryWindow.resumeAfterCancelledTermination()
            FTPBrowserWindow.resumeAfterCancelledTermination()
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            self.traceUserTermination("verification-barrier-begin", values: ["verificationExit": verificationExit])
            guard await self.prepareVerificationTermination(environment: env, phase: "before-reply-true") else {
                self.shuttingDown = false
                player.profileBackup.resumeAfterCancelledTermination()
                player.videoAssets.resumeAfterCancelledTermination()
                player.liveASR.resumeAfterCancelledTermination()
                MetalRenderOwnership.resumeAfterCancelledTermination()
                MetalAppSmokeVerifier.resumeAfterCancelledTermination()
                _ = pip.cancelShutdownIfSafe()
                player.nativeAudioQueue.resumeAfterCanceledTermination()
                player.resumeVideoConfigurationAfterCancelledTermination(previouslyAccepting: wasAcceptingVideo)
                self.traceUserTermination("delegate-reply-false", values: ["reason": "verification-domain-or-sidecar-not-confirmed"])
                SubtitleAuthoringWindow.cancelAppTerminationReview()
                OrdinaryMediaOpenController.resumeAfterCancelledTermination()
                DirectoryLibraryController.resumeAfterCancelledTermination()
                FTPBrowserController.resumeAfterCancelledTermination()
                DirectoryLibraryWindow.resumeAfterCancelledTermination()
            FTPBrowserWindow.resumeAfterCancelledTermination()
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            self.traceUserTermination("verification-barrier-approved")
            guard self.writeVideoTerminationEvidence(player: player, begin: videoTermination, environment: env) else {
                self.shuttingDown = false
                player.profileBackup.resumeAfterCancelledTermination()
                player.videoAssets.resumeAfterCancelledTermination()
                player.liveASR.resumeAfterCancelledTermination()
                MetalRenderOwnership.resumeAfterCancelledTermination()
                MetalAppSmokeVerifier.resumeAfterCancelledTermination()
                _ = pip.cancelShutdownIfSafe()
                _ = InputController.shared.resumeVerificationWritesAfterCancelledTermination(environment: env)
                player.nativeAudioQueue.resumeAfterCanceledTermination()
                player.resumeVideoConfigurationAfterCancelledTermination(previouslyAccepting: wasAcceptingVideo)
                player.toast("验证会话的视频退出屏障未确认，本次退出已取消。")
                self.traceUserTermination("delegate-reply-false", values: ["reason": "video-termination-evidence-not-confirmed"])
                SubtitleAuthoringWindow.cancelAppTerminationReview()
                OrdinaryMediaOpenController.resumeAfterCancelledTermination()
                DirectoryLibraryController.resumeAfterCancelledTermination()
                FTPBrowserController.resumeAfterCancelledTermination()
                DirectoryLibraryWindow.resumeAfterCancelledTermination()
            FTPBrowserWindow.resumeAfterCancelledTermination()
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            guard SubtitleAuthoringWindow.confirmAppTerminationPermit(), MetalRenderOwnership.terminationConfirmed else {
                self.shuttingDown = false
                player.profileBackup.resumeAfterCancelledTermination()
                player.videoAssets.resumeAfterCancelledTermination()
                player.liveASR.resumeAfterCancelledTermination()
                MetalRenderOwnership.resumeAfterCancelledTermination()
                MetalAppSmokeVerifier.resumeAfterCancelledTermination()
                _ = pip.cancelShutdownIfSafe()
                _ = InputController.shared.resumeVerificationWritesAfterCancelledTermination(environment: env)
                player.nativeAudioQueue.resumeAfterCanceledTermination()
                player.resumeVideoConfigurationAfterCancelledTermination(previouslyAccepting: wasAcceptingVideo)
                SubtitleAuthoringWindow.cancelAppTerminationReview()
                player.toast("字幕编辑状态已变化，本次退出已取消。")
                self.traceUserTermination("delegate-reply-false", values: ["reason": "subtitle-edit-permit-changed"])
                OrdinaryMediaOpenController.resumeAfterCancelledTermination()
                DirectoryLibraryController.resumeAfterCancelledTermination()
                FTPBrowserController.resumeAfterCancelledTermination()
                DirectoryLibraryWindow.resumeAfterCancelledTermination()
            FTPBrowserWindow.resumeAfterCancelledTermination()
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            // Verification cancellation must leave the playback core usable.
            // Only an approved exit may send mpv's irreversible quit command.
            if webCoreUsed {
                self.traceUserTermination("web-core-finalization-begin")
                await player.shutdownWebPlayback()
                self.traceUserTermination("web-core-finalization-completed")
            }
            guard SubtitleAuthoringWindow.confirmAppTerminationPermit(), MetalRenderOwnership.terminationConfirmed else {
                self.shuttingDown = false
                player.profileBackup.resumeAfterCancelledTermination()
                player.videoAssets.resumeAfterCancelledTermination()
                player.liveASR.resumeAfterCancelledTermination()
                MetalRenderOwnership.resumeAfterCancelledTermination()
                MetalAppSmokeVerifier.resumeAfterCancelledTermination()
                _ = pip.cancelShutdownIfSafe()
                _ = InputController.shared.resumeVerificationWritesAfterCancelledTermination(environment: env)
                player.nativeAudioQueue.resumeAfterCanceledTermination()
                player.resumeVideoConfigurationAfterCancelledTermination(previouslyAccepting: wasAcceptingVideo)
                SubtitleAuthoringWindow.cancelAppTerminationReview()
                // The Web Core quit above is irreversible. Cancel the App
                // exit to preserve edits, but never claim that Core resumed.
                player.toast(webCoreUsed ? "字幕编辑状态已变化，退出已取消；播放已关闭，请重新打开媒体。"
                    : "字幕编辑状态已变化，本次退出已取消。")
                self.traceUserTermination("delegate-reply-false", values: ["reason": "subtitle-edit-permit-changed-after-finalization"])
                OrdinaryMediaOpenController.resumeAfterCancelledTermination()
                DirectoryLibraryController.resumeAfterCancelledTermination()
                FTPBrowserController.resumeAfterCancelledTermination()
                DirectoryLibraryWindow.resumeAfterCancelledTermination()
            FTPBrowserWindow.resumeAfterCancelledTermination()
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            self.traceUserTermination("delegate-reply-true")
            sender.reply(toApplicationShouldTerminate: true)
        }
        traceUserTermination("delegate-terminate-later")
        return .terminateLater
    }
}
