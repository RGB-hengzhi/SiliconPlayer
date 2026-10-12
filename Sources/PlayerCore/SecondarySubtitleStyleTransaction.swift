import Foundation

public enum SubtitleStyleValue: Equatable, Sendable {
    case flag(Bool), number(Double), string(String)
    public func matches(_ other: Self) -> Bool {
        switch (self, other) {
        case (.number(let a), .number(let b)): return a.isFinite && b.isFinite && abs(a - b) <= 0.0001
        default: return self == other
        }
    }
}

@MainActor public protocol SecondarySubtitleStylePropertyIO {
    func propertyNames() throws -> Set<String>
    func read(_ name: String) throws -> SubtitleStyleValue
    func write(_ name: String, value: SubtitleStyleValue) throws
}

public struct SecondarySubtitleStyleApplyResult: Sendable {
    public let supported: Bool
    public let applied: Bool
    public let message: String?
    /// Non-nil only when a partial mutation could not be restored/read back.
    public let recovery: [String: SubtitleStyleValue]?
    public let previous: [String: SubtitleStyleValue]?
}

/// A synchronous checked transaction, not a compositor-atomic frame update.
/// Only secondary-sub-* keys can enter this write set; primary keys are absent.
@MainActor public enum SecondarySubtitleStyleTransaction {
    public static let mode = "secondary-sub-style-independent"
    public static let styleKeys = ["secondary-sub-font", "secondary-sub-font-size",
        "secondary-sub-color", "secondary-sub-outline-color", "secondary-sub-outline-size",
        "secondary-sub-border-style", "secondary-sub-back-color", "secondary-sub-ass-override"]
    public static let requiredKeys = [mode] + styleKeys

    public static func supported(by io: any SecondarySubtitleStylePropertyIO) -> Bool {
        guard let names = try? io.propertyNames() else { return false }
        return requiredKeys.allSatisfy(names.contains)
    }
    public static func desired(_ style: SecondarySubtitleStyleSettings?) throws -> [String: SubtitleStyleValue] {
        guard let style else { return [mode: .flag(false), "secondary-sub-ass-override": .string("strip")] }
        let s = try style.validated()
        return [mode: .flag(s.enabled), "secondary-sub-font": .string(s.font),
            "secondary-sub-font-size": .number(s.size), "secondary-sub-color": .string(s.color),
            "secondary-sub-outline-color": .string(s.outlineColor),
            "secondary-sub-outline-size": .number(s.outline),
            "secondary-sub-border-style": .string(s.background ? "background-box" : "outline-and-shadow"),
            "secondary-sub-back-color": .string(s.backColor), "secondary-sub-ass-override": .string(s.assOverride)]
    }
    private static func legacyInherited(_ style: SecondarySubtitleStyleSettings?,
                                        names: Set<String>, io: any SecondarySubtitleStylePropertyIO) -> Bool {
        guard !names.contains(mode), style?.enabled != true,
              (style?.assOverride ?? "strip") == "strip", names.contains("secondary-sub-ass-override"),
              (try? desired(style)) != nil,
              let actual = try? io.read("secondary-sub-ass-override") else { return false }
        // Other disabled style fields are inactive intent, not claimed rendered.
        return actual.matches(.string("strip"))
    }
    public static func matches(_ style: SecondarySubtitleStyleSettings?, io: any SecondarySubtitleStylePropertyIO) -> Bool {
        guard let names = try? io.propertyNames() else { return false }
        if !requiredKeys.allSatisfy(names.contains) {
            return legacyInherited(style, names: names, io: io)
        }
        guard let values = try? desired(style) else { return false }
        return matchesValues(values, io: io)
    }
    private static func matchesValues(_ values: [String: SubtitleStyleValue], io: any SecondarySubtitleStylePropertyIO) -> Bool {
        values.allSatisfy { key, expected in
            guard let actual = try? io.read(key) else { return false }
            return actual.matches(expected)
        }
    }
    private static func setAndVerify(_ name: String, _ value: SubtitleStyleValue,
                                     io: any SecondarySubtitleStylePropertyIO) throws {
        if try io.read(name).matches(value) { return }
        try io.write(name, value: value)
        guard try io.read(name).matches(value) else { throw SecondarySubtitleStyleFailure.invalidValue(name) }
    }
    private static func orderedWrite(_ values: [String: SubtitleStyleValue],
                                     io: any SecondarySubtitleStylePropertyIO) throws {
        // Never expose a partly configured independent style. Previously enabled
        // styling can briefly inherit during this non-atomic public-API sequence.
        try setAndVerify(mode, .flag(false), io: io)
        for key in styleKeys { if let value = values[key] { try setAndVerify(key, value, io: io) } }
        if let finalMode = values[mode] { try setAndVerify(mode, finalMode, io: io) }
        guard matchesValues(values, io: io) else { throw SecondarySubtitleStyleFailure.invalidValue("final-readback") }
    }
    /// Recovery is an explicit retry on the same immutable core handle.
    /// A failure never becomes success because setters happened to return zero.
    public static func restore(_ before: [String: SubtitleStyleValue],
                               io: any SecondarySubtitleStylePropertyIO) -> Bool {
        guard Set(before.keys) == Set(requiredKeys) else { return false }
        if matchesValues(before, io: io) { return true }
        do { try orderedWrite(before, io: io); return true }
        catch { return false }
    }
    public static func apply(_ style: SecondarySubtitleStyleSettings?,
                             io: any SecondarySubtitleStylePropertyIO) -> SecondarySubtitleStyleApplyResult {
        let names: Set<String>
        do { names = try io.propertyNames() }
        catch { return .init(supported: false, applied: false, message: error.localizedDescription, recovery: nil, previous: nil) }
        let available = requiredKeys.allSatisfy(names.contains)
        if !available {
            // Legacy inherit on a legacy engine issues no unavailable setters.
            let inheritedLegacy = legacyInherited(style, names: names, io: io)
            return .init(supported: false, applied: inheritedLegacy,
                message: inheritedLegacy ? nil : SecondarySubtitleStyleFailure.unavailable.localizedDescription,
                recovery: nil, previous: nil)
        }
        var before: [String: SubtitleStyleValue] = [:]
        do {
            let target = try desired(style)
            for key in requiredKeys { before[key] = try io.read(key) }
            if matchesValues(target, io: io) {
                return .init(supported: true, applied: true, message: nil, recovery: nil, previous: before)
            }
            try orderedWrite(target, io: io)
            return .init(supported: true, applied: true, message: nil, recovery: nil, previous: before)
        } catch {
            // Preflight/read failures before a complete snapshot made no writes.
            if before.count != requiredKeys.count {
                return .init(supported: true, applied: false, message: error.localizedDescription, recovery: nil, previous: nil)
            }
            let restored = restore(before, io: io)
            return .init(supported: true, applied: false,
                message: error.localizedDescription + (restored ? "；已恢复原副字幕样式" : "；回滚未确认，请重试恢复"),
                recovery: restored ? nil : before, previous: before)
        }
    }
}
