import AppKit
import Foundation
import Darwin

// This stub records routing only. It does not play media, open windows, or
// reproduce the production player's implementation.
@MainActor
final class PlayerModel {
    var calls: [String] = []
    let volume = 80.0
    let speed = 1.0
    var showAdvanced = false { didSet { if showAdvanced { calls.append("advanced") } } }
    var showLibrary = false { didSet { if showLibrary { calls.append("library") } } }
    func togglePause() { calls.append("pause") }
    func stopPlayback() { calls.append("stop") }
    func revertSeek() { calls.append("revert") }
    func jumpKeyframe(_ seconds: Double) { calls.append("keyframe:\(seconds)") }
    func jump(_ seconds: Double) { calls.append("jump:\(seconds)") }
    func setVolume(_ value: Double) { calls.append("volume:\(value)") }
    func setSpeed(_ value: Double) { calls.append("speed:\(value)") }
    func beginTemporarySpeed(_ event: NSEvent) -> Bool { calls.append("hold-speed:\(event.keyCode)"); return true }
    func toggleMute() { calls.append("mute") }
    func frameStep(backward: Bool = false) { calls.append(backward ? "frame-back" : "frame-forward") }
    func cycleAB() { calls.append("ab") }
    func screenshot() { calls.append("screenshot") }
    func next() { calls.append("next") }
    func previous() { calls.append("previous") }
    func jumpChapter(_ direction: Int) { calls.append("chapter:\(direction)") }
    func addBookmark() { calls.append("bookmark") }
    func toggleMiniMode() { calls.append("mini") }
}

private struct InputCheckFailure: Error, CustomStringConvertible {
    let description: String
}

/// Uses the real private NSUserDefaults store, but reports one explicit
/// synchronization failure to exercise production cancellation handling.
private final class ControlledSynchronizeFailureDefaults: UserDefaults {
    var rejectNextSynchronization = false
    override func synchronize() -> Bool {
        let actual = super.synchronize()
        if rejectNextSynchronization { rejectNextSynchronization = false; return false }
        return actual
    }
}

@main
struct InputChecks {
    private static let storageKey = "SiliconPlayer.shortcuts.v1"

