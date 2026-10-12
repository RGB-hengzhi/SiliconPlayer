import Foundation
import PlayerCore

// Separates native core/session/event cycles from persistent logical UUIDs.
// These identities are memory-only; PlaybackQueueDocument is unchanged.
struct NativeQueueRevision: Equatable {
    var logical: UInt64
    var settings: UInt64
    var preferences: UInt64
}

struct NativeQueueOwner: Equatable, Hashable {
    let core: UUID
    let session: UUID
}

struct NativeQueueTicket: Equatable, Hashable {
    let owner: NativeQueueOwner
    let entryID: Int64
    // Raw mpv events have no cycle number. The event ledger grants this only
    // after a validated START; it must never invent a cycle at END_FILE.
    let cycle: UInt64
}

struct NativeQueueBinding {
    let entryID: Int64
    let item: MediaItem
}

/// Copies scalar C event fields before the next mpv_wait_event. FILE_LOADED
/// has no native ID; this ledger accepts it only for one unambiguous START.
struct NativeQueueEventLedger {
    enum Outcome {
        case unowned
        case ignored(String)
        case start(NativeQueueTicket, NativeQueueBinding)
        case loaded(NativeQueueTicket)
        case end(NativeQueueTicket)
        case unsafe(String)
    }
    private(set) var owner: NativeQueueOwner?
    private(set) var bindings: [Int64: NativeQueueBinding] = [:]
    private var pendingLoaded: NativeQueueTicket?
    private var active: NativeQueueTicket?
    private var open: [Int64: [NativeQueueTicket]] = [:]
    private var loaded = Set<NativeQueueTicket>()
    private var cycle: UInt64 = 0
    private var retired = Set<Int64>()
    private var retiredOrder: [Int64] = []
    private(set) var requiresNewCore = false
    func isRetired(_ entryID: Int64) -> Bool { retired.contains(entryID) }

    // A same-core retired ID reuse is not silently assigned the new session.
    // A finite tombstone budget disables native mode rather than forgetting IDs.
    mutating func install(owner: NativeQueueOwner, rows: [NativeQueueBinding]) -> Bool {
        guard !requiresNewCore, !rows.isEmpty, rows.count <= 32,
              rows.allSatisfy({ $0.entryID >= 0 && !retired.contains($0.entryID) }),
              Set(rows.map(\.entryID)).count == rows.count,
              Set(rows.map { $0.item.id }).count == rows.count else { return false }
        if let currentOwner = self.owner, currentOwner != owner { return false }
        if let active {
            guard let old = bindings[active.entryID],
                  rows.first(where: { $0.entryID == active.entryID })?.item.id == old.item.id else { return false }
        }
        self.owner = owner
        bindings = Dictionary(uniqueKeysWithValues: rows.map { ($0.entryID, $0) })
        return true
    }
    // Initial attachment preserves a real already-loaded ordinary item. The
    // host must supply actual playing row/UUID/path/loaded readbacks captured
    // before append, then quarantine events while assembly is unconfirmed.
    mutating func adoptAlreadyLoaded(entryID: Int64, itemID: UUID) -> NativeQueueTicket? {
        guard active == nil, pendingLoaded == nil, let owner,
              bindings[entryID]?.item.id == itemID, open[entryID, default: []].isEmpty,
              cycle < UInt64.max else { return nil }
        cycle += 1
        let ticket = NativeQueueTicket(owner: owner, entryID: entryID, cycle: cycle)
        active = ticket; open[entryID] = [ticket]; loaded.insert(ticket)
        return ticket
    }
    mutating func start(entryID: Int64, expectedUUID: UUID?, repeatingFile: Bool) -> Outcome {
        if retired.contains(entryID) { return .ignored("retired native entry") }
        guard let owner else { return .unowned }
        guard let binding = bindings[entryID], binding.item.id == expectedUUID else {
            return .unsafe("unmapped or unexpected successor; tail nil never uses initial UUID")
        }
        if let active, active.entryID == entryID, !repeatingFile {
            return .ignored("duplicate START does not grant another cycle")
        }
        guard pendingLoaded == nil else { return .unsafe("START before prior FILE_LOADED is resolved") }
        // Repeated IDs with an outstanding END cannot be disambiguated from
        // the public raw END fields alone. First-phase loops fail closed here.
        guard open[entryID, default: []].isEmpty else {
            return .unsafe("same entry ID reused before its prior END; cycle ambiguity")
        }
        guard cycle < UInt64.max else { return .unsafe("cycle exhausted") }
        cycle += 1
        let ticket = NativeQueueTicket(owner: owner, entryID: entryID, cycle: cycle)
        open[entryID, default: []].append(ticket)
        active = ticket; pendingLoaded = ticket
        return .start(ticket, binding)
    }
    mutating func fileLoaded() -> Outcome {
        guard owner != nil else { return .unowned }
        guard let ticket = pendingLoaded, ticket == active else {
            return .unsafe("FILE_LOADED has no unique accepted START")
        }
        pendingLoaded = nil; loaded.insert(ticket)
        return .loaded(ticket)
    }
    mutating func end(entryID: Int64) -> Outcome {
        // A late owned END can resolve a retired receipt for history. It must
        // never advance the current session or publish current/loaded again.
        guard var tickets = open[entryID], tickets.count == 1 else {
            return retired.contains(entryID) ? .ignored("retired END without receipt") : .unowned
        }
        let ticket = tickets.removeFirst()
        open.removeValue(forKey: entryID); loaded.remove(ticket)
        if pendingLoaded == ticket { pendingLoaded = nil }
        if active == ticket { active = nil }
        return .end(ticket)
    }
    mutating func retireSession() {
        for id in bindings.keys where retired.insert(id).inserted {
            retiredOrder.append(id)
        }
        if retiredOrder.count > 4096 { requiresNewCore = true }
        owner = nil; bindings = [:]; active = nil; pendingLoaded = nil
        // Keep bounded END receipts until drained; cancellation history uses
        // its own immutable contexts rather than player.position/duration.
        if open.values.reduce(0, { $0 + $1.count }) > 128 { requiresNewCore = true }
    }
    mutating func removeBindingsKeepingActive() {
        let keeping = active?.entryID
        for id in bindings.keys where id != keeping && retired.insert(id).inserted { retiredOrder.append(id) }
        bindings = bindings.filter { $0.key == keeping }
        if retiredOrder.count > 4096 { requiresNewCore = true }
    }
    mutating func coreDestroyed() { self = Self() }
}
