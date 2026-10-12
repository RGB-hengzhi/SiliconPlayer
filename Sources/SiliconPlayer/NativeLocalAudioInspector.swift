import Foundation
import Darwin
import PlayerCore

// Inspects bounded local sources using owned descriptors and bundled ffprobe.
@MainActor final class NativeLocalAudioInspector {
    private static var jobs: [UUID: NativeAudioProbeJob] = [:]
    private static var cleanupFailures: [UUID: NativeAudioProbeJob] = [:]
    private var running: NativeAudioProbeJob?
    private var request = UUID()
    private let toolsDirectory: URL?
    init(toolsDirectory: URL? = nil) { self.toolsDirectory = toolsDirectory }
    static var hasActiveJobs: Bool { !jobs.isEmpty || !cleanupFailures.isEmpty }
    func cancel() { request = UUID(); running?.cancel(); running = nil }
    deinit { running?.cancel() }
    static func shutdownAll() async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        jobs.values.forEach { $0.cancel() }
        while !jobs.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return jobs.isEmpty && cleanupFailures.isEmpty // Never turn unconfirmed ownership into cleanup success.
    }
    func inspect(item: MediaItem, directories: [URL], coverNames: [String]) async throws -> NativeAudioInspection {
        let token = UUID(); request = token
        let url = item.url
        let format = url.pathExtension.lowercased()
        guard item.webMedia == nil, url.isFileURL, ["wav", "flac"].contains(format),
              let tools = toolsDirectory ?? Self.helperDirectory(),
              FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("ffprobe").path) else { throw NativeAudioProbeError.ineligible }
        let executable = tools.appendingPathComponent("ffprobe")
        let arguments = ["-v", "error", "-hide_banner", "-protocol_whitelist", "file,pipe",
            "-f", format, "-show_streams", "-show_format", "-of", "json", "/dev/fd/3"]
        let job = NativeAudioProbeJob(executable: executable, sourceURL: url, arguments: arguments, timeout: 1.5)
        running?.cancel(); running = job; Self.jobs[job.id] = job
        defer {
            Self.jobs.removeValue(forKey: job.id)
            if job.needsCleanupConfirmation { Self.cleanupFailures[job.id] = job }
            if running?.id == job.id { running = nil }
        }
        let result = try await Task.detached(priority: .utility) {
            // Opening the source and scanning local directory entries happens
            // off MainActor. Kernel I/O isn't claimed bounded by process timeout.
            let before = try Self.fingerprint(url)
            let data = try job.run(expected: before).get()
            let stamps = try Self.directoryStamps([url.deletingLastPathComponent()] + directories)
            guard before == (try Self.fingerprint(url)),
                  try Self.discoveryEmpty(source: url, directories: directories, coverNames: coverNames),
                  stamps == (try Self.directoryStamps(stamps.map(\.url))) else {
                throw NativeAudioProbeError.changedOrExternal
            }
            return try Self.parse(data: data, item: item, fingerprint: before, stamps: stamps)
        }.value
        guard request == token, running?.id == job.id else { throw NativeAudioProbeError.cancelled }
        running = nil
        return result
    }
    // Packaged candidates never mask a missing bundled tool with the dev tree.
    private static func helperDirectory() -> URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Tools")
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Vendor/tools")
        let candidates = Bundle.main.bundleURL.pathExtension.lowercased() == "app" ? [bundled] : [bundled, dev]
        return candidates.compactMap { $0 }.first {
            FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("ffprobe").path)
        }
    }
    nonisolated static func fingerprint(_ url: URL) throws -> NativeAudioInspection.Fingerprint {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeAudioProbeError.invalidFile }
        defer { Darwin.close(fd) }
        var filesystem = statfs()
        guard Darwin.fstatfs(fd, &filesystem) == 0,
              filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw NativeAudioProbeError.invalidFile }
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw NativeAudioProbeError.invalidFile }
        return try statFingerprint(value)
    }
    nonisolated static func statFingerprint(_ value: stat) throws -> NativeAudioInspection.Fingerprint {
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              value.st_size > 0, value.st_mtimespec.tv_sec >= 0,
              value.st_mtimespec.tv_nsec >= 0, value.st_mtimespec.tv_nsec < 1_000_000_000,
              UInt64(value.st_mtimespec.tv_sec) <= (UInt64.max - 999_999_999) / 1_000_000_000 else {
            throw NativeAudioProbeError.invalidFile
        }
        return .init(device: UInt64(UInt32(truncatingIfNeeded: value.st_dev)), inode: UInt64(value.st_ino), size: UInt64(value.st_size),
            modificationNanoseconds: UInt64(value.st_mtimespec.tv_sec) * 1_000_000_000 + UInt64(value.st_mtimespec.tv_nsec))
    }
    nonisolated static func directoryStamps(_ directories: [URL]) throws -> [NativeAudioInspection.DirectoryStamp] {
        guard directories.count <= 33 else { throw NativeAudioProbeError.changedOrExternal }
        var result: [NativeAudioInspection.DirectoryStamp] = []
        var seen = Set<String>()
        for directory in directories {
            let url = directory.standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            var value = stat()
            if lstat(url.path, &value) != 0 {
                guard errno == ENOENT else { throw NativeAudioProbeError.invalidFile }
                result.append(.init(url: url, value: nil)); continue
            }
            guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), value.st_size >= 0,
                  value.st_mtimespec.tv_sec >= 0, value.st_mtimespec.tv_nsec >= 0,
                  value.st_mtimespec.tv_nsec < 1_000_000_000,
                  UInt64(value.st_mtimespec.tv_sec) <= (UInt64.max - 999_999_999) / 1_000_000_000 else {
                throw NativeAudioProbeError.invalidFile
            }
            result.append(.init(url: url, value: .init(device: UInt64(UInt32(truncatingIfNeeded: value.st_dev)),
                inode: UInt64(value.st_ino), size: UInt64(value.st_size),
                modificationNanoseconds: UInt64(value.st_mtimespec.tv_sec) * 1_000_000_000 + UInt64(value.st_mtimespec.tv_nsec))))
        }
        return result
    }
    nonisolated static func stillMatches(_ inspection: NativeAudioInspection) -> Bool {
        (try? fingerprint(inspection.originalURL)) == inspection.fingerprint
            && (try? directoryStamps(inspection.discoveryStamps.map(\.url))) == inspection.discoveryStamps
    }
    // Conservative superset of v0.41 fuzzy-name and cover whitelist matches.
    // No extension whitelist can conceal an unknown external resource. A
    // matching AppleDouble also refuses native mode, rather than assuming mpv
    // ignores its contents. Nonmatching files do not affect normal album dirs.
    nonisolated private static func discoveryEmpty(source: URL, directories: [URL], coverNames: [String]) throws -> Bool {
        guard directories.count <= 32, coverNames.count <= 64 else { return false }
        let needle = source.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
        guard !needle.isEmpty else { return false }
        let covers = coverNames.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        var visited = Set<String>()
        for directory in [source.deletingLastPathComponent()] + directories {
            let path = directory.standardizedFileURL.path
            guard visited.insert(path).inserted else { continue }
            var information = stat()
            if lstat(path, &information) != 0 {
                if errno == ENOENT { continue }
                throw NativeAudioProbeError.invalidFile
            }
            guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), let dir = opendir(path) else { return false }
            defer { closedir(dir) }
            var count = 0
            while let entry = readdir(dir) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(validatingCString: $0) }
                }
                guard let name else { return false }
                if name == "." || name == ".." { continue }
                count += 1; guard count <= 512 else { return false }
                let url = directory.appendingPathComponent(name).standardizedFileURL
                if url == source.standardizedFileURL { continue }
                let lower = name.precomposedStringWithCanonicalMapping.lowercased()
                let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
                if lower.contains(needle) || covers.contains(stem) { return false }
            }
        }
        return true
    }
    nonisolated private static func parse(data: Data, item: MediaItem, fingerprint: NativeAudioInspection.Fingerprint, stamps: [NativeAudioInspection.DirectoryStamp]) throws -> NativeAudioInspection {
        guard data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]], streams.count == 1,
              let stream = streams.first, stream["codec_type"] as? String == "audio",
              let format = root["format"] as? [String: Any], let name = format["format_name"] as? String,
              ["wav", "flac"].contains(name), let codec = stream["codec_name"] as? String,
              ["pcm_s16le", "pcm_s24le", "pcm_s32le", "flac"].contains(codec),
              let rateText = stream["sample_rate"] as? String, let rate = Int(rateText), (8_000...384_000).contains(rate),
              let channels = stream["channels"] as? Int, (1...8).contains(channels),
              let layout = stream["channel_layout"] as? String, !layout.isEmpty, layout.utf8.count <= 128,
              let durationText = format["duration"] as? String, let duration = Double(durationText),
              duration.isFinite, duration > 0 else { throw NativeAudioProbeError.ineligible }
        let raw = (stream["bits_per_raw_sample"] as? String).flatMap(Int.init) ?? 0
        let bits = raw > 0 ? raw : (stream["bits_per_sample"] as? Int ?? 0)
        guard [16, 24, 32].contains(bits) else { throw NativeAudioProbeError.ineligible }
        return NativeAudioInspection(originalURL: item.url, fingerprint: fingerprint, container: name, codec: codec,
            sampleRate: rate, channels: channels, channelLayout: layout, significantBits: bits,
            audioStreamCount: 1, nonAudioStreamCount: 0, seekable: true, duration: duration,
            externalDiscoveryProvenEmpty: true, discoveryStamps: stamps)
    }
}

