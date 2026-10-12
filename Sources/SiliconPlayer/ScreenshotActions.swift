import AppKit
import CMPV
import PlayerCore
import UniformTypeIdentifiers
import ImageIO
import Darwin

extension PlayerModel {
    /// Only the private manual session uses its Owner-created output directory.
    /// Resolve from the exact report/storage binding, never from resettable preferences.
    /// This lookup performs no filesystem IO; normal launches retain their user defaults.
    static func privateManualScreenshotDirectory(environment: [String: String]) -> URL? {
        guard environment["SILICONPLAYER_VERIFY_MODE"] == "native-ui-manual",
              InputController.verificationSuiteName(environment: environment) != nil,
              let report = environment["SILICONPLAYER_VERIFY_REPORT"] else { return nil }
        return URL(fileURLWithPath: report).deletingLastPathComponent()
            .appendingPathComponent("owned-output", isDirectory: true)
            .appendingPathComponent("screenshots", isDirectory: true)
    }

    var selectedScreenshotDirectory: URL {
        if let owned = Self.privateManualScreenshotDirectory(environment: ProcessInfo.processInfo.environment) { return owned }
        let path = settings.screenshot.sanitized().directory
        return path.isEmpty ? Self.screenshotDirectory : URL(fileURLWithPath: path, isDirectory: true)
    }

