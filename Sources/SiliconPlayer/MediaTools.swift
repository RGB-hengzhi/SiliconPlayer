import AppKit
import Combine
import Darwin
import Foundation

private struct ToolResult: Sendable {
    let code: Int32
    let stderr: String
}

// Pipes are drained on background queues, so neither a verbose helper nor a
// long recording can fill a pipe and block the main actor.
private final class ToolSession: @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    private let lock = NSLock()
    private var diagnostics = Data()

    func appendError(_ data: Data) {
        lock.lock()
        diagnostics.append(data)
        if diagnostics.count > 128 * 1024 { diagnostics.removeFirst(diagnostics.count - 128 * 1024) }
        lock.unlock()
    }
    func errorText() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: diagnostics, as: UTF8.self)
    }

    func collect(onLine: @escaping @Sendable (String) -> Void, completion: @escaping @Sendable (ToolResult) -> Void) {
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            var pending = ""
            while true {
                let data = self.output.fileHandleForReading.readData(ofLength: 4096)
                if data.isEmpty { break }
                pending += String(decoding: data, as: UTF8.self)
                // FFmpeg's machine-readable progress and Whisper's console output.
                while let boundary = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                    let line = String(pending[..<boundary])
                    pending.removeSubrange(...boundary)
                    onLine(line)
                }
                if pending.count > 32 * 1024 { pending = String(pending.suffix(4096)) }
            }
            if !pending.isEmpty { onLine(pending) }
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = self.errors.fileHandleForReading.readData(ofLength: 4096)
                if data.isEmpty { break }
                self.appendError(data)
                let text = String(decoding: data, as: UTF8.self)
                for line in text.components(separatedBy: .newlines) where line.contains("progress") { onLine(line) }
            }
            readers.leave()
        }
        DispatchQueue.global(qos: .utility).async {
            self.process.waitUntilExit()
            readers.wait()
            try? self.input.fileHandleForWriting.close()
            try? self.output.fileHandleForReading.close()
            try? self.errors.fileHandleForReading.close()
            completion(ToolResult(code: self.process.terminationStatus, stderr: self.errorText()))
        }
    }
}

@MainActor
final class MediaTools: ObservableObject {
    static let shared = MediaTools()
    @Published private(set) var busy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "准备导出、录制或生成字幕"
    @Published private(set) var error: String?
    @Published private(set) var isRecording = false
    @Published private(set) var lastOutput: URL?
    private(set) var lastSubtitleSource: URL?
    var onSubtitlesReady: ((URL) -> Void)?

    private var session: ToolSession?
    private var job: Task<Void, Never>?
    private var generation = UUID()
    private var stopRequested = false
    private var cancelled = false

