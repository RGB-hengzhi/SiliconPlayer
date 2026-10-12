import AppKit
import ImageIO
import PlayerCore

/// Opt-in real application checks. Uses the same async API as menus, toolbar
/// and shortcut actions; never calls the compatibility synchronous screenshot.
/// A RunLoop heartbeat measures MainActor scheduling, not physical UI latency.
@MainActor
final class AsyncScreenshotVerifier {
    private final class Ticket {
        let label: String
        let requestedAt = ProcessInfo.processInfo.systemUptime
        var id: UInt64?
        var result: Result<URL, Error>?
        var callSeconds = 0.0
        var maximumGap = 0.0
        var heartbeats = 0
        var finishedAt: Double?
        init(_ label: String) { self.label = label }
    }
    private struct CheckFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private let player: PlayerModel
    private let report: URL
    private let folder: URL
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var quitTimer: Timer?
    private var observer: NSObjectProtocol?
    private var measuring: Ticket?
    private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    private var rows: [[String: Any]] = []
    private var result: [String: Any]?
    private var firstURL: URL?
    private var quitTicket: Ticket?
    private var quitRequestedAt: Double?
    private var quitBeforeReply = false
    private var quitTempPresent = false
    private var quitTarget: URL?
    private var quitFromSwiftTask: Bool?
    private let heartbeatLimit = 0.100

    init(player: PlayerModel, report: URL) {
        self.player = player; self.report = report
        folder = report.deletingPathExtension().appendingPathExtension("images")
    }

