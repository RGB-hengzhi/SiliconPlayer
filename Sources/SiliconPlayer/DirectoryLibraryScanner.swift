import Foundation
import Darwin
import PlayerCore

struct DirectoryLibraryFailure: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

final class DirectoryScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
    }
}

/// Retained native descriptor ownership, also on failed close. Registry checks
/// never issue syscalls on MainActor. A failed release cannot become an idle App.
final class DirectoryLibraryFD: @unchecked Sendable {
    private static let registryLock = NSLock()
    // Access is protected by registryLock; no unsynchronized global mutation.
    nonisolated(unsafe) private static var owners: [UUID: DirectoryLibraryFD] = [:]
    private let lock = NSLock()
    private let id = UUID()
    let descriptor: Int32
    private let boundIdentity: DirectoryLibraryIdentity?
    private var retired = false
    private var released = false
    init(_ fd: Int32) {
        descriptor = fd
        var st = stat()
        boundIdentity = fstat(fd, &st) == 0 ? DirectoryLibraryScanner.identity(st) : nil
        Self.registryLock.lock(); Self.owners[id] = self; Self.registryLock.unlock()
    }
    static var ownedDescriptorCount: Int {
        registryLock.lock(); defer { registryLock.unlock() }; return owners.count
    }
    static var hasOwnedDescriptors: Bool { ownedDescriptorCount != 0 }
    @discardableResult
    func close(using operation: (() -> Int32)? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if released { return true }
        let firstAttempt = !retired; retired = true
        var current = stat()
        if fstat(descriptor, &current) != 0 {
            guard errno == EBADF else { return false }
            released = true
        } else {
            // After a failed close, dev/inode alone cannot prove that a numeric
            // FD was not reused. A retry only accepts EBADF above; it does not
            // signal/close an ambiguous live descriptor, even of the same file.
            guard firstAttempt else { return false }
            guard boundIdentity == nil || DirectoryLibraryScanner.identity(current) == boundIdentity else { return false }
            let status = operation?() ?? Darwin.close(descriptor)
            guard status == 0 else { return false }
            released = true
        }
        Self.registryLock.lock(); Self.owners.removeValue(forKey: id); Self.registryLock.unlock()
        return true
    }
    private var isRetired: Bool { lock.lock(); defer { lock.unlock() }; return retired && !released }
    static var hasRetiredDescriptors: Bool {
        registryLock.lock(); let snapshot = Array(owners.values); registryLock.unlock()
        return snapshot.contains { $0.isRetired }
    }
    private func retryIfRetired() -> Bool {
        lock.lock(); let retry = retired; lock.unlock()
        return retry ? close() : true
    }
    static func retryRetired() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                registryLock.lock(); let snapshot = Array(owners.values); registryLock.unlock()
                var closed = true
                for owner in snapshot { closed = owner.retryIfRetired() && closed }
                continuation.resume(returning: closed)
            }
        }
    }
}

struct DirectoryScanLimits: Sendable {
    let maximumNodes: Int
    let maximumMedia: Int
    let maximumDepth: Int
    let maximumSeconds: TimeInterval
    init(nodes: Int = 100_000, media: Int = 20_000, depth: Int = 32, seconds: TimeInterval = 30) {
        maximumNodes = min(max(nodes, 1), 100_000); maximumMedia = min(max(media, 1), 20_000)
        maximumDepth = min(max(depth, 0), 32); maximumSeconds = min(max(seconds, 0.1), 30)
    }
}

enum DirectoryScanPolicy: Sendable, Equatable {
    case library
    // Ordinary Open preserves Foundation hidden/package rules and does not
    // inherit the explicitly-local watcher restriction or mount-boundary filter.
    case ordinaryOpen
}

