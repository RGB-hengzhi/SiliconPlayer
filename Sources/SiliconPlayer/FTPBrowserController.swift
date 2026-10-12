import Foundation
import AppKit
import Darwin
import Combine
import RemoteTransferBridge
import PlayerCore

private struct FTPNativeReceipt: Sendable {
    let published: Bool, released: Bool, cancelled: Bool
    let code: Int, response: Int, stage: String
    let bytes: Int64
    let listing: Data?
    init(_ d: [AnyHashable: Any]) {
        published = d["published"] as? Bool == true; released = d["released"] as? Bool == true
        cancelled = d["cancelled"] as? Bool == true; code = (d["curlCode"] as? NSNumber)?.intValue ?? -1
        response = (d["responseCode"] as? NSNumber)?.intValue ?? -1; stage = d["stage"] as? String ?? "missing-receipt"
        bytes = (d["received"] as? NSNumber)?.int64Value ?? -1; listing = d["listing"] as? Data
    }
}

/// Sendability is confined to an audited native object whose cancel, snapshot,
/// and retryCleanup use one lock. Only one private serial worker calls execute.
private final class FTPNativeOwner: @unchecked Sendable {
    let native: SPFTPTransfer
    let queue = DispatchQueue(label: "SiliconPlayer.ftp-owned-worker", qos: .utility)
    init(_ native: SPFTPTransfer) { self.native = native }
    func execute() async -> FTPNativeReceipt {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: FTPNativeReceipt(self.native.execute())) }
        }
    }
    func cancel() { native.cancel() }
    func retry() async -> Bool {
        await withCheckedContinuation { c in queue.async { c.resume(returning: self.native.retryCleanup()) } }
    }
}

/// A failed exclusive mkdir retains the actual descriptor stack and namespace
/// until the matching empty directory was really removed. All fields below are
/// guarded by lock; only utility workers call retryCleanup. No FD has had close
/// attempted when this ownership is transferred out of createCacheFolder.
private final class FTPEmptyCacheOwner: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptors: [DirectoryLibraryFD]
    private let parent: DirectoryLibraryFD
    private let name: String
    private let parentDevice: dev_t, parentInode: ino_t
    private let directoryIdentity: (device: dev_t, inode: ino_t)?
    private var directoryRemoved = false
    init(descriptors: [DirectoryLibraryFD], parent: DirectoryLibraryFD, name: String,
         parentDevice: dev_t, parentInode: ino_t, directoryIdentity: (device: dev_t, inode: ino_t)?) {
        self.descriptors = descriptors; self.parent = parent; self.name = name
        self.parentDevice = parentDevice; self.parentInode = parentInode; self.directoryIdentity = directoryIdentity
    }
    func retryCleanup() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !directoryRemoved {
            // No close attempt precedes this deletion. Missing/changed identity
            // stays owned and failed; absence alone cannot prove moved dir release.
            guard let directoryIdentity else { return false }
            var heldParent = stat(), named = stat()
            guard fstat(parent.descriptor, &heldParent) == 0,
                  heldParent.st_dev == parentDevice, heldParent.st_ino == parentInode,
                  heldParent.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  fstatat(parent.descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  named.st_dev == directoryIdentity.device, named.st_ino == directoryIdentity.inode,
                  unlinkat(parent.descriptor, name, AT_REMOVEDIR) == 0 else { return false }
            directoryRemoved = true
        }
        // Once rmdir succeeded, never again issue unlinkat on a numeric parent FD.
        // DirectoryLibraryFD retries only accept EBADF and never reclose a reused FD.
        var released = true
        for owner in descriptors.reversed() { released = owner.close() && released }
        return released
    }
}

