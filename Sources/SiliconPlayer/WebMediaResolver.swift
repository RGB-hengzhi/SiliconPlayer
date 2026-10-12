import Foundation
import Combine
import Darwin
import PlayerCore

/// Preflight metadata only. Playback independently resolves the original page.
@MainActor
final class WebMediaResolver: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var status = "输入单个视频网页地址"
    @Published private(set) var error: String?
    @Published private(set) var document: WebMediaDocument?

    private let toolsDirectory: URL?
    private let timeout: TimeInterval
    private var generation: UInt64 = 0
    private var job: WebMediaProcessJob?
    private static var jobs: [UUID: WebMediaProcessJob] = [:]

    init(toolsDirectory: URL? = nil, timeout: TimeInterval = 45) {
        self.toolsDirectory = toolsDirectory
        self.timeout = timeout.isFinite ? min(45, max(0.1, timeout)) : 45
    }

    static var hasActiveJobs: Bool { !jobs.isEmpty }

    /// Includes jobs belonging to closed sheets; their registry entries retain
    /// the process job, never the view/resolver, until cleanup has finished.
    static func shutdownAll() async {
        while !jobs.isEmpty {
            let pending = Array(jobs.values)
            pending.forEach { $0.cancel() }
            for job in pending { await job.waitUntilClosed() }
            for job in pending { jobs.removeValue(forKey: job.id) }
        }
    }

    func resolve(address: String) {
        generation &+= 1
        let request = generation
        job?.cancel(); job = nil
        document = nil; error = nil; busy = false
        do {
            let pageURL = try WebMediaDocument.validatedPageURL(address)
            let directory = try helperDirectory()
            let executable = directory.appendingPathComponent("yt-dlp/yt-dlp_macos")
            let deno = directory.appendingPathComponent("deno")
            let arguments = ["--ignore-config", "--no-plugin-dirs", "--no-remote-components",
                "--no-js-runtimes", "--js-runtimes", "deno:\(deno.path)",
                "--no-cookies-from-browser", "--no-update", "--no-cache-dir",
                "--socket-timeout", "15", "--no-playlist", "--simulate", "--dump-single-json",
                "--", pageURL.absoluteString]
            let running = WebMediaProcessJob(executable: executable, arguments: arguments, timeout: timeout)
            job = running; Self.jobs[running.id] = running
            busy = true; status = "正在解析网页媒体…"
            let work = Task.detached(priority: .userInitiated) {
                let result = running.run()
                switch result {
                case .success(let data):
                    return Result { try WebMediaDocument.parse(data: data, pageURL: pageURL) }
                case .failure(let failure): return .failure(failure)
                }
            }
            Task { [weak self] in
                let result = await work.value
                Self.jobs.removeValue(forKey: running.id)
                guard let self, self.generation == request, self.job?.id == running.id else { return }
                self.job = nil; self.busy = false
                switch result {
                case .success(let document):
                    self.document = document; self.status = "解析完成，可选择格式与字幕"
                case .failure(let failure):
                    self.error = failure.localizedDescription; self.status = "解析失败"
                }
            }
        } catch {
            self.error = error.localizedDescription; status = "解析失败"
        }
    }

    /// Restores the UI immediately. Actual process cleanup remains registered
    /// and can be awaited by application termination.
    func cancel() {
        generation &+= 1
        job?.cancel(); job = nil
        busy = false; document = nil; error = nil; status = "已取消解析"
    }

    deinit { job?.cancel() }

    private func helperDirectory() throws -> URL {
        let candidates: [URL]
        if let toolsDirectory { candidates = [toolsDirectory] }
        else if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            candidates = [Bundle.main.resourceURL?.appendingPathComponent("WebTools")].compactMap { $0 }
        }
        else {
            candidates = [Bundle.main.resourceURL?.appendingPathComponent("WebTools"),
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Vendor/WebTools")].compactMap { $0 }
        }
        guard let directory = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("yt-dlp/yt-dlp_macos").path)
            && FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("deno").path)
        }) else { throw WebMediaProcessError.missingTools }
        return directory.standardizedFileURL
    }
}

private enum WebMediaProcessError: LocalizedError {
    case missingTools, launch, cancelled, timedOut, stdoutLimit, stderrLimit, failed, read
    var errorDescription: String? {
        switch self {
        case .missingTools: return "网页解析工具缺失或不可执行，请使用包含 WebTools 的完整应用"
        case .launch: return "无法启动本应用的网页解析工具"
        case .cancelled: return "已取消解析"
        case .timedOut: return "网页解析超时，请检查网络后重试"
        case .stdoutLimit: return "网页媒体信息超过 16 MiB 上限"
        case .stderrLimit: return "网页解析工具的诊断输出超过 128 KiB 上限"
        case .failed: return "网页解析失败；此页面可能需要登录、受地区限制或暂不受支持"
        case .read: return "无法读取网页解析工具返回的信息"
        }
    }
}

/// A single POSIX process group is created atomically by posix_spawn. Every
/// signal targets that owned group; no name-based or global process killing.
private final class WebMediaProcessJob: @unchecked Sendable {
    let id = UUID()
    private let executable: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var cancelled = false
    private var closed = false

