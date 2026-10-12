import Foundation

/// An in-memory lease over one accepted core speed. No settings/store writes.
/// Host injection checks can test this state machine; they cannot certify
/// physical key duration, AppKit delivery, libmpv or audible playback.
@MainActor
final class TemporaryPlaybackSpeedController {
    struct Snapshot {
        let mediaToken: UUID
        let itemID: UUID
        let speed: Double
        let eligible: Bool
    }
    private struct Lease {
        let id: UUID
        let mediaToken: UUID
        let itemID: UUID
        let original: Double
        let applied: Double
    }
    private struct HeldKey {
        let code: UInt16
        let modifiers: UInt
        let windowNumber: Int
    }
    private let snapshot: () -> Snapshot?
    private let write: (Double) -> Int32
    private let publish: (Double) -> Void
    private var lease: Lease?
    private var heldKey: HeldKey?
    private var restorationFailed = false
    private(set) var error: String?
    private(set) var beginCount = 0
    private(set) var restoreCount = 0
    private(set) var abandonedCount = 0
    var active: Bool { lease != nil }
    var pendingRestoration: Bool { lease != nil && restorationFailed }
    var originWindowNumber: Int? { heldKey?.windowNumber }

    init(snapshot: @escaping () -> Snapshot?, write: @escaping (Double) -> Int32,
         publish: @escaping (Double) -> Void) {
        self.snapshot = snapshot; self.write = write; self.publish = publish
    }

    /// Repeats never capture another original, even after a permanent edit has
    /// superseded this lease while its physical key is still held down.
    @discardableResult
    func begin(code: UInt16, modifiers: UInt, windowNumber: Int, isRepeat: Bool) -> Bool {
        if heldKey?.code == code { return true }
        guard !isRepeat, heldKey == nil else { return false }
        if lease != nil, !finish(reason: "retry-before-new-hold") { return false }
        guard let old = snapshot(), old.eligible, Self.valid(old.speed) else { return false }
        let target = min(4, old.speed * 2)
        guard target > old.speed + 0.00000001 else { return false }
        let ticket = Lease(id: UUID(), mediaToken: old.mediaToken, itemID: old.itemID,
                           original: old.speed, applied: target)
        lease = ticket
        heldKey = HeldKey(code: code, modifiers: modifiers, windowNumber: windowNumber)
        restorationFailed = false; error = nil
        let status = write(target)
        guard lease?.id == ticket.id else { return true }
        guard let current = snapshot(), Self.sameBinding(current, ticket) else {
            abandon(); return true
        }
        publish(current.speed)
        if status >= 0, Self.equal(current.speed, target) {
            beginCount += 1
        } else {
            error = "临时倍速未确认生效（状态 \(status)）。"
            // If the host still reports the original value, there is nothing
            // left to restore. A changed accepted target retains its lease.
            if Self.equal(current.speed, old.speed) || !Self.equal(current.speed, target) {
                lease = nil
            }
        }
        return true
    }

    @discardableResult
    func keyUp(code: UInt16) -> Bool {
        guard heldKey?.code == code else { return false }
        heldKey = nil
        _ = finish(reason: "key-up")
        return true
    }

    func flagsChanged(modifiers: UInt) {
        guard let key = heldKey, key.modifiers != modifiers else { return }
        _ = finish(reason: "modifiers-changed")
    }

    func windowResigned(_ number: Int) {
        guard heldKey?.windowNumber == number else { return }
        _ = finish(reason: "origin-window-resigned")
    }

    /// Same-media restoration is allowed only while the actual core value is
    /// still this lease's accepted temporary value. Foreign media or a changed
    /// external value cannot receive the old original speed.
    @discardableResult
    func finish(reason: String) -> Bool {
        heldKey = nil
        guard let ticket = lease else { return true }
        guard let current = snapshot(), Self.sameBinding(current, ticket) else {
            abandon(); return true
        }
        if Self.equal(current.speed, ticket.original) {
            publish(current.speed); clearLease(); return true
        }
        guard Self.equal(current.speed, ticket.applied) else {
            publish(current.speed); abandon(); return true
        }
        let status = write(ticket.original)
        guard lease?.id == ticket.id else { return true }
        guard let after = snapshot(), Self.sameBinding(after, ticket) else {
            abandon(); return true
        }
        publish(after.speed)
        guard status >= 0, Self.equal(after.speed, ticket.original) else {
            restorationFailed = true
            error = "临时倍速恢复未确认（\(reason)，状态 \(status)）；请重试或显式设置速度。"
            return false
        }
        restoreCount += 1; clearLease(); return true
    }

    /// Call only after the real host setter accepted a user's permanent speed
    /// intent, including an intent equal to the temporary numeric value.
    func permanentChangeAccepted() { clearLease() }

    func observe() {
        guard let ticket = lease else { return }
        guard let current = snapshot(), Self.sameBinding(current, ticket) else { abandon(); return }
        if !Self.equal(current.speed, ticket.applied) {
            publish(current.speed); abandon(); return
        }
        // Retry is explicit after a failed write. A 0.15-second poll must not
        // spin property assignments or repeatedly overwrite another intent.
        if !current.eligible, !restorationFailed { _ = finish(reason: "playback-no-longer-eligible") }
    }

    /// Restoration is best effort during irreversible shutdown. The real
    /// closing operation always runs, even after a negative restoration reply.
    /// Only actual core closure/process exit releases any remaining lease.
    func closingAfterRestore<Result>(reason: String, operation: () -> Result) -> Result {
        _ = finish(reason: reason)
        return operation()
    }

    func coreClosed() { heldKey = nil; abandon() }

    private func clearLease() { lease = nil; restorationFailed = false; error = nil }
    private func abandon() { if lease != nil { abandonedCount += 1 }; clearLease() }
    private static func valid(_ value: Double) -> Bool { value.isFinite && value >= 0.25 && value <= 4 }
    private static func equal(_ a: Double, _ b: Double) -> Bool { a.isFinite && b.isFinite && abs(a - b) <= 0.00000001 }
    private static func sameBinding(_ value: Snapshot, _ ticket: Lease) -> Bool {
        value.mediaToken == ticket.mediaToken && value.itemID == ticket.itemID
    }
}
