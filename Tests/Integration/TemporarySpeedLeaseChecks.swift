import Foundation

private struct CheckError: Error { let message: String }

/// Compiles the actual proposed controller, not a copied policy implementation.
/// The host below is a setter/readback fault injector, not libmpv/AppKit.
@MainActor private final class Host {
    var token = UUID(), item = UUID()
    var visibleSelection: UUID? = UUID()
    var speed = 1.0
    var eligible = true
    var closed = false
    var rejectNextWrite = false
    var ignoreNextWrite = false
    var onWrite: ((Double) -> Void)?
    var writes: [Double] = []
    var published: [Double] = []
    var prepareCalls = 0
    @discardableResult func guardedLoadVisibleSelection() -> Bool {
        guard controller.finish(reason: "replacement-load"), let selected = visibleSelection else { return false }
        prepareCalls += 1; item = selected; token = UUID(); return true
    }
    lazy var controller = TemporaryPlaybackSpeedController(snapshot: { [weak self] in
        guard let self, !self.closed else { return nil }
        return .init(mediaToken: self.token, itemID: self.item, speed: self.speed, eligible: self.eligible)
    }, write: { [weak self] value in self?.write(value) ?? -3 },
       publish: { [weak self] value in self?.published.append(value) })
    func write(_ value: Double) -> Int32 {
        writes.append(value)
        if rejectNextWrite { rejectNextWrite = false; return -4 }
        if ignoreNextWrite { ignoreNextWrite = false; return 0 }
        speed = value; onWrite?(value)
        return 0
    }
    @discardableResult func begin(repeatEvent: Bool = false) -> Bool {
        controller.begin(code: 17, modifiers: 0, windowNumber: 77, isRepeat: repeatEvent)
    }
}

