import Foundation
import Darwin
import Combine
import PlayerCore

struct OrdinaryMediaOpenContext: Equatable, Sendable {
    let queueRevision: UInt64
    let currentItemID: UUID?
    let loadToken: UUID
    let preferenceToken: UUID
    let boundItemID: UUID?
}

struct OrdinaryMediaOpenExpansion: Sendable {
    let media: [URL]
    let subtitles: [URL]
    let rejectedAddresses: Int
    let visited: Int
}

/// All root classification, payload reads, traversal and sort run on utility
/// queues. NSOpenPanel modal handling and subsequent mpv/profile load are separate
/// existing contracts; this is not a claim that all App filesystem I/O moved.
enum OrdinaryMediaOpenExpansionWorker {
    private static let metadataQueue = DispatchQueue(label: "SiliconPlayer.open-metadata", qos: .utility)
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
    static let maximumInputs = 128
    static let maximumEntries = 20_000
    static let maximumSubtitles = 128
    static let maximumPlaylistBytes = 4 * 1024 * 1024
    static let maximumSeconds: TimeInterval = 30

    private static func accepted(_ url: URL) -> Bool {
        url.isFileURL || (["http", "https", "rtsp", "rtsps", "rtmp"].contains(url.scheme?.lowercased() ?? "")
            && url.host != nil && url.user == nil && url.password == nil)
    }
    private static func onMetadataQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            metadataQueue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func check(_ token: DirectoryScanCancellation, started: TimeInterval) throws {
        try token.check()
        guard ProcessInfo.processInfo.systemUptime - started <= maximumSeconds else {
            throw DirectoryLibraryFailure("目录／列表展开超过 30 秒，原播放列表保留。")
        }
    }
    private static func playlist(_ input: URL, token: DirectoryScanCancellation, started: TimeInterval) throws -> [URL] {
        try check(token, started: started)
        // Explicit playlist symlinks remain allowed, as in the old read(from:).
        // Bind the final regular physical file; preserve input as the relative base.
        let physical = input.standardizedFileURL.resolvingSymlinksInPath()
        let fd = Darwin.open(physical.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw DirectoryLibraryFailure("无法读取所选播放列表；原列表保留。") }
        let owner = DirectoryLibraryFD(fd)
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_size >= 0, before.st_size <= Int64(maximumPlaylistBytes) else {
            _ = owner.close(); throw DirectoryLibraryFailure("播放列表必须是最多 4 MiB 的普通文件；原列表保留。")
        }
        do {
            var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                try check(token, started: started)
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count < 0 { if errno == EINTR { continue }; throw DirectoryLibraryFailure("播放列表读取中断；原列表保留。") }
                if count == 0 { break }
                guard data.count + count <= maximumPlaylistBytes else { throw DirectoryLibraryFailure("播放列表读取时超出 4 MiB 上限。") }
                data.append(contentsOf: buffer.prefix(count))
            }
            var after = stat(), path = stat()
            guard fstat(fd, &after) == 0, lstat(physical.path, &path) == 0,
                  after.st_dev == before.st_dev, after.st_ino == before.st_ino, after.st_size == before.st_size,
                  after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                  path.st_dev == before.st_dev, path.st_ino == before.st_ino,
                  data.count == Int(before.st_size) else { throw DirectoryLibraryFailure("播放列表在读取时变化；原列表保留。") }
            let result: [URL]
            do { result = try PlaylistDocument.read(data: data, from: input) }
            catch PlaylistDocumentError.streamingManifest { result = [input] }
            guard owner.close() else { throw DirectoryLibraryFailure("播放列表描述符尚未确认释放。") }
            return result
        } catch { _ = owner.close(); throw error }
    }
    private enum Input: Sendable { case file(URL), directory(URL), skip }
    private static func classify(_ input: URL) throws -> Input {
        let url = MediaItem.normalized(input)
        guard url.isFileURL else { return .file(url) }
        guard let values = try? url.resourceValues(forKeys: keys) else {
            if url.hasDirectoryPath { throw DirectoryLibraryFailure("所选目录无法读取或已离线；原队列保留。") }
            return .file(url)
        }
        if values.isSymbolicLink == true {
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { return .skip }
        }
        guard values.isDirectory == true else {
            if url.hasDirectoryPath { throw DirectoryLibraryFailure("所选目录已被替换，原列表保留。") }
            return .file(url)
        }
        return values.isSymbolicLink == true || values.isHidden == true ? .skip : .directory(url)
    }
    static func expand(_ urls: [URL], cancellation: DirectoryScanCancellation,
                       progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> OrdinaryMediaOpenExpansion {
        guard !urls.isEmpty, urls.count <= maximumInputs else { throw DirectoryLibraryFailure("一次最多打开 128 个明确选择的路径。") }
        let started = ProcessInfo.processInfo.systemUptime
        let lists: [URL] = try await onMetadataQueue {
            var result: [URL] = []
            for url in urls {
                try check(cancellation, started: started)
                if url.isFileURL, ["m3u", "m3u8", "pls"].contains(url.pathExtension.lowercased()) {
                    result += try playlist(url, token: cancellation, started: started)
                } else { result.append(url) }
                guard result.count <= maximumEntries else { throw DirectoryLibraryFailure("展开超过 20000 个地址；原播放列表保留。") }
            }
            return result
        }
        let filtered = lists.filter(accepted)
        let subtitles = filtered.filter(MediaFormats.isSubtitle)
        guard subtitles.count <= maximumSubtitles else { throw DirectoryLibraryFailure("一次最多加载 128 个字幕地址；原队列保留。") }
        let inputs: [Input] = try await onMetadataQueue {
            try filtered.filter { !MediaFormats.isSubtitle($0) }.map(classify)
        }
        var media: [URL] = [], known = Set<URL>(), visited = 0
        func append(_ url: URL) throws {
            let normalized = MediaItem.normalized(url)
            if !MediaFormats.isSubtitle(normalized), known.insert(normalized).inserted { media.append(normalized) }
            guard media.count + subtitles.count <= maximumEntries else { throw DirectoryLibraryFailure("展开超过 20000 个媒体／字幕地址；原列表保留。") }
        }
        for input in inputs {
            try check(cancellation, started: started)
            switch input {
            case .skip: continue
            case .file(let url): try append(url)
            case .directory(let url):
                let remainingTime = maximumSeconds - (ProcessInfo.processInfo.systemUptime - started)
                guard visited < 100_000, media.count + subtitles.count < maximumEntries, remainingTime > 0.1 else {
                    throw DirectoryLibraryFailure("完整目录展开已达到总资源上限；原列表保留。")
                }
                let prior = visited
                let result = try await DirectoryLibraryScanner.scan(root: url, expected: nil, recursive: true,
                    cancellation: cancellation,
                    limits: .init(nodes: 100_000 - visited, media: maximumEntries - media.count - subtitles.count, seconds: remainingTime),
                    policy: .ordinaryOpen, progress: { progress(prior + $0) })
                visited += result.visited
                // Keep the input's standardized path/alias identity, just as MediaFormats.expand.
                // The FD-backed scanner binds the canonical root only for ownership checks.
                let ordered = try await onMetadataQueue {
                    result.files.map { url.appendingPathComponent($0.relativePath).standardizedFileURL }.sorted {
                        $0.path.localizedStandardCompare($1.path) == .orderedAscending
                    }
                }
                for file in ordered { try append(file) }
            }
        }
        try check(cancellation, started: started)
        guard !DirectoryLibraryFD.hasRetiredDescriptors else { throw DirectoryLibraryFailure("目录／列表描述符未确认释放，原列表保留。") }
        progress(visited)
        return .init(media: media, subtitles: subtitles, rejectedAddresses: lists.count - filtered.count, visited: visited)
    }
}