    func chooseScreenshotDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择截图保存文件夹"; panel.canChooseDirectories = true
        panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = selectedScreenshotDirectory
        if panel.runModal() == .OK, let url = panel.url {
            updateSettings { $0.screenshot.directory = url.path }
        }
    }

    func screenshotSavePanel() {
        guard loaded && tracks.contains(where: { $0.type == "video" }) else { toast("请先打开视频"); return }
        let panel = NSSavePanel()
        let format = settings.sanitized().screenshotFormat
        panel.title = "截图另存为"; panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: format) ?? .png]
        panel.directoryURL = selectedScreenshotDirectory
        panel.nameFieldStringValue = ScreenshotPreferences.filename(title: playlist.currentItem?.title ?? "SiliconPlayer", format: format)
        if panel.runModal() == .OK, let url = panel.url { saveScreenshotAsync(to: url, allowReplacement: true) }
    }

    @discardableResult
    func saveScreenshotAsync(to destination: URL? = nil, mode: ScreenshotMode? = nil, allowReplacement: Bool = false,
                             completion: ((Result<URL, Error>) -> Void)? = nil) -> UInt64? {
        let preferences = settings.sanitized()
        // Unlike screenshotDirectory, resolving this URL performs no mkdir on
        // MainActor. Directory creation and all image/file work belong to IO.
        let directory = Self.privateManualScreenshotDirectory(environment: ProcessInfo.processInfo.environment)
            ?? (preferences.screenshot.directory.isEmpty
                ? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("SiliconPlayer", isDirectory: true)
                : URL(fileURLWithPath: preferences.screenshot.directory, isDirectory: true))
        let target = destination ?? directory.appendingPathComponent(ScreenshotPreferences.filename(title: playlist.currentItem?.title ?? "SiliconPlayer", format: preferences.screenshotFormat))
        return screenshotJobs.start(target: target, mode: mode ?? preferences.screenshot.mode,
                                    allowReplacement: allowReplacement, pasteboard: nil, completion: completion)
    }

    @discardableResult
    func copyScreenshotAsync(mode: ScreenshotMode? = nil, pasteboard: NSPasteboard = .general,
                             completion: ((Result<Void, Error>) -> Void)? = nil) -> UInt64? {
        screenshotJobs.start(target: nil, mode: mode ?? settings.screenshot.mode,
                             allowReplacement: false, pasteboard: pasteboard,
                             completion: { result in completion?(result.map { _ in () }) })
    }

    var pendingScreenshotCount: Int { screenshotJobs.pendingCount }
    var screenshotDiagnostics: [AsyncScreenshotDiagnostic] { screenshotJobs.diagnostics }
    func cancelScreenshotsForMediaChange() { screenshotJobs.cancel(reason: "媒体已切换，截图已取消") }
    func cancelScreenshotsForShutdown() { screenshotJobs.beginShutdown() }
    func shutdownScreenshots() async {
        screenshotJobs.beginShutdown()
        // screenshot-to-file in mpv 0.41 has no can_abort. Keep the renderer and
        // event loop alive until replies and IO cleanup, never delete a writer's
        // temporary directory early or block MainActor waiting for it.
        while pendingScreenshotCount > 0 { try? await Task.sleep(nanoseconds: 30_000_000) }
    }

    /// Synchronous compatibility path ONLY for the older opt-in verifier. All
    /// product entry points must use saveScreenshotAsync/copyScreenshotAsync.
    @discardableResult
    func saveScreenshot(to destination: URL? = nil, mode: ScreenshotMode? = nil, allowReplacement: Bool = false) -> URL? {
        guard ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_REPORT"] != nil else {
            error = "同步截图仅供旧验证器使用"; return nil
        }
        guard loaded && tracks.contains(where: { $0.type == "video" }) else { toast("请先打开视频"); return nil }
        let preferences = settings.sanitized()
        let target = destination ?? selectedScreenshotDirectory.appendingPathComponent(ScreenshotPreferences.filename(title: playlist.currentItem?.title ?? "SiliconPlayer", format: preferences.screenshotFormat))
        guard target.isFileURL, ["png", "jpg", "jpeg", "webp"].contains(target.pathExtension.lowercased()) else { error = "截图目标必须是本地 PNG、JPEG 或 WebP 文件"; return nil }
        do {
            if !allowReplacement && FileManager.default.fileExists(atPath: target.path) {
                throw NSError(domain: "SiliconPlayer.Screenshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "目标文件已存在，请另存为或选择其他位置"])
            }
            let data = try encodedScreenshot(mode: mode ?? preferences.screenshot.mode, format: target.pathExtension.lowercased())
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Never combine these flags. Exclusive creation also protects a
            // target created by another process while mpv was encoding.
            try data.write(to: target, options: allowReplacement ? .atomic : .withoutOverwriting)
            toast("截图已保存：\(target.lastPathComponent)")
            return target
        } catch { self.error = "截图失败：\(error.localizedDescription)"; return nil }
    }

    @discardableResult
    func copyScreenshot(mode: ScreenshotMode? = nil, pasteboard: NSPasteboard = .general) -> Bool {
        guard ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_REPORT"] != nil else {
            error = "同步截图仅供旧验证器使用"; return false
        }
        guard loaded && tracks.contains(where: { $0.type == "video" }) else { toast("请先打开视频"); return false }
        do {
            let data = try encodedScreenshot(mode: mode ?? settings.screenshot.mode, format: "png")
            guard let image = NSImage(data: data), let tiff = image.tiffRepresentation else {
                throw NSError(domain: "SiliconPlayer.Screenshot", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法读取截图图像"])
            }
            // Prepare both representations before clearing the clipboard.
            let item = NSPasteboardItem()
            item.setData(data, forType: .png); item.setData(tiff, forType: .tiff)
            pasteboard.clearContents()
            guard pasteboard.writeObjects([item]) else {
                throw NSError(domain: "SiliconPlayer.Screenshot", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法写入剪贴板"])
            }
            toast("截图已复制到剪贴板")
            return true
        } catch { self.error = "截图失败：\(error.localizedDescription)"; return false }
    }

    private func encodedScreenshot(mode: ScreenshotMode, format: String) throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SiliconPlayer-shot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("frame.\(format)")
        let status = executeCommand(["screenshot-to-file", output.path, mode.rawValue])
        guard status >= 0 else {
            throw NSError(domain: "SiliconPlayer.Screenshot", code: Int(status), userInfo: [NSLocalizedDescriptionKey: String(cString: mpv_error_string(status))])
        }
        let data = try Data(contentsOf: output)
        guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
}

