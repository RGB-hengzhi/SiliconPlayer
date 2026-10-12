import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation

private struct ThumbnailProcessResult: Sendable {
    let status: Int32
    let diagnostic: String
}

private final class ThumbnailProcess: @unchecked Sendable {
    let process = Process()
    let errors = Pipe()

    func start(executable: URL, arguments: [String], completion: @escaping @Sendable (ThumbnailProcessResult) -> Void) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        process.qualityOfService = .utility
        try process.run()
        DispatchQueue.global(qos: .utility).async {
            let data = self.errors.fileHandleForReading.readDataToEndOfFile()
            self.process.waitUntilExit()
            try? self.errors.fileHandleForReading.close()
            completion(ThumbnailProcessResult(status: self.process.terminationStatus,
                                              diagnostic: String(decoding: data.suffix(8192), as: UTF8.self)))
        }
    }
}

@MainActor
final class ThumbnailTools: ObservableObject {
    static let shared = ThumbnailTools()
    @Published private(set) var busy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var error: String?
    @Published private(set) var status = "查看视频时间点或生成缩略图拼图"
    @Published private(set) var generatingSheet = false
    @Published private(set) var lastOutput: URL?

    private var task: Task<Void, Never>?
    private var active: ThumbnailProcess?
    private var generation = UUID()
    private let imageCache = NSCache<NSString, NSImage>()
    private let cacheDirectory: URL

