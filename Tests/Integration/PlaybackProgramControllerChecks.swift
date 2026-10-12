import Foundation
import PlayerCore

@MainActor final class ProgramHost: PlaybackProgramHost {
    var restoredPlaybackProgram: PlaybackProgram?
    var persistedPlaybackProgram: PlaybackProgram? { restoredPlaybackProgram }
    var item = UUID(), token = UUID(), entry: Int64 = 18
    var time: Int64 = 0, remaining: Int64? = -1, eof = false, paused = false
    var prepareOK = true, closeOK = true, closeHeld = false
    var currentInterval: PlaybackInterval?
    var seeks: [Int64] = [], actions: [PlaybackProgramAction] = [], writes = 0, closeCalls = 0
    var closeContinuation: CheckedContinuation<Bool, Never>?
    func playbackProgramSnapshot() -> PlaybackProgramSnapshot? {
        .init(itemID: item, loadToken: token, entryID: entry, position: time, duration: 20_000_000,
              remaining: remaining, seeking: false, paused: paused, seekable: true, eof: eof, forward: true,
              configuredStart: currentInterval?.startMicroseconds, configuredEnd: currentInterval?.endMicroseconds,
              configuredCount: currentInterval?.nativeLoopSeeks ?? -1)
    }
    func savePlaybackProgram(_ program: PlaybackProgram?, token: UUID) -> Bool {
        guard token == self.token else { return false }; restoredPlaybackProgram = program; return true
    }
    func preparePlaybackProgramCore() -> Bool { prepareOK }
    func writePlaybackProgramInterval(_ interval: PlaybackInterval?) -> Bool {
        writes += 1; currentInterval = interval; remaining = interval?.nativeLoopSeeks ?? -1; return true
    }
    func seekPlaybackProgram(_ target: Int64) -> Bool { seeks.append(target); time = target; return true }
    func holdPlaybackProgramBoundary() -> Bool { paused = true; return true }
    func restorePlaybackProgramPause(_ value: Bool) -> Bool { paused = value; return true }
    func closeRecognitionForPlaybackProgram() async -> Bool {
        closeCalls += 1
        if closeHeld { return await withCheckedContinuation { closeContinuation = $0 } }
        return closeOK
    }
    func performPlaybackProgramAction(_ action: PlaybackProgramAction, ticket: PlaybackProgramTicket) -> Bool {
        guard ticket.itemID == item, ticket.loadToken == token, ticket.entryID == entry else { return false }
        actions.append(action); return true
    }
}

@main struct PlaybackProgramControllerChecks {
    @MainActor static func settle(_ predicate: () -> Bool) async {
        for _ in 0..<10_000 { if predicate() { return }; await Task.yield() }
        precondition(predicate(), "controlled actor operation did not settle")
    }
    @MainActor static func make() -> (ProgramHost, PlaybackProgramController, PlaybackInterval) {
        let host = ProgramHost(); var p = PlaybackProgram(); p.enabled = true
        let row = PlaybackInterval(title: "A", startMicroseconds: 2_000_000, endMicroseconds: 5_000_000, totalPlays: 2)
        p.intervals = [row]; p.selectedIntervalID = row.id; p.introEndMicroseconds = 1_000_000
        p.outroStartMicroseconds = 18_000_000; host.restoredPlaybackProgram = p
        let controller = PlaybackProgramController(host: host); return (host, controller, row)
    }
    @MainActor static func main() async {
        do {
            let (host, c, row) = make(); var p = host.restoredPlaybackProgram!
            p.automaticallyStartSelected = true; host.restoredPlaybackProgram = p
            c.mediaLoaded(explicitStart: true)
            precondition(host.seeks.isEmpty && c.activeIntervalID == nil, "bookmark/history explicit start takes priority")
            precondition(c.activate(row.id) && host.seeks == [2_000_000] && host.remaining == 1, "explicit activation owns start")
            c.playbackRestartObserved(); let second = PlaybackInterval(title: "B", startMicroseconds: 7_000_000, endMicroseconds: 9_000_000)
            p.intervals.append(second); p.afterInterval = .nextInterval; p.revision = UUID()
            precondition(c.save(p) && c.activate(row.id)); c.playbackRestartObserved()
            host.remaining = 0; host.time = 5_033_333; c.observe()
            await settle { c.activeIntervalID == second.id }
            precondition(!host.paused && host.closeCalls == 1 && host.seeks.last == 7_000_000, "next interval strongly closes recognition then restores playing intent")
            print("PASS explicit-start-priority")
        }
        do {
            let (host, c, row) = make(); host.closeHeld = true; c.mediaLoaded(explicitStart: true)
            precondition(c.activate(row.id)); c.playbackRestartObserved()
            host.remaining = 0; host.time = 5_033_333; c.observe()
            await settle { host.closeContinuation != nil }
            host.token = UUID(); c.invalidate(); c.mediaLoaded(explicitStart: true)
            host.closeContinuation?.resume(returning: true)
            for _ in 0..<10 { await Task.yield() }
            precondition(host.actions.isEmpty, "old close cannot act on same UUID replacement load")
            print("PASS late-close-new-load")
        }
        do {
            let (host, c, row) = make(); c.mediaLoaded(explicitStart: true); precondition(c.activate(row.id))
            c.manualSeekAccepted(); host.time = 19_000_000; c.observe()
            precondition(c.activeIntervalID == nil && host.actions.isEmpty && host.closeCalls == 0, "manual seek past B/outro wins")
            print("PASS manual-seek-disables-skips")
        }
        do {
            let (host, c, _) = make(); c.mediaLoaded(explicitStart: true)
            host.eof = true; host.time = 20_000_000; c.mediaEOF(); c.mediaEOF()
            await settle { host.actions.count == 1 }
            precondition(host.actions == [.nextMedia] && host.closeCalls == 1, "one actual EOF action after strong closure")
            print("PASS eof-exact-once")
        }
        do {
            let (host, c, row) = make(); host.closeOK = false; c.mediaLoaded(explicitStart: true)
            precondition(c.activate(row.id)); c.playbackRestartObserved(); host.remaining = 0; host.time = 5_033_333; c.observe()
            await settle { c.error != nil }
            precondition(host.actions.isEmpty && host.paused, "failed strong cleanup preserves paused media")
            print("PASS cleanup-failure-no-action")
        }
        do {
            let (host, c, row) = make(); c.mediaLoaded(explicitStart: true); host.prepareOK = false
            precondition(!c.activate(row.id) && host.writes == 0 && host.seeks.isEmpty, "native tail failure blocks A/B mutation")
            let saved = host.restoredPlaybackProgram
            precondition(!c.save(saved) && host.restoredPlaybackProgram == saved, "afterMedia-only enable cannot bypass native tail readback")
            c.mediaLoaded(explicitStart: true)
            precondition(!c.ownsMediaEnd && c.error != nil, "failed loaded tail retirement leaves original EOF owner intact")
            print("PASS native-owner-boundary")
        }
    }
}