@main private struct TemporarySpeedLeaseChecks {
    @MainActor static func main() throws {
        var ids: [String] = []
        func expect(_ condition: Bool, _ detail: String) throws {
            if !condition { throw CheckError(message: detail) }
        }
        func record(_ id: String) { ids.append(id); print("PASS " + id) }
        do {
            let h = Host(); h.speed = 0.75
            try expect(h.begin() && h.speed == 1.5, "original fractional speed was not doubled")
            try expect(h.controller.keyUp(code: 17) && h.speed == 0.75 && h.writes == [1.5, 0.75], "release did not restore exact original")
            record("fractional-original-and-release")
        }
        do {
            let h = Host(); try expect(h.begin(), "first hold rejected")
            try expect(h.begin(repeatEvent: true) && h.begin() && h.writes == [2] && h.controller.beginCount == 1, "repeat recaptured temporary speed")
            _ = h.controller.keyUp(code: 17)
            try expect(h.speed == 1 && h.writes == [2, 1], "repeat changed restoration original")
            record("repeat-does-not-recapture")
        }
        do {
            let h = Host(); _ = h.begin()
            try expect(!h.controller.keyUp(code: 18) && h.controller.active && h.speed == 2, "unrelated key-up ended hold")
            _ = h.controller.keyUp(code: 17); record("physical-key-up-ownership")
        }
        do {
            let h = Host(); _ = h.begin(); h.speed = 1.25; h.controller.permanentChangeAccepted()
            try expect(h.begin(repeatEvent: true) && h.writes == [2], "accepted permanent edit was recaptured by repeat")
            _ = h.controller.keyUp(code: 17)
            try expect(h.speed == 1.25 && h.writes == [2], "release overwrote explicit permanent intent")
            record("permanent-edit-wins-and-repeat-stays-retired")
        }
        do {
            let h = Host(); _ = h.begin(); h.controller.permanentChangeAccepted()
            _ = h.controller.keyUp(code: 17)
            try expect(h.speed == 2 && h.writes == [2], "numerically equal permanent intent was overwritten")
            record("equal-numeric-permanent-intent-wins")
        }
        do {
            let h = Host(); _ = h.begin()
            // Exercise the same injected setter's actual negative reply.
            h.rejectNextWrite = true
            let accepted = h.write(1.25)
            if accepted >= 0 { h.controller.permanentChangeAccepted() }
            try expect(accepted < 0 && h.speed == 2 && h.controller.active, "negative setter retired lease")
            _ = h.controller.keyUp(code: 17)
            try expect(h.speed == 1 && h.controller.restoreCount == 1 && h.writes == [2, 1.25, 1], "failed permanent setter lost restoration lease")
            record("unaccepted-permanent-intent-does-not-retire")
        }
        do {
            let h = Host(); _ = h.begin(); h.token = UUID(); h.item = UUID(); h.speed = 1.75
            _ = h.controller.keyUp(code: 17)
            try expect(h.speed == 1.75 && h.writes == [2] && h.controller.abandonedCount == 1, "old media speed leaked into foreign binding")
            record("foreign-media-never-receives-old-speed")
        }
        do {
            let h = Host(); _ = h.begin(); h.speed = 0.5; h.controller.observe(); _ = h.controller.keyUp(code: 17)
            try expect(h.speed == 0.5 && h.writes == [2] && !h.controller.active, "observed external speed was overwritten")
            record("observed-external-intent-wins")
        }
        do {
            let h = Host(); _ = h.begin(); h.rejectNextWrite = true; _ = h.controller.keyUp(code: 17)
            try expect(h.speed == 2 && h.controller.pendingRestoration && h.controller.error != nil, "failed restore falsely cleared ownership")
            h.controller.observe(); try expect(h.writes == [2, 1], "poll retried failed setter automatically")
            try expect(h.controller.finish(reason: "explicit-retry") && h.speed == 1 && !h.controller.pendingRestoration, "explicit retry did not release exact lease")
            record("failed-restore-retains-ticket-and-explicit-retry")
        }
        do {
            let h = Host(); _ = h.begin(); let before = h.token; h.rejectNextWrite = true
            let allowed = h.controller.finish(reason: "replacement-load")
            if allowed { h.token = UUID() }
            try expect(!allowed && h.token == before && h.speed == 2 && h.controller.pendingRestoration, "replacement advanced after unconfirmed restore")
            try expect(h.controller.finish(reason: "replacement-load-retry") && h.speed == 1, "replacement retry failed")
            h.token = UUID(); h.speed = 1.5; _ = h.controller.keyUp(code: 17)
            try expect(h.speed == 1.5, "old late key-up overwrote next media")
            record("replacement-boundary-fails-closed-and-late-up-is-inert")
        }
        do {
            let h = Host(); _ = h.begin(); h.eligible = false; h.controller.observe()
            try expect(h.speed == 1 && !h.eligible && h.writes == [2, 1], "pause/EOF ineligibility did not restore, or eligibility was mutated")
            record("playback-ineligibility-restores-without-resume")
        }
        do {
            for value in [Double.nan, Double.infinity, -1, 0, 4.1, 4] {
                let h = Host(); h.speed = value
                try expect(!h.begin() && h.writes.isEmpty && !h.controller.active, "invalid or capped input wrote speed")
            }
            let h = Host(); h.closed = true
            try expect(!h.begin() && h.writes.isEmpty, "closed core accepted lease")
            record("invalid-capped-and-closed-inputs-rejected")
        }
        do {
            let h = Host(); _ = h.begin(); h.controller.windowResigned(88)
            try expect(h.speed == 2, "foreign window cancelled origin lease")
            h.controller.windowResigned(77); try expect(h.speed == 1, "origin window failed to restore")
            _ = h.begin(); h.controller.flagsChanged(modifiers: 1)
            try expect(h.speed == 1 && h.writes == [2, 1, 2, 1], "modifier change failed to restore")
            record("origin-window-and-modifier-cancellation")
        }
        do {
            let h = Host()
            h.onWrite = { _ in h.speed = 1.25; h.controller.permanentChangeAccepted() }
            _ = h.begin(); h.onWrite = nil; _ = h.controller.keyUp(code: 17)
            try expect(h.speed == 1.25 && h.controller.beginCount == 0 && h.writes == [2], "synchronous newer intent overwritten by old completion")
            record("synchronous-reentrant-newer-intent-not-overwritten")
        }
        do {
            let h = Host(); h.ignoreNextWrite = true; _ = h.begin()
            try expect(h.controller.beginCount == 0 && !h.controller.active && h.speed == 1 && h.controller.error != nil, "command status alone certified effect")
            _ = h.controller.keyUp(code: 17)
            try expect(h.writes == [2], "never-applied target was later restored")
            record("accepted-status-requires-real-readback")
        }
        do {
            let h = Host(); _ = h.begin(); h.rejectNextWrite = true
            var closeCalls = 0
            let actualHostStatus: Int32 = h.controller.closingAfterRestore(reason: "quit") {
                closeCalls += 1
                // Before actual native closure, failed restoration still owns
                // its lease. Closing must run instead of returning early.
                if !h.controller.pendingRestoration { return -999 }
                h.closed = true; h.controller.coreClosed(); return 0
            }
            try expect(actualHostStatus == 0 && closeCalls == 1 && h.closed
                && !h.controller.active && !h.controller.pendingRestoration
                && h.writes == [2, 1], "restore failure blocked closing or released ownership prematurely")
            record("failed-restore-does-not-block-actual-closing-dispatch")
        }
        do {
            let h = Host(); h.visibleSelection = h.item; let actualOldItem = h.item
            _ = h.begin()
            // Real PlayerModel select/next/remove/open first mutate the UI
            // queue, then call load. The snapshot must still name the old
            // MediaPreferences/Core binding until prepareForLoad happens.
            h.visibleSelection = UUID()
            try expect(h.visibleSelection != h.item && h.item == actualOldItem, "test did not separate visible selection from core binding")
            try expect(h.controller.finish(reason: "selection-before-load") && h.speed == 1
                && h.writes == [2, 1] && h.controller.restoreCount == 1, "queue mutation made old temporary speed leak into next load")
            h.item = h.visibleSelection!; h.token = UUID()
            _ = h.controller.keyUp(code: 17)
            try expect(h.speed == 1 && h.writes == [2, 1], "stale key-up wrote after actual new binding")
            record("visible-queue-change-restores-old-core-binding-before-prepare")
        }
        do {
            let h = Host(); h.visibleSelection = h.item; let oldItem = h.item, oldToken = h.token
            _ = h.begin(); h.visibleSelection = nil; h.eligible = false
            try expect(h.controller.finish(reason: "remove-all-stop") && h.speed == 1
                && h.writes == [2, 1] && h.item == oldItem && h.token == oldToken
                && h.visibleSelection == nil && h.prepareCalls == 0,
                "empty queue or playback ineligibility prevented restoring still-bound old core")
            record("empty-visible-queue-still-restores-old-bound-core")
        }
        do {
            let h = Host(); h.visibleSelection = h.item; let oldItem = h.item, oldToken = h.token
            _ = h.begin(); h.visibleSelection = UUID(); h.rejectNextWrite = true
            try expect(!h.guardedLoadVisibleSelection() && h.visibleSelection != oldItem
                && h.item == oldItem && h.token == oldToken && h.prepareCalls == 0
                && h.speed == 2 && h.controller.pendingRestoration && h.controller.error != nil,
                "failed restoration either prepared new core or lost explicit failure while UI selection had changed")
            try expect(h.guardedLoadVisibleSelection() && h.prepareCalls == 1 && h.item == h.visibleSelection
                && h.token != oldToken && h.speed == 1 && h.writes == [2, 1, 1],
                "explicit retry did not restore before preparing selected media")
            _ = h.controller.keyUp(code: 17)
            try expect(h.writes == [2, 1, 1], "late key-up changed newly prepared binding")
            record("failed-load-preserves-old-core-and-reports-selection-divergence-until-retry")
        }
        try expect(ids.count == 19 && Set(ids).count == 19, "case identity drift")
        let result: [String: Any] = ["passed": true, "ids": ids, "count": ids.count,
            "scope": "Proposed real lease controller with injected setter/readback/failures. No AppKit delivery, libmpv, PCM, UI, physical hold, App or accepted production capability."]
        if CommandLine.arguments.count == 2 {
            let file = URL(fileURLWithPath: CommandLine.arguments[1])
            guard !FileManager.default.fileExists(atPath: file.path) else { throw CheckError(message: "Output already exists") }
            try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: file, options: .withoutOverwriting)
        }
    }
}