    static var toolsDirectory: URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Tools", isDirectory: true)
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor/tools", isDirectory: true)
        return [bundled, development].compactMap { $0 }.first {
            FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("ffmpeg").path)
        }
    }

    private func helper(_ name: String) throws -> URL {
        guard let directory = Self.toolsDirectory else { throw failure("未找到媒体工具，请先运行 scripts/bootstrap_media_tools.py 并重新打包应用。") }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw failure("缺少 \(name) 工具。") }
        return url
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "SiliconPlayer.MediaTools", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func input(_ url: URL) throws -> String {
        if url.isFileURL {
            guard FileManager.default.fileExists(atPath: url.path) else { throw failure("媒体文件不存在。") }
            return url.path
        }
        guard ["https", "http", "rtsp", "rtsps", "rtmp"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw failure("请选择本地媒体或有效的 HTTP / HTTPS / RTSP / RTMP 直接媒体地址。")
        }
        return url.absoluteString
    }

    private func workFile(output: URL, source: URL) throws -> URL {
        guard output.isFileURL, !source.isFileURL || output.standardizedFileURL.resolvingSymlinksInPath() != source.standardizedFileURL.resolvingSymlinksInPath() else { throw failure("输出文件必须与源媒体不同。") }
        guard FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path) else { throw failure("输出目录不存在。") }
        let ext = output.pathExtension.isEmpty ? "mkv" : output.pathExtension
        return output.deletingLastPathComponent().appendingPathComponent(".siliconplayer-\(UUID().uuidString).\(ext)")
    }

    private func publish(_ temporary: URL, to output: URL) throws {
        let info = try temporary.resourceValues(forKeys: [.fileSizeKey])
        guard (info.fileSize ?? 0) > 0 else { throw failure("工具未生成有效文件。") }
        // A same-directory rename publishes only a completed result and replaces
        // an existing destination atomically, including on the external volume.
        let result = temporary.path.withCString { from in
            output.path.withCString { to in Darwin.rename(from, to) }
        }
        if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "无法保存生成文件：\(String(cString: strerror(errno)))"]) }
        lastOutput = output
    }

    private func start(_ title: String, recording: Bool = false, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        generation = UUID()
        let id = generation
        busy = true; progress = 0; status = title; error = nil
        isRecording = recording; stopRequested = false; cancelled = false
        job = Task {
            do {
                try await operation()
                try Task.checkCancellation()
                if self.generation == id {
                    self.progress = 1
                    self.status = recording ? "录制已保存" : "处理完成"
                }
            } catch {
                if self.generation == id {
                    if self.cancelled || error is CancellationError { self.status = "已取消" }
                    else { self.error = error.localizedDescription; self.status = "处理失败" }
                }
            }
            if self.generation == id { self.busy = false; self.isRecording = false; self.session = nil; self.job = nil }
        }
    }

    private func run(_ name: String, arguments: [String], duration: Double? = nil, base: Double = 0, weight: Double = 1) async throws {
        try Task.checkCancellation()
        let current = ToolSession()
        current.process.executableURL = try helper(name)
        current.process.arguments = arguments
        current.process.standardInput = current.input
        current.process.standardOutput = current.output
        current.process.standardError = current.errors
        current.process.qualityOfService = .utility
        session = current
        let id = generation
        try current.process.run()
        if isRecording && stopRequested { try? current.input.fileHandleForWriting.write(contentsOf: Data("q\n".utf8)) }
        let result: ToolResult = await withCheckedContinuation { continuation in
            current.collect(onLine: { [weak self] line in
                Task { @MainActor in
                    guard let self, self.generation == id, self.busy else { return }
                    if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst("out_time_us=".count)) {
                        let seconds = max(0, us / 1_000_000)
                        if let duration, duration > 0 { self.progress = min(base + weight * 0.99, base + weight * seconds / duration) }
                        else if self.isRecording && !self.stopRequested { self.status = String(format: "正在录制 · %.1f 秒", seconds) }
                    } else if line.contains("progress"), let percent = Self.percent(in: line) {
                        self.progress = min(0.99, base + weight * percent / 100)
                    }
                }
            }, completion: { result in continuation.resume(returning: result) })
        }
        if session === current { session = nil }
        try Task.checkCancellation()
        guard result.code == 0 else {
            let diagnostic = result.stderr.split(separator: "\n").suffix(10).joined(separator: "\n")
            throw failure("\(name) 处理失败（\(result.code)）\(diagnostic.isEmpty ? "" : "：\n" + diagnostic)")
        }
        progress = max(progress, min(0.99, base + weight))
    }

    private static func percent(in line: String) -> Double? {
        guard let percent = line.firstIndex(of: "%") else { return nil }
        let prefix = line[..<percent]
        let digits = prefix.reversed().prefix(while: { $0.isNumber || $0 == "." }).reversed()
        return Double(String(digits))
    }

    func exportClip(source: URL, start: Double, end: Double, output: URL, transcode: Bool) {
        self.start(transcode ? "正在精确导出片段" : "正在按关键帧导出片段") {
            guard start.isFinite, end.isFinite, start >= 0, end > start else { throw self.failure("请输入有效区间，结束时间必须大于开始时间。") }
            let path = try self.input(source)
            let temporary = try self.workFile(output: output, source: source)
            defer { try? FileManager.default.removeItem(at: temporary) }
            var args = ["-hide_banner", "-loglevel", "error", "-y", "-progress", "pipe:1", "-nostats", "-ss", String(start), "-i", path, "-t", String(end - start)]
            if transcode { args += ["-c:v", "h264_videotoolbox", "-b:v", "8M", "-c:a", "aac", "-b:a", "192k"] }
            else { args += ["-map", "0:v?", "-map", "0:a?", "-c", "copy", "-avoid_negative_ts", "make_zero"] }
            if ["mp4", "mov", "m4v"].contains(output.pathExtension.lowercased()) { args += ["-movflags", "+faststart"] }
            args.append(temporary.path)
            try await self.run("ffmpeg", arguments: args, duration: end - start)
            try self.publish(temporary, to: output)
        }
    }

    func extractAudio(source: URL, output: URL) {
        self.start("正在导出音频") {
            let path = try self.input(source)
            let temporary = try self.workFile(output: output, source: source)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await self.run("ffmpeg", arguments: ["-hide_banner", "-loglevel", "error", "-y", "-progress", "pipe:1", "-nostats", "-i", path, "-vn", "-c:a", "pcm_s16le", "-f", "wav", temporary.path])
            try self.publish(temporary, to: output)
        }
    }

    func recordStream(source: URL, output: URL) {
        self.start("正在连接录制源", recording: true) {
            let path = try self.input(source)
            let temporary = try self.workFile(output: output, source: source)
            defer { try? FileManager.default.removeItem(at: temporary) }
            var args = ["-hide_banner", "-loglevel", "error", "-y", "-progress", "pipe:1", "-nostats"]
            if source.isFileURL { args += ["-re"] }
            args += ["-i", path, "-map", "0:v?", "-map", "0:a?", "-c", "copy", temporary.path]
            try await self.run("ffmpeg", arguments: args)
            try self.publish(temporary, to: output)
        }
    }

    func generateSubtitles(source: URL, output: URL, language: String) {
        self.start("正在为离线字幕提取声音") {
            let path = try self.input(source)
            guard ["auto", "zh", "en", "ja", "ko", "fr", "de", "es", "ru"].contains(language) else { throw self.failure("暂不支持所选识别语言。") }
            guard let directory = Self.toolsDirectory else { throw self.failure("未找到字幕识别工具。") }
            let model = directory.appendingPathComponent("ggml-base.bin")
            guard FileManager.default.fileExists(atPath: model.path) else { throw self.failure("未找到 base 多语言识别模型。") }
            let temporaryOutput = try self.workFile(output: output, source: source)
            let working = FileManager.default.temporaryDirectory.appendingPathComponent("SiliconPlayer-ASR-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: working); try? FileManager.default.removeItem(at: temporaryOutput) }
            let wav = working.appendingPathComponent("audio.wav")
            let prefix = working.appendingPathComponent("subtitles")
            try await self.run("ffmpeg", arguments: ["-hide_banner", "-loglevel", "error", "-y", "-progress", "pipe:1", "-nostats", "-i", path, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav.path], base: 0, weight: 0.15)
            self.status = "正在识别字幕 · base 多语言模型（CPU / Accelerate）"
            try await self.run("whisper-cli", arguments: ["-m", model.path, "-f", wav.path, "-l", language, "-t", "4", "-ng", "-osrt", "-pp", "-of", prefix.path], base: 0.15, weight: 0.85)
            let srt = prefix.appendingPathExtension("srt")
            let contents = try String(contentsOf: srt, encoding: .utf8)
            guard contents.contains("-->") else { throw self.failure("识别完成，但未检测到可保存的语音字幕。") }
            try FileManager.default.copyItem(at: srt, to: temporaryOutput)
            try self.publish(temporaryOutput, to: output)
            self.lastSubtitleSource = source
            self.onSubtitlesReady?(output)
        }
    }

    func stop() {
        guard busy, isRecording, !stopRequested else { return }
        stopRequested = true
        status = "正在停止录制并完成文件"
        guard let current = session else { return }
        // FFmpeg reads q from stdin, writes the trailer, and exits normally.
        try? current.input.fileHandleForWriting.write(contentsOf: Data("q\n".utf8))
        let id = generation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if self.generation == id, self.busy, current.process.isRunning {
                current.process.terminate()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self.generation == id, self.busy, current.process.isRunning { Darwin.kill(current.process.processIdentifier, SIGKILL) }
            }
        }
    }

    func cancel() {
        guard busy else { return }
        cancelled = true; status = "正在取消"; job?.cancel()
        guard let current = session else { return }
        try? current.input.fileHandleForWriting.close()
        if current.process.isRunning { current.process.terminate() }
        let id = generation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if self.generation == id, self.busy, current.process.isRunning { Darwin.kill(current.process.processIdentifier, SIGKILL) }
        }
    }

    func revealOutput() {
        if let lastOutput { NSWorkspace.shared.activateFileViewerSelecting([lastOutput]) }
    }

    func shutdown() async {
        if isRecording { stop() } else { cancel() }
        let deadline = Date().addingTimeInterval(10)
        while busy && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
        if busy {
            cancel()
            let cleanupDeadline = Date().addingTimeInterval(3)
            while busy && Date() < cleanupDeadline { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
    }
}