struct AsyncScreenshotDiagnostic: Codable {
    let id: UInt64
    let mode: String
    let target: String?
    let requestedAt: Double
    var tempDirectory: String?
    var commandSubmittedAt: Double?
    var replyAt: Double?
    var replyStatus: Int32?
    var processingAt: Double?
    var completedAt: Double?
    var width: Int?
    var height: Int?
    var bitsPerComponent: Int?
    var imageIOOffMain = false
    var tempExistedAtReply = false
    var tempRemoved = false
    var published = false
    var publicationAtomic: Bool?
    var commitStartedAt: Double?
    var cancelled = false
    var failure: String?
}

private struct ScreenshotFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Only the commit syscall runs under this lock. Expensive staging, decoding,
/// encoding and fallback writes are outside it. A commit that started before
/// cancellation may finish; cancellation before commit never creates a target.
private final class ScreenshotPublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func publish<T>(_ action: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw ScreenshotFailure(message: "截图已取消") }
        return try action()
    }
}

private struct ScreenshotFilePublication {
    let atomic: Bool
    let startedAt: Double
}

/// An exclusive rename is atomic on APFS. exFAT returns ENOTSUP for
/// RENAME_EXCL, so it needs exclusive creation instead. The fallback never
/// overwrites, but the new file can be visible while bytes are being written.
/// No large IO occurs while holding the cancellation lock.
private func publishScreenshotFile(staged: URL, target: URL, replacement: Bool,
                                   gate: ScreenshotPublicationGate) throws -> ScreenshotFilePublication {
    enum Commit { case rename, create(Int32) }
    var startedAt = 0.0
    let commit: Commit = try gate.publish {
        startedAt = ProcessInfo.processInfo.systemUptime
        let renamed = staged.path.withCString { source in
            target.path.withCString { destination in
                replacement ? Darwin.rename(source, destination) : renamex_np(source, destination, UInt32(RENAME_EXCL))
            }
        }
        if renamed == 0 { return .rename }
        let failure = errno
        guard !replacement && failure == ENOTSUP else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure)) }
        let descriptor = target.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600)) }
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return .create(descriptor)
    }
    switch commit {
    case .rename: return ScreenshotFilePublication(atomic: true, startedAt: startedAt)
    case .create(let descriptor):
        var created = stat()
        let identified = fstat(descriptor, &created) == 0
        defer { _ = Darwin.close(descriptor) }
        do {
            let data = try Data(contentsOf: staged)
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { throw CocoaError(.fileReadCorruptFile) }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(count == 0 ? EIO : errno)) }
                    offset += count
                }
            }
            return ScreenshotFilePublication(atomic: false, startedAt: startedAt)
        } catch {
            // Never remove a different file that replaced our failed creation.
            var current = stat()
            if identified && target.path.withCString({ lstat($0, &current) }) == 0,
               current.st_dev == created.st_dev && current.st_ino == created.st_ino {
                _ = target.path.withCString { Darwin.unlink($0) }
            }
            throw error
        }
    }
}

private struct PreparedScreenshot {
    let output: URL
    let png: Data?
    let tiff: Data?
    let width: Int
    let height: Int
    let bits: Int
    let offMain: Bool
    let published: Bool
    let publication: ScreenshotFilePublication?
}

