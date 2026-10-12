import Foundation
import PlayerCore

// Settles playback receipts against their original item and own duration.
struct NativeQueueHistorySettlement {
    enum Reason { case naturalEOF, manualStop, removedCurrent, newRequest, error, unsafeTransition }
    let ticket: NativeQueueTicket
    let itemID: UUID
    let originalURL: URL
    let position: Double
    let duration: Double
    let reason: Reason
}

/// Survives session invalidation, so old A END arriving after B START or Stop
/// can be attributed without using B's URL/duration. Reservations also prevent
/// an older same-URL loop receipt overwriting a newer cycle's history.
struct NativeQueueHistoryLedger {
    struct Context {
        let ticket: NativeQueueTicket
        let item: MediaItem
        let ordinal: UInt64
        var loaded: Bool
        var position: Double
        var duration: Double
        var canceled: Bool
        var ended: Bool
    }
    private var contexts: [NativeQueueTicket: Context] = [:]
    private var order: [NativeQueueTicket] = []
    private var latestByURL: [URL: UInt64] = [:]
    private var ordinal: UInt64 = 0
    private(set) var requiresDrain = false

    mutating func register(_ ticket: NativeQueueTicket, item: MediaItem) -> Bool {
        let key = MediaItem.normalized(item.url)
        guard contexts[ticket] == nil, ordinal < UInt64.max, contexts.count < 128,
              latestByURL[key] != nil || latestByURL.count < 8192 else {
            requiresDrain = true; return false
        }
        ordinal += 1
        latestByURL[key] = ordinal
        contexts[ticket] = Context(ticket: ticket, item: item, ordinal: ordinal,
            loaded: false, position: 0, duration: 0, canceled: false, ended: false)
        order.append(ticket)
        return true
    }
    mutating func update(_ ticket: NativeQueueTicket, loaded: Bool, position: Double, duration: Double) {
        guard var context = contexts[ticket], !context.ended,
              position.isFinite, duration.isFinite, position >= 0, duration > 0 else { return }
        context.loaded = context.loaded || loaded
        context.position = min(position, duration); context.duration = duration
        contexts[ticket] = context
    }
    private func settlement(_ context: Context, reason: NativeQueueHistorySettlement.Reason,
                            natural: Bool) -> NativeQueueHistorySettlement? {
        guard context.loaded, context.duration > 0,
              latestByURL[MediaItem.normalized(context.item.url)] == context.ordinal else { return nil }
        return NativeQueueHistorySettlement(ticket: context.ticket, itemID: context.item.id,
            originalURL: context.item.url, position: natural ? context.duration : context.position,
            duration: context.duration, reason: reason)
    }
    func currentSettlement(_ ticket: NativeQueueTicket) -> NativeQueueHistorySettlement? {
        guard let context = contexts[ticket], !context.ended, !context.canceled else { return nil }
        return settlement(context, reason: .newRequest, natural: false)
    }
    mutating func end(_ ticket: NativeQueueTicket, naturalEOF: Bool) -> NativeQueueHistorySettlement? {
        guard var context = contexts[ticket], !context.ended else { return nil }
        context.ended = true; contexts[ticket] = context
        let result = settlement(context, reason: naturalEOF ? .naturalEOF : .error, natural: naturalEOF)
        contexts.removeValue(forKey: ticket); order.removeAll { $0 == ticket }
        return result
    }
    /// Call before clearing policy contexts. START alone does not prove EOF;
    /// unended older media settle their last known position and own duration.
    /// A later real EOF can upgrade it only if no newer same-URL reservation won.
    mutating func cancel(owner: NativeQueueOwner, reason: NativeQueueHistorySettlement.Reason) -> [NativeQueueHistorySettlement] {
        var result: [NativeQueueHistorySettlement] = []
        for ticket in order where ticket.owner == owner {
            guard var context = contexts[ticket], !context.ended, !context.canceled else { continue }
            context.canceled = true; contexts[ticket] = context
            if let value = settlement(context, reason: reason, natural: false) { result.append(value) }
        }
        return result
    }
    // Every ordinary replacement of the same original URL reserves a newer
    // ordinal too, before any native old END can overwrite that history.
    mutating func reserveOrdinaryURL(_ url: URL) -> Bool {
        let key = MediaItem.normalized(url)
        // Ordinary mode has no new receipt to reserve. Only a URL already
        // known to native history can receive a dangerous late old END.
        guard latestByURL[key] != nil else { return true }
        guard ordinal < UInt64.max, latestByURL[key] != nil || latestByURL.count < 8192 else {
            requiresDrain = true; return false
        }
        ordinal += 1; latestByURL[key] = ordinal
        return true
    }
    mutating func coreDestroyed() {
        contexts = [:]; order = []; latestByURL = [:]; requiresDrain = false
        // Core destruction makes its old receipts impossible; the next core
        // starts a new bounded map without keeping arbitrary past URLs forever.
    }
}
