import Foundation
import Combine
import PlayerCore

struct DirectoryLibraryFolder: Identifiable {
    let id: UUID
    var url: URL
    var identity: DirectoryLibraryIdentity?
    var recursive = true
    var files: [DirectoryLibraryFile] = []
    var status = "等待扫描"
    var scanned = 0
    var available = true
    var paused = false
    var scanning = false
    var closing = false
    var delta = DirectoryLibraryDelta.compare(old: [], new: [])
}

@MainActor
final class DirectoryLibraryController: ObservableObject {
    private final class Slot {
        let id: UUID
        var generation: UInt64 = 0
        var cancellation: DirectoryScanCancellation?
        var scan: Task<Void, Never>?
        var scanID: UUID?
        var watcher: DirectoryLibraryWatcher?
        var watchID: UUID?
        var watchClose: Task<Void, Never>?
        var retirementID: UUID?
        var closeFailed = false
        var dirty = false
        var debounce: Task<Void, Never>?
        init(_ id: UUID) { self.id = id }
    }
    private static var owners: [UUID: DirectoryLibraryController] = [:]
    private static var acceptingNewOwners = true
    static var hasActiveJobs: Bool { DirectoryLibraryFD.hasOwnedDescriptors || owners.values.contains { $0.slots.values.contains { $0.scan != nil || $0.watcher != nil || $0.watchClose != nil } } }
    static func beginTermination() {
        acceptingNewOwners = false
        for owner in owners.values { owner.accepting = false; owner.cancelScheduling() }
    }
    static func shutdownAll() async -> Bool {
        beginTermination(); var released = true
        for owner in Array(owners.values) { let stopped = await owner.shutdown(); released = stopped && released }
        let descriptorsReleased = await DirectoryLibraryFD.retryRetired()
        return released && descriptorsReleased && !hasActiveJobs
    }
    static func resumeAfterCancelledTermination() {
        acceptingNewOwners = true
        // Do not silently restart monitoring after a canceled application Quit.
        for owner in owners.values { owner.accepting = true }
    }
    static var allowsNewWindow: Bool { acceptingNewOwners }

    @Published private(set) var folders: [DirectoryLibraryFolder] = []
    @Published private(set) var error: String?
    private let ownerID = UUID()
    private var slots: [UUID: Slot] = [:]
    private var accepting = true
    var canAcceptRequests: Bool { accepting && Self.acceptingNewOwners }
    init() { Self.owners[ownerID] = self }

