import Foundation
import PlayerCore

@MainActor private final class FilterEngineProbe {
    typealias Completion = @MainActor (Result<Void, Error>) -> Void
    var calls: [UserVideoFilterChain] = []
    var pending: [Completion] = []
    func apply(_ chain: UserVideoFilterChain, _ completion: @escaping Completion) {
        calls.append(chain); pending.append(completion)
    }
    func finish(_ result: Result<Void, Error>) { pending.removeFirst()(result) }
}

@main struct UserVideoFiltersChecks {
    @MainActor static func main() throws {
        let tests = UserVideoFiltersTests()
        let core: [(String, () throws -> Void)] = [
            ("valid defaults and disabled-entry validation", tests.testDefaultsAndDisabledEntriesRemainValidated),
            ("range/nonfinite/unknown parameter rejection", tests.testRangesNonFiniteAndUnknownParametersAreRejected),
            ("chain identity/version/count limits", tests.testChainIdentityVersionAndLengthLimits),
            ("reorder/disable identity preservation", tests.testOrderMovesAndDisabledRowsPreserveIdentity),
            ("constant generated graph syntax", tests.testGeneratedGraphContainsOnlyBoundedSyntax),
            ("JSON/atomic persistence and rejected-edit byte preservation", tests.testJSONAndAtomicStorePreserveOrderValuesAndOldBytes),
            ("corrupt/oversize/local/write failure boundaries", tests.testCorruptOversizeAndWriteErrorsRemainVisibleWithoutReplacingFiles)
        ]
        for (name, body) in core { try body(); print("PASS Core \(name)") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let desired = UserVideoFilterChain(filters: [UserVideoFilter(kind: .blur)])
        let old = UserVideoFilterChain(filters: [UserVideoFilter(kind: .horizontalFlip)])
        let failure = UserVideoFilterError.invalid("synthetic engine initialization failure")
        func setup(_ name: String, existing: UserVideoFilterChain? = nil) throws -> (UserVideoFiltersController, FilterEngineProbe, URL) {
            let file = temporary.appendingPathComponent(name).appendingPathComponent("filters.json")
            if let existing { try UserVideoFilterStore(fileURL: file).save(existing) }
            let controller = UserVideoFiltersController(fileURL: file)
            let probe = FilterEngineProbe(); controller.install { probe.apply($0, $1) }
            return (controller, probe, file)
        }
        do {
            let file = temporary.appendingPathComponent("not-installed.json")
            let controller = UserVideoFiltersController(fileURL: file)
            precondition(!controller.commit(desired) && controller.errorText != nil && !FileManager.default.fileExists(atPath: file.path))
            let (ready, probe, _) = try setup("invalid")
            var invalid = desired; invalid.filters[0].values["sigma"] = .nan
            precondition(!ready.commit(invalid) && probe.calls.isEmpty)
            print("PASS Controller uninstalled/invalid edits never reach engine or disk")
        }
        do {
            let (controller, probe, file) = try setup("success")
            precondition(controller.commit(desired) && controller.isApplying && controller.chain.filters.isEmpty)
            precondition(!FileManager.default.fileExists(atPath: file.path) && !controller.commit(old))
            let duplicate = probe.pending[0]
            probe.finish(.success(()))
            let persisted = try UserVideoFilterStore(fileURL: file).load()
            precondition(!controller.isApplying && controller.chain == desired && persisted == desired)
            duplicate(.failure(failure))
            precondition(controller.errorText == nil && probe.calls.count == 1)
            print("PASS Controller commits only after engine confirmation; busy/duplicate completion guarded")
        }
        do {
            let (controller, probe, file) = try setup("rejected", existing: old)
            let bytes = try Data(contentsOf: file)
            precondition(controller.commit(desired)); probe.finish(.failure(failure))
            precondition(controller.isApplying && probe.calls == [desired, old])
            probe.finish(.success(()))
            precondition(controller.chain == old && !controller.isApplying && controller.errorText != nil)
            let persisted = try Data(contentsOf: file)
            precondition(persisted == bytes)
            print("PASS Controller failed application restores previous chain and persisted bytes")
        }
        do {
            let (controller, probe, file) = try setup("fallback", existing: old)
            let bytes = try Data(contentsOf: file)
            precondition(controller.commit(desired)); probe.finish(.failure(failure)); probe.finish(.failure(failure))
            precondition(probe.calls.last == UserVideoFilterChain())
            probe.finish(.success(()))
            precondition(controller.runtimeSuspended && controller.effectiveFragments.isEmpty && controller.chain == old)
            var persisted = try Data(contentsOf: file)
            precondition(controller.errorText != nil && !controller.isApplying && persisted == bytes)
            controller.resumeForNewMedia(); precondition(!controller.runtimeSuspended && !controller.effectiveFragments.isEmpty)
            controller.suspendForCurrentMedia(reason: "changed dimensions")
            persisted = try Data(contentsOf: file)
            precondition(controller.chain == old && controller.effectiveFragments.isEmpty && persisted == bytes)
            precondition(controller.commit(old)); probe.finish(.failure(failure))
            precondition(probe.calls.last == UserVideoFilterChain()); probe.finish(.success(()))
            precondition(controller.runtimeSuspended && controller.chain == old)
            print("PASS Controller rollback failure/suspended-media retry falls back to baseline without losing settings")
        }
        do {
            let blocking = temporary.appendingPathComponent("regular-file")
            try Data("original".utf8).write(to: blocking)
            let controller = UserVideoFiltersController(fileURL: blocking.appendingPathComponent("filters.json"))
            let probe = FilterEngineProbe(); controller.install { probe.apply($0, $1) }
            precondition(controller.commit(desired)); probe.finish(.success(()))
            precondition(probe.calls.last == UserVideoFilterChain() && controller.chain.filters.isEmpty)
            probe.finish(.success(()))
            precondition(!controller.isApplying && controller.errorText?.contains("保存失败") == true)
            let preserved = try String(contentsOf: blocking)
            precondition(preserved == "original")
            print("PASS Controller persistence failure rolls engine back and reports real file error")
        }
        do {
            let file = temporary.appendingPathComponent("corrupt.json")
            let bytes = Data("not json".utf8); try bytes.write(to: file)
            let controller = UserVideoFiltersController(fileURL: file)
            let preserved = try Data(contentsOf: file)
            precondition(controller.chain.filters.isEmpty && controller.errorText != nil && preserved == bytes)
            print("PASS Controller malformed saved document stays visible and unchanged")
        }
        do {
            let (controller, probe, file) = try setup("late", existing: old)
            let bytes = try Data(contentsOf: file)
            precondition(controller.commit(desired))
            let obsolete = probe.pending.removeFirst()
            controller.resumeForNewMedia()
            precondition(!controller.isApplying && controller.chain == old)
            precondition(controller.commit(UserVideoFilterChain()))
            obsolete(.success(())); obsolete(.failure(failure))
            precondition(controller.isApplying && controller.chain == old && probe.calls.count == 2)
            var preserved = try Data(contentsOf: file); precondition(preserved == bytes)
            probe.finish(.success(()))
            precondition(controller.chain.filters.isEmpty && !controller.isApplying)
            precondition(controller.commit(desired))
            let stopped = probe.pending.removeFirst(); controller.cancelPending(reason: "已停止播放")
            stopped(.success(())); stopped(.failure(failure))
            preserved = try Data(contentsOf: file)
            precondition((try? UserVideoFilterStore(fileURL: file).load().filters.isEmpty) == true)
            precondition(!controller.isApplying && controller.chain.filters.isEmpty && controller.errorText?.contains("未保存") == true)
            precondition(controller.commit(desired))
            let suspended = probe.pending.removeFirst(); controller.suspendForCurrentMedia(reason: "failed new dimensions")
            suspended(.success(())); suspended(.failure(failure))
            precondition(controller.runtimeSuspended && !controller.isApplying && controller.chain.filters.isEmpty)
            precondition(probe.calls.count == 4 && preserved == (try? Data(contentsOf: file)))
            print("PASS Controller switch/stop/suspend invalidate late callbacks and preserve a newer transaction")
        }
        print("14 user-video-filter Core/controller groups passed; engine callbacks are a test probe, no mpv/window/pixel acceptance.")
    }
}
