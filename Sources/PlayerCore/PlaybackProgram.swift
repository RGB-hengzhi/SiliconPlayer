import Foundation

/// Per-media opt-in. No global queue, track ID, or system power operation is encoded.
public enum PlaybackProgramAction: String, Codable, CaseIterable, Sendable {
    case nextInterval, continuePlayback, nextMedia, pause, stop, quit, appSleep
}

public struct PlaybackInterval: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var startMicroseconds: Int64
    public var endMicroseconds: Int64
    /// Total passes, including the initial pass. nil means infinite.
    public var totalPlays: Int?
    public init(id: UUID = UUID(), title: String, startMicroseconds: Int64,
                endMicroseconds: Int64, totalPlays: Int? = 1) {
        self.id = id; self.title = title; self.startMicroseconds = startMicroseconds
        self.endMicroseconds = endMicroseconds; self.totalPlays = totalPlays
    }
    public var nativeLoopSeeks: Int64 { totalPlays.map { Int64($0 - 1) } ?? -1 }
    public func validated() throws -> Self {
        guard title.utf8.count <= 256, !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              startMicroseconds >= 0, endMicroseconds > startMicroseconds,
              endMicroseconds <= PlaybackProgram.maximumTime,
              totalPlays.map({ (1...1_000_000).contains($0) }) ?? true else {
            throw MediaPreferenceError.invalidDocument
        }
        return self
    }
}

public struct PlaybackProgram: Codable, Hashable, Sendable {
    public static let maximumIntervals = 64
    public static let maximumTime: Int64 = 7 * 24 * 60 * 60 * 1_000_000
    public var revision = UUID()
    public var enabled = false
    public var intervals: [PlaybackInterval] = []
    public var selectedIntervalID: UUID?
    public var automaticallyStartSelected = false
    public var afterInterval = PlaybackProgramAction.pause
    public var afterMedia = PlaybackProgramAction.nextMedia
    public var introEndMicroseconds: Int64?
    public var outroStartMicroseconds: Int64?
    public init() {}
    public func validated() throws -> Self {
        guard intervals.count <= Self.maximumIntervals,
              Set(intervals.map(\.id)).count == intervals.count,
              selectedIntervalID.map({ id in intervals.contains { $0.id == id } }) ?? true,
              !automaticallyStartSelected || selectedIntervalID != nil,
              ![.nextInterval, .continuePlayback].contains(afterMedia) else {
            throw MediaPreferenceError.invalidDocument
        }
        for interval in intervals { _ = try interval.validated() }
        for mark in [introEndMicroseconds, outroStartMicroseconds].compactMap({ $0 }) {
            guard mark > 0, mark <= Self.maximumTime else { throw MediaPreferenceError.invalidDocument }
        }
        if let intro = introEndMicroseconds, let outro = outroStartMicroseconds,
           intro >= outro { throw MediaPreferenceError.invalidDocument }
        return self
    }
    public var selectedInterval: PlaybackInterval? { intervals.first { $0.id == selectedIntervalID } }
    public func successor(after id: UUID) -> PlaybackInterval? {
        guard let index = intervals.firstIndex(where: { $0.id == id }), index + 1 < intervals.count else { return nil }
        return intervals[index + 1]
    }
    public static func microseconds(_ seconds: Double) -> Int64? {
        guard seconds.isFinite, seconds >= 0, seconds <= Double(maximumTime) / 1_000_000 else { return nil }
        return Int64((seconds * 1_000_000).rounded())
    }
    public static func seconds(_ value: Int64) -> String {
        let whole = value / 1_000_000, remainder = value % 1_000_000
        return String(whole) + "." + String(repeating: "0", count: 6 - String(remainder).count) + String(remainder)
    }
    public static func parseSeconds(_ text: String) -> Int64? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              !parts[0].isEmpty, parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              let whole = Int64(parts[0]), whole <= maximumTime / 1_000_000 else { return nil }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= 6, fraction.allSatisfy({ $0.isASCII && $0.isNumber }),
              let digits = Int64(fraction.isEmpty ? "0" : fraction) else { return nil }
        var scaled = digits
        for _ in fraction.count..<6 { scaled *= 10 }
        let value = whole * 1_000_000 + scaled
        return value <= maximumTime ? value : nil
    }
}

/// The actual Core media binding, independent of the queue's selected UI row.
public struct PlaybackProgramTicket: Equatable, Sendable {
    public let itemID: UUID
    public let loadToken: UUID
    public let entryID: Int64
    public let programRevision: UUID
    public init(itemID: UUID, loadToken: UUID, entryID: Int64, programRevision: UUID) {
        self.itemID = itemID; self.loadToken = loadToken; self.entryID = entryID; self.programRevision = programRevision
    }
}

/// Finite completion is read from mpv's real remaining-ab-loops. A decrease in
/// position never stands in for a loop count. Polling gives bounded coarse B
/// crossing, not sample/frame-accurate pausing at B.
public struct PlaybackIntervalCompletion: Sendable {
    public private(set) var ticket: PlaybackProgramTicket?
    public private(set) var interval: PlaybackInterval?
    public private(set) var completed = false
    private var previousPosition: Int64?
    private var seekSettled = false
    public init() {}
    public mutating func arm(_ interval: PlaybackInterval, ticket: PlaybackProgramTicket,
                             actualRemaining: Int64) throws {
        _ = try interval.validated()
        guard actualRemaining == interval.nativeLoopSeeks else { throw MediaPreferenceError.invalidDocument }
        self.ticket = ticket; self.interval = interval; completed = false
        previousPosition = nil; seekSettled = false
    }
    public mutating func invalidate() { self = .init() }
    public mutating func observe(ticket: PlaybackProgramTicket, position: Int64, remaining: Int64,
                                  seeking: Bool, forward: Bool) -> Bool {
        guard self.ticket == ticket, let interval, !completed, position >= 0 else { return false }
        guard !seeking, forward else { return false }
        // A real post-seek observation must be within the selected interval.
        // An immediate seek to beyond B cannot arm an end action.
        if !seekSettled {
            guard position >= interval.startMicroseconds, position < interval.endMicroseconds else { return false }
            seekSettled = true; previousPosition = position; return false
        }
        defer { previousPosition = position }
        guard interval.totalPlays != nil, remaining == 0,
              let previousPosition, previousPosition < interval.endMicroseconds,
              position >= interval.endMicroseconds else { return false }
        completed = true; return true
    }
}