    private func change(_ id: UUID, _ body: (inout DirectoryLibraryFolder) -> Void) {
        if let i = folders.firstIndex(where: { $0.id == id }) { body(&folders[i]) }
    }
    func add(_ url: URL) {
        guard accepting, Self.acceptingNewOwners, slots.count < 4 else { error = "本次最多监控四个目录；退出收尾时不能新增。"; return }
        let url = url.standardizedFileURL
        guard !folders.contains(where: { $0.url == url }) else { error = "此目录已在清单中。"; return }
        let id = UUID(); slots[id] = Slot(id)
        folders.append(DirectoryLibraryFolder(id: id, url: url)); refresh(id)
    }
    func setRecursive(_ id: UUID, _ recursive: Bool) {
        guard accepting, let folder = folders.first(where: { $0.id == id }), !folder.closing,
              let slot = slots[id] else { return }
        cancelScan(id); change(id) { $0.recursive = recursive }
        slot.dirty = true
        if slot.scan == nil { refresh(id) }
    }
    func cancelScan(_ id: UUID) {
        guard let slot = slots[id], slot.retirementID == nil else { return }
        slot.generation &+= 1; slot.cancellation?.cancel(); slot.dirty = false
        slot.debounce?.cancel(); slot.debounce = nil
        change(id) { $0.status = "扫描已取消，旧清单保留；如需停止监听请暂停。" }
    }
    private func signal(_ signal: DirectoryWatchSignal, rootID: UUID, watchID: UUID) {
        guard accepting, let slot = slots[rootID], slot.watchID == watchID,
              let folder = folders.first(where: { $0.id == rootID }), !folder.paused, !folder.closing else { return }
        if signal.rootChanged {
            change(rootID) { $0.available = false; $0.paused = true }
            Task { @MainActor in await self.pause(rootID, message: "目录或祖先已移动／卷已卸载，监控已停止。请重新选择目录。") }
            return
        }
        if signal.requiresFullRescan { change(rootID) { $0.status = "原生事件合并或丢失，正在重新核对完整清单。" } }
        slot.dirty = true; schedule(slot)
    }
    private func schedule(_ slot: Slot) {
        guard accepting, slot.debounce == nil, slot.scan == nil else { return }
        slot.debounce = Task { @MainActor [weak self, weak slot] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, let slot else { return }
            slot.debounce = nil
            if slot.dirty { self.refresh(slot.id) }
        }
    }
    func refresh(_ id: UUID) {
        guard accepting, let slot = slots[id], let folder = folders.first(where: { $0.id == id }), !folder.closing else { return }
        if slot.scan != nil { slot.dirty = true; return }
        guard slot.watchClose == nil, !slot.closeFailed else { error = "旧监控资源尚未确认释放，请再次暂停或移除。"; return }
        slot.debounce?.cancel(); slot.debounce = nil; slot.dirty = false
        let generation = slot.generation, job = UUID(), cancellation = DirectoryScanCancellation()
        slot.cancellation = cancellation; slot.scanID = job
        change(id) { $0.scanning = true; $0.scanned = 0; $0.status = "正在后台扫描；可取消。" }
        slot.scan = Task { @MainActor in
            defer {
                if slot.scanID == job {
                    slot.scan = nil; slot.scanID = nil; slot.cancellation = nil
                    self.change(id) { $0.scanning = false }
                    if slot.dirty, self.accepting, self.folders.first(where: { $0.id == id })?.paused == false { self.schedule(slot) }
                }
            }
            do {
                var root = folder.url, expected = folder.identity
                if !folder.paused, slot.watcher == nil {
                    let watchID = UUID()
                    let watcher = DirectoryLibraryWatcher { [weak self] signal in
                        Task { @MainActor in self?.signal(signal, rootID: id, watchID: watchID) }
                    }
                    // Publish native ownership before the first await. Pause/Quit
                    // can retire a stream whose Start is still running.
                    slot.watcher = watcher; slot.watchID = watchID
                    let started = try await watcher.start(root: root, expected: expected)
                    // Even cancellation during native Start keeps its actual root
                    // binding. A later refresh cannot rebind a still-owned old stream.
                    guard slot.watcher === watcher, slot.watchID == watchID else { throw CancellationError() }
                    root = started.url; expected = started.identity
                    self.change(id) { $0.url = root; $0.identity = expected }
                    try cancellation.check()
                    guard slot.generation == generation, self.accepting else { throw CancellationError() }
                    guard !self.folders.contains(where: { $0.id != id && $0.url == started.url }) else { throw DirectoryLibraryFailure("此真实目录已在清单中。") }
                }
                let result = try await DirectoryLibraryScanner.scan(root: root, expected: expected,
                    recursive: folder.recursive, cancellation: cancellation, progress: { [weak self] count in
                        Task { @MainActor in
                            guard let self, self.slots[id]?.scanID == job, self.slots[id]?.generation == generation else { return }
                            self.change(id) { $0.scanned = count }
                        }
                    })
                try cancellation.check()
                guard slot.scanID == job, slot.generation == generation, self.accepting else { throw CancellationError() }
                self.change(id) {
                    $0.delta = DirectoryLibraryDelta.compare(old: $0.files, new: result.files)
                    $0.files = result.files; $0.url = result.root; $0.identity = result.identity
                    $0.available = true; $0.scanned = result.visited
                    $0.status = ($0.paused ? "暂停监听；手动扫描完成" : "监听中；扫描完成")
                        + " · \(result.files.count) 个媒体 · \(result.directories) 个目录 · 跳过 \(result.skipped) 项"
                }
            } catch is CancellationError {
                // Cancellation/old generation never replaces the old snapshot.
            } catch {
                if slot.scanID == job, slot.generation == generation {
                    self.change(id) { $0.available = false; $0.paused = true; $0.status = error.localizedDescription + "（旧清单保留；监听暂停）" }
                    self.startWatchClose(slot)
                }
            }
        }
    }
    private func startWatchClose(_ slot: Slot) {
        guard slot.watchClose == nil, let watcher = slot.watcher else { return }
        let watchID = slot.watchID
        slot.watchClose = Task { @MainActor in
            let closed = await watcher.close()
            guard slot.watcher === watcher, slot.watchID == watchID else { return }
            slot.watchClose = nil; slot.closeFailed = !closed
            if closed { slot.watcher = nil; slot.watchID = nil }
        }
    }
    private func release(_ slot: Slot, timeout: TimeInterval = 3) async -> Bool {
        slot.generation &+= 1; slot.cancellation?.cancel(); slot.dirty = false
        slot.debounce?.cancel(); slot.debounce = nil
        startWatchClose(slot)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while slot.scan != nil || slot.watchClose != nil {
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let retainedClosed = await DirectoryLibraryFD.retryRetired()
        return slot.watcher == nil && !slot.closeFailed && retainedClosed
    }
    // Keep the retirement token through the post-await mutation. Concurrent
    // callers cannot resume or clear a newer operation's native owner.
    private func retire(_ slot: Slot, completion: (Bool) -> Void) async -> Bool {
        guard slot.retirementID == nil else { return false }
        let attempt = UUID(); slot.retirementID = attempt
        defer { if slot.retirementID == attempt { slot.retirementID = nil } }
        let released = await release(slot)
        guard slots[slot.id] === slot, slot.retirementID == attempt else { return false }
        completion(released)
        return released
    }
    func pause(_ id: UUID, message: String = "监听已暂停；可手动刷新。") async {
        guard let slot = slots[id], slot.retirementID == nil else { return }
        change(id) { $0.paused = true; $0.closing = true; $0.status = "正在取消扫描并释放原生监听。" }
        _ = await retire(slot) { released in
            self.change(id) { $0.closing = !released; $0.status = released ? message : "资源未确认释放；请再次暂停或移除，原任务仍受本程序持有。" }
        }
    }
    func resume(_ id: UUID) {
        guard accepting, let folder = folders.first(where: { $0.id == id }), !folder.closing,
              let slot = slots[id], slot.retirementID == nil, slot.scan == nil, slot.watcher == nil else { return }
        change(id) { $0.paused = false }; refresh(id)
    }
    func remove(_ id: UUID) async {
        guard let slot = slots[id], slot.retirementID == nil else { return }
        change(id) { $0.paused = true; $0.closing = true; $0.status = "正在移除；不会删除磁盘文件。" }
        _ = await retire(slot) { released in
            guard released else {
                self.change(id) { $0.status = "移除尚未完成；资源仍受持有，可再次移除。" }; return
            }
            self.slots.removeValue(forKey: id); self.folders.removeAll { $0.id == id }
        }
    }
    private func cancelScheduling() {
        for slot in slots.values { slot.debounce?.cancel(); slot.debounce = nil; slot.dirty = false; slot.cancellation?.cancel() }
    }
    func shutdown() async -> Bool {
        accepting = false; cancelScheduling(); var complete = true
        for slot in Array(slots.values) {
            change(slot.id) { $0.paused = true; $0.closing = true }
            let released = await retire(slot) { released in
                self.change(slot.id) { $0.closing = !released; $0.status = released ? "已释放监听与扫描；恢复监听需要明确点击。" : "目录任务尚在收尾。" }
            }
            complete = released && complete
        }
        return complete
    }
    func resumeAfterWindowCloseFailure() {
        if Self.acceptingNewOwners { accepting = true }
    }
    func closeWindowOwner() async -> Bool {
        let closed = await shutdown()
        if closed { Self.owners.removeValue(forKey: ownerID) }
        return closed
    }
    func diagnostics() async -> [String: Any] {
        var watches: [[String: Any]] = []
        for slot in slots.values {
            if let watcher = slot.watcher {
                let d = await watcher.diagnostics()
                watches.append(["id": slot.id.uuidString, "active": d.active, "fdOwned": d.fdOwned,
                    "batches": d.callbackBatches, "events": d.receivedEvents, "starts": d.starts, "stops": d.stops])
            }
        }
        return ["scanJobs": slots.values.filter { $0.scan != nil }.count,
                "watchOwners": slots.values.filter { $0.watcher != nil }.count,
                "closeJobs": slots.values.filter { $0.watchClose != nil }.count,
                "watches": watches, "accepting": accepting, "ownedDescriptors": DirectoryLibraryFD.ownedDescriptorCount]
    }
}