@MainActor
final class AsyncScreenshotJobs {
    private final class Job {
        let id: UInt64
        let generation: UUID
        let folder: URL
        let output: URL
        let target: URL?
        let mode: ScreenshotMode
        let replacement: Bool
        let pasteboard: NSPasteboard?
        let clipboardChangeCount: Int?
        let completion: ((Result<URL, Error>) -> Void)?
        let gate = ScreenshotPublicationGate()
        var trace: AsyncScreenshotDiagnostic
        var awaitingReply = false
        var finishing = false
        var timeout: Task<Void, Never>?
        init(id: UInt64, generation: UUID, target: URL?, mode: ScreenshotMode, replacement: Bool,
             pasteboard: NSPasteboard?, completion: ((Result<URL, Error>) -> Void)?) {
            self.id = id; self.generation = generation; self.target = target; self.mode = mode
            self.replacement = replacement; self.pasteboard = pasteboard; self.completion = completion
            clipboardChangeCount = pasteboard?.changeCount
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("SiliconPlayer-shot-\(UUID().uuidString)", isDirectory: true)
            output = folder.appendingPathComponent("frame.\(target?.pathExtension.lowercased() ?? "png")")
            trace = AsyncScreenshotDiagnostic(id: id, mode: mode.rawValue, target: target?.path, requestedAt: ProcessInfo.processInfo.systemUptime)
        }
    }
    private weak var player: PlayerModel?
    private let io = DispatchQueue(label: "local.siliconplayer.screenshot-io", qos: .utility)
    private var jobs: [UInt64: Job] = [:]
    private var history: [AsyncScreenshotDiagnostic] = []
    private var nextID: UInt64 = 0x5348_0000_0000_0000
    private var generation = UUID()
    private var shuttingDown = false
    init(player: PlayerModel) { self.player = player }
    var pendingCount: Int { jobs.count }
    var diagnostics: [AsyncScreenshotDiagnostic] { history + jobs.values.map(\.trace).sorted { $0.id < $1.id } }

    @discardableResult
    func start(target: URL?, mode: ScreenshotMode, allowReplacement: Bool, pasteboard: NSPasteboard?,
               completion: ((Result<URL, Error>) -> Void)?) -> UInt64? {
        guard let player else { return nil }
        func reject(_ message: String) -> UInt64? {
            let failure = ScreenshotFailure(message: message)
            player.screenshotStatus = "截图失败：\(message)"
            player.toast(player.screenshotStatus)
            completion?(.failure(failure)); return nil
        }
        guard !shuttingDown else { return reject("播放器正在退出") }
        guard player.loaded && player.tracks.contains(where: { $0.type == "video" }) else { return reject("请先打开视频") }
        guard jobs.isEmpty else {
            player.screenshotStatus = "上一张截图仍在处理"
            player.toast("上一张截图仍在处理")
            completion?(.failure(ScreenshotFailure(message: "上一张截图仍在处理")))
            return nil
        }
        if let target, !target.isFileURL || !["png", "jpg", "jpeg", "webp"].contains(target.pathExtension.lowercased()) {
            return reject("截图目标必须是本地 PNG、JPEG 或 WebP 文件")
        }
        nextID &+= 1
        let job = Job(id: nextID, generation: generation, target: target, mode: mode, replacement: allowReplacement, pasteboard: pasteboard, completion: completion)
        jobs[job.id] = job
        player.screenshotBusy = true; player.screenshotStatus = "正在处理截图…"
        let folder = job.folder, target = job.target, replacement = job.replacement, id = job.id
        io.async { [weak self] in
            let prepared: Result<Void, Error> = Result {
                if let target, !replacement && FileManager.default.fileExists(atPath: target.path) {
                    throw ScreenshotFailure(message: "目标文件已存在，请另存为或选择其他位置")
                }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            Task { @MainActor in self?.submit(id: id, preparation: prepared) }
        }
        return job.id
    }

    private func submit(id: UInt64, preparation: Result<Void, Error>) {
        guard let job = jobs[id], let player else { return }
        if case .failure(let failure) = preparation { finish(job, result: .failure(failure)); return }
        job.trace.tempDirectory = job.folder.path
        guard job.generation == generation && !job.gate.isCancelled && !shuttingDown else {
            finish(job, result: .failure(ScreenshotFailure(message: "截图已取消"))); return
        }
        job.awaitingReply = true
        job.trace.commandSubmittedAt = ProcessInfo.processInfo.systemUptime
        let result = player.executeAsyncCommand(["screenshot-to-file", job.output.path, job.mode.rawValue], replyID: id)
        if result < 0 {
            job.awaitingReply = false
            finish(job, result: .failure(ScreenshotFailure(message: String(cString: mpv_error_string(result)))))
            return
        }
        job.timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self, let current = self.jobs[id], current.awaitingReply else { return }
            // A timeout is logical cancellation, not acknowledgement that the
            // non-abortable writer stopped. Keep its job and directory alive.
            current.gate.cancel(); current.trace.cancelled = true
            current.trace.failure = "截图处理超时，正在等待后台完成"
            self.player?.screenshotStatus = "截图处理超时，正在等待后台完成"
            self.player?.toast("截图处理超时，正在等待后台完成")
        }
    }