    init(executable: URL, arguments: [String], timeout: TimeInterval) {
        self.executable = executable; self.arguments = arguments; self.timeout = timeout
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    private func markClosed() { lock.lock(); closed = true; lock.unlock() }
    func waitUntilClosed() async {
        while !isClosed { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func run() -> Result<Data, Error> {
        defer { markClosed() }
        do { return .success(try execute()) } catch { return .failure(error) }
    }

    private func execute() throws -> Data {
        guard !isCancelled else { throw WebMediaProcessError.cancelled }
        let started = ProcessInfo.processInfo.systemUptime
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SiliconPlayer-WebMedia-\(id.uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw WebMediaProcessError.launch }
        defer { try? FileManager.default.removeItem(at: temporary) }

        var output: [Int32] = [-1, -1], diagnostic: [Int32] = [-1, -1]
        guard pipe(&output) == 0 else { throw WebMediaProcessError.launch }
        defer { for fd in output where fd >= 0 { Darwin.close(fd) } }
        guard pipe(&diagnostic) == 0 else { throw WebMediaProcessError.launch }
        defer { for fd in diagnostic where fd >= 0 { Darwin.close(fd) } }
        for fd in output + diagnostic { guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw WebMediaProcessError.launch } }
        for fd in [output[0], diagnostic[0]] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw WebMediaProcessError.launch }
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw WebMediaProcessError.launch }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw WebMediaProcessError.launch }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, diagnostic[1], STDERR_FILENO) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { throw WebMediaProcessError.launch }
        for fd in output + diagnostic { guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw WebMediaProcessError.launch } }
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=en_US.UTF-8", "LC_ALL=en_US.UTF-8",
            "TMPDIR=\(temporary.path)/", "DENO_DIR=\(temporary.appendingPathComponent("deno-cache").path)"]
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let spawnResult = argv.withUnsafeBufferPointer { arguments in
            envp.withUnsafeBufferPointer { environment in
                posix_spawn(&pid, executable.path, &actions, &attributes, arguments.baseAddress!, environment.baseAddress!)
            }
        }
        guard spawnResult == 0, pid > 0 else { throw WebMediaProcessError.launch }
        Darwin.close(output[1]); output[1] = -1
        Darwin.close(diagnostic[1]); diagnostic[1] = -1

        var data = Data(), diagnosticsCount = 0, failure: Error?
        var outputEOF = false, diagnosticEOF = false, childExited = false
        var terminationStarted: TimeInterval?
        var finalStatus: Int32 = 0
        // Retain the unreaped leader (WNOWAIT) until group signals finish. Its
        // PID/PGID cannot be recycled into an unrelated job during cleanup.
        while true {
            do {
                try drain(output[0], eof: &outputEOF) { bytes in
                    guard data.count + bytes.count <= WebMediaDocument.maximumBytes else { throw WebMediaProcessError.stdoutLimit }
                    data.append(contentsOf: bytes)
                }
                try drain(diagnostic[0], eof: &diagnosticEOF) { bytes in
                    diagnosticsCount += bytes.count
                    guard diagnosticsCount <= 128 * 1024 else { throw WebMediaProcessError.stderrLimit }
                }
            } catch { if failure == nil { failure = error } }
            if isCancelled, failure == nil { failure = WebMediaProcessError.cancelled }
            let now = ProcessInfo.processInfo.systemUptime
            if !childExited, terminationStarted == nil, now - started >= timeout, failure == nil { failure = WebMediaProcessError.timedOut }
            if !childExited {
                var information = siginfo_t()
                let result = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
                if result == 0, information.si_pid == pid { childExited = true }
                else if result < 0, errno != EINTR { failure = failure ?? WebMediaProcessError.read; childExited = true }
            }
            if (failure != nil || childExited), terminationStarted == nil {
                terminationStarted = now
                _ = kill(-pid, SIGTERM)
            }
            if let terminationStarted, now - terminationStarted >= 0.2 {
                _ = kill(-pid, SIGKILL)
                // Pipes may contain the final bounded output after leader exit.
                if failure == nil {
                    do {
                        try drain(output[0], eof: &outputEOF) { bytes in
                            guard data.count + bytes.count <= WebMediaDocument.maximumBytes else { throw WebMediaProcessError.stdoutLimit }
                            data.append(contentsOf: bytes)
                        }
                        try drain(diagnostic[0], eof: &diagnosticEOF) { bytes in
                            diagnosticsCount += bytes.count
                            guard diagnosticsCount <= 128 * 1024 else { throw WebMediaProcessError.stderrLimit }
                        }
                    } catch { failure = error }
                }
                while waitpid(pid, &finalStatus, 0) < 0 { if errno != EINTR { break } }
                // SIGKILL has already targeted the reserved owned PGID. Allow
                // orphaned runtime children to disappear before reporting the
                // job closed; these probes never send another signal.
                let groupDeadline = ProcessInfo.processInfo.systemUptime + 1
                while kill(-pid, 0) == 0, ProcessInfo.processInfo.systemUptime < groupDeadline { usleep(10_000) }
                break
            }
            var polling = [pollfd(fd: output[0], events: Int16(POLLIN), revents: 0), pollfd(fd: diagnostic[0], events: Int16(POLLIN), revents: 0)]
            if outputEOF && diagnosticEOF { usleep(20_000) }
            else { _ = poll(&polling, nfds_t(polling.count), 20) }
        }
        if let failure { throw failure }
        guard finalStatus & 0x7f == 0, (finalStatus >> 8) & 0xff == 0 else { throw WebMediaProcessError.failed }
        return data
    }

    /// Fair bounded batches ensure continuously writing helpers cannot starve
    /// the deadline, cancellation check or the other pipe.
    private func drain(_ fd: Int32, eof: inout Bool, consume: (ArraySlice<UInt8>) throws -> Void) throws {
        guard !eof else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        for _ in 0..<4 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 { try consume(buffer.prefix(count)) }
            else if count == 0 { eof = true; return }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else if errno != EINTR { throw WebMediaProcessError.read }
        }
    }
}