@MainActor
final class OrdinaryMediaOpenController: ObservableObject {
    private final class Job {
        let id = UUID()
        let cancellation = DirectoryScanCancellation()
        var task: Task<Void, Never>?
    }
    private static var owners: [UUID: OrdinaryMediaOpenController] = [:]
    private static var acceptingNewOwners = true
    static var canAcceptRequests: Bool { acceptingNewOwners }
    static var hasActiveJobs: Bool { owners.values.contains { !$0.jobs.isEmpty } }
    static func beginTermination() {
        acceptingNewOwners = false
        for owner in owners.values { owner.accepting = false; owner.cancel() }
    }
    static func shutdownAll(timeout: TimeInterval = 3) async -> Bool {
        beginTermination()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while hasActiveJobs {
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // App calls this before DirectoryLibraryController.shutdownAll; do not
        // race its watcher FDs or regard still-active watcher FDs as ours.
        return await DirectoryLibraryFD.retryRetired()
    }
    static func resumeAfterCancelledTermination() {
        acceptingNewOwners = true; for owner in owners.values { owner.accepting = true }
        // Canceled requests are never automatically replayed.
    }
    @Published private(set) var status = "尚无目录／列表打开任务"
    @Published private(set) var visited = 0
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private(set) var acceptedCount = 0
    private(set) var staleCount = 0
    private(set) var cancelledCount = 0
    private(set) var lastCommittedRequest: UUID?
    private let id = UUID()
    enum Completion: Equatable, Sendable { case committed, cancelled, stale, failed(String) }
    private var completed: [UUID: Completion] = [:]
    private var completedOrder: [UUID] = []
    private let reportError: @MainActor (String) -> Void
    private let snapshot: @MainActor () -> OrdinaryMediaOpenContext?
    private let commit: @MainActor (OrdinaryMediaOpenExpansion, Bool, Double?) -> Bool
    private var accepting = true
    private var jobs: [UUID: Job] = [:]
    private var latest: UUID?
    private var lastRequest: (urls: [URL], append: Bool, resumeAt: Double?)?
    var canRetry: Bool { !busy && accepting && Self.acceptingNewOwners && lastRequest != nil }
    var canCancel: Bool { latest != nil }
    init(snapshot: @escaping @MainActor () -> OrdinaryMediaOpenContext?,
         commit: @escaping @MainActor (OrdinaryMediaOpenExpansion, Bool, Double?) -> Bool,
         reportError: @escaping @MainActor (String) -> Void = { _ in }) {
        self.snapshot = snapshot; self.commit = commit; self.reportError = reportError; Self.owners[id] = self
    }
    func cancel() {
        latest = nil
        for job in jobs.values { job.cancellation.cancel() }
        if !jobs.isEmpty { status = "正在取消；旧队列保留，等待后台描述符真实释放。" }
    }
    func completion(for request: UUID) -> Completion? { completed[request] }
    /// Cancel only this exact request. A foreign newer open is not cancelled.
    /// Its task/FD remains registered until the real worker returns.
    func cancel(request: UUID) {
        guard let job = jobs[request] else { return }
        job.cancellation.cancel()
        if latest == request { latest = nil; status = "正在取消该打开请求，等待后台实际释放。" }
    }
    func isPending(request: UUID) -> Bool { jobs[request] != nil }

    func waitForCommit(_ request: UUID, timeout: TimeInterval = 35) async throws {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        guard jobs[request] != nil || completed[request] != nil else { throw DirectoryLibraryFailure("Unknown open request") }
        while completed[request] == nil {
            guard ProcessInfo.processInfo.systemUptime < end else { throw DirectoryLibraryFailure("Open preparation did not complete within timeout") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard completed[request] == .committed else {
            throw DirectoryLibraryFailure("Open request not committed: \(String(describing: completed[request]))")
        }
    }
    private func settle(_ request: UUID, _ result: Completion) {
        completed[request] = result; completedOrder.append(request)
        while completedOrder.count > 64 { completed.removeValue(forKey: completedOrder.removeFirst()) }
    }
    func retry() {
        if canRetry, let request = lastRequest { _ = submit(request.urls, append: request.append, resumeAt: request.resumeAt) }
    }
    @discardableResult
    func submit(_ urls: [URL], append: Bool, resumeAt: Double? = nil) -> UUID? {
        guard accepting, Self.acceptingNewOwners else { error = "播放器正在退出收尾，不能开始新的目录打开。"; reportError(error!); return nil }
        cancel()
        guard jobs.count < 4, !urls.isEmpty, urls.count <= OrdinaryMediaOpenExpansionWorker.maximumInputs else {
            error = "先等待旧扫描真实取消，或一次选择最多 128 个路径。"; reportError(error!); return nil
        }
        guard let context = snapshot() else { error = "打开目标播放器已释放。"; reportError(error!); return nil }
        let job = Job(), jobID = job.id
        jobs[job.id] = job; latest = job.id; lastRequest = (urls, append, resumeAt)
        busy = true; visited = 0; error = nil; status = "正在后台展开目录／列表；原队列继续保留，可取消。"
        job.task = Task { @MainActor in
            var outcome = Completion.cancelled
            defer {
                self.settle(jobID, outcome)
                self.jobs.removeValue(forKey: job.id)
                if self.latest == job.id { self.latest = nil }
                self.busy = !self.jobs.isEmpty
                if self.jobs.isEmpty && self.status.hasPrefix("正在取消") { self.status = "已取消；旧队列保留。" }
            }
            do {
                let expansion = try await OrdinaryMediaOpenExpansionWorker.expand(urls, cancellation: job.cancellation,
                    progress: { [weak self] count in
                        Task { @MainActor in
                            guard let self, self.latest == jobID else { return }
                            self.visited = count
                        }
                    })
                try job.cancellation.check()
                guard self.latest == job.id, self.accepting, Self.acceptingNewOwners else { throw CancellationError() }
                guard self.snapshot() == context else {
                    outcome = .stale; self.staleCount += 1
                    self.status = "队列或当前媒体已变化；旧扫描结果未应用，请明确重试。"
                    self.error = self.status; self.reportError(self.status)
                    return
                }
                guard self.commit(expansion, append, resumeAt) else {
                    self.error = "目录已展开，但当前播放请求未被接受；队列保留，未声称打开成功。"
                    outcome = .failed(self.error!); self.status = self.error!; self.reportError(self.error!); return
                }
                outcome = .committed; self.acceptedCount += 1; self.lastCommittedRequest = job.id
                self.status = "已打开 \(expansion.media.count) 个媒体；不会自动监控目录。"
            } catch is CancellationError {
                self.cancelledCount += 1
                if self.latest == job.id { self.status = "已取消；旧队列保留。" }
            } catch {
                outcome = .failed(error.localizedDescription)
                if self.latest == job.id {
                    self.error = error.localizedDescription; self.status = error.localizedDescription + "（旧队列保留）"
                    self.reportError(self.status)
                }
            }
        }
        return jobID
    }
}
