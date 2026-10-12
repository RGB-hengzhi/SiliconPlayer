import Foundation
import PlayerCore

private struct CheckFailure: Error { let detail: String }

/// Data/fault injector for the actual proposed transaction. This is not libmpv,
/// a renderer, a disk publisher, a playback model or an AppKit test.
@MainActor private final class PropertyIO: SecondarySubtitleStylePropertyIO {
    static var initial: [String: SubtitleStyleValue] { [
        "secondary-sub-style-independent": .flag(false),
        "secondary-sub-font": .string("sans-serif"),
        "secondary-sub-font-size": .number(38),
        "secondary-sub-color": .string("#FFFFFFFF"),
        "secondary-sub-outline-color": .string("#FF000000"),
        "secondary-sub-outline-size": .number(1.65),
        "secondary-sub-border-style": .string("outline-and-shadow"),
        "secondary-sub-back-color": .string("#FF000000"),
        "secondary-sub-ass-override": .string("strip"),
        "sub-font": .string("Primary untouched"), "sub-font-size": .number(41),
        "sub-color": .string("#FF00FF00"), "sub-delay": .number(0.7),
        "secondary-sub-delay": .number(-0.4), "secondary-sub-pos": .number(17)
    ] }
    var values = initial
    var names = Set(initial.keys)
    var propertyListFails = false
    var readFails: String?
    var rejectWriteAt: Int?
    var ignoreWriteAt: Int?
    var rejectFrom: Int?
    var writes: [(String, SubtitleStyleValue)] = []
    func propertyNames() throws -> Set<String> {
        if propertyListFails { throw SecondarySubtitleStyleFailure.missing("property-list") }
        return names
    }
    func read(_ name: String) throws -> SubtitleStyleValue {
        guard readFails != name, names.contains(name), let value = values[name] else {
            throw SecondarySubtitleStyleFailure.missing(name)
        }
        return value
    }
    func write(_ name: String, value: SubtitleStyleValue) throws {
        writes.append((name, value)); let ordinal = writes.count
        if rejectWriteAt == ordinal || rejectFrom.map({ ordinal >= $0 }) == true {
            throw SecondarySubtitleStyleFailure.write(name)
        }
        if ignoreWriteAt != ordinal { values[name] = value }
    }
}