    private init() {
        cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SiliconPlayer/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        imageCache.countLimit = 36
        imageCache.totalCostLimit = 64 * 1024 * 1024
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "SiliconPlayer.Thumbnails", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func validate(_ source: URL) throws {
        guard source.isFileURL else { throw failure("缩略图仅处理本地文件。") }
        guard FileManager.default.fileExists(atPath: source.path) else { throw failure("媒体文件不存在。") }
    }

    private func key(source: URL, time: Double) throws -> String {
        let info = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let value = "720|\(source.standardizedFileURL.resolvingSymlinksInPath().path)|\(info.fileSize ?? 0)|\(info.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(String(format: "%.3f", time))"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func helper() throws -> URL {
        guard let directory = MediaTools.toolsDirectory else { throw failure("未找到 FFmpeg 缩略图工具。") }
        return directory.appendingPathComponent("ffmpeg")
    }

    private func interrupt() {
        task?.cancel()
        task = nil
        generation = UUID()
        if let current = active, current.process.isRunning {
            current.process.terminate()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if current.process.isRunning { Darwin.kill(current.process.processIdentifier, SIGKILL) }
            }
        }
        active = nil
    }

    func cancel() {
        interrupt()
        busy = false; generatingSheet = false; progress = 0; status = "已取消"
    }

    func frame(source: URL, time: Double, completion: @escaping (NSImage?) -> Void) {
        // A timeline hover must never abort a user's contact-sheet export.
        guard !generatingSheet else { completion(nil); return }
        interrupt()
        let id = generation
        error = nil; status = "正在读取视频画面"; busy = true; progress = 0
        task = Task {
            do {
                try self.validate(source)
                guard time.isFinite, time >= 0 else { throw self.failure("请输入有效的秒数。") }
                let cacheKey = try self.key(source: source, time: time)
                if let cached = self.imageCache.object(forKey: cacheKey as NSString) {
                    self.touchCache(cacheKey)
                    if self.generation == id { self.busy = false; self.progress = 1; self.status = "已读取缓存画面"; self.task = nil; completion(cached) }
                    return
                }
                let data = try await self.readFrame(source: source, time: time, id: id)
                try Task.checkCancellation()
                guard self.generation == id else { return }
                guard let image = NSImage(data: data) else { throw self.failure("无法读取缩略图。") }
                self.imageCache.setObject(image, forKey: cacheKey as NSString, cost: Int(image.size.width * image.size.height * 4))
                self.busy = false; self.progress = 1; self.status = "画面时间：\(Self.timeLabel(time))"; self.task = nil
                completion(image)
            } catch {
                if self.generation == id {
                    self.busy = false; self.task = nil
                    self.error = error.localizedDescription; self.status = "无法读取画面"; completion(nil)
                }
            }
        }
    }

    private func readFrame(source: URL, time: Double, id: UUID) async throws -> Data {
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
        let cacheKey = try key(source: source, time: time)
        let cached = cacheDirectory.appendingPathComponent(cacheKey + ".png")
        if let data = try? Data(contentsOf: cached), NSImage(data: data) != nil { touchCache(cacheKey); return data }
        let temporary = cacheDirectory.appendingPathComponent(".tmp-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let current = ThumbnailProcess()
        active = current
        let executable = try helper()
        let arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-ss", String(time), "-i", source.path,
                         "-map", "0:v:0", "-an", "-sn", "-frames:v", "1", "-vf", "scale=720:-2", "-c:v", "mjpeg", "-q:v", "2", "-update", "1", temporary.path]
        let result: ThumbnailProcessResult = try await withCheckedThrowingContinuation { continuation in
            do { try current.start(executable: executable, arguments: arguments) { continuation.resume(returning: $0) } }
            catch { continuation.resume(throwing: error) }
        }
        if active === current { active = nil }
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
        guard result.status == 0, let frameData = try? Data(contentsOf: temporary), !frameData.isEmpty else {
            throw failure("该时间点没有可读取的视频画面。\(result.diagnostic.isEmpty ? "" : "\n" + result.diagnostic)")
        }
        let data = try await Self.pngData(from: frameData)
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
        try data.write(to: cached, options: .atomic)
        trimCache()
        return data
    }

    nonisolated private static func pngData(from frame: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                if let bitmap = NSBitmapImageRep(data: frame), let png = bitmap.representation(using: .png, properties: [:]) {
                    continuation.resume(returning: png)
                } else {
                    continuation.resume(throwing: NSError(domain: "SiliconPlayer.Thumbnails", code: 5, userInfo: [NSLocalizedDescriptionKey: "无法转换预览画面。"] ))
                }
            }
        }
    }

    private func touchCache(_ key: String) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cacheDirectory.appendingPathComponent(key + ".png").path)
    }

    private func trimCache() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        var entries: [(URL, Int, Date)] = files.filter { $0.pathExtension == "png" }.map { url in
            let info = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, info?.fileSize ?? 0, info?.contentModificationDate ?? .distantPast)
        }
        entries.sort { $0.2 < $1.2 }
        var bytes = entries.reduce(0) { $0 + $1.1 }
        var remaining = entries.count
        for entry in entries where bytes > 64 * 1024 * 1024 || remaining > 128 {
            try? FileManager.default.removeItem(at: entry.0)
            bytes -= entry.1; remaining -= 1
        }
    }

    func generateContactSheet(source: URL, duration: Double, count: Int, columns: Int, width: Int, output: URL) {
        interrupt()
        let id = generation
        error = nil; progress = 0; busy = true; generatingSheet = true; status = "正在生成缩略图拼图"
        task = Task {
            var temporaryOutput: URL?
            defer {
                if let temporaryOutput { try? FileManager.default.removeItem(at: temporaryOutput) }
                if self.generation == id { self.busy = false; self.generatingSheet = false; self.task = nil; self.active = nil }
            }
            do {
                try self.validate(source)
                guard duration.isFinite, duration > 0, (1...60).contains(count), (1...10).contains(columns), columns <= count, (400...4096).contains(width) else {
                    throw self.failure("请使用有效片长、1–60 张、1–10 列与 400–4096 像素宽度。")
                }
                guard output.isFileURL, output.standardizedFileURL.resolvingSymlinksInPath() != source.standardizedFileURL.resolvingSymlinksInPath() else { throw self.failure("输出必须是与媒体不同的本地 PNG 文件。") }
                let geometry = try Self.geometry(count: count, columns: columns, width: width)
                var frames: [Data] = []
                var labels: [String] = []
                for index in 0..<count {
                    try Task.checkCancellation()
                    let time = duration * Double(index + 1) / Double(count + 1)
                    frames.append(try await self.readFrame(source: source, time: time, id: id))
                    labels.append(Self.timeLabel(time))
                    self.progress = Double(index + 1) / Double(count) * 0.9
                    self.status = "正在生成画面 \(index + 1) / \(count)"
                }
                let title = "\(source.lastPathComponent) · \(count) 帧 · \(Self.timeLabel(duration))"
                self.status = "正在排版与保存 PNG"
                let png = try await Self.renderSheet(frames: frames, labels: labels, title: title, geometry: geometry)
                try Task.checkCancellation()
                guard self.generation == id else { throw CancellationError() }
                let temporary = output.deletingLastPathComponent().appendingPathComponent(".siliconplayer-sheet-\(UUID().uuidString).png")
                temporaryOutput = temporary
                try png.write(to: temporary, options: .atomic)
                let result = temporary.path.withCString { from in output.path.withCString { to in Darwin.rename(from, to) } }
                guard result == 0 else { throw self.failure("无法保存 PNG：\(String(cString: strerror(errno)))") }
                self.lastOutput = output; self.progress = 1; self.status = "已保存 \(count) 张缩略图拼图"
            } catch {
                if self.generation == id {
                    if error is CancellationError { self.status = "已取消" }
                    else { self.error = error.localizedDescription; self.status = "生成失败" }
                }
            }
        }
    }

    private struct SheetGeometry: Sendable {
        let width: Int
        let height: Int
        let columns: Int
        let cellWidth: CGFloat
        let imageHeight: CGFloat
    }

    nonisolated private static func geometry(count: Int, columns: Int, width: Int) throws -> SheetGeometry {
        let cell = (CGFloat(width) - 40 - CGFloat(columns - 1) * 12) / CGFloat(columns)
        let imageHeight = floor(cell * 9 / 16)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let height = Int(76 + CGFloat(rows) * (imageHeight + 30 + 12) + 20)
        guard height <= 16384, width * height <= 50_000_000 else {
            throw NSError(domain: "SiliconPlayer.Thumbnails", code: 2, userInfo: [NSLocalizedDescriptionKey: "拼图尺寸过大，请增加列数、减小宽度或张数。"])
        }
        return SheetGeometry(width: width, height: height, columns: columns, cellWidth: cell, imageHeight: imageHeight)
    }

    nonisolated private static func renderSheet(frames: [Data], labels: [String], title: String, geometry g: SheetGeometry) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let result = try autoreleasepool { () throws -> Data in
                        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: g.width, pixelsHigh: g.height,
                                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                            throw NSError(domain: "SiliconPlayer.Thumbnails", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法创建拼图画布。"])
                        }
                        NSGraphicsContext.saveGraphicsState()
                        defer { NSGraphicsContext.restoreGraphicsState() }
                        NSGraphicsContext.current = context
                        NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
                        NSBezierPath(rect: NSRect(x: 0, y: 0, width: g.width, height: g.height)).fill()
                        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
                        let header: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
                        (title as NSString).draw(in: NSRect(x: 20, y: CGFloat(g.height) - 51, width: CGFloat(g.width) - 40, height: 28), withAttributes: header)
                        for (index, data) in frames.enumerated() {
                            guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { continue }
                            let row = index / g.columns, column = index % g.columns
                            let x = 20 + CGFloat(column) * (g.cellWidth + 12)
                            let y = CGFloat(g.height) - 76 - CGFloat(row + 1) * (g.imageHeight + 42) + 12
                            let imageRect = NSRect(x: x, y: y + 30, width: g.cellWidth, height: g.imageHeight)
                            NSColor.black.setFill(); NSBezierPath(rect: imageRect).fill()
                            let scale = min(imageRect.width / image.size.width, imageRect.height / image.size.height)
                            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                            image.draw(in: NSRect(x: imageRect.midX - size.width / 2, y: imageRect.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1)
                            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1)]
                            (labels[index] as NSString).draw(in: NSRect(x: x + 2, y: y + 6, width: g.cellWidth - 4, height: 22), withAttributes: attributes)
                        }
                        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "SiliconPlayer.Thumbnails", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法编码 PNG 拼图。"])
                        }
                        return png
                    }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    nonisolated static func timeLabel(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "00:00:00.000" }
        let milliseconds = Int((min(value, 359_999_999) * 1000).rounded())
        let seconds = milliseconds / 1000
        return String(format: "%02d:%02d:%02d.%03d", seconds / 3600, seconds / 60 % 60, seconds % 60, milliseconds % 1000)
    }
}