@MainActor
final class FTPBrowserController: ObservableObject {
    @Published var addressText = "ftp://"
    @Published var username = ""
    @Published var password = ""
    @Published var requireTLS = true
    @Published private(set) var certificateAuthority: FTPCertificateAuthority?
    private var certificatePanel: NSOpenPanel?
    @Published private(set) var resources: [FTPDirectoryResource] = []
    @Published private(set) var directory: FTPDirectoryAddress?
    @Published private(set) var busy = false
    @Published private(set) var status = "明确连接 FTP/FTPS；默认要求控制与数据通道 TLS。"
    @Published private(set) var error: String?
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var expectedBytes: Int64?
    @Published private(set) var readyCopies: [URL: URL] = [:]
    @Published private(set) var accepting = true
    @MainActor private final class Job {
        let id = UUID()
        var native: FTPNativeOwner?
        var task: Task<Void, Never>?
        var cancelled = false
        var folder: URL?
        var cleanupFailed = false
        var allocationCleanup: FTPEmptyCacheOwner?
        var playbackController: OrdinaryMediaOpenController?
        var playbackRequest: UUID?
    }
    private struct CacheAllocation: Sendable {
        let folder: URL; let descriptorsClosed: Bool
        let failedCreation: FTPEmptyCacheOwner?
    }
    private let id = UUID()
    private var jobs: [UUID: Job] = [:]
    private var latest: UUID?
    private var closeAttempt: UUID?
    private var progressTimer: Timer?
    private var lastDirectory: FTPDirectoryAddress?
    private static var owners: [UUID: FTPBrowserController] = [:]
    private static var acceptsNewOwners = true
    private let keychain = FTPKeychainStore()

