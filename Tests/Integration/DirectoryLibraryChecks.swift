import Foundation
import Darwin
import PlayerCore

private struct CheckFailure: Error { let message: String }
private final class Signals: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DirectoryWatchSignal] = []
    func receive(_ signal: DirectoryWatchSignal) { lock.lock(); values.append(signal); lock.unlock() }
    func snapshot() -> [DirectoryWatchSignal] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Prepared-only checks: real temporary directory + real SDK FSEvents, no
/// PlayerModel stub, no media decode, no synthetic native event or fake close.
@main @MainActor
struct DirectoryLibraryChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw CheckFailure(message: message) }
    }
    static func eventually(_ predicate: () -> Bool, seconds: Double = 6) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate() {
            if ProcessInfo.processInfo.systemUptime > deadline { throw CheckFailure(message: "real event/scan timeout") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    static func put(_ url: URL, _ text: String = "fixture metadata only") throws { try Data(text.utf8).write(to: url) }
    static func scan(_ root: URL, recursive: Bool = true, cancellation: DirectoryScanCancellation = .init(),
                     limits: DirectoryScanLimits = .init()) async throws -> DirectoryLibraryScanResult {
        try await DirectoryLibraryScanner.scan(root: root, expected: nil, recursive: recursive,
            cancellation: cancellation, limits: limits)
    }
    static func main() async {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("SP-directory-check-" + UUID().uuidString)
        var passed: [String] = []
        var failures: [String] = []
        var observations: [String: Any] = [:]
        var watchers: [DirectoryLibraryWatcher] = []
        var controllers: [DirectoryLibraryController] = []
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
            let root = base.appendingPathComponent("目录 中文")
            let child = root.appendingPathComponent("child")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            let a = root.appendingPathComponent("a.mp4"), b = child.appendingPathComponent("b.flac")
            try put(a); try put(b)
            let hidden = root.appendingPathComponent(".hidden.mp4"); try put(hidden)
            let package = root.appendingPathComponent("Demo.app")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
            try put(package.appendingPathComponent("inside.mp4"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.mp4"), withDestinationURL: a)
            let initial = try await scan(root)
            try require(initial.files.map(\.relativePath) == ["a.mp4", "child/b.flac"], "recursive/hidden/package/link boundary")
            passed.append("directory-scan-recursive-boundaries")

            let shallow = try await scan(root, recursive: false)
            try require(shallow.files.map(\.relativePath) == ["a.mp4"], "one-level scan")
            passed.append("directory-scan-shallow")

            try put(a, "new longer actual bytes"); try FileManager.default.removeItem(at: b)
            let c = child.appendingPathComponent("c.wav"); try put(c)
            let updated = try await scan(root)
            let delta = DirectoryLibraryDelta.compare(old: initial.files, new: updated.files)
            try require(delta.added == 1 && delta.removed == 1 && delta.modified == 1, "actual stat delta")
            observations["actualDelta"] = ["added": delta.added, "removed": delta.removed, "modified": delta.modified,
                "initialPaths": initial.files.map(\.relativePath), "updatedPaths": updated.files.map(\.relativePath)]
            passed.append("directory-scan-real-add-remove-modify")

            let large = base.appendingPathComponent("large")
            try FileManager.default.createDirectory(at: large, withIntermediateDirectories: false)
            for i in 0..<512 { try put(large.appendingPathComponent("\(i).mp4"), "") }
            let cancellation = DirectoryScanCancellation()
            var cancelled = false
            do {
                _ = try await DirectoryLibraryScanner.scan(root: large, expected: nil, recursive: true,
                    cancellation: cancellation, progress: { count in if count >= 128 { cancellation.cancel() } })
            } catch is CancellationError { cancelled = true }
            try require(cancelled, "actual traversal cancellation at progress checkpoint")
            passed.append("directory-scan-cancel-during-traversal")

            var limited = false
            do { _ = try await scan(large, limits: DirectoryScanLimits(nodes: 10)) }
            catch is DirectoryLibraryFailure { limited = true }
            try require(limited, "bounded node scan must fail, not publish partial success")
            passed.append("directory-scan-limit-no-partial-success")

            let signals = Signals()
            let watch = DirectoryLibraryWatcher { signals.receive($0) }; watchers.append(watch)
            let started = try await watch.start(root: root, expected: initial.identity)
            let beforeCount = signals.snapshot().count
            let nested = child.appendingPathComponent("nested-new.mkv"); try put(nested)
            try await eventually { signals.snapshot().count > beforeCount }
            let eventScan = try await DirectoryLibraryScanner.scan(root: started.url, expected: started.identity,
                recursive: true, cancellation: .init())
            try require(eventScan.files.contains { $0.url == nested }, "native hierarchy event and actual rescan")
            passed.append("directory-watch-real-descendant-event")

            let closed = await watch.close(); let closedDiag = await watch.diagnostics()
            try require(closed && !closedDiag.active && !closedDiag.fdOwned && closedDiag.stops == 1, "actual native+FD close")
            let stoppedCount = signals.snapshot().count
            try put(child.appendingPathComponent("after-close.mp4"))
            try await Task.sleep(nanoseconds: 800_000_000)
            try require(signals.snapshot().count == stoppedCount, "Stop must prohibit future SDK callbacks")
            observations["nativeWatch"] = ["starts": closedDiag.starts, "stops": closedDiag.stops,
                "callbackBatches": closedDiag.callbackBatches, "events": closedDiag.receivedEvents,
                "activeAfterClose": closedDiag.active, "fdOwnedAfterClose": closedDiag.fdOwned,
                "flags": signals.snapshot().map(\.flags), "countAfterWriteWhileClosed": signals.snapshot().count]
            passed.append("directory-watch-stop-release-no-future-events")

            let moveSignals = Signals()
            let moveWatch = DirectoryLibraryWatcher { moveSignals.receive($0) }; watchers.append(moveWatch)
            _ = try await moveWatch.start(root: root, expected: started.identity)
            let moved = base.appendingPathComponent("moved")
            try FileManager.default.moveItem(at: root, to: moved)
            try await eventually { moveSignals.snapshot().contains { $0.rootChanged } }
            var lost = false
            do { let (_, unexpectedHandle, _) = try DirectoryLibraryScanner.openRoot(root, expected: started.identity); _ = unexpectedHandle.close() }
            catch is DirectoryLibraryFailure { lost = true }
            let moveClosed = await moveWatch.close()
            try require(lost && moveClosed, "real root move detected and retired")
            observations["rootMove"] = ["originalPathRejected": lost, "released": moveClosed,
                "actualEventFlags": moveSignals.snapshot().map(\.flags)]
            passed.append("directory-watch-root-move")

            let controller = DirectoryLibraryController(); controllers.append(controller)
            controller.add(moved)
            try await eventually { controller.folders.first?.scanning == false && controller.folders.first?.files.isEmpty == false }
            guard let folder = controller.folders.first else { throw CheckFailure(message: "controller folder missing") }
            let previous = folder.files
            await controller.pause(folder.id)
            let pauseDiag = await controller.diagnostics()
            try require(pauseDiag["watchOwners"] as? Int == 0 && pauseDiag["scanJobs"] as? Int == 0, "real controller pause owns no stream/scan")
            try put(moved.appendingPathComponent("manual.wav"))
            controller.refresh(folder.id)
            try await eventually { controller.folders.first?.scanning == false && controller.folders.first?.files != previous }
            try require(controller.folders.first?.paused == true, "manual refresh must not secretly resume monitor")
            passed.append("directory-controller-paused-manual-refresh")

            controller.resume(folder.id)
            try await eventually { controller.folders.first?.scanning == false && controller.folders.first?.paused == false }
            await controller.remove(folder.id)
            let removeDiag = await controller.diagnostics()
            try require(controller.folders.isEmpty && removeDiag["watchOwners"] as? Int == 0 && removeDiag["scanJobs"] as? Int == 0, "remove actual resources")
            passed.append("directory-controller-remove-strong-release")

            var queue = Playlist(); queue.add([a])
            let current = queue.currentItem?.id
            let appended = DirectoryLibraryQueueAppend.applying([c, c], to: queue)
            try require(appended.currentItem?.id == current && appended.items.count == 2 && queue.items.count == 1,
                        "real Playlist preserves current UUID, deduplicates and leaves original value")
            let idle = DirectoryLibraryQueueAppend.applying([c], to: Playlist())
            try require(idle.items.count == 1, "explicit idle append data only; App no-load contract separately verified")
            passed.append("directory-explicit-queue-append-real-playlist")
        } catch { failures.append(String(describing: error)) }
        // Always attempt actual cleanup before removing the test files. A failed
        // native release leaves the directory/evidence for the Root owner.
        var allReleased = true
        for watch in watchers { let closed = await watch.close(); allReleased = closed && allReleased }
        for controller in controllers { let closed = await controller.closeWindowOwner(); allReleased = closed && allReleased }
        let allStopped = await DirectoryLibraryController.shutdownAll()
        allReleased = allStopped && !DirectoryLibraryController.hasActiveJobs && allReleased
        if allReleased { try? FileManager.default.removeItem(at: base) }
        let result: [String: Any] = ["status": failures.isEmpty && allReleased && passed.count == 11 ? "passed" : "failed",
            "passedIDs": passed, "errors": failures, "observations": observations, "allReleased": allReleased, "appGroups": 0,
            "temporaryRoot": base.path, "nativeVolumeDisconnect": "not-run", "fullAppUI": "not-run"]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
        if !failures.isEmpty || !allReleased || passed.count != 11 { exit(1) }
    }
}