/// One serial utility queue for all roots. No main-thread traversal, media decode,
/// payload reads, symlink traversal, package descent or crossing mounted devices.
enum DirectoryLibraryScanner {
    private static let queue = DispatchQueue(label: "SiliconPlayer.directory-scan", qos: .utility)
    static func identity(_ st: stat) -> DirectoryLibraryIdentity {
        DirectoryLibraryIdentity(device: UInt64(bitPattern: Int64(st.st_dev)), inode: UInt64(st.st_ino))
    }
    static func openRoot(_ input: URL, expected: DirectoryLibraryIdentity?, policy: DirectoryScanPolicy = .library) throws -> (URL, DirectoryLibraryFD, DirectoryLibraryIdentity) {
        guard input.isFileURL else { throw DirectoryLibraryFailure("请选择本机目录。") }
        var original = stat()
        guard lstat(input.path, &original) == 0, original.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DirectoryLibraryFailure("目录不存在、已移动，或所选路径是符号链接。请重新选择目录。")
        }
        // Resolve existing ancestor aliases before binding the selected real directory.
        let url = input.standardizedFileURL.resolvingSymlinksInPath()
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw DirectoryLibraryFailure("无法打开目录；可能已移除、失去权限或磁盘已离线。") }
        let owned = DirectoryLibraryFD(fd)
        var st = stat(), fs = statfs()
        guard fstat(fd, &st) == 0, st.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              identity(st) == identity(original), fstatfs(fd, &fs) == 0,
              (policy == .ordinaryOpen || fs.f_flags & UInt32(MNT_LOCAL) != 0), expected == nil || expected == identity(st) else {
            _ = owned.close()
            throw DirectoryLibraryFailure(policy == .library ? "仅支持本机卷的真实目录；目录身份变化或网络卷不能继续监控。" : "目录身份已变化或目录卷无法读取；原列表保留。")
        }
        return (url, owned, identity(st))
    }
    static func scan(root: URL, expected: DirectoryLibraryIdentity?, recursive: Bool,
                     cancellation: DirectoryScanCancellation, limits: DirectoryScanLimits = .init(),
                     policy: DirectoryScanPolicy = .library, progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> DirectoryLibraryScanResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard !DirectoryLibraryFD.hasRetiredDescriptors else { throw DirectoryLibraryFailure("先前目录描述符仍未确认释放，不能开启新扫描。") }
                    let result = try perform(root: root, expected: expected,
                        recursive: recursive, cancellation: cancellation, limits: limits, policy: policy, progress: progress)
                    guard !DirectoryLibraryFD.hasRetiredDescriptors else { throw DirectoryLibraryFailure("目录描述符未确认释放；旧清单保留，任务仍受本程序持有。") }
                    continuation.resume(returning: result)
                }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func perform(root input: URL, expected: DirectoryLibraryIdentity?, recursive: Bool,
                                cancellation: DirectoryScanCancellation, limits: DirectoryScanLimits, policy: DirectoryScanPolicy,
                                progress: @Sendable (Int) -> Void) throws -> DirectoryLibraryScanResult {
        try cancellation.check()
        let (root, rootHandle, rootIdentity) = try openRoot(input, expected: expected, policy: policy)
        let fd = rootHandle.descriptor
        defer { _ = rootHandle.close() }
        let started = ProcessInfo.processInfo.systemUptime
        var files: [DirectoryLibraryFile] = [], visited = 0, directories = 0, skipped = 0
        func check() throws {
            try cancellation.check()
            guard visited <= limits.maximumNodes, files.count <= limits.maximumMedia,
                  ProcessInfo.processInfo.systemUptime - started <= limits.maximumSeconds else {
                throw DirectoryLibraryFailure("扫描超过 100000 项／20000 个媒体／30 秒上限，未替换完整旧清单。请选择更小目录或仅扫描本层。")
            }
        }
        func walk(_ directoryFD: Int32, relative: String, depth: Int) throws {
            try check()
            let streamFD = dup(directoryFD)
            guard streamFD >= 0 else { throw DirectoryLibraryFailure("无法取得扫描目录描述符。") }
            let streamHandle = DirectoryLibraryFD(streamFD)
            guard let stream = fdopendir(streamFD) else { _ = streamHandle.close(); throw DirectoryLibraryFailure("无法读取目录。") }
            defer { _ = streamHandle.close(using: { closedir(stream) }) }
            directories += 1
            while true {
                try check(); errno = 0
                guard let pointer = readdir(stream) else {
                    if errno != 0 { throw DirectoryLibraryFailure("目录读取中断，未替换完整旧清单。") }
                    break
                }
                let name: String? = withUnsafePointer(to: &pointer.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingCString: $0) }
                }
                guard let name else { skipped += 1; continue }
                guard name != ".", name != "..", !name.hasPrefix(".") else { continue }
                visited += 1; try check()
                if visited % 128 == 0 { progress(visited) }
                var item = stat()
                guard fstatat(directoryFD, name, &item, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT { skipped += 1; continue }
                    throw DirectoryLibraryFailure("目录条目不可读，未替换完整旧清单。")
                }
                let path = relative.isEmpty ? name : relative + "/" + name
                let kind = item.st_mode & mode_t(S_IFMT)
                if policy == .ordinaryOpen, kind != mode_t(S_IFLNK) {
                    let url = root.appendingPathComponent(path)
                    let values = try url.resourceValues(forKeys: [.isHiddenKey, .isPackageKey])
                    if values.isHidden == true || (kind == mode_t(S_IFDIR) && values.isPackage == true) {
                        skipped += 1; continue
                    }
                }
                if kind == mode_t(S_IFDIR), recursive {
                    let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
                    guard policy == .ordinaryOpen || (!["app", "bundle", "framework", "photoslibrary"].contains(ext) && identity(item).device == rootIdentity.device) else {
                        skipped += 1; continue
                    }
                    guard depth < limits.maximumDepth else { throw DirectoryLibraryFailure("目录超过 32 层，完整递归扫描已停止；旧清单保留。") }
                    let child = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard child >= 0 else {
                        if errno == ENOENT || errno == ELOOP { skipped += 1; continue }
                        throw DirectoryLibraryFailure("子目录不可读，完整扫描已停止。")
                    }
                    let childHandle = DirectoryLibraryFD(child)
                    defer { _ = childHandle.close() }
                    var opened = stat()
                    guard fstat(child, &opened) == 0, identity(opened) == identity(item) else { throw DirectoryLibraryFailure("子目录在扫描中被替换。") }
                    try walk(child, relative: path, depth: depth + 1)
                } else if kind == mode_t(S_IFREG), MediaFormats.mediaExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()) {
                    files.append(DirectoryLibraryFile(relativePath: path, url: root.appendingPathComponent(path), identity: identity(item),
                        bytes: item.st_size, modifiedSeconds: Int64(item.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(item.st_mtimespec.tv_nsec)))
                    try check()
                } else { skipped += 1 }
            }
        }
        try walk(fd, relative: "", depth: 0); try check()
        let (_, finalHandle, _) = try openRoot(root, expected: rootIdentity, policy: policy)
        guard finalHandle.close() else { throw DirectoryLibraryFailure("扫描校验目录描述符未确认释放。") }
        files.sort { $0.relativePath < $1.relativePath }
        return DirectoryLibraryScanResult(root: root, identity: rootIdentity, files: files, visited: visited,
            directories: directories, skipped: skipped, elapsed: ProcessInfo.processInfo.systemUptime - started)
    }
}