    init() { Self.owners[id] = self }
    static var hasActiveJobs: Bool { owners.values.contains { !$0.jobs.isEmpty } }
    static var canCreate: Bool { acceptsNewOwners }
    var canRequest: Bool { accepting && Self.acceptsNewOwners && jobs.isEmpty && certificatePanel == nil && !DirectoryLibraryFD.hasRetiredDescriptors }
    var capabilities: [AnyHashable: Any] { SPFTPTransfer.capabilities() }
    func chooseCertificateAuthority() {
        guard canRequest else { return }
        do {
            let scope = FTPCertificateAuthority.Scope(try FTPDirectoryAddress(addressText, requireTLS: requireTLS))
            guard scope.requiresTLS else { throw FTPCertificateFailure.invalidSource }
            let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false; panel.title = "只为该 FTP/FTPS 连接选择 CA PEM"
            certificatePanel = panel
            panel.begin { [weak self, weak panel] response in
                MainActor.assumeIsolated {
                    guard let self, let panel, self.certificatePanel === panel else { return }
                    self.certificatePanel = nil
                    guard response == .OK, let url = panel.url, self.canRequest else { return }
                    self.begin("正在验证明确选择的 CA PEM…") { [self] job in
                        let value = try await Self.onWorker { try FTPCertificateAuthority.load(url, scope: scope) }
                        guard self.stillCurrent(job) else { throw CancellationError() }
                        self.certificateAuthority = value
                        self.status = "已选择当前连接 CA；系统信任与钥匙串未改变。"
                    }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func restoreSystemTrust() {
        guard canRequest else { return }; certificateAuthority = nil
        status = "已恢复下一请求的系统默认信任；仍严格校验证书链与主机名。"
    }
    private func authority(for endpoint: FTPDirectoryAddress) throws -> Data? {
        guard let certificateAuthority else { return nil }
        guard certificateAuthority.scope == FTPCertificateAuthority.Scope(endpoint) else { throw FTPCertificateFailure.differentConnection }
        return certificateAuthority.pem
    }
    private func allocateFolder(_ job: Job) async throws -> URL {
        let allocation = try await Self.onWorker { try Self.createCacheFolder() }
        if let cleanup = allocation.failedCreation {
            job.allocationCleanup = cleanup; job.cleanupFailed = true; throw FTPBrowserFailure.cacheUnavailable
        }
        job.folder = allocation.folder
        guard allocation.descriptorsClosed else { job.cleanupFailed = true; throw FTPBrowserFailure.cleanupPending }
        return allocation.folder
    }
    private func credentials() throws -> (String, String) {
        let user = username.isEmpty ? "anonymous" : username
        let secret = username.isEmpty ? "SiliconPlayer@" : password
        try FTPKeychainStore.validate(username: user, password: secret); return (user, secret)
    }
    private func begin(_ message: String, body: @escaping @MainActor (Job) async throws -> Void) {
        guard canRequest else { error = "上一请求仍在收尾，或退出接受门已关闭。"; return }
        let job = Job(); jobs[job.id] = job; latest = job.id; busy = true
        status = message; error = nil; receivedBytes = 0; expectedBytes = nil
        job.task = Task { @MainActor [self, job] in
            defer {
                // Failure to prove native FD/handle cleanup retains the exact
                // job. A new request is blocked until actual retry succeeds.
                job.task = nil
                if !job.cleanupFailed { jobs.removeValue(forKey: job.id) }
                if latest == job.id { busy = false; stopProgress() }
            }
            do {
                guard stillCurrent(job) else { throw CancellationError() }
                try await body(job)
            }
            catch {
                if latest == job.id {
                    if job.cancelled || error is CancellationError { status = "请求已取消并完成实际清理；已经确认提交的播放不会回滚。" }
                    else { self.error = error.localizedDescription }
                }
            }
        }
    }
    private func stillCurrent(_ job: Job) -> Bool {
        accepting && Self.acceptsNewOwners && jobs[job.id] === job && latest == job.id && !job.cancelled
    }
    private func run(_ job: Job, address: URL, credentials: (String, String), tls: Bool,
                     listing: Bool, folder: URL? = nil, name: String? = nil, ca: Data? = nil) async throws -> FTPNativeReceipt {
        let ownsCAOnlyFolder = ca != nil && folder == nil
        let nativeFolder: URL?
        if ownsCAOnlyFolder { nativeFolder = try await allocateFolder(job) }
        else { nativeFolder = folder }
        let n = SPFTPTransfer(address: address, username: credentials.0, password: credentials.1,
            requireTLS: tls, listingMode: listing, outputFolder: nativeFolder, outputName: name,
            maximumBytes: listing ? 8 * 1_048_576 : 20 * 1_073_741_824, certificateAuthorityPEM: ca)
        let owner = FTPNativeOwner(n); job.native = owner
        if job.cancelled || !accepting || !Self.acceptsNewOwners { owner.cancel() }
        startProgress(job)
        let receipt = await owner.execute()
        guard jobs[job.id] === job else { throw FTPBrowserFailure.cleanupPending }
        job.cleanupFailed = !receipt.released
        guard receipt.released else { throw FTPBrowserFailure.cleanupPending }
        job.native = nil
        if ownsCAOnlyFolder, let nativeFolder {
            do { try await Self.onWorker { try FileManager.default.removeItem(at: nativeFolder) }; job.folder = nil }
            catch { job.cleanupFailed = true; throw FTPBrowserFailure.cleanupPending }
        }
        if job.cancelled || receipt.cancelled { throw CancellationError() }
        guard receipt.published && receipt.code == 0 else { throw FTPBrowserFailure.native(stage: receipt.stage, code: receipt.code, reply: receipt.response) }
        return receipt
    }
    func connect(_ chosen: FTPDirectoryAddress? = nil) {
        do {
            let endpoint = try chosen ?? FTPDirectoryAddress(addressText, requireTLS: requireTLS)
            let c = try credentials(), ca = try authority(for: endpoint)
            begin("正在连接并读取 MLSD 当前目录…") { [self] job in
                let result = try await run(job, address: endpoint.url, credentials: c, tls: endpoint.requireTLS, listing: true, ca: ca)
                guard let data = result.listing else { throw FTPBrowserFailure.malformedListing }
                // Parse on a utility worker, not on the main actor; its returned document is a bounded Sendable value.
                let parsed = try await Self.onWorker { try FTPDirectoryDocument.parse(data, at: endpoint) }
                guard stillCurrent(job) else { throw CancellationError() }
                directory = endpoint; lastDirectory = endpoint; addressText = endpoint.url.absoluteString
                resources = parsed; status = "已读取 \(parsed.count) 项；当前播放和队列未改变。"
            }
        } catch { self.error = error.localizedDescription }
    }
    func diagnostics() -> [String: Any] {
        ["accepting": accepting && Self.acceptsNewOwners, "busy": busy, "jobCount": jobs.count,
         "readyCopyCount": readyCopies.count, "closeAttemptPresent": closeAttempt != nil, "jobs": jobs.values.map {
             ["id": $0.id.uuidString, "taskPending": $0.task != nil, "cancelled": $0.cancelled,
              "cleanupFailed": $0.cleanupFailed, "openRequestPending": $0.playbackRequest != nil, "native": $0.native?.native.snapshot() ?? [:]] as [String: Any]
         }]
    }
    func reconnect() { if let lastDirectory { connect(lastDirectory) } else { connect() } }
    func disconnect() async {
        guard await shutdown() else { error = FTPBrowserFailure.cleanupPending.localizedDescription; return }
        resources = []; directory = nil; status = "已断开并清空当前清单与内存凭据；本机副本和播放器队列保留。"
        resumeAfterWindowCloseFailure()
    }
    func download(_ resource: FTPDirectoryResource, player: PlayerModel, append: Bool = false) {
        guard readyCopies.count < 32, !resource.isDirectory, let endpoint = directory, resources.contains(resource), endpoint.accepts(resource.url),
              !player.profileRecoveryBlocked else { error = "当前文件或播放配置不可用。"; return }
        do {
            let c = try credentials(), context = player.ordinaryMediaOpenContext(), ca = try authority(for: endpoint)
            begin("正在下载；只有完整成功后才可播放…") { [self, weak player] job in
                let allocation = try await Self.onWorker { try Self.createCacheFolder() }
                let folder = allocation.folder
                if let cleanup = allocation.failedCreation {
                    // Register the failed mkdir namespace before throwing. This
                    // job cannot disappear while its real parent/FD owner remains.
                    job.allocationCleanup = cleanup; job.cleanupFailed = true
                    throw FTPBrowserFailure.cacheUnavailable
                }
                job.folder = folder
                guard allocation.descriptorsClosed else { job.cleanupFailed = true; throw FTPBrowserFailure.cleanupPending }
                let name = Self.cacheName(resource.url)
                do {
                    let result = try await run(job, address: resource.url, credentials: c, tls: endpoint.requireTLS,
                                               listing: false, folder: folder, name: name, ca: ca)
                    let destination = folder.appendingPathComponent(name)
                    guard result.bytes > 0 else { throw FTPBrowserFailure.cacheUnavailable }
                    guard stillCurrent(job) else { throw CancellationError() }
                    readyCopies[resource.url] = destination
                    job.folder = nil // complete durable cache retained for explicit later Play
                    guard let player, !player.profileRecoveryBlocked, player.ordinaryMediaOpenContext() == context else {
                        status = FTPBrowserFailure.stalePlayback.localizedDescription; return
                    }
                    try await commitCopy(job, player: player, destination: destination, append: append)
                } catch {
                    if !job.cleanupFailed && job.folder != nil {
                        do { try await Self.onWorker { try FileManager.default.removeItem(at: folder) }; job.folder = nil }
                        catch { job.cleanupFailed = true; throw FTPBrowserFailure.cleanupPending }
                    }
                    throw error
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func commitCopy(_ job: Job, player: PlayerModel, destination: URL, append: Bool) async throws {
        guard stillCurrent(job), !player.profileRecoveryBlocked,
              let request = player.open([destination], append: append) else {
            throw FTPBrowserFailure.playbackOpenFailed
        }
        let owner = player.ordinaryMediaOpen
        job.playbackController = owner; job.playbackRequest = request
        let end = ProcessInfo.processInfo.systemUptime + 35
        var timedOut = false
        while owner.completion(for: request) == nil {
            guard owner.isPending(request: request) else {
                job.playbackRequest = nil; job.playbackController = nil
                throw FTPBrowserFailure.playbackOpenFailed
            }
            if !stillCurrent(job) { owner.cancel(request: request) }
            if ProcessInfo.processInfo.systemUptime >= end && !timedOut {
                timedOut = true; owner.cancel(request: request)
                if latest == job.id { error = "本机副本打开超时；正在等待该元数据任务真实释放，未声称加入成功。" }
            }
            // Do not clear this job on timeout/cancel while its exact metadata
            // worker is still alive. Global quit retries retain both registries.
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let completion = owner.completion(for: request)
        job.playbackRequest = nil; job.playbackController = nil
        guard stillCurrent(job), !timedOut else { throw CancellationError() }
        guard completion == .committed else { throw FTPBrowserFailure.playbackOpenFailed }
        status = append ? "本机副本已由播放器确认加入队列。" : "本机副本打开请求已确认提交；实际解码加载仍由播放器状态确认。"
    }
    func playCopy(_ resource: FTPDirectoryResource, player: PlayerModel, append: Bool = false) {
        guard canRequest, let url = readyCopies[resource.url], !player.profileRecoveryBlocked else { return }
        let context = player.ordinaryMediaOpenContext()
        begin("正在明确提交本机副本…") { [self, weak player] job in
            guard let player, player.ordinaryMediaOpenContext() == context else { throw FTPBrowserFailure.stalePlayback }
            try await commitCopy(job, player: player, destination: url, append: append)
        }
    }
    func keychainAction(_ action: String) {
        do {
            let endpoint = try FTPDirectoryAddress(addressText, requireTLS: requireTLS)
            let user = username, secret = password, store = keychain
            try FTPKeychainStore.validate(username: user, password: secret)
            begin("正在完成明确的钥匙串操作…") { [self] job in
                let value: String? = try await Self.onWorker {
                    switch action {
                    case "save": try store.save(endpoint, username: user, password: secret); return nil
                    case "read": return try store.read(endpoint, username: user)
                    case "delete": try store.delete(endpoint, username: user); return nil
                    default: throw FTPBrowserFailure.invalidCredentials
                    }
                }
                guard stillCurrent(job) else { throw CancellationError() }
                if action == "read" { password = value ?? ""; status = value == nil ? "该协议、主机、端口、TLS 模式与账号未保存凭据。" : "已从本程序的精确钥匙串项读取密码。" }
                else { status = action == "save" ? "已明确保存到本机钥匙串；配置备份不含密码。" : "已删除精确钥匙串项。" }
            }
        } catch { self.error = error.localizedDescription }
    }
    func cancel() {
        for job in jobs.values {
            job.cancelled = true; job.native?.cancel()
            if let request = job.playbackRequest { job.playbackController?.cancel(request: request) }
        }
        status = "正在取消并等待原生清理；旧清单保留。"
    }
    func shutdown(timeout: TimeInterval = 3) async -> Bool {
        guard closeAttempt == nil else { return false }
        let attempt = UUID(); closeAttempt = attempt
        defer { if closeAttempt == attempt { closeAttempt = nil } }
        accepting = false; certificatePanel?.cancel(nil); certificatePanel = nil; cancel()
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while jobs.values.contains(where: { $0.task != nil }) {
            if ProcessInfo.processInfo.systemUptime >= end { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard await DirectoryLibraryFD.retryRetired(), closeAttempt == attempt else { return false }
        for job in Array(jobs.values) {
            if let allocation = job.allocationCleanup {
                let released = (try? await Self.onWorker { allocation.retryCleanup() }) == true
                guard closeAttempt == attempt, jobs[job.id] === job, released else { job.cleanupFailed = true; return false }
                job.allocationCleanup = nil
            }
            if let native = job.native {
                let released = await native.retry()
                guard closeAttempt == attempt, jobs[job.id] === job, released else { return false }
            }
            if let folder = job.folder {
                do {
                    try await Self.onWorker { try FileManager.default.removeItem(at: folder) }
                    guard closeAttempt == attempt, jobs[job.id] === job else { return false }
                }
                catch { job.cleanupFailed = true; return false }
            }
            jobs.removeValue(forKey: job.id)
        }
        let descriptorsClosed = await DirectoryLibraryFD.retryRetired()
        guard closeAttempt == attempt, descriptorsClosed else { return false }
        stopProgress(); password = ""; username = ""; certificateAuthority = nil; return jobs.isEmpty
    }
    func releaseWindow() async -> Bool {
        let done = await shutdown(); if done { Self.owners.removeValue(forKey: id) }; return done
    }
    static func beginTermination() {
        acceptsNewOwners = false
        owners.values.forEach { $0.accepting = false; $0.certificatePanel?.cancel(nil); $0.certificatePanel = nil; $0.cancel() }
    }
    static func shutdownAll() async -> Bool {
        var done = true
        for owner in Array(owners.values) { done = await owner.shutdown() && done }
        return done && !hasActiveJobs
    }
    static func resumeAfterCancelledTermination() {
        acceptsNewOwners = true
        for owner in owners.values { if owner.jobs.isEmpty && owner.closeAttempt == nil { owner.accepting = true } }
    }
    func resumeAfterWindowCloseFailure() { if Self.acceptsNewOwners && jobs.isEmpty && closeAttempt == nil { accepting = true } }
    private func startProgress(_ job: Job) {
        stopProgress()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self, weak job] _ in
            MainActor.assumeIsolated {
                guard let self, let job, self.latest == job.id, let native = job.native else { return }
                let d = native.native.snapshot()
                self.receivedBytes = (d["received"] as? NSNumber)?.int64Value ?? 0
                let n = (d["expected"] as? NSNumber)?.int64Value ?? -1; self.expectedBytes = n > 0 ? n : nil
            }
        }
        progressTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func stopProgress() { progressTimer?.invalidate(); progressTimer = nil }
    private nonisolated static func onWorker<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { do { continuation.resume(returning: try action()) } catch { continuation.resume(throwing: error) } }
        }
    }
    private nonisolated static func createCacheFolder() throws -> CacheAllocation {
        guard !DirectoryLibraryFD.hasRetiredDescriptors,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let physical = Darwin.realpath(support.path, nil) else { throw FTPBrowserFailure.cacheUnavailable }
        let rootPath = String(cString: physical); Darwin.free(physical)
        // Compare physical filesystem paths only; Foundation directory URL slash
        // spelling is not an ownership test. Every created component is FD-bound.
        var owners: [DirectoryLibraryFD] = []
        var created: (parent: DirectoryLibraryFD, name: String, path: String,
                      parentDevice: dev_t, parentInode: ino_t,
                      identity: (device: dev_t, inode: ino_t)?)?
        defer { for owner in owners.reversed() { _ = owner.close() } }
        func bind(_ fd: Int32, privateDirectory: Bool) throws -> DirectoryLibraryFD {
            guard fd >= 0 else { throw FTPBrowserFailure.cacheUnavailable }
            let owner = DirectoryLibraryFD(fd); owners.append(owner)
            var item = stat(), filesystem = statfs()
            guard fstat(fd, &item) == 0, item.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  fstatfs(fd, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw FTPBrowserFailure.cacheUnavailable }
            if privateDirectory {
                guard item.st_uid == geteuid(), item.st_mode & mode_t(0o777) == mode_t(0o700) else { throw FTPBrowserFailure.cacheUnavailable }
            }
            return owner
        }
        let root = try bind(Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK), privateDirectory: false)
        var parent = root
        do {
            for name in ["SiliconPlayer", "FTPCache"] {
                let status = mkdirat(parent.descriptor, name, 0o700)
                guard status == 0 || errno == EEXIST else { throw FTPBrowserFailure.cacheUnavailable }
                parent = try bind(openat(parent.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK),
                                  privateDirectory: name == "FTPCache")
            }
            let name = UUID().uuidString
            var parentIdentity = stat()
            guard fstat(parent.descriptor, &parentIdentity) == 0 else { throw FTPBrowserFailure.cacheUnavailable }
            let destinationPath = rootPath + "/SiliconPlayer/FTPCache/" + name
            guard mkdirat(parent.descriptor, name, 0o700) == 0 else { throw FTPBrowserFailure.cacheUnavailable }
            // Retain namespace immediately after the successful exclusive mkdir;
            // even failure of the very first identity read cannot erase ownership.
            created = (parent, name, destinationPath, parentIdentity.st_dev, parentIdentity.st_ino, nil)
            var newlyCreated = stat()
            guard fstatat(parent.descriptor, name, &newlyCreated, AT_SYMLINK_NOFOLLOW) == 0,
                  newlyCreated.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw FTPBrowserFailure.cacheUnavailable }
            created?.identity = (newlyCreated.st_dev, newlyCreated.st_ino)
            let folder = try bind(openat(parent.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK), privateDirectory: true)
            var held = stat(), named = stat()
            guard fstat(folder.descriptor, &held) == 0,
                  fstatat(parent.descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  held.st_dev == newlyCreated.st_dev, held.st_ino == newlyCreated.st_ino,
                  held.st_dev == named.st_dev, held.st_ino == named.st_ino,
                  fsync(parent.descriptor) == 0 else { throw FTPBrowserFailure.cacheUnavailable }
            var destinationIdentity = stat()
            guard lstat(destinationPath, &destinationIdentity) == 0,
                  destinationIdentity.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  destinationIdentity.st_dev == held.st_dev, destinationIdentity.st_ino == held.st_ino else {
                throw FTPBrowserFailure.cacheUnavailable
            }
            // Once any parent close has been attempted its numeric FD cannot be
            // used for unlinkat. Return the owned empty folder even on close
            // failure so the job retains it; the real FD registry retains native
            // descriptors, and shutdown retries that registry before deleting it.
            created = nil
            var closed = true
            for owner in owners.reversed() { closed = owner.close() && closed }
            return CacheAllocation(folder: URL(fileURLWithPath: destinationPath, isDirectory: true), descriptorsClosed: closed, failedCreation: nil)
        } catch {
            if let created {
                let cleanup = FTPEmptyCacheOwner(descriptors: owners, parent: created.parent, name: created.name,
                    parentDevice: created.parentDevice, parentInode: created.parentInode, directoryIdentity: created.identity)
                owners = [] // transfer before defer; no numeric FD close/reuse window
                return CacheAllocation(folder: URL(fileURLWithPath: created.path, isDirectory: true),
                                       descriptorsClosed: false, failedCreation: cleanup)
            }
            throw error
        }
    }
    private nonisolated static func cacheName(_ url: URL) -> String {
        let name = url.lastPathComponent
        let safe = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined().replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        if !safe.isEmpty && safe != "." && safe != ".." && safe.utf8.count <= 180 { return safe }
        let ext = url.pathExtension.lowercased()
        let allowed = ext.count <= 12 && ext.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        var prefix = ""
        for character in (safe as NSString).deletingPathExtension {
            if (prefix + String(character)).utf8.count > 150 { break }; prefix.append(character)
        }
        if prefix.isEmpty { prefix = "media" }
        return prefix + (allowed && !ext.isEmpty ? "." + ext : "")
    }
}