    @MainActor
    static func main() throws {
        setbuf(stdout, nil)
        // The fullscreen route reads NSApp.keyWindow. No window or event loop
        // is created; only dispatch and consumption are checked here.
        _ = NSApplication.shared
        try normalization()
        print("PASS defaults, aliases, modifier order and finite key syntax")
        try defaultRouting()
        print("PASS real NSEvent default routing, stop, revertSeek and both keyframe directions")
        try reservedShortcuts()
        print("PASS reserved menus/system commands including canonical cmd+ctrl+f")
        try rejectedEdits()
        print("PASS invalid actions/keys and conflicts preserve bindings and stored data")
        try persistenceAndUnbinding()
        print("PASS save/reload, custom NSEvent modifiers, special keys and unbinding")
        try restoration()
        print("PASS restore defaults clears errors and persists the restored mapping")
        try migration()
        print("PASS upgrade merge retains custom mappings and safely handles duplicates/new actions")
        try invalidPreferences()
        print("PASS malformed JSON and invalid/reserved stored keys fall back safely")
        try verificationIsolation()
        print("PASS explicit real-app verification preference suite preserves standard shortcuts")
        try backupValidation()
        print("PASS typed shortcut backup rejects invalid whole documents before changing stored bytes")
        try backupStorage()
        print("PASS shortcut transaction write reload and original malformed-byte rollback use isolated preferences")
        try verificationTermination()
        print("PASS bound verification termination clears same instance closes all shortcut writes and resumes cancelled exit")
        try ordinaryTerminationProtection()
        print("PASS termination cleanup rejects foreign verification identity and preserves ordinary injected and standard preferences")
        try failedTerminationRollback()
        print("PASS failed verification rollback retains original domain and closed write gate until successful exact retry")
        try boundedTerminationDiskReads()
        print("PASS private-domain disk evidence reads real bounded regular files and rejects symlink FIFO malformed and oversize inputs")
        print("15 input integration groups passed; synthetic NSEvents, no UI/physical keyboard or media-key acceptance inferred")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw InputCheckFailure(description: message) }
    }

    @MainActor
    private static func verificationIsolation() throws {
        let report = "/private/tmp/input-verify-\(UUID().uuidString)/report.json"
        let storage = "/private/tmp/input-verify-storage"
        let environment = ["SILICONPLAYER_VERIFY_REPORT": report, "SILICONPLAYER_VERIFY_STORAGE": storage]
        let suite = try XCTSuite(environment)
        try expect(suite == InputController.verificationSuiteName(environment: environment), "Suite is unstable")
        try expect(!suite.contains(report) && !suite.contains(storage), "Suite leaks path text")
        try expect(suite != InputController.verificationSuiteName(environment: environment.merging(["SILICONPLAYER_VERIFY_REPORT": report + "-other"], uniquingKeysWith: { _, new in new })), "Separate reports share preferences")
        for invalid in [[:], ["SILICONPLAYER_VERIFY_REPORT":report], ["SILICONPLAYER_VERIFY_STORAGE":storage],
                        ["SILICONPLAYER_VERIFY_REPORT":"relative", "SILICONPLAYER_VERIFY_STORAGE":storage],
                        ["SILICONPLAYER_VERIFY_REPORT":report, "SILICONPLAYER_VERIFY_STORAGE":"/bad\npath"]] {
            try expect(InputController.verificationSuiteName(environment: invalid) == nil, "Implicit/invalid verification accepted")
            try expect(!InputController.clearVerificationPreferences(environment: invalid), "Invalid cleanup touched preferences")
        }
        let original = UserDefaults.standard.data(forKey: storageKey)
        guard let isolatedPreferences = UserDefaults(suiteName: suite) else { throw InputCheckFailure(description: "Suite creation failed") }
        defer { isolatedPreferences.removePersistentDomain(forName: suite) }
        guard let controller = InputController(verificationEnvironment: environment) else { throw InputCheckFailure(description: "Bound verification instance failed") }
        try expect(controller.update(action: "togglePause", key: "option+space"), "Isolated update failed")
        try expect(InputController(preferences: isolatedPreferences).bindings.first(where: { $0.action == "togglePause" })?.key == "option+space", "Isolated update did not persist")
        try expect(controller.closeVerificationWritesAndClear(environment: environment, phase: "isolation-check")?.succeeded == true, "Verification cleanup failed")
        try expect(isolatedPreferences.data(forKey: storageKey) == nil, "Verification shortcut bytes remain after cleanup")
        try expect(UserDefaults.standard.data(forKey: storageKey) == original, "Standard shortcuts modified")
    }

    @MainActor
    private static func XCTSuite(_ environment: [String: String]) throws -> String {
        guard let name = InputController.verificationSuiteName(environment: environment) else {
            throw InputCheckFailure(description: "Valid verification paths rejected")
        }
        return name
    }

    @MainActor
    private static func verificationTermination() throws {
        let environment = ["SILICONPLAYER_VERIFY_REPORT":"/private/tmp/input-terminal-\(UUID().uuidString)/report.json",
                           "SILICONPLAYER_VERIFY_STORAGE":"/private/tmp/input-terminal-profile"]
        let suite = try XCTSuite(environment)
        guard let controller = InputController(verificationEnvironment: environment), let observer = UserDefaults(suiteName: suite) else {
            throw InputCheckFailure(description: "Bound suite initialization failed")
        }
        defer { observer.removePersistentDomain(forName: suite); _ = observer.synchronize() }
        try expect(controller.update(action: "togglePause", key: "option+space"), "Initial verified edit failed")
        let original = try controller.profileShortcutData(), originalBindings = controller.bindings
        observer.set("owned-test-only", forKey: "verification-test-sentinel")
        guard let result = controller.closeVerificationWritesAndClear(environment: environment, phase: "before-terminateNow") else {
            throw InputCheckFailure(description: "Exact suite cleanup rejected")
        }
        try expect(result.suite == suite && result.sameBoundInstance && result.synchronizeSucceeded && result.memoryDomainEmpty && result.succeeded,
                   "Bound same-instance clear not confirmed")
        try expect(result.beforeKeys == [storageKey,"verification-test-sentinel"].sorted() && result.afterKeys.isEmpty && result.writesClosed,
                   "Private before/after key evidence incorrect")
        try expect(result.finishedUptime >= result.startedUptime && result.invocation == 1, "Missing actual cleanup order")
        try expect(!controller.update(action: "togglePause", key: "ctrl+space"), "Closed verification edit accepted")
        controller.restoreDefaults()
        try expect(controller.bindings == originalBindings && (try controller.profileShortcutData()) == nil, "Closed update/reset changed bindings or republished bytes")
        for candidate in [original, nil] {
            var rejected = false
            do { try controller.writeProfileShortcutData(candidate) } catch { rejected = true }
            try expect(rejected && (try controller.profileShortcutData()) == nil, "Closed raw transaction write/remove accepted")
        }
        try expect(controller.resumeVerificationWritesAfterCancelledTermination(environment: environment), "Cancelled exit did not resume")
        try expect(!controller.verificationWritesClosed && (try controller.profileShortcutData()) == original && observer.string(forKey: "verification-test-sentinel") == "owned-test-only",
                   "Cancelled exit failed to restore the private domain exactly")
        try expect(controller.update(action: "togglePause", key: "ctrl+space"), "Cancelled exit left writes blocked")
        try expect(controller.closeVerificationWritesAndClear(environment: environment, phase: "before-reply-true")?.succeeded == true, "Second exit clear failed")
        let fallback = controller.closeVerificationWritesAndClear(environment: environment, phase: "willTerminate-fallback")
        try expect(fallback?.succeeded == true && fallback?.beforeKeys.isEmpty == true && fallback?.writesClosed == true,
                   "Fallback is not idempotent or reopened writes")
    }

    @MainActor
    private static func ordinaryTerminationProtection() throws {
        let environment = ["SILICONPLAYER_VERIFY_REPORT":"/private/tmp/input-foreign-\(UUID().uuidString)/report.json",
                           "SILICONPLAYER_VERIFY_STORAGE":"/private/tmp/input-foreign-profile"]
        let originalStandard = try UserDefaults.standard.object(forKey: storageKey).map { value in
            try PropertyListSerialization.data(fromPropertyList: ["value":value], format: .binary, options: 0)
        }
        try isolated { controller, preferences in
            try expect(controller.update(action: "togglePause", key: "option+space"), "Ordinary setup failed")
            let original = preferences.data(forKey: storageKey)
            try expect(controller.closeVerificationWritesAndClear(environment: environment, phase: "foreign") == nil,
                       "Ordinary instance accepted a requested verification domain")
            try expect(!controller.verificationWritesClosed && preferences.data(forKey: storageKey) == original, "Ordinary store was cleared/closed")
            try expect(!controller.resumeVerificationWritesAfterCancelledTermination(environment: environment), "Ordinary instance restored an unrelated domain")
            try expect(controller.update(action: "togglePause", key: "ctrl+space"), "Ordinary writes were blocked")
        }
        let daily = InputController()
        try expect(daily.closeVerificationWritesAndClear(environment: environment, phase: "foreign") == nil && !daily.verificationWritesClosed,
                   "Daily instance cleared an unbound verification domain")
        let afterStandard = try UserDefaults.standard.object(forKey: storageKey).map { value in
            try PropertyListSerialization.data(fromPropertyList: ["value":value], format: .binary, options: 0)
        }
        try expect(originalStandard == afterStandard, "Daily shortcut value changed")
        guard let bound = InputController(verificationEnvironment: environment) else { throw InputCheckFailure(description: "Foreign guard setup failed") }
        var other = environment; other["SILICONPLAYER_VERIFY_REPORT"]! += "-other"
        try expect(bound.closeVerificationWritesAndClear(environment: other, phase: "foreign") == nil && !bound.verificationWritesClosed,
                   "Bound instance accepted another report identity")
        try expect(!InputController.clearVerificationPreferences(environment: environment), "Static fallback cleared a domain not bound to shared")
    }

    @MainActor
    private static func failedTerminationRollback() throws {
        let environment = ["SILICONPLAYER_VERIFY_REPORT":"/private/tmp/input-failed-rollback-\(UUID().uuidString)/report.json",
                           "SILICONPLAYER_VERIFY_STORAGE":"/private/tmp/input-failed-rollback-profile"]
        let suite = try XCTSuite(environment)
        guard let actual = ControlledSynchronizeFailureDefaults(suiteName: suite),
              let controller = InputController(verificationEnvironment: environment, preferencesFactory: { requested in
                  requested == suite ? actual : nil
              }) else { throw InputCheckFailure(description: "Controlled real suite initialization failed") }
        defer { actual.removePersistentDomain(forName: suite); _ = actual.synchronize() }
        try expect(controller.update(action: "togglePause", key: "option+space"), "Rollback setup failed")
        let original = try controller.profileShortcutData()
        actual.set(Data("owned-original".utf8), forKey: "private-rollback-sentinel")
        try expect(controller.closeVerificationWritesAndClear(environment: environment, phase: "rollback-test")?.succeeded == true,
                   "Pre-fault clear failed")
        actual.rejectNextSynchronization = true
        try expect(!controller.resumeVerificationWritesAfterCancelledTermination(environment: environment), "Injected synchronization failure was accepted")
        try expect(controller.verificationWritesClosed && !controller.update(action: "togglePause", key: "ctrl+space"),
                   "Failed rollback reopened the write gate")
        var refused = false
        do { try controller.writeProfileShortcutData(nil) } catch { refused = true }
        try expect(refused, "Failed rollback permitted a raw transaction write")
        // The second retry must use the original retained snapshot, not the
        // currently observed domain after a failed attempt.
        actual.set(Data("owned-interference".utf8), forKey: "private-rollback-sentinel")
        try expect(controller.resumeVerificationWritesAfterCancelledTermination(environment: environment), "Exact rollback retry failed")
        try expect(!controller.verificationWritesClosed && (try controller.profileShortcutData()) == original
                   && actual.data(forKey: "private-rollback-sentinel") == Data("owned-original".utf8),
                   "Retry lost the original domain or failed exact restoration")
        try expect(controller.update(action: "togglePause", key: "ctrl+space"), "Successful retry did not reopen writes")
    }

    @MainActor
    private static func boundedTerminationDiskReads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("input-disk-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = InputController.readVerificationDomainFile(directory.appendingPathComponent("absent.plist"))
        try expect(missing.state == "absent" && missing.cleared, "Missing own file was not classified absent")
        let empty = directory.appendingPathComponent("empty.plist")
        try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0).write(to: empty)
        let clean = InputController.readVerificationDomainFile(empty)
        try expect(clean.state == "empty" && clean.cleared && clean.keyCount == 0 && clean.sha256?.count == 64,
                   "Actual empty binary plist evidence incorrect")
        let nonempty = directory.appendingPathComponent("nonempty.plist")
        try PropertyListSerialization.data(fromPropertyList: ["owned":Data("bytes".utf8)], format: .binary, options: 0).write(to: nonempty)
        let dirty = InputController.readVerificationDomainFile(nonempty)
        try expect(dirty.state == "nonempty" && !dirty.cleared && dirty.keyCount == 1, "Actual nonempty plist accepted")
        let link = directory.appendingPathComponent("symlink.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: empty)
        try expect(!InputController.readVerificationDomainFile(link).cleared, "Symlink was followed")
        let fifo = directory.appendingPathComponent("fifo.plist")
        try expect(mkfifo(fifo.path, 0o600) == 0, "Owned FIFO creation failed")
        let start = ProcessInfo.processInfo.systemUptime
        let special = InputController.readVerificationDomainFile(fifo)
        try expect(special.state == "nonregular" && !special.cleared && ProcessInfo.processInfo.systemUptime - start < 1,
                   "FIFO read blocked or was accepted")
        try expect(InputController.readVerificationDomainFile(directory).state == "nonregular", "Directory accepted as a preference file")
        let malformed = directory.appendingPathComponent("invalid.plist")
        try Data("{malformed".utf8).write(to: malformed)
        try expect(InputController.readVerificationDomainFile(malformed).state == "invalid", "Malformed domain accepted")
        let oversize = directory.appendingPathComponent("oversize.plist")
        try Data().write(to: oversize)
        let handle = try FileHandle(forWritingTo: oversize)
        try handle.truncate(atOffset: 2 * 1024 * 1024 + 1); try handle.close()
        try expect(InputController.readVerificationDomainFile(oversize).state == "oversize", "Oversize domain accepted")
    }

    @MainActor
    private static func backupValidation() throws {
        try isolated { controller, preferences in
            try expect(controller.update(action: "togglePause", key: "option+space"), "Setup failed")
            let original = preferences.data(forKey: storageKey), bindings = controller.bindings
            let invalid: [[(action: String, key: String)]] = [
                [("unknown", "x")], [("togglePause", "cmd+shift+u")],
                [("togglePause", "left")], [("togglePause", "space"), ("togglePause", "x")],
                [("togglePause", "cmd++x")]
            ]
            for values in invalid {
                var rejected = false
                do { _ = try controller.encodedBackupShortcuts(values) } catch { rejected = true }
                try expect(rejected, "Invalid whole backup accepted")
                try expect(preferences.data(forKey: storageKey) == original && controller.bindings == bindings, "Rejected backup mutated data")
            }
            let encoded = try controller.encodedBackupShortcuts([("togglePause", "OPTION+SPACE")])
            let decoded = try JSONDecoder().decode([ShortcutBinding].self, from: encoded)
            try expect(decoded.count == InputController.defaults.count && decoded.first?.key == "option+space", "Backup normalization/default merge failed")
            try expect(preferences.data(forKey: storageKey) == original, "Encoding wrote preferences")
        }
    }

    @MainActor
    private static func backupStorage() throws {
        try isolated { controller, preferences in
            let encoded = try controller.encodedBackupShortcuts([("togglePause", "option+space")])
            try controller.writeProfileShortcutData(encoded)
            try expect(try controller.profileShortcutData() == encoded, "Transaction bytes differ")
            try expect(controller.bindings == InputController.defaults, "Transaction updated runtime before commit")
            controller.reloadProfileShortcuts()
            try expect(controller.bindings.first?.key == "option+space", "Committed shortcuts did not reload")
            let broken = Data("{broken legacy json".utf8)
            try controller.writeProfileShortcutData(broken)
            controller.reloadProfileShortcuts()
            try expect(controller.bindings == InputController.defaults && preferences.data(forKey: storageKey) == broken, "Malformed original bytes were not preserved")
            try controller.writeProfileShortcutData(encoded)
            controller.reloadProfileShortcuts()
            let before = try controller.profileShortcutData()
            var rejected = false
            do { try controller.writeProfileShortcutData(Data(repeating: 65, count: 1024 * 1024 + 1)) } catch { rejected = true }
            try expect(rejected && (try controller.profileShortcutData()) == before, "Oversize write changed existing bytes")
            let originalBindings = controller.bindings
            controller.editingBlocked = true
            try expect(!controller.update(action: "togglePause", key: "option+p"), "Recovery block permitted an edit")
            controller.restoreDefaults()
            try expect(controller.bindings == originalBindings && (try controller.profileShortcutData()) == before,
                "Recovery block changed bindings or saved bytes")
            // Transaction rollback still needs its private storage adapter.
            try controller.writeProfileShortcutData(broken)
            try expect(try controller.profileShortcutData() == broken, "Recovery block prevented original-byte rollback")
            controller.editingBlocked = false
            try controller.writeProfileShortcutData(nil)
            controller.reloadProfileShortcuts()
            try expect(preferences.data(forKey: storageKey) == nil && controller.bindings == InputController.defaults, "Original absent value did not restore")
        }
    }

    @MainActor
    private static func isolated(_ body: (InputController, UserDefaults) throws -> Void) throws {
        let name = "SiliconPlayer.InputChecks.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: name) else {
            throw InputCheckFailure(description: "Cannot create isolated test preferences")
        }
        defer { preferences.removePersistentDomain(forName: name) }
        try body(InputController(preferences: preferences), preferences)
    }

    @MainActor
    private static func key(_ action: String, in controller: InputController) -> String? {
        controller.bindings.first { $0.action == action }?.key
    }

    private static func event(_ code: UInt16, flags: NSEvent.ModifierFlags = [], characters: String = "", type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          characters: characters, charactersIgnoringModifiers: characters,
                                          isARepeat: false, keyCode: code) else {
            throw InputCheckFailure(description: "Cannot construct NSEvent for keyCode \(code)")
        }
        return event
    }

    @MainActor
    private static func normalization() throws {
        try isolated { controller, _ in
            try expect(controller.bindings == InputController.defaults, "Fresh preferences changed defaults")
            try expect(Set(controller.bindings.map(\.id)).count == controller.bindings.count, "Duplicate default actions")
            try expect(Set(controller.bindings.map(\.key)).count == controller.bindings.count, "Duplicate default keys")
            try expect(controller.bindings.allSatisfy { !$0.key.isEmpty && !$0.title.isEmpty && $0.id == $0.action }, "Invalid default metadata")
        }
        let cases: [(String, String)] = [
            (" OPTION + command + SHIFT + B ", "cmd+option+shift+b"),
            ("shift+←", "shift+left"), ("alt+pgdn", "option+pagedown"),
            ("command + ,", "cmd+,"), ("Control+COMMAND+F", "cmd+ctrl+f"),
            ("⌘+⌃+⌥+⇧+b", "cmd+ctrl+option+shift+b"),
            ("空格键", "space"), ("backspace", "delete"), ("enter", "return"),
            ("=", "equal"), ("/", "slash"), ("plus", "plus"), ("  ", "")
        ]
        for (raw, expected) in cases {
            try expect(InputController.normalize(raw) == expected, "Wrong normalization: \(raw)")
        }
        for key in ["home", "end", "forwarddelete", "tab", "return", "escape", "backslash", "semicolon", "quote", "grave"] + (1...12).map({ "f\($0)" }) {
            try expect(InputController.normalize(key) == key, "Known key rejected: \(key)")
        }
        for raw in ["ctrl+ctrl+b", "cmd++b", "cmd+unknown", "b+cmd", "shift+", "+", "fn+b", "f13", "你好", "é", "😀"] {
            try expect(InputController.normalize(raw) == nil, "Invalid syntax accepted: \(raw)")
        }
    }

    @MainActor
    private static func defaultRouting() throws {
        struct Route {
            let action: String
            let code: UInt16
            var flags: NSEvent.ModifierFlags = []
            var characters = ""
            let call: String?
        }
        let routes: [Route] = [
            .init(action: "togglePause", code: 49, call: "pause"),
            .init(action: "stop", code: 9, characters: "v", call: "stop"),
            .init(action: "revertSeek", code: 51, flags: .shift, call: "revert"),
            .init(action: "keyframeBackward", code: 123, flags: .control, call: "keyframe:-5.0"),
            .init(action: "keyframeForward", code: 124, flags: .control, call: "keyframe:5.0"),
            .init(action: "seekBackward", code: 123, call: "jump:-5.0"),
            .init(action: "seekForward", code: 124, call: "jump:5.0"),
            .init(action: "seekBackwardLarge", code: 123, flags: .shift, call: "jump:-30.0"),
            .init(action: "seekForwardLarge", code: 124, flags: .shift, call: "jump:30.0"),
            .init(action: "volumeUp", code: 126, call: "volume:85.0"),
            .init(action: "volumeDown", code: 125, call: "volume:75.0"),
            .init(action: "fullscreen", code: 3, characters: "f", call: nil),
            .init(action: "mute", code: 46, characters: "m", call: "mute"),
            .init(action: "speedDown", code: 33, call: "speed:0.75"),
            .init(action: "speedUp", code: 30, call: "speed:1.25"),
            .init(action: "holdSpeed", code: 17, characters: "t", call: "hold-speed:17"),
            .init(action: "frameForward", code: 47, call: "frame-forward"),
            .init(action: "frameBackward", code: 43, call: "frame-back"),
            .init(action: "abLoop", code: 0, characters: "a", call: "ab"),
            .init(action: "screenshot", code: 1, characters: "s", call: "screenshot"),
            .init(action: "next", code: 45, characters: "n", call: "next"),
            .init(action: "previous", code: 35, characters: "p", call: "previous"),
            .init(action: "chapterPrevious", code: 116, call: "chapter:-1"),
            .init(action: "chapterNext", code: 121, call: "chapter:1"),
            .init(action: "bookmark", code: 11, characters: "b", call: "bookmark"),
            .init(action: "advanced", code: 35, flags: .option, characters: "p", call: "advanced"),
            .init(action: "mini", code: 46, flags: .option, characters: "m", call: "mini"),
            .init(action: "library", code: 4, flags: .option, characters: "h", call: "library")
        ]
        try expect(Set(routes.map(\.action)) == Set(InputController.defaults.map(\.action)), "Every default action needs an event route check")
        try isolated { controller, _ in
            let player = PlayerModel()
            for route in routes {
                player.calls = []
                try expect(controller.handle(try event(route.code, flags: route.flags, characters: route.characters), player: player), "Event not consumed: \(route.action)")
                try expect(player.calls == route.call.map({ [$0] }) ?? [], "Wrong route for \(route.action): \(player.calls)")
            }
            player.calls = []
            for ignored in [try event(49, type: .keyUp), try event(65535), try event(7, characters: "x"), try event(7, characters: "é")] {
                try expect(!controller.handle(ignored, player: player), "Unmapped/non-keyDown event consumed")
            }
            try expect(player.calls.isEmpty, "Ignored event invoked a player action")
        }
    }

    @MainActor
    private static func reservedShortcuts() throws {
        let reserved = [
            "cmd+o", "cmd+shift+o", "cmd+u", "cmd+shift+s", "cmd+s", "cmd+l", "cmd+i", "cmd+,",
            "cmd+g", "cmd+b", "cmd+shift+b", "cmd+shift+p", "cmd+q", "cmd+w", "cmd+h",
            "cmd+option+h", "cmd+m", "cmd+z", "cmd+shift+z", "cmd+x", "cmd+c", "cmd+v", "cmd+a", "cmd+f",
            "cmd+ctrl+f", "ctrl+cmd+f"
        ]
        try isolated { controller, preferences in
            let before = controller.bindings
            for combination in reserved {
                try expect(!controller.update(action: "bookmark", key: combination), "Reserved key accepted: \(combination)")
                try expect(controller.error != nil, "Missing reserved-key diagnostic")
                try expect(controller.bindings == before, "Reserved edit changed a binding")
            }
            try expect(preferences.data(forKey: storageKey) == nil, "Rejected edits wrote preferences")
            let player = PlayerModel()
            for blocked in [try event(3, flags: [.control, .command], characters: "f"), try event(43, flags: .command), try event(1, flags: .command, characters: "s")] {
                try expect(!controller.handle(blocked, player: player), "Reserved NSEvent consumed")
            }
            try expect(player.calls.isEmpty, "Reserved event invoked player action")
        }
    }

    @MainActor
    private static func rejectedEdits() throws {
        try isolated { controller, preferences in
            try expect(controller.update(action: "bookmark", key: "option+k"), "Cannot set valid test key")
            let before = controller.bindings
            let data = preferences.data(forKey: storageKey)
            try expect(!controller.update(action: "bookmark", key: "s"), "Duplicate screenshot key accepted")
            try expect(controller.error?.contains("截图") == true, "Conflict did not identify the existing action")
            for (action, key) in [("unknown", "k"), ("bookmark", "cmd++b"), ("bookmark", "f13")] {
                try expect(!controller.update(action: action, key: key), "Invalid edit accepted")
                try expect(controller.error != nil, "Missing invalid-edit diagnostic")
            }
            try expect(controller.bindings == before, "Rejected edit changed a binding")
            try expect(preferences.data(forKey: storageKey) == data, "Rejected edit replaced saved data")
        }
    }

    @MainActor
    private static func persistenceAndUnbinding() throws {
        try isolated { controller, preferences in
            try expect(controller.update(action: "bookmark", key: "option+command+k"), "Custom combination rejected")
            try expect(controller.error == nil && key("bookmark", in: controller) == "cmd+option+k", "Custom combination not canonical")
            let reloaded = InputController(preferences: preferences)
            try expect(key("bookmark", in: reloaded) == "cmd+option+k", "Custom mapping did not persist")
            let player = PlayerModel()
            let combination = try event(40, flags: [.command, .option], characters: "k")
            try expect(reloaded.handle(combination, player: player) && player.calls == ["bookmark"], "Custom modifiers routed incorrectly")
            player.calls = []
            try expect(!reloaded.handle(try event(40, flags: .command, characters: "k"), player: player), "Partial modifiers unexpectedly matched")
            try expect(reloaded.update(action: "bookmark", key: "   "), "Blank unbinding rejected")
            try expect(key("bookmark", in: InputController(preferences: preferences)) == "", "Unbinding did not persist")
            try expect(!reloaded.handle(combination, player: player) && player.calls.isEmpty, "Unbound key still invoked action")
            for (name, code, flags, characters) in [("f12", UInt16(111), NSEvent.ModifierFlags(), ""), ("plus", 69, [], "+"), ("shift+equal", 24, .shift, "=")] {
                try expect(reloaded.update(action: "bookmark", key: name), "Special key assignment rejected: \(name)")
                player.calls = []
                try expect(reloaded.handle(try event(code, flags: flags, characters: characters), player: player), "Special key event did not match: \(name)")
                try expect(player.calls == ["bookmark"], "Special key routed incorrectly")
            }
        }
    }

    @MainActor
    private static func restoration() throws {
        try isolated { controller, preferences in
            try expect(controller.update(action: "stop", key: "option+v"), "Cannot customize stop")
            try expect(controller.update(action: "screenshot", key: ""), "Cannot unbind screenshot")
            try expect(!controller.update(action: "bookmark", key: "cmd+ctrl+f"), "System fullscreen protection failed")
            controller.restoreDefaults()
            try expect(controller.error == nil, "Reset retained old error")
            try expect(controller.bindings == InputController.defaults, "Reset did not restore all defaults")
            try expect(InputController(preferences: preferences).bindings == InputController.defaults, "Reset did not persist")
        }
    }

    @MainActor
    private static func migration() throws {
        try isolated { _, preferences in
            let saved = [
                ShortcutBinding(action: "bookmark", title: "Old title", key: "option+k"),
                ShortcutBinding(action: "togglePause", title: "Old pause", key: "return"),
                ShortcutBinding(action: "unknownAction", title: "Ignored", key: "option+q"),
                ShortcutBinding(action: "bookmark", title: "Duplicate", key: "option+j")
            ]
            preferences.set(try JSONEncoder().encode(saved), forKey: storageKey)
            let upgraded = InputController(preferences: preferences)
            try expect(upgraded.bindings.count == InputController.defaults.count, "Upgrade lost or invented actions")
            try expect(key("bookmark", in: upgraded) == "option+k" && key("togglePause", in: upgraded) == "return", "Upgrade lost custom keys or changed first-record precedence")
            try expect(upgraded.bindings.first(where: { $0.action == "bookmark" })?.title == InputController.defaults.first(where: { $0.action == "bookmark" })?.title, "Persisted title replaced current action metadata")
            for action in ["stop", "revertSeek", "keyframeBackward", "keyframeForward"] {
                try expect(key(action, in: upgraded) == InputController.defaults.first(where: { $0.action == action })?.key, "New action lost its default: \(action)")
            }
            preferences.set(try JSONEncoder().encode([
                ShortcutBinding(action: "togglePause", title: "Pause", key: "v"),
                ShortcutBinding(action: "seekForward", title: "Forward", key: "left")
            ]), forKey: storageKey)
            let duplicate = InputController(preferences: preferences)
            try expect(key("togglePause", in: duplicate) == "v" && key("stop", in: duplicate) == "", "New default stole an existing customized shortcut")
            try expect(key("seekBackward", in: duplicate) == "left" && key("seekForward", in: duplicate) == "right", "Duplicate stored key did not fall back safely")
            let assigned = duplicate.bindings.map(\.key).filter { !$0.isEmpty }
            try expect(Set(assigned).count == assigned.count, "Upgrade produced duplicate active keys")
            duplicate.restoreDefaults()
            try expect(key("stop", in: duplicate) == "v", "Reset did not recover a migrated unbound default")
            preferences.set(try JSONEncoder().encode([
                ShortcutBinding(action: "bookmark", title: "Existing T", key: "t")
            ]), forKey: storageKey)
            let oldT = InputController(preferences: preferences)
            try expect(key("bookmark", in: oldT) == "t" && key("holdSpeed", in: oldT) == "", "New hold default stole an existing customized T")
            let backup = try JSONDecoder().decode([ShortcutBinding].self,
                from: oldT.encodedBackupShortcuts([(action: "bookmark", key: "t")]))
            try expect(backup.first(where: { $0.action == "bookmark" })?.key == "t"
                && backup.first(where: { $0.action == "holdSpeed" })?.key == "", "Implicit new T default broke older backup")
            do {
                _ = try oldT.encodedBackupShortcuts([(action: "bookmark", key: "t"), (action: "holdSpeed", key: "t")])
                throw InputCheckFailure(description: "Explicit hold conflict accepted")
            } catch is InputCheckFailure { throw InputCheckFailure(description: "Explicit hold conflict accepted") }
            catch { /* Original duplicate-key rejection remains required. */ }
        }
    }

    @MainActor
    private static func invalidPreferences() throws {
        try isolated { _, preferences in
            for bytes in [Data("garbage".utf8), Data("{}".utf8), Data("[{\"action\":\"bookmark\",\"title\":\"bad\",\"key\":12}]".utf8)] {
                preferences.set(bytes, forKey: storageKey)
                try expect(InputController(preferences: preferences).bindings == InputController.defaults, "Malformed preferences changed defaults")
            }
            let saved = [
                ShortcutBinding(action: "bookmark", title: "Bad", key: "ctrl+cmd+f"),
                ShortcutBinding(action: "stop", title: "Bad", key: "ctrl+ctrl+v")
            ]
            preferences.set(try JSONEncoder().encode(saved), forKey: storageKey)
            let fallback = InputController(preferences: preferences)
            try expect(key("bookmark", in: fallback) == "b" && key("stop", in: fallback) == "v", "Invalid/reserved stored keys did not restore defaults")
        }
    }
}
