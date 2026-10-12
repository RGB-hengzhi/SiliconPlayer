import Foundation
import Darwin
import PlayerCore

// Draft against the NEW ledgers/plan/real inspector bodies; never imports the
// old 33-case NativeQueuePolicy and never substitutes a PlayerModel or mpv.
@main struct NativeAudioQueueChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "NativeAudioQueueChecks", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1].hasPrefix("/"), CommandLine.arguments[2].hasPrefix("/") else {
            throw NSError(domain: "fixture", code: 1)
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let tools = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let a = MediaItem(url: directory.appendingPathComponent("A 中文.wav"))
        let b = MediaItem(url: directory.appendingPathComponent("B 空格.flac"))
        let owner = NativeQueueOwner(core: UUID(), session: UUID())
        var ledger = NativeQueueEventLedger()
        try require(ledger.install(owner: owner, rows: [.init(entryID: 71, item: a), .init(entryID: 72, item: b)]), "initial map")
        guard let ta = ledger.adoptAlreadyLoaded(entryID: 71, itemID: a.id) else { throw NSError(domain: "ticket", code: 1) }
        if case .ignored = ledger.start(entryID: 71, expectedUUID: a.id, repeatingFile: false) {} else { try require(false, "duplicate current START") }
        var tb: NativeQueueTicket?
        if case .start(let ticket, let binding) = ledger.start(entryID: 72, expectedUUID: b.id, repeatingFile: false) {
            tb = ticket; try require(binding.item.id == b.id && ticket.cycle > ta.cycle, "UUID/cycle")
        } else { try require(false, "successor START") }
        if case .loaded(let ticket) = ledger.fileLoaded() { try require(ticket == tb, "no-ID LOADED binds exactly pending ticket") }
        else { try require(false, "FILE_LOADED") }
        ledger.retireSession() // B already loaded, A's END is still late.
        if case .end(let ticket) = ledger.end(entryID: 71) { try require(ticket == ta, "late A after retire") }
        else { try require(false, "lost late A receipt") }
        try require(!ledger.install(owner: .init(core: owner.core, session: UUID()), rows: [.init(entryID: 71, item: a)]), "retired native ID reuse rejected")
        print("PASS native-audio.event-ticket-late-receipt")

        var history = NativeQueueHistoryLedger()
        let ah = NativeQueueTicket(owner: owner, entryID: 71, cycle: 1)
        let bh = NativeQueueTicket(owner: owner, entryID: 72, cycle: 2)
        try require(history.register(ah, item: a) && history.register(bh, item: b), "register contexts")
        history.update(ah, loaded: true, position: 3.25, duration: 10)
        history.update(bh, loaded: true, position: 1.5, duration: 24)
        let stop = history.cancel(owner: owner, reason: .manualStop)
        try require(stop.count == 2, "Stop settles ALL loaded receipts, not only active B")
        try require(stop.first(where: { $0.itemID == a.id })?.duration == 10 && stop.first(where: { $0.itemID == a.id })?.position == 3.25, "A immutable duration/position, not B duration")
        let late = history.end(ah, naturalEOF: true)
        try require(late?.originalURL == a.url && late?.position == 10 && late?.duration == 10, "only real late EOF upgrades A")
        let file = directory.appendingPathComponent("history-result.json")
        let store = HistoryStore(fileURL: file)
        for value in stop { store.record(url: value.originalURL, position: value.position, duration: value.duration) }
        if let late { store.record(url: late.originalURL, position: late.position, duration: late.duration) }
        store.flush()
        try require(store.lastError == nil, "real HistoryStore accepted attributed settlements")
        let persisted = HistoryStore(fileURL: file).recentEntries
        try require(persisted.first(where: { $0.url == a.url })?.duration == 10
            && persisted.first(where: { $0.url == b.url })?.duration == 24, "real persisted own durations")
        print("PASS native-audio.history-all-loaded-own-duration")

        var newer = NativeQueueHistoryLedger()
        try require(newer.register(ah, item: a), "old cycle")
        newer.update(ah, loaded: true, position: 3, duration: 10)
        _ = newer.cancel(owner: owner, reason: .newRequest)
        try require(newer.reserveOrdinaryURL(a.url), "same original URL ordinary replacement reservation")
        try require(newer.end(ah, naturalEOF: true) == nil, "old EOF cannot overwrite newer ordinary same URL")
        let an = NativeQueueTicket(owner: .init(core: owner.core, session: UUID()), entryID: 90, cycle: 1)
        try require(newer.register(an, item: a), "new session same UUID")
        newer.update(an, loaded: true, position: 6.5, duration: 10)
        try require(newer.currentSettlement(an)?.position == 6.5, "Stop then explicit Play rebuild owns new ticket")
        print("PASS native-audio.history-newer-original-url-wins")