private enum NativeAudioProbeError: LocalizedError {
    case ineligible, invalidFile, changedOrExternal, launch, cancelled, timedOut, stdoutLimit, stderrLimit, failed, read
    var errorDescription: String? {
        switch self {
        case .cancelled: return "连续音频预检已取消"
        case .timedOut: return "连续音频预检超时，保持普通切换"
        case .changedOrExternal: return "文件已改变或存在潜在自动加载资源，保持普通切换"
        case .invalidFile: return "此文件无法安全预检，保持普通切换"
        case .ineligible: return "仅已确认单音轨同参数 WAV/FLAC 可进入连续音频"
        default: return "连续音频预检未完成，保持普通切换"
        }
    }
}

private final class NativeAudioProbeJob: @unchecked Sendable {
    let id = UUID()
    private let executable: URL
    private let sourceURL: URL
    private var sourceFD: Int32 = -1
    private let arguments: [String]
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var cancelled = false
    private var closed = false
    private var spawned = false
    private var cleanupConfirmed = false
    var needsCleanupConfirmation: Bool {
        lock.lock(); defer { lock.unlock() }; return spawned && !cleanupConfirmed
    }
    private func spawnedWorker() { lock.lock(); spawned = true; lock.unlock() }
    private func confirmedCleanup() { lock.lock(); cleanupConfirmed = true; lock.unlock() }