    func tick() -> [String: Any]? {
        if let result { return result }
        guard task == nil else { return nil }
        let timer = Timer(timeInterval: 0.010, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.heartbeat() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.run()
                self.finish(nil)
            } catch { self.finish(error.localizedDescription) }
        }
        return nil
    }

    private func heartbeat() {
        let now = ProcessInfo.processInfo.systemUptime
        if let measuring {
            measuring.maximumGap = max(measuring.maximumGap, now - lastHeartbeat)
            if player.pendingScreenshotCount > 0 { measuring.heartbeats += 1 }
        }
        lastHeartbeat = now
    }

    private func require(_ value: Bool, _ message: String) throws {
        if !value { throw CheckFailure(message: message) }
    }
    private func wait(seconds: Double = 25, until predicate: () -> Bool) async throws {
        let limit = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate() {
            try require(ProcessInfo.processInfo.systemUptime < limit, "Timed out waiting for async screenshot state")
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    private func start(_ label: String, target: URL? = nil, mode: ScreenshotMode = .video,
                       replacement: Bool = false, pasteboard: NSPasteboard? = nil) -> Ticket {
        let ticket = Ticket(label)
        measuring = ticket; lastHeartbeat = ProcessInfo.processInfo.systemUptime
        let start = lastHeartbeat
        if let pasteboard {
            ticket.id = player.copyScreenshotAsync(mode: mode, pasteboard: pasteboard) { [weak self] outcome in
                ticket.result = outcome.map { _ in self?.folder ?? FileManager.default.temporaryDirectory }
                self?.completeMeasurement(ticket)
            }
        } else {
            ticket.id = player.saveScreenshotAsync(to: target, mode: mode, allowReplacement: replacement) { [weak self] outcome in
                ticket.result = outcome; self?.completeMeasurement(ticket)
            }
        }
        ticket.callSeconds = ProcessInfo.processInfo.systemUptime - start
        return ticket
    }
    private func completeMeasurement(_ ticket: Ticket) {
        let now = ProcessInfo.processInfo.systemUptime
        ticket.maximumGap = max(ticket.maximumGap, now - lastHeartbeat)
        ticket.finishedAt = now
        if measuring === ticket { measuring = nil }
    }
    private func trace(_ ticket: Ticket) -> AsyncScreenshotDiagnostic? {
        guard let id = ticket.id else { return nil }
        return player.screenshotDiagnostics.first { $0.id == id }
    }
    private func completed(_ ticket: Ticket, success: Bool) async throws -> AsyncScreenshotDiagnostic {
        try require(ticket.id != nil, "\(ticket.label): request rejected")
        try await wait { ticket.result != nil }
        guard let outcome = ticket.result, let diagnostic = trace(ticket) else {
            throw CheckFailure(message: "\(ticket.label): missing reply/completion diagnostic")
        }
        switch outcome {
        case .success: try require(success, "\(ticket.label): unexpectedly published")
        case .failure(let error):
            try require(!success, "\(ticket.label): \(error.localizedDescription)")
        }
        try require(diagnostic.tempRemoved && player.pendingScreenshotCount == 0 && !player.screenshotBusy,
                    "\(ticket.label): job or temporary files survived completion")
        if diagnostic.commandSubmittedAt != nil {
            try require(diagnostic.replyAt != nil && diagnostic.tempExistedAtReply,
                        "\(ticket.label): cleanup occurred before actual COMMAND_REPLY")
        }
        try require(ticket.callSeconds <= heartbeatLimit && ticket.maximumGap <= heartbeatLimit,
                    "\(ticket.label): MainActor exceeded 100 ms (call \(ticket.callSeconds), gap \(ticket.maximumGap))")
        if success {
            try require(diagnostic.replyStatus == 0 && diagnostic.imageIOOffMain && diagnostic.published,
                        "\(ticket.label): no real successful reply/background decode/publication")
            try require(player.error == nil, "\(ticket.label): unexpected player error: \(player.error ?? "")")
        }
        let encoded = try JSONEncoder().encode(diagnostic)
        var row = (try JSONSerialization.jsonObject(with: encoded) as? [String: Any]) ?? [:]
        row["name"] = ticket.label; row["passed"] = true
        row["apiCallSeconds"] = ticket.callSeconds; row["maxMainActorGapSeconds"] = ticket.maximumGap
        row["heartbeatsWhilePending"] = ticket.heartbeats
        row["expectedSuccess"] = success
        rows.append(row)
        if !success { player.error = nil } // Expected failures were recorded above.
        return diagnostic
    }
    /// Deliberately intervenes AFTER submission and BEFORE processing its reply.
    /// Do not turn a too-fast operation into a pass: record failure if there is
    /// no observable window for the requested race/cancellation scenario.
    private func pendingReply(_ ticket: Ticket) async throws -> AsyncScreenshotDiagnostic {
        try await wait(seconds: 10) { self.trace(ticket)?.commandSubmittedAt != nil || ticket.result != nil }
        guard let diagnostic = trace(ticket), diagnostic.commandSubmittedAt != nil,
              diagnostic.replyAt == nil, ticket.result == nil, let path = diagnostic.tempDirectory else {
            throw CheckFailure(message: "\(ticket.label): no pending COMMAND_REPLY window; use a slower 4K PNG fixture")
        }
        try require(FileManager.default.fileExists(atPath: path), "\(ticket.label): writer directory missing before reply")
        return diagnostic
    }
    private func pausedMedia(_ url: URL? = nil) async throws {
        if let url { try await player.openAndWaitForCommit([url]) }
        try await wait { self.player.loaded && self.player.tracks.contains { $0.type == "video" } }
        player.set("pause", "yes"); player.setSpeed(1); player.seek(min(2, player.duration / 2), remember: false)
        try await wait { !self.player.flag("seeking") && !self.player.isLoading }
        // Permit the render queue to present the paused seek frame. This is not
        // included in the screenshot MainActor responsiveness measurement.
        try await Task.sleep(nanoseconds: 400_000_000)
        player.error = nil
    }

    private func run() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await pausedMedia()
        firstURL = player.playlist.currentItem?.url
        try require(firstURL != nil, "Missing fixture URL")
        player.settings.screenshotFormat = "png"
        player.applySettings(); player.set("screenshot-high-bit-depth", "yes")
        if ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_ASYNC_QUIT"] == "1" {
            try await verifyActualQuit(); return
        }

        let video = folder.appendingPathComponent("4k-video.png")
        let main = start("4k-png", target: video)
        try require(player.screenshotBusy, "Busy state was not set synchronously")
        var busyFailure = false
        let rejected = player.saveScreenshotAsync(to: folder.appendingPathComponent("busy-rejected.png")) { outcome in
            if case .failure = outcome { busyFailure = true }
        }
        try require(rejected == nil && busyFailure && player.screenshotBusy, "Busy rejection failed to complete safely")
        let mainTrace = try await completed(main, success: true)
        try require((mainTrace.width ?? 0) >= 3840 && (mainTrace.height ?? 0) >= 2160 && (mainTrace.bitsPerComponent ?? 0) > 8,
                    "4K 10-bit input did not produce a high bit depth 4K PNG")
        try require(main.heartbeats > 0, "No MainActor heartbeat ran during 4K PNG processing")
        rows[rows.count - 1]["busyRejectionCompleted"] = true

        for (name, mode, ext) in [("subtitles", ScreenshotMode.subtitles, "png"), ("window", .window, "png"), ("jpeg", .video, "jpg"), ("webp", .video, "webp")] {
            _ = try await completed(start(name, target: folder.appendingPathComponent("\(name).\(ext)"), mode: mode), success: true)
        }

        let board = NSPasteboard(name: NSPasteboard.Name("SiliconPlayer.AsyncVerification.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("before-copy", forType: .string)
        let copying = start("copy-png-tiff", pasteboard: board)
        _ = try await completed(copying, success: true)
        // Bytes and the TIFF have already been fully decoded/encoded on the IO
        // queue; parsing clipboard data here is unnecessary large MainActor IO.
        try require(board.availableType(from: [.png]) == .png && board.availableType(from: [.tiff]) == .tiff,
                    "Copy did not publish both PNG and TIFF")
        guard let copiedPNG = board.data(forType: .png), let copiedTIFF = board.data(forType: .tiff) else {
            throw CheckFailure(message: "Clipboard representations have no bytes")
        }
        let clipboardDecoded = await Task.detached(priority: .utility) {
            [copiedPNG, copiedTIFF].allSatisfy { data in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return false }
                return image.width >= 3840 && image.height >= 2160 && !Thread.isMainThread
            }
        }.value
        try require(clipboardDecoded, "Published clipboard PNG/TIFF failed background full decode")
        rows[rows.count - 1]["clipboardPNGAndTIFFDecoded"] = true

        let protected = folder.appendingPathComponent("protected.png"), sentinel = Data("external-owner-content".utf8)
        try sentinel.write(to: protected)
        _ = try await completed(start("existing-target", target: protected), success: false)
        try require(try Data(contentsOf: protected) == sentinel, "Existing destination changed")
        _ = try await completed(start("approved-replacement", target: protected, replacement: true), success: true)
        try require(try Data(contentsOf: protected) != sentinel, "Approved replacement did not occur")

        let raced = folder.appendingPathComponent("concurrent-created.png")
        let race = start("created-before-command-reply", target: raced)
        _ = try await pendingReply(race)
        let intervenedAt = ProcessInfo.processInfo.systemUptime
        try sentinel.write(to: raced, options: .withoutOverwriting)
        let raceTrace = try await completed(race, success: false)
        try require(raceTrace.replyStatus == 0, "Same-name race failed before valid Core encoding")
        try require((raceTrace.commandSubmittedAt ?? .infinity) < intervenedAt && intervenedAt < (raceTrace.replyAt ?? 0),
                    "Target race did not occur between submission and reply")
        try require(try Data(contentsOf: raced) == sentinel && !raceTrace.published, "Concurrent destination was overwritten")
        rows[rows.count - 1]["intervenedAt"] = intervenedAt

        let parent = folder.appendingPathComponent("blocked-parent")
        try sentinel.write(to: parent)
        let failedWrite = try await completed(start("write-failure", target: parent.appendingPathComponent("frame.png")), success: false)
        try require(failedWrite.replyStatus == 0, "Write-failure case failed before valid Core encoding")
        try require(try Data(contentsOf: parent) == sentinel, "Failed write changed parent")

        let stoppedTarget = folder.appendingPathComponent("cancelled-stop.png")
        let stopped = start("stop-before-reply", target: stoppedTarget)
        _ = try await pendingReply(stopped)
        let stopping = ProcessInfo.processInfo.systemUptime
        player.stopPlayback()
        let stopSeconds = ProcessInfo.processInfo.systemUptime - stopping
        let stoppedTrace = try await completed(stopped, success: false)
        try require(stoppedTrace.cancelled && !stoppedTrace.published && !FileManager.default.fileExists(atPath: stoppedTarget.path), "Stop published stale screenshot")
        try require(stopSeconds <= heartbeatLimit, "Stop cancellation blocked MainActor")
        rows[rows.count - 1]["cancelCallSeconds"] = stopSeconds
        try await pausedMedia(firstURL)

        guard let nextPath = ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_SECOND"] else { throw CheckFailure(message: "Missing media-switch fixture") }
        let nextURL = URL(fileURLWithPath: nextPath)
        let switchedTarget = folder.appendingPathComponent("cancelled-switch.png")
        let switched = start("switch-save-before-reply", target: switchedTarget)
        _ = try await pendingReply(switched)
        try await player.openAndWaitForCommit([nextURL])
        let switchedTrace = try await completed(switched, success: false)
        try require(switchedTrace.cancelled && !switchedTrace.published && !FileManager.default.fileExists(atPath: switchedTarget.path), "Media switch published old destination")
        try await pausedMedia(firstURL)

        board.clearContents(); board.setString("switch-copy-sentinel", forType: .string)
        let copySwitch = start("switch-copy-before-reply", pasteboard: board)
        _ = try await pendingReply(copySwitch)
        try await player.openAndWaitForCommit([nextURL])
        let copySwitchTrace = try await completed(copySwitch, success: false)
        try require(copySwitchTrace.cancelled && !copySwitchTrace.published && board.string(forType: .string) == "switch-copy-sentinel", "Media switch changed clipboard")
        try await pausedMedia(firstURL)

        board.clearContents(); board.setString("old-clipboard", forType: .string)
        let changed = start("newer-clipboard-preserved", pasteboard: board)
        _ = try await pendingReply(changed)
        board.clearContents(); board.setString("new-user-clipboard", forType: .string)
        _ = try await completed(changed, success: false)
        try require(board.string(forType: .string) == "new-user-clipboard", "Screenshot overwrote newer clipboard contents")

        let shutdownTarget = folder.appendingPathComponent("cancelled-shutdown.png")
        let shutting = start("shutdown-waits-for-reply", target: shutdownTarget)
        _ = try await pendingReply(shutting)
        var shutdownComplete = false
        let cleanup = Task { @MainActor in await self.player.shutdownScreenshots(); shutdownComplete = true }
        await Task.yield()
        let outstanding = trace(shutting)
        try require(outstanding?.cancelled == true, "Shutdown did not logically cancel")
        if outstanding?.replyAt == nil {
            try require(!shutdownComplete && player.pendingScreenshotCount > 0, "Shutdown returned before real reply")
            try require(FileManager.default.fileExists(atPath: outstanding?.tempDirectory ?? ""), "Shutdown deleted active writer directory")
        }
        let shutdownTrace = try await completed(shutting, success: false)
        await cleanup.value
        try require(shutdownComplete && shutdownTrace.cancelled && !shutdownTrace.published && !FileManager.default.fileExists(atPath: shutdownTarget.path), "Shutdown left stale output")
    }

    /// A separate script run requests actual NSApplication termination while
    /// mpv is still encoding. AppDelegate must return terminateLater, keep
    /// polling replies, await cleanup, then deliver willTerminate. This observer
    /// reports the result at that final notification, not a mock quit event.
    private func verifyActualQuit() async throws {
        let target = folder.appendingPathComponent("cancelled-actual-quit.png")
        let ticket = start("actual-app-quit-before-reply", target: target)
        _ = try await pendingReply(ticket)
        quitTicket = ticket; quitTarget = target
        // NSApplication termination may enter a nested AppKit run loop. Calling
        // it from a running cooperative MainActor Task can retain that executor
        // job and prevent the shutdown/reply Tasks from running. Model the real
        // AppKit Cmd-Q entry instead, then yield this async job before it fires.
        let quitTimer = Timer(timeInterval: 0.001, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestActualQuitFromRunLoop() }
        }
        self.quitTimer = quitTimer; RunLoop.main.add(quitTimer, forMode: .common)
        try await wait(seconds: 45) { self.result != nil }
    }
    private func requestActualQuitFromRunLoop() {
        quitTimer = nil
        guard let ticket = quitTicket, let pending = trace(ticket), pending.commandSubmittedAt != nil,
              pending.replyAt == nil, ticket.result == nil, player.pendingScreenshotCount > 0 else {
            finish("Actual quit timer missed the pending COMMAND_REPLY window; use a slower 4K PNG fixture")
            return
        }
        quitFromSwiftTask = withUnsafeCurrentTask { $0 != nil }
        guard quitFromSwiftTask == false else {
            finish("Actual quit timer unexpectedly ran inside a cooperative Swift Task")
            return
        }
        quitBeforeReply = true
        quitTempPresent = FileManager.default.fileExists(atPath: pending.tempDirectory ?? "")
        guard quitTempPresent else { finish("Actual quit writer directory disappeared before reply"); return }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeQuitReport() }
        }
        quitRequestedAt = ProcessInfo.processInfo.systemUptime
        NSApp.terminate(nil)
    }
    private func writeQuitReport() {
        guard let ticket = quitTicket else { return }
        heartbeat(); timer?.invalidate(); timer = nil
        let diagnostic = trace(ticket)
        let failure: String?
        if !quitBeforeReply || !quitTempPresent { failure = "Quit did not begin with a pending writer" }
        else if player.pendingScreenshotCount != 0 || player.screenshotBusy { failure = "Actual app quit preceded screenshot cleanup" }
        else if diagnostic?.replyAt == nil || diagnostic?.replyStatus != 0 || diagnostic?.tempExistedAtReply != true || diagnostic?.tempRemoved != true || diagnostic?.cancelled != true || diagnostic?.published != false { failure = "Actual quit lacked successful real reply/cancellation/temp-cleanup evidence" }
        else if FileManager.default.fileExists(atPath: quitTarget?.path ?? "") { failure = "Actual quit published cancelled target" }
        else if ticket.maximumGap > heartbeatLimit || ticket.callSeconds > heartbeatLimit { failure = "Actual quit blocked MainActor beyond 100 ms" }
        else { failure = nil }
        var values = summary(failure)
        values["actualApplicationTermination"] = true
        values["quitInitiatedFromAppKitRunLoop"] = quitFromSwiftTask == false
        values["quitInitiatedFromSwiftTask"] = quitFromSwiftTask
        values["quitBeganBeforeReply"] = quitBeforeReply; values["tempPresentAtQuitRequest"] = quitTempPresent
        values["quitRequestedAt"] = quitRequestedAt; values["willTerminateAt"] = ProcessInfo.processInfo.systemUptime
        values["apiCallSeconds"] = ticket.callSeconds; values["maxMainActorGapSeconds"] = ticket.maximumGap
        result = values
        do { try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]).write(to: report, options: .atomic) }
        catch { NSLog("Async quit verification report failed: %@", error.localizedDescription) }
    }
    private func summary(_ failure: String?) -> [String: Any] {
        let diagnostics: Any
        if let data = try? JSONEncoder().encode(player.screenshotDiagnostics), let object = try? JSONSerialization.jsonObject(with: data) { diagnostics = object }
        else { diagnostics = [] }
        var values: [String: Any] = [
            "mode": "async-screenshots", "asyncScreenshotPassed": failure == nil,
            "asyncScreenshotChecks": rows, "asyncScreenshotDiagnostics": diagnostics,
            "heartbeatIntervalSeconds": 0.010, "mainActorGapLimitSeconds": heartbeatLimit,
            "pendingScreenshots": player.pendingScreenshotCount, "screenshotBusy": player.screenshotBusy,
            "scope": "Real mpv COMMAND_REPLY and ImageIO decode; MainActor scheduling heartbeat, not physical UI responsiveness or HDR display certification"
        ]
        if let failure { values["failure"] = failure }
        return values
    }
    private func finish(_ failure: String?) {
        guard result == nil else { return }
        quitTimer?.invalidate(); quitTimer = nil
        heartbeat(); timer?.invalidate(); timer = nil
        if failure != nil { player.cancelScreenshotsForMediaChange() }
        result = summary(failure)
    }
}