        // These typed inspections are model inputs, not ffprobe qualification
        // proof. The real inspector case below supplies separate actual media.
        let items = (0..<10).map { MediaItem(url: directory.appendingPathComponent("queue\($0).wav")) }
        var queue = Playlist(); queue.add(items: items)
        var inspected: [UUID: NativeAudioInspection] = [:]
        for item in queue.items {
            inspected[item.id] = .init(originalURL: item.url,
                fingerprint: .init(device: 1, inode: 1, size: 1, modificationNanoseconds: 1),
                container: "wav", codec: "pcm_s24le", sampleRate: 48000, channels: 2,
                channelLayout: "stereo", significantBits: 24, audioStreamCount: 1,
                nonAudioStreamCount: 0, seekable: true, duration: 12,
                externalDiscoveryProvenEmpty: true, discoveryStamps: [])
        }
        let revision = NativeQueueRevision(logical: 9, settings: 3, preferences: 5)
        let base = PlaybackSettings()
        func environment(_ document: MediaPreferenceDocument = .init()) -> NativeAudioPlanBuilder.Environment {
            .init(revision: revision, base: base, effective: base, activeSpeed: 1,
                audioDelay: 0, subtitleDelay: 0, profileBlocked: false, currentTrackAutomatic: true,
                realAudioFilterEmpty: true, realOutputMatchesSource: true, mediaDocument: document,
                observedSampleRate: 48000, observedChannels: 2, observedLayout: "stereo")
        }
        let window = try NativeAudioPlanBuilder.make(logical: queue, owner: owner,
            environment: environment(), inspections: inspected, resumePositions: [:], startPlaying: false)
        try require(window.entries.count == 8 && !window.fullLogicalQueue && queue.items.count == 10, "bounded window preserves ninth and tenth logical rows")
        try require(window.entries.map { $0.item.id } == Array(queue.items.prefix(8)).map(\.id), "original UUID/order")
        try require(!window.startPlaying && window.revision == revision, "initial captured pause/revision")
        let boundary = try NativeAudioPlanBuilder.make(logical: queue, owner: owner,
            environment: environment(), inspections: inspected, resumePositions: [items[2].id: 6], startPlaying: true)
        try require(boundary.entries.count == 2, "successor resume becomes ordinary boundary, not discarded")
        var document = MediaPreferenceDocument()
        var record = MediaPreferenceRecord(identity: try MediaIdentity(originalURL: items[2].url))
        var geometry = MediaGeometryPreference(); geometry.zoom = 0.25; record.geometry = geometry
        try document.save(record)
        let saved = try NativeAudioPlanBuilder.make(logical: queue, owner: owner,
            environment: environment(document), inspections: inspected, resumePositions: [:], startPlaying: true)
        try require(saved.entries.count == 2 && document.record(for: record.identity)?.geometry?.zoom == 0.25,
            "saved media geometry is an ordinary boundary and remains intact")
        _ = queue.select(id: items[8].id)
        let last = try NativeAudioPlanBuilder.make(logical: queue, owner: owner,
            environment: environment(), inspections: inspected, resumePositions: [:], startPlaying: true)
        try require(last.entries.count == 2 && last.initialItemID == items[8].id && !last.fullLogicalQueue, "next controlled segment at item9 without rotating/dropping queue")
        print("PASS native-audio.plan-window-preserves-queue-resume-boundary")

        let inspector = NativeLocalAudioInspector(toolsDirectory: tools)
        let actual = try await inspector.inspect(item: a, directories: [directory], coverNames: [])
        let actualB = try await inspector.inspect(item: b, directories: [directory], coverNames: [])
        try require(actual.audioStreamCount == 1 && actual.nonAudioStreamCount == 0 && actual.codec == "pcm_s24le", "real WAV parser/child")
        try require(actualB.codec == "flac" && actualB.sampleRate == actual.sampleRate && actualB.channels == actual.channels && actualB.significantBits == 24, "real FLAC agrees")
        try require(NativeLocalAudioInspector.stillMatches(actual), "preflight unchanged")
        let possible = directory.appendingPathComponent("A 中文.zh.srt")
        try Data("subtitle".utf8).write(to: possible, options: .withoutOverwriting)
        try require(!NativeLocalAudioInspector.stillMatches(actual), "new potential external file invalidates saved discovery proof")
        var refused = false
        do { _ = try await inspector.inspect(item: a, directories: [directory], coverNames: []) }
        catch { refused = true }
        try require(refused, "external candidate was silently disabled")
        // A decomposed file stem must match the NFC cover whitelist. Probe B,
        // whose filename cannot match A's existing external-subtitle candidate,
        // before and after creating the cover so rejection has a unique cause.
        _ = try await inspector.inspect(item: b, directories: [directory], coverNames: ["cóver"])
        let unicodeCover = directory.appendingPathComponent("co\u{0301}ver.png")
        try Data("potential external cover".utf8).write(to: unicodeCover, options: .withoutOverwriting)
        var unicodeCoverRefused = false
        do { _ = try await inspector.inspect(item: b, directories: [directory], coverNames: ["cóver"]) }
        catch { unicodeCoverRefused = true }
        try require(unicodeCoverRefused, "NFD cover file must match NFC configured cover stem")
        try require(!NativeLocalAudioInspector.hasActiveJobs, "real child registry cleared")
        print("PASS native-audio.real-inspector-file-and-discovery-proof")
        print("INFO 5 new module checks completed; no App, CoreAudio or physical continuity claim")
    }
}
