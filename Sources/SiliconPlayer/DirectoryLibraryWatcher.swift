import Foundation
import CoreServices
import Darwin
import PlayerCore

struct DirectoryWatchSignal: Sendable {
    let flags: UInt32
    let events: Int
    let requiresFullRescan: Bool
    let rootChanged: Bool
}

/// All native stream/FD state is confined to queue, including Stop/Invalidate/
/// Release. The CF context retains this owner until stream release. Events never
/// execute a player command; they only request a fresh bounded filesystem index.
final class DirectoryLibraryWatcher: @unchecked Sendable {
    struct Started: Sendable { let url: URL; let identity: DirectoryLibraryIdentity }
    struct Diagnostics: Sendable {
        let active: Bool; let fdOwned: Bool; let callbackBatches: UInt64
        let receivedEvents: UInt64; let starts: Int; let stops: Int; let closeStatus: Int32?
    }
    private let queue = DispatchQueue(label: "SiliconPlayer.directory-events", qos: .utility)
    private let receive: @Sendable (DirectoryWatchSignal) -> Void
    private var stream: FSEventStreamRef?
    private var handle: DirectoryLibraryFD?
    private var identity: DirectoryLibraryIdentity?
    private var started = false
    private var batches: UInt64 = 0, events: UInt64 = 0
    private var starts = 0, stops = 0
    private var lastClose: Int32?
    init(receive: @escaping @Sendable (DirectoryWatchSignal) -> Void) { self.receive = receive }

    func start(root: URL, expected: DirectoryLibraryIdentity? = nil) async throws -> Started {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard !DirectoryLibraryFD.hasRetiredDescriptors else { throw DirectoryLibraryFailure("先前目录描述符仍未确认释放，不能开启新监听。") }
                    guard self.stream == nil, self.handle == nil else { throw DirectoryLibraryFailure("旧监控仍未确认释放。") }
                    let (url, handle, identity) = try DirectoryLibraryScanner.openRoot(root, expected: expected)
                    self.handle = handle; self.identity = identity
                    var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                        retain: { raw in
                            guard let raw else { return nil }
                            _ = Unmanaged<DirectoryLibraryWatcher>.fromOpaque(UnsafeMutableRawPointer(mutating: raw)).retain()
                            return raw
                        }, release: { raw in
                            if let raw { Unmanaged<DirectoryLibraryWatcher>.fromOpaque(UnsafeMutableRawPointer(mutating: raw)).release() }
                        }, copyDescription: nil)
                    let callback: FSEventStreamCallback = { _, info, count, _, flags, _ in
                        guard let info else { return }
                        let owner = Unmanaged<DirectoryLibraryWatcher>.fromOpaque(info).takeUnretainedValue()
                        guard owner.started else { return }
                        var combined: UInt32 = 0
                        for i in 0..<min(count, 4096) { combined |= flags[i] }
                        owner.batches &+= 1; owner.events &+= UInt64(count)
                        let overflow = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped)
                        owner.receive(DirectoryWatchSignal(flags: combined, events: count,
                            requiresFullRescan: count > 4096 || combined & (overflow | UInt32(kFSEventStreamEventFlagUnmount)) != 0,
                            rootChanged: combined & UInt32(kFSEventStreamEventFlagRootChanged) != 0))
                    }
                    let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
                    guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                        [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else {
                        throw DirectoryLibraryFailure("无法创建原生目录监控。")
                    }
                    self.stream = stream
                    FSEventStreamSetDispatchQueue(stream, self.queue)
                    guard FSEventStreamStart(stream) else { throw DirectoryLibraryFailure("此卷的 FSEvents 监控无法启动；未宣称已经监控。") }
                    self.started = true; self.starts += 1
                    continuation.resume(returning: Started(url: url, identity: identity))
                } catch {
                    _ = self.closeOnQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    private func closeOnQueue() -> Bool {
        if let stream {
            if started { FSEventStreamStop(stream); started = false; stops += 1 }
            // SetDispatchQueue was performed even when Start failed.
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil
        }
        if let handle {
            let closed = handle.close(); lastClose = closed ? 0 : -1
            guard closed else { return false }
            self.handle = nil
        }
        return stream == nil && handle == nil && !started
    }
    func close() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.closeOnQueue()) }
        }
    }
    func diagnostics() async -> Diagnostics {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Diagnostics(active: self.started, fdOwned: self.handle != nil,
                callbackBatches: self.batches, receivedEvents: self.events, starts: self.starts, stops: self.stops, closeStatus: self.lastClose)) }
        }
    }
}
