import Foundation
import PlayerCore

func require(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label) }
func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }

@main struct PlaybackProgramChecks {
    static func main() throws {
        let identity = try MediaIdentity(originalURL: URL(fileURLWithPath: "/tmp/program-proof.mov"))
        var record = MediaPreferenceRecord(identity: identity)
        let oldBytes = try JSONEncoder().encode(record)
        let oldRecord = try JSONDecoder().decode(MediaPreferenceRecord.self, from: oldBytes)
        require(oldRecord.playbackProgram == nil, "legacy absent optional")
        print("PASS legacy-record")

        let interval = PlaybackInterval(title: "练习", startMicroseconds: 2_000_000, endMicroseconds: 5_000_000, totalPlays: 3)
        var p = PlaybackProgram(); p.enabled = true; p.intervals = [interval]; p.selectedIntervalID = interval.id
        _ = try p.validated()
        var bad = p; bad.intervals[0].totalPlays = 0
        require(rejects { _ = try bad.validated() }, "zero passes")
        bad = p; bad.intervals.append(interval)
        require(rejects { _ = try bad.validated() }, "duplicate stable UUID")
        bad = p; bad.introEndMicroseconds = 8_000_000; bad.outroStartMicroseconds = 7_000_000
        require(rejects { _ = try bad.validated() }, "reversed skip range")
        bad = p; bad.intervals = (0..<65).map { _ in PlaybackInterval(title: "x", startMicroseconds: 0, endMicroseconds: 1_000_000) }; bad.selectedIntervalID = nil
        require(rejects { _ = try bad.validated() }, "bounded interval collection")
        bad = p; bad.afterMedia = .nextInterval
        require(rejects { _ = try bad.validated() }, "recursive media end forbidden")
        print("PASS bounded-validation")

        record.playbackProgram = p; record.audioDelay = 0.75
        record.primarySubtitle = .disabled; record.secondarySubtitle = .automatic
        var doc = MediaPreferenceDocument(); try doc.save(record)
        let restored = try MediaPreferenceDocument.boundedDecode(doc.encoded())
        require(restored.record(for: identity) == record, "nested program and dual-track fields retained")
        var invalidRecord = record; invalidRecord.playbackProgram = bad
        require(rejects { try doc.save(invalidRecord) }, "nested media/backup validation gate")
        require(doc.record(for: identity) == record, "failed validation preserves prior value")
        print("PASS media-roundtrip")

        require(PlaybackProgram.parseSeconds("2.123456") == 2_123_456, "microsecond decimal exact")
        require(PlaybackProgram.seconds(2_123_456) == "2.123456", "decimal roundtrip")
        require(PlaybackProgram.parseSeconds("2.1234567") == nil, "no implicit precision loss")
        require(PlaybackProgram.parseSeconds("-2") == nil && PlaybackProgram.microseconds(.infinity) == nil, "invalid timestamps")
        print("PASS exact-decimal")

        let ticket = PlaybackProgramTicket(itemID: UUID(), loadToken: UUID(), entryID: 14, programRevision: p.revision)
        var one = interval; one.totalPlays = 1
        var state = PlaybackIntervalCompletion(); try state.arm(one, ticket: ticket, actualRemaining: 0)
        require(!state.observe(ticket: ticket, position: 2_000_000, remaining: 0, seeking: true, forward: true), "seek does not settle")
        require(!state.observe(ticket: ticket, position: 2_033_333, remaining: 0, seeking: false, forward: true), "actual in-range sample")
        require(state.observe(ticket: ticket, position: 5_033_333, remaining: 0, seeking: false, forward: true), "one-pass final crossing")
        require(!state.observe(ticket: ticket, position: 5_066_666, remaining: 0, seeking: false, forward: true), "exact once")
        print("PASS one-pass-crossing")

        try state.arm(interval, ticket: ticket, actualRemaining: 2)
        _ = state.observe(ticket: ticket, position: 2_100_000, remaining: 2, seeking: false, forward: true)
        require(!state.observe(ticket: ticket, position: 4_900_000, remaining: 2, seeking: false, forward: true), "first pass")
        require(!state.observe(ticket: ticket, position: 2_100_000, remaining: 1, seeking: false, forward: true), "position decrease is not completion")
        require(!state.observe(ticket: ticket, position: 4_900_000, remaining: 0, seeking: false, forward: true), "actual final pass still before B")
        require(state.observe(ticket: ticket, position: 5_033_333, remaining: 0, seeking: false, forward: true), "real zero count and crossing")
        require(rejects { try state.arm(interval, ticket: ticket, actualRemaining: 3) }, "wrong count readback rejects activation")
        print("PASS finite-native-count")

        var infinite = interval; infinite.totalPlays = nil
        try state.arm(infinite, ticket: ticket, actualRemaining: -1)
        _ = state.observe(ticket: ticket, position: 2_100_000, remaining: -1, seeking: false, forward: true)
        require(!state.observe(ticket: ticket, position: 6_000_000, remaining: 0, seeking: false, forward: true), "infinite does not invent finite completion")
        print("PASS infinite-count")

        try state.arm(one, ticket: ticket, actualRemaining: 0)
        _ = state.observe(ticket: ticket, position: 2_100_000, remaining: 0, seeking: false, forward: true)
        let newLoad = PlaybackProgramTicket(itemID: ticket.itemID, loadToken: UUID(), entryID: ticket.entryID, programRevision: p.revision)
        require(!state.observe(ticket: newLoad, position: 6_000_000, remaining: 0, seeking: false, forward: true), "same UUID new load rejects old crossing")
        state.invalidate()
        require(!state.observe(ticket: ticket, position: 6_000_000, remaining: 0, seeking: false, forward: true), "manual seek/Stop invalidation")
        print("PASS ticket-and-intent")
    }
}