    func commandReply(id: UInt64, status: Int32) {
        guard let job = jobs[id], job.awaitingReply else { return }
        job.awaitingReply = false; job.timeout?.cancel(); job.timeout = nil
        job.trace.replyAt = ProcessInfo.processInfo.systemUptime; job.trace.replyStatus = status
        // This existence check is for the opt-in diagnostics only, not decoding
        // or reading image bytes on MainActor.
        if ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_REPORT"] != nil {
            job.trace.tempExistedAtReply = FileManager.default.fileExists(atPath: job.folder.path)
        }
        guard status >= 0 else {
            finish(job, result: .failure(ScreenshotFailure(message: String(cString: mpv_error_string(status))))); return
        }
        guard job.generation == generation && !job.gate.isCancelled && !shuttingDown else {
            finish(job, result: .failure(ScreenshotFailure(message: "截图已取消"))); return
        }
        job.trace.processingAt = ProcessInfo.processInfo.systemUptime
        let output = job.output, target = job.target, replacement = job.replacement, gate = job.gate
        let copying = job.pasteboard != nil
        io.async { [weak self] in
            let result: Result<PreparedScreenshot, Error> = Result {
                guard !gate.isCancelled else { throw ScreenshotFailure(message: "截图已取消") }
                guard let source = CGImageSourceCreateWithURL(output as CFURL, nil),
                      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                      let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                      image.width > 0, image.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
                var png: Data?, tiff: Data?
                if copying {
                    png = try Data(contentsOf: output)
                    let buffer = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(buffer, UTType.tiff.identifier as CFString, 1, nil) else {
                        throw ScreenshotFailure(message: "无法创建 TIFF 图像")
                    }
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else { throw ScreenshotFailure(message: "无法编码 TIFF 图像") }
                    tiff = buffer as Data
                }
                var published = false
                var publication: ScreenshotFilePublication?
                if let target {
                    let parent = target.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    // Stage on the target volume: atomic rename cannot cross
                    // volumes, and our workspace may be exFAT.
                    let staged = parent.appendingPathComponent(".SiliconPlayer-shot-\(UUID().uuidString).tmp")
                    defer { try? FileManager.default.removeItem(at: staged) }
                    try FileManager.default.copyItem(at: output, to: staged)
                    publication = try publishScreenshotFile(staged: staged, target: target, replacement: replacement, gate: gate)
                    published = true
                }
                return PreparedScreenshot(output: target ?? output, png: png, tiff: tiff,
                                          width: image.width, height: image.height, bits: image.bitsPerComponent,
                                          offMain: !Thread.isMainThread, published: published, publication: publication)
            }
            Task { @MainActor in self?.processed(id: id, result: result) }
        }
    }

    private func processed(id: UInt64, result: Result<PreparedScreenshot, Error>) {
        guard let job = jobs[id] else { return }
        switch result {
        case .failure(let failure): finish(job, result: .failure(failure))
        case .success(let image):
            job.trace.width = image.width; job.trace.height = image.height; job.trace.bitsPerComponent = image.bits
            job.trace.imageIOOffMain = image.offMain; job.trace.published = image.published
            job.trace.publicationAtomic = image.publication?.atomic; job.trace.commitStartedAt = image.publication?.startedAt
            guard job.generation == generation && !job.gate.isCancelled && !shuttingDown else {
                finish(job, result: .failure(ScreenshotFailure(message: "截图已取消"))); return
            }
            if let pasteboard = job.pasteboard {
                guard pasteboard.changeCount == job.clipboardChangeCount else {
                    finish(job, result: .failure(ScreenshotFailure(message: "剪贴板已更新，取消复制截图"))); return
                }
                guard let png = image.png, let tiff = image.tiff else {
                    finish(job, result: .failure(CocoaError(.fileReadCorruptFile))); return
                }
                let item = NSPasteboardItem()
                item.setData(png, forType: .png); item.setData(tiff, forType: .tiff)
                pasteboard.clearContents()
                guard pasteboard.writeObjects([item]) else {
                    finish(job, result: .failure(ScreenshotFailure(message: "无法写入剪贴板"))); return
                }
                job.trace.published = true
            }
            finish(job, result: .success(image.output))
        }
    }

    private func finish(_ job: Job, result: Result<URL, Error>) {
        guard !job.finishing else { return }
        // Only reachable before command submission or AFTER its reply. Never
        // remove a folder merely because the request was cancelled/timed out.
        guard !job.awaitingReply else { return }
        job.finishing = true; job.timeout?.cancel(); job.timeout = nil
        if case .failure(let failure) = result { job.trace.failure = failure.localizedDescription }
        let folder = job.folder, id = job.id
        io.async { [weak self] in
            try? FileManager.default.removeItem(at: folder)
            let removed = !FileManager.default.fileExists(atPath: folder.path)
            Task { @MainActor in
                guard let self, let current = self.jobs.removeValue(forKey: id) else { return }
                current.trace.tempRemoved = removed; current.trace.completedAt = ProcessInfo.processInfo.systemUptime
                let cleanedResult: Result<URL, Error> = removed ? result : .failure(ScreenshotFailure(message: "临时截图文件清理失败"))
                if !removed { current.trace.failure = "临时截图文件清理失败" }
                self.history.append(current.trace); if self.history.count > 32 { self.history.removeFirst() }
                self.player?.screenshotBusy = !self.jobs.isEmpty
                if current.generation == self.generation && !current.gate.isCancelled && !self.shuttingDown {
                    switch cleanedResult {
                    case .success(let url):
                        self.player?.screenshotStatus = ""
                        self.player?.toast(current.pasteboard == nil ? "截图已保存：\(url.lastPathComponent)" : "截图已复制到剪贴板")
                    case .failure(let error):
                        // A screenshot is a background job. Presenting and
                        // immediately dismissing a SwiftUI/NSAlert sheet can
                        // block MainActor during its window animation. Keep
                        // this error visible without invoking the media alert.
                        let status = "截图失败：\(error.localizedDescription)"
                        self.player?.screenshotStatus = status
                        self.player?.toast(status)
                    }
                } else if self.jobs.isEmpty {
                    self.player?.screenshotStatus = self.shuttingDown ? "" : "截图已取消"
                }
                let currentResult = current.generation == self.generation && !current.gate.isCancelled && !self.shuttingDown
                    ? cleanedResult : .failure(ScreenshotFailure(message: "截图已取消"))
                current.completion?(currentResult)
            }
        }
    }

    func cancel(reason: String) {
        generation = UUID()
        for job in jobs.values where !job.finishing {
            job.gate.cancel(); job.trace.cancelled = true; job.trace.failure = reason
        }
        if !jobs.isEmpty { player?.screenshotStatus = "正在结束已取消截图…" }
    }
    func beginShutdown() { shuttingDown = true; cancel(reason: "播放器退出，截图已取消") }
}