    init(executable: URL, sourceURL: URL, arguments: [String], timeout: TimeInterval) {
        self.executable = executable; self.sourceURL = sourceURL
        self.arguments = arguments; self.timeout = timeout
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    private func markClosed() { lock.lock(); closed = true; lock.unlock() }
    func waitUntilClosed() async {
        while !isClosed { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func run(expected: NativeAudioInspection.Fingerprint) -> Result<Data, Error> {
        defer { markClosed() }
        do { return .success(try execute(expected: expected)) } catch { return .failure(error) }
    }

    private func execute(expected: NativeAudioInspection.Fingerprint) throws -> Data {
        guard !isCancelled else { throw NativeAudioProbeError.cancelled }
        let opened = Darwin.open(sourceURL.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw NativeAudioProbeError.invalidFile }
        defer { Darwin.close(opened) }
        var regular = stat()
        guard fstat(opened, &regular) == 0,
              regular.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), regular.st_size > 0,
              try NativeLocalAudioInspector.statFingerprint(regular) == expected else {
            throw NativeAudioProbeError.invalidFile
        }
        sourceFD = fcntl(opened, F_DUPFD_CLOEXEC, 20)
        guard sourceFD >= 20 else { throw NativeAudioProbeError.launch }
        defer { Darwin.close(sourceFD); sourceFD = -1 }
        let started = ProcessInfo.processInfo.systemUptime
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SiliconPlayer-NativeAudio-\(id.uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw NativeAudioProbeError.launch }
        defer { try? FileManager.default.removeItem(at: temporary) }

        var output: [Int32] = [-1, -1], diagnostic: [Int32] = [-1, -1]
        guard pipe(&output) == 0 else { throw NativeAudioProbeError.launch }
        defer { for fd in output where fd >= 0 { Darwin.close(fd) } }
        guard pipe(&diagnostic) == 0 else { throw NativeAudioProbeError.launch }
        defer { for fd in diagnostic where fd >= 0 { Darwin.close(fd) } }
        for fd in output + diagnostic { guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw NativeAudioProbeError.launch } }
        for fd in [output[0], diagnostic[0]] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw NativeAudioProbeError.launch }
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw NativeAudioProbeError.launch }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw NativeAudioProbeError.launch }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, diagnostic[1], STDERR_FILENO) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { throw NativeAudioProbeError.launch }
        for fd in output + diagnostic { guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw NativeAudioProbeError.launch } }
        // Install the pinned regular file after closing child pipe read ends,
        // one of which may use fd 3. The helper never reopens the user's path.
        guard posix_spawn_file_actions_adddup2(&actions, sourceFD, 3) == 0,
              posix_spawn_file_actions_addclose(&actions, sourceFD) == 0 else { throw NativeAudioProbeError.launch }
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
        guard spawnResult == 0, pid > 0 else { throw NativeAudioProbeError.launch }
        spawnedWorker()
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
                    guard data.count + bytes.count <= 1_048_576 else { throw NativeAudioProbeError.stdoutLimit }
                    data.append(contentsOf: bytes)
                }
                try drain(diagnostic[0], eof: &diagnosticEOF) { bytes in
                    diagnosticsCount += bytes.count
                    guard diagnosticsCount <= 128 * 1024 else { throw NativeAudioProbeError.stderrLimit }
                }
            } catch { if failure == nil { failure = error } }
            if isCancelled, failure == nil { failure = NativeAudioProbeError.cancelled }
            let now = ProcessInfo.processInfo.systemUptime
            if !childExited, terminationStarted == nil, now - started >= timeout, failure == nil { failure = NativeAudioProbeError.timedOut }
            if !childExited {
                var information = siginfo_t()
                let result = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
                if result == 0, information.si_pid == pid { childExited = true }
                else if result < 0, errno != EINTR { failure = failure ?? NativeAudioProbeError.read; childExited = true }
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
                            guard data.count + bytes.count <= 1_048_576 else { throw NativeAudioProbeError.stdoutLimit }
                            data.append(contentsOf: bytes)
                        }
                        try drain(diagnostic[0], eof: &diagnosticEOF) { bytes in
                            diagnosticsCount += bytes.count
                            guard diagnosticsCount <= 128 * 1024 else { throw NativeAudioProbeError.stderrLimit }
                        }
                    } catch { failure = error }
                }
                // Keep the leader reserved until a bounded exact-PGID kernel
                // snapshot confirms every member (including leader) zombie.
                // EPERM from signaling a zombie-only macOS group is therefore
                // not confused with a running child or ownership failure.
                let groupDeadline = ProcessInfo.processInfo.systemUptime + 1
                var gone = ownedGroupExited(pid)
                while !gone, ProcessInfo.processInfo.systemUptime < groupDeadline {
                    usleep(10_000); gone = ownedGroupExited(pid)
                }
                var waited: pid_t
                repeat { waited = waitpid(pid, &finalStatus, 0) } while waited < 0 && errno == EINTR
                if gone && waited == pid { confirmedCleanup() }
                else { failure = failure ?? NativeAudioProbeError.read }
                break
            }
            var polling = [pollfd(fd: output[0], events: Int16(POLLIN), revents: 0), pollfd(fd: diagnostic[0], events: Int16(POLLIN), revents: 0)]
            if outputEOF && diagnosticEOF { usleep(20_000) }
            else { _ = poll(&polling, nfds_t(polling.count), 20) }
        }
        if let failure { throw failure }
        guard finalStatus & 0x7f == 0, (finalStatus >> 8) & 0xff == 0 else { throw NativeAudioProbeError.failed }
        return data
    }

    private func ownedGroupExited(_ pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pid]
        var bytes = 0
        let initial = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, UInt32($0.count), nil, &bytes, nil, 0) }
        let stride = MemoryLayout<kinfo_proc>.stride
        guard initial == 0, bytes > 0, bytes <= 4096 * stride else { return false }
        var members = [kinfo_proc](repeating: kinfo_proc(), count: bytes / stride + 4)
        bytes = members.count * stride
        let status = members.withUnsafeMutableBytes { buffer in
            mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, UInt32($0.count), buffer.baseAddress, &bytes, nil, 0) }
        }
        guard status == 0, bytes > 0, bytes % stride == 0, bytes / stride <= members.count else { return false }
        var leader = false
        for member in members.prefix(bytes / stride) {
            guard member.kp_eproc.e_pgid == pid, Int32(member.kp_proc.p_stat) == Int32(SZOMB) else { return false }
            if member.kp_proc.p_pid == pid { leader = true }
        }
        return leader
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
            else if errno != EINTR { throw NativeAudioProbeError.read }
        }
    }
}