@main private struct SecondarySubtitleStyleChecks {
    @MainActor static func main() throws {
        var ids: [String] = []
        func expect(_ truth: Bool, _ detail: String) throws {
            if !truth { throw CheckFailure(detail: detail) }
        }
        func record(_ id: String) { ids.append(id); print("PASS " + id) }
        func mustReject(_ body: () throws -> Void, _ detail: String) throws {
            var rejected = false
            do { try body() } catch { rejected = true }
            try expect(rejected, detail)
        }
        func target() -> SecondarySubtitleStyleSettings {
            var p = SecondarySubtitleStyleSettings()
            p.enabled = true; p.font = "Helvetica"; p.size = 58
            p.color = "#FFFFC000"; p.outlineColor = "#FF004080"; p.outline = 4
            p.background = true; p.backColor = "#CC402000"; p.assOverride = "force"
            return p
        }
        func backup(_ settings: PlaybackSettings, media: MediaPreferenceDocument = .init()) -> UserProfileBackupDocument {
            .init(global: settings, shortcuts: [], filters: .init(), media: media,
                  appVersion: "test-only", createdAt: Date(timeIntervalSince1970: 1000))
        }
        let validateShortcut: BackupShortcutValidator = { _, key in key }
        let identity = try MediaIdentity(originalURL: URL(fileURLWithPath: "/private/tmp/style-fixture.mp4"))
        do {
            let old = Data(##"{"subtitleFont":"Arial","subtitleSize":44,"subtitleColor":"#00AA00"}"##.utf8)
            let value = try JSONDecoder().decode(PlaybackSettings.self, from: old)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
            try expect(value.secondarySubtitleStyle == nil && object["secondarySubtitleStyle"] == nil,
                       "missing new key did not retain legacy inherit / omission")
            let derived = SecondarySubtitleStyleSettings(primary: value)
            try expect(derived.font == "Arial" && derived.size == 44 && derived.color == "#FF00AA00" && !derived.enabled,
                       "enable draft did not start from current primary visual settings")
            record("legacy-preferences-omit-new-style-key")
        }
        do {
            let bytes = try backup(PlaybackSettings()).encoded(shortcutValidator: validateShortcut)
            let restored = try UserProfileBackupDocument.boundedDecode(bytes, shortcutValidator: validateShortcut)
            try expect(restored.global.secondarySubtitleStyle == nil,
                       "version-1 canonical profile without new optional key was rejected")
            record("legacy-profile-canonical-roundtrip")
        }
        do {
            var settings = PlaybackSettings(); settings.secondarySubtitleStyle = target()
            var recordValue = MediaPreferenceRecord(identity: identity); recordValue.secondarySubtitleStyle = target()
            var media = MediaPreferenceDocument(); try media.save(recordValue)
            let bytes = try backup(settings, media: media).encoded(shortcutValidator: validateShortcut)
            let restored = try UserProfileBackupDocument.boundedDecode(bytes, shortcutValidator: validateShortcut)
            try expect(restored.global.secondarySubtitleStyle == target()
                       && restored.media.record(for: identity)?.secondarySubtitleStyle == target(),
                       "complete global + media style profile lost fields")
            record("new-profile-retains-global-and-media-styles")
        }
        do {
            let bytes = try backup(PlaybackSettings()).encoded(shortcutValidator: validateShortcut)
            var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            var settings = object["global"] as! [String: Any]
            settings["secondarySubtitleStyle"] = ["enabled": true, "size": 999]
            object["global"] = settings
            let malformed = try JSONSerialization.data(withJSONObject: object)
            try mustReject({ _ = try UserProfileBackupDocument.boundedDecode(malformed, shortcutValidator: validateShortcut) },
                           "strict profile silently defaulted malformed partial style")
            record("malformed-profile-style-is-not-silently-defaulted")
        }
        do {
            var p = target(); p.font = String(repeating: "🇨🇳", count: 200) + "\n"
            p.size = .infinity; p.outline = -.infinity; p.color = " #ffaa80 "
            p.backColor = "bad"; p.assOverride = "unknown"
            let q = p.sanitized(); _ = try q.validated()
            try expect(q.font.utf8.count <= 512 && q.font.count <= 128 && !q.font.contains("\n")
                       && q.size == 40 && q.outline == 2 && q.color == "#FFFFAA80"
                       && q.backColor == "#AF000000" && q.assOverride == "strip", "bounded sanitizer failed")
            record("font-color-finite-sanitization")
        }
        do {
            var session = MediaPreferenceSettingsSession()
            let before = session.effectiveSettings
            var after = before; after.secondarySubtitleStyle = target()
            try session.adoptEffectiveEdit(from: before, to: after)
            try expect(session.baseSnapshot.secondarySubtitleStyle == target(), "idle edit did not change global base")
            let current = session.effectiveSettings; var clear = current; clear.secondarySubtitleStyle = nil
            try session.adoptEffectiveEdit(from: current, to: clear)
            try expect(session.baseSnapshot.secondarySubtitleStyle == nil, "idle removal did not remove optional JSON field")
            record("idle-style-edit-and-nil-removal-change-global-base")
        }
        do {
            var session = MediaPreferenceSettingsSession()
            try session.prepareForLoad(record: nil)
            let before = session.effectiveSettings; var after = before
            after.secondarySubtitleStyle = target(); after.brightness = 15
            try session.adoptEffectiveEdit(from: before, to: after)
            try expect(session.effectiveSettings.secondarySubtitleStyle == target()
                       && session.baseSnapshot.secondarySubtitleStyle == nil
                       && session.baseSnapshot.brightness == 15, "media overlay leaked style into global base")
            session.invalidatePlayback()
            try expect(session.effectiveSettings.secondarySubtitleStyle == nil, "overlay survived playback invalidation")
            record("media-style-overlay-does-not-pollute-global-base")
        }
        do {
            var global = PlaybackSettings(); global.secondarySubtitleStyle = target()
            var session = MediaPreferenceSettingsSession(base: global)
            var r = MediaPreferenceRecord(identity: identity); r.secondarySubtitleStyle = SecondarySubtitleStyleSettings()
            try session.prepareForLoad(record: r)
            try expect(session.effectiveSettings.secondarySubtitleStyle?.enabled == false
                       && session.baseSnapshot.secondarySubtitleStyle?.enabled == true,
                       "explicit media inherit was overwritten by enabled global style")
            let old = session.effectiveSettings; var edited = old; edited.secondarySubtitleStyle = nil
            try session.adoptEffectiveEdit(from: old, to: edited)
            try expect(session.effectiveSettings.secondarySubtitleStyle?.enabled == false, "active nil edit resurrected global independent mode")
            try session.prepareForLoad(record: nil)
            try expect(session.effectiveSettings.secondarySubtitleStyle == target(), "new media retained previous style overlay")
            record("media-explicit-inherit-and-new-load-reset")
        }
        do {
            var r = MediaPreferenceRecord(identity: identity); r.secondarySubtitleStyle = target()
            var d = MediaPreferenceDocument(); try d.save(r)
            let restored = try MediaPreferenceDocument.boundedDecode(d.encoded())
            try expect(restored.record(for: identity)?.secondarySubtitleStyle == target(), "media document style lost")
            var invalid = target(); invalid.size = 999; r.secondarySubtitleStyle = invalid
            try mustReject({ _ = try r.validated() }, "invalid media style admitted by record validator")
            record("media-record-style-roundtrip-and-validation")
        }
        do {
            let io = PropertyIO()
            let result = SecondarySubtitleStyleTransaction.apply(nil, io: io)
            try expect(result.applied && result.supported && io.writes.isEmpty, "already inherited engine was mutated")
            let p = target(); _ = SecondarySubtitleStyleTransaction.apply(p, io: io)
            io.writes = []
            let repeated = SecondarySubtitleStyleTransaction.apply(p, io: io)
            try expect(repeated.applied && io.writes.isEmpty, "unchanged independent style recreated decoder unnecessarily")
            record("checked-no-op-does-not-toggle-hard-update-mode")
        }
        do {
            let io = PropertyIO(); io.values["secondary-sub-style-independent"] = .flag(true)
            let previous = io.values
            let result = SecondarySubtitleStyleTransaction.apply(target(), io: io)
            try expect(result.applied && io.writes.first?.0 == "secondary-sub-style-independent"
                       && io.writes.first?.1 == .flag(false) && io.writes.last?.1 == .flag(true),
                       "independent mode was enabled before complete style configuration")
            try expect(io.values["sub-font"] == previous["sub-font"] && io.values["sub-color"] == previous["sub-color"]
                       && io.values["sub-delay"] == previous["sub-delay"]
                       && io.values["secondary-sub-delay"] == previous["secondary-sub-delay"]
                       && io.values["secondary-sub-pos"] == previous["secondary-sub-pos"]
                       && io.writes.allSatisfy({ $0.0.hasPrefix("secondary-sub-") }), "primary style/timing was modified")
            record("secondary-only-configuration-enables-mode-last")
        }
        do {
            let io = PropertyIO(); let before = io.values; io.rejectWriteAt = 2
            let result = SecondarySubtitleStyleTransaction.apply(target(), io: io)
            try expect(!result.applied && result.recovery == nil && io.values == before,
                       "setter failure did not fail and restore original engine state")
            record("negative-setter-result-rolls-back")
        }
        do {
            let io = PropertyIO(); let before = io.values; io.ignoreWriteAt = 2
            let result = SecondarySubtitleStyleTransaction.apply(target(), io: io)
            try expect(!result.applied && result.recovery == nil && io.values == before,
                       "zero return with wrong readback was treated as successful application")
            record("silent-setter-rejection-is-caught-by-readback")
        }
        do {
            let io = PropertyIO(); let before = io.values; io.rejectFrom = 2
            let result = SecondarySubtitleStyleTransaction.apply(target(), io: io)
            try expect(!result.applied && result.recovery != nil && io.values != before,
                       "failed rollback discarded recovery snapshot or claimed applied")
            io.rejectFrom = nil
            try expect(SecondarySubtitleStyleTransaction.restore(result.recovery!, io: io) && io.values == before,
                       "explicit retry could not restore exact prior nine-property snapshot")
            record("failed-rollback-retains-snapshot-and-retry")
        }
        do {
            let io = PropertyIO(); io.names.remove("secondary-sub-style-independent")
            let inherited = SecondarySubtitleStyleTransaction.apply(nil, io: io)
            let independent = SecondarySubtitleStyleTransaction.apply(target(), io: io)
            try expect(inherited.applied && !inherited.supported && !independent.applied && io.writes.isEmpty,
                       "legacy engine got nonexistent setters or claimed independent style")
            var disabled = SecondarySubtitleStyleSettings(); disabled.assOverride = "force"
            let unsupportedOverride = SecondarySubtitleStyleTransaction.apply(disabled, io: io)
            io.values["secondary-sub-ass-override"] = .string("force")
            try expect(!unsupportedOverride.applied && !SecondarySubtitleStyleTransaction.matches(nil, io: io) && io.writes.isEmpty,
                       "legacy path claimed a secondary override that was not applied")
            record("legacy-engine-inherit-only-without-fake-properties")
        }
        do {
            let io = PropertyIO(); io.names.remove("secondary-sub-back-color")
            let result = SecondarySubtitleStyleTransaction.apply(nil, io: io)
            try expect(!result.applied && !SecondarySubtitleStyleTransaction.matches(nil, io: io) && io.writes.isEmpty,
                       "incomplete upgraded engine was disguised as legacy inherit")
            record("partial-new-capability-is-rejected")
        }
        do {
            let io = PropertyIO(); io.propertyListFails = true
            let result = SecondarySubtitleStyleTransaction.apply(nil, io: io)
            try expect(!result.applied && !SecondarySubtitleStyleTransaction.matches(nil, io: io) && io.writes.isEmpty,
                       "property list error was confused with legacy property absence")
            record("capability-query-error-is-not-missing-feature-success")
        }
        do {
            let io = PropertyIO(); io.readFails = "secondary-sub-font-size"
            let result = SecondarySubtitleStyleTransaction.apply(target(), io: io)
            try expect(!result.applied && result.recovery == nil && io.writes.isEmpty, "partial preflight snapshot was mutated")
            record("incomplete-preflight-snapshot-writes-nothing")
        }
        do {
            let io = PropertyIO(); _ = SecondarySubtitleStyleTransaction.apply(target(), io: io)
            let primary = io.values["sub-color"]; let before = io.values
            let result = SecondarySubtitleStyleTransaction.apply(nil, io: io)
            try expect(result.applied && io.values["secondary-sub-style-independent"] == .flag(false)
                       && io.values["secondary-sub-ass-override"] == .string("strip")
                       && io.values["sub-color"] == primary && result.previous?["secondary-sub-font"] == before["secondary-sub-font"],
                       "inherit reset changed primary state or lost rollback snapshot")
            record("inherit-reset-keeps-primary-and-full-before-snapshot")
        }
        do {
            let io = PropertyIO(); var invalid = target(); invalid.font = "\u{0000}bad"
            let result = SecondarySubtitleStyleTransaction.apply(invalid, io: io)
            try expect(!result.applied && io.writes.isEmpty && result.recovery == nil,
                       "invalid preference crossed the native write boundary")
            record("invalid-preference-is-rejected-before-native-writes")
        }
        try expect(ids.count == 20 && Set(ids).count == ids.count, "case IDs missing or duplicated")
        print("SecondarySubtitleStyleChecks: \(ids.count) planned checks executed")
    }
}
