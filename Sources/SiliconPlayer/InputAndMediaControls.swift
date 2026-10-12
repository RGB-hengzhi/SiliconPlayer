import AppKit
import Combine
import MediaPlayer
import CryptoKit
import Darwin

struct ShortcutBinding: Identifiable, Codable, Equatable {
    let action: String
    let title: String
    var key: String
    var id: String { action }
}

@MainActor
final class InputController: ObservableObject {
    static let shared: InputController = {
        guard verificationSuiteName(environment: ProcessInfo.processInfo.environment) != nil else {
            return InputController()
        }
        guard let controller = InputController(verificationEnvironment: ProcessInfo.processInfo.environment) else {
            preconditionFailure("Unable to create isolated verification preferences")
        }
        return controller
    }()
    @Published private(set) var bindings: [ShortcutBinding]
    @Published private(set) var error: String?
    var editingBlocked = false
    private let preferences: UserDefaults
    private let verificationSuite: String?
    private let preferencesIdentity: ObjectIdentifier
    private var terminationOriginalDomain: [String: Any]?
    private var terminationInvocation = 0
    private(set) var verificationWritesClosed = false
    private static let storageKey = "SiliconPlayer.shortcuts.v1"

    struct VerificationTerminationCleanup: Codable {
        let suite: String
        let phase: String
        let beforeKeys: [String]
        let afterKeys: [String]
        let sameBoundInstance: Bool
        let writesClosed: Bool
        let synchronizeSucceeded: Bool
        let memoryDomainEmpty: Bool
        let succeeded: Bool
        let invocation: Int
        let startedUptime: Double
        let finishedUptime: Double
    }

    struct VerificationDomainDiskSnapshot: Codable {
        let state: String
        let cleared: Bool
        let bytes: Int?
        let sha256: String?
        let keyCount: Int?
        let error: String?
    }

    struct VerificationTerminationDiskBarrier: Codable {
        let domainPlist: String
        let before: VerificationDomainDiskSnapshot
        let after: VerificationDomainDiskSnapshot
        let diskDomainEmpty: Bool
        let timeoutSeconds: Double
        let waitDurationSeconds: Double
        let pollCount: Int
        let startedUptime: Double
        let finishedUptime: Double
    }

    /// A real-app verifier must not restore shortcut backups into daily settings.
    /// Both explicit verification paths are required; normal launches use standard.
    static func verificationSuiteName(environment: [String: String]) -> String? {
        guard let report = environment["SILICONPLAYER_VERIFY_REPORT"],
              let storage = environment["SILICONPLAYER_VERIFY_STORAGE"],
              [report, storage].allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 8192
                  && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { return nil }
        let value = Data((report + "\u{0}" + storage).utf8)
        let digest = SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
        return "local.siliconplayer.verification." + digest
    }
    @discardableResult
    static func clearVerificationPreferences(environment: [String: String]) -> Bool {
        guard verificationSuiteName(environment: environment) != nil,
              let result = shared.closeVerificationWritesAndClear(environment: environment, phase: "willTerminate-fallback") else { return false }
        return result.succeeded
    }

    /// Only the instance constructed for this exact verification environment
    /// owns this domain. Ordinary/daily instances never clear a requested suite.
    func closeVerificationWritesAndClear(environment: [String: String], phase: String) -> VerificationTerminationCleanup? {
        guard let suite = verificationSuite, suite == Self.verificationSuiteName(environment: environment) else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        let before = preferences.persistentDomain(forName: suite) ?? [:]
        if !verificationWritesClosed { terminationOriginalDomain = before }
        verificationWritesClosed = true
        terminationInvocation += 1
        preferences.removeObject(forKey: Self.storageKey)
        preferences.removePersistentDomain(forName: suite)
        let synchronized = preferences.synchronize()
        let after = preferences.persistentDomain(forName: suite) ?? [:]
        let sameInstance = ObjectIdentifier(preferences) == preferencesIdentity
        return VerificationTerminationCleanup(suite: suite, phase: phase,
            beforeKeys: before.keys.sorted(), afterKeys: after.keys.sorted(), sameBoundInstance: sameInstance,
            writesClosed: verificationWritesClosed, synchronizeSucceeded: synchronized, memoryDomainEmpty: after.isEmpty,
            succeeded: synchronized && after.isEmpty && sameInstance, invocation: terminationInvocation,
            startedUptime: started, finishedUptime: ProcessInfo.processInfo.systemUptime)
    }

    /// A failed cleanup/sidecar must cancel that exit attempt. Restore only
    /// this bound private domain and reopen its write gate, never daily data.
    @discardableResult
    func resumeVerificationWritesAfterCancelledTermination(environment: [String: String]) -> Bool {
        guard let suite = verificationSuite, suite == Self.verificationSuiteName(environment: environment),
              verificationWritesClosed else { return false }
        let original = terminationOriginalDomain ?? [:]
        preferences.setPersistentDomain(original, forName: suite)
        let synchronized = preferences.synchronize()
        let restored = preferences.persistentDomain(forName: suite) ?? [:]
        guard synchronized, NSDictionary(dictionary: restored).isEqual(to: original) else {
            // Retain the original bytes and the closed gate for a later retry.
            return false
        }
        verificationWritesClosed = false
        terminationOriginalDomain = nil
        return true
    }

    /// Preference synchronization confirms the service view, not that its
    /// plist has already been flushed. Only explicit verification sessions
    /// wait for their own on-disk domain before allowing termination.
    func awaitVerificationDomainDiskClear(environment: [String: String]) async -> VerificationTerminationDiskBarrier? {
        guard let suite = verificationSuite, suite == Self.verificationSuiteName(environment: environment),
              verificationWritesClosed else { return nil }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
            .appendingPathComponent(suite + ".plist")
        let started = ProcessInfo.processInfo.systemUptime
        let timeout = 15.0
        let before = Self.readVerificationDomainFile(path)
        var after = before, count = 1
        while !after.cleared, ProcessInfo.processInfo.systemUptime - started < timeout {
            // Never block AppKit's main RunLoop while waiting for the service.
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch { break }
            guard verificationWritesClosed else { break }
            after = Self.readVerificationDomainFile(path); count += 1
        }
        let finished = ProcessInfo.processInfo.systemUptime
        return VerificationTerminationDiskBarrier(domainPlist: path.path, before: before, after: after,
            diskDomainEmpty: after.cleared && verificationWritesClosed, timeoutSeconds: timeout,
            waitDurationSeconds: finished - started, pollCount: count, startedUptime: started, finishedUptime: finished)
    }

    /// O_NOFOLLOW + a single descriptor's fstat prevent symlink/FIFO/device
    /// reads. This reads at most 2 MiB and never edits or deletes a plist.
    static func readVerificationDomainFile(_ path: URL) -> VerificationDomainDiskSnapshot {
        func rejected(_ state: String, _ reason: String, bytes: Int? = nil) -> VerificationDomainDiskSnapshot {
            VerificationDomainDiskSnapshot(state: state, cleared: false, bytes: bytes, sha256: nil, keyCount: nil, error: reason)
        }
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return .init(state: "absent", cleared: true, bytes: nil, sha256: nil, keyCount: nil, error: nil) }
            return rejected("unreadable", "open errno \(errno)")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return rejected("unreadable", "fstat errno \(errno)") }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return rejected("nonregular", "Not a regular file") }
        let limit = 2 * 1024 * 1024
        guard info.st_size >= 0, info.st_size <= limit else { return rejected("oversize", "Private domain exceeds read bound") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let amount = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if amount < 0 { if errno == EINTR { continue }; return rejected("unreadable", "read errno \(errno)", bytes: data.count) }
            if amount == 0 { break }
            guard data.count + amount <= limit else { return rejected("oversize", "Private domain grew beyond read bound") }
            data.append(contentsOf: buffer.prefix(amount))
        }
        guard let domain = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return rejected("invalid", "Private domain is not a property-list dictionary", bytes: data.count)
        }
        return .init(state: domain.isEmpty ? "empty" : "nonempty", cleared: domain.isEmpty, bytes: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), keyCount: domain.count, error: nil)
    }

    static let defaults: [ShortcutBinding] = [
        .init(action: "togglePause", title: "播放 / 暂停", key: "space"),
        .init(action: "stop", title: "停止并清空画面", key: "v"),
        .init(action: "revertSeek", title: "撤销 / 恢复上次跳转", key: "shift+delete"),
        .init(action: "keyframeBackward", title: "按关键帧后退 5 秒", key: "ctrl+left"),
        .init(action: "keyframeForward", title: "按关键帧快进 5 秒", key: "ctrl+right"),
        .init(action: "seekBackward", title: "后退 5 秒", key: "left"),
        .init(action: "seekForward", title: "快进 5 秒", key: "right"),
        .init(action: "seekBackwardLarge", title: "后退 30 秒", key: "shift+left"),
        .init(action: "seekForwardLarge", title: "快进 30 秒", key: "shift+right"),
        .init(action: "volumeUp", title: "增加音量", key: "up"),
        .init(action: "volumeDown", title: "降低音量", key: "down"),
        .init(action: "fullscreen", title: "切换全屏", key: "f"),
        .init(action: "mute", title: "静音 / 取消静音", key: "m"),
        .init(action: "speedDown", title: "降低播放速度", key: "["),
        .init(action: "speedUp", title: "提高播放速度", key: "]"),
        .init(action: "frameForward", title: "向前逐帧", key: "."),
        .init(action: "frameBackward", title: "向后逐帧", key: ","),
        .init(action: "abLoop", title: "设置 A / B / 清除循环", key: "a"),
        .init(action: "screenshot", title: "截图", key: "s"),
        .init(action: "next", title: "下一项", key: "n"),
        .init(action: "previous", title: "上一项", key: "p"),
        .init(action: "chapterPrevious", title: "上一章节", key: "pageup"),
        .init(action: "chapterNext", title: "下一章节", key: "pagedown"),
        .init(action: "bookmark", title: "添加当前位置书签", key: "b"),
        .init(action: "advanced", title: "高级播放设置", key: "option+p"),
        .init(action: "mini", title: "切换迷你窗口", key: "option+m"),
        .init(action: "library", title: "播放历史与书签", key: "option+h"),
        .init(action: "holdSpeed", title: "按住临时加速（2 倍，最高 4×）", key: "t")
    ]

    /// Menu equivalents and standard macOS editing commands belong to AppKit.
    private static let reserved = Set([
        "cmd+o", "cmd+shift+o", "cmd+u", "cmd+shift+u", "cmd+shift+s", "cmd+s", "cmd+l", "cmd+i", "cmd+,",
        "cmd+g", "cmd+b", "cmd+shift+b", "cmd+shift+p",
        "cmd+q", "cmd+w", "cmd+h", "cmd+option+h", "cmd+m", "cmd+z", "cmd+shift+z",
        "cmd+x", "cmd+c", "cmd+v", "cmd+a", "cmd+f", "cmd+ctrl+f"
    ])
    private static let specialKeys = Set([
        "space", "left", "right", "up", "down", "pageup", "pagedown", "home", "end",
        "tab", "return", "escape", "delete", "forwarddelete", "plus", "minus", "equal", "slash", "backslash",
        "semicolon", "quote", "grave"
    ] + (1...12).map { "f\($0)" })
    private static let aliases = [
        "command": "cmd", "⌘": "cmd", "alt": "option", "opt": "option", "⌥": "option",
        "control": "ctrl", "ctl": "ctrl", "⌃": "ctrl", "⇧": "shift", "spacebar": "space",
        "空格": "space", "空格键": "space", "←": "left", "→": "right", "↑": "up", "↓": "down",
        "enter": "return", "esc": "escape", "pgup": "pageup", "pgdn": "pagedown",
        "page-up": "pageup", "page-down": "pagedown", "backspace": "delete", "del": "delete",
        "=": "equal", "-": "minus", "/": "slash", "\\": "backslash", ";": "semicolon", "'": "quote", "`": "grave"
    ]

    convenience init(preferences: UserDefaults = .standard) {
        self.init(preferences: preferences, verificationSuite: nil)
    }

    convenience init?(verificationEnvironment environment: [String: String],
                      preferencesFactory: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }) {
        guard let suite = Self.verificationSuiteName(environment: environment),
              let preferences = preferencesFactory(suite) else { return nil }
        self.init(preferences: preferences, verificationSuite: suite)
    }

    private init(preferences: UserDefaults, verificationSuite: String?) {
        self.preferences = preferences
        self.verificationSuite = verificationSuite
        preferencesIdentity = ObjectIdentifier(preferences)
        bindings = Self.defaults
        guard let data = preferences.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode([ShortcutBinding].self, from: data) else { return }
        // Merge by action so new commands retain defaults after an upgrade.
        var used = Set<String>()
        var storedByAction = [String: String]()
        for binding in stored where Self.defaults.contains(where: { $0.action == binding.action }) {
            if storedByAction[binding.action] == nil { storedByAction[binding.action] = binding.key }
        }
        bindings = Self.defaults.map { original in
            var result = original
            let candidate = storedByAction[original.action] ?? original.key
            if let key = Self.normalize(candidate), !Self.reserved.contains(key), key.isEmpty || used.insert(key).inserted {
                result.key = key
            } else {
                // An invalid stored shortcut must not silently steal another command.
                result.key = used.insert(original.key).inserted ? original.key : ""
            }
            return result
        }
    }

    /// Canonical syntax: cmd+ctrl+option+shift+key. Empty text unbinds an action.
    static func normalize(_ input: String) -> String? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.isEmpty { return "" }
        let parts = raw.split(separator: "+", omittingEmptySubsequences: false).map {
            let text = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return aliases[text] ?? text
        }
        guard !parts.contains(where: { $0.isEmpty }), let key = parts.last else { return nil }
        let modifiers = Array(parts.dropLast())
        let allowedModifiers = ["cmd", "ctrl", "option", "shift"]
        guard modifiers.allSatisfy(allowedModifiers.contains), Set(modifiers).count == modifiers.count else { return nil }
        let plainKeys = "abcdefghijklmnopqrstuvwxyz0123456789[],."
        guard specialKeys.contains(key) || (key.count == 1 && plainKeys.contains(key)) else { return nil }
        return (allowedModifiers.filter(modifiers.contains) + [key]).joined(separator: "+")
    }

    @discardableResult
    func update(action: String, key: String) -> Bool {
        guard !verificationWritesClosed else { error = "验证会话正在退出，不能继续保存快捷键。"; return false }
        guard !editingBlocked else { error = "设置恢复尚未完成，暂不能保存快捷键。"; return false }
        error = nil
        guard let index = bindings.firstIndex(where: { $0.action == action }) else {
            error = "未知的快捷键操作。"; return false
        }
        guard let normalized = Self.normalize(key) else {
            error = "组合格式无效。请使用例如 space、shift+left 或 option+b。"; return false
        }
        guard !Self.reserved.contains(normalized) else {
            error = "这个组合已由系统或播放器菜单使用，请选择另一个组合。"; return false
        }
        if !normalized.isEmpty, let conflict = bindings.first(where: { $0.action != action && $0.key == normalized }) {
            error = "这个组合已分配给“\(conflict.title)”。请先修改或清空该操作。"; return false
        }
        bindings[index].key = normalized
        save()
        return error == nil
    }

    func restoreDefaults() {
        guard !verificationWritesClosed else { error = "验证会话正在退出，不能继续保存快捷键。"; return }
        guard !editingBlocked else { error = "设置恢复尚未完成，暂不能保存快捷键。"; return }
        bindings = Self.defaults
        error = nil
        save()
    }

    static func validateBackupShortcut(action: String, key: String) throws -> String {
        guard defaults.contains(where: { $0.action == action }),
              let normalized = normalize(key), !reserved.contains(normalized) else {
            throw NSError(domain: "SiliconPlayer.ShortcutBackup", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "备份包含未知操作、无效快捷键或系统保留组合。"])
        }
        return normalized
    }

    /// Pure validation/encoding. New actions retain their defaults when reading
    /// an older backup; conflicts are rejected before preferences are touched.
    func encodedBackupShortcuts(_ values: [(action: String, key: String)]) throws -> Data {
        guard values.count <= 256, Set(values.map(\.action)).count == values.count else {
            throw NSError(domain: "SiliconPlayer.ShortcutBackup", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "备份包含重复快捷键操作。"])
        }
        var changes: [String: String] = [:]
        for value in values { changes[value.action] = try Self.validateBackupShortcut(action: value.action, key: value.key) }
        var candidate = Self.defaults
        var used = Set<String>()
        for index in candidate.indices {
            candidate[index].key = changes[candidate[index].action] ?? candidate[index].key
            // An older backup may legitimately use T for an existing action.
            // Only the new implicit hold default yields; explicit conflicts
            // remain errors and no pre-existing shortcut is replaced.
            if candidate[index].action == "holdSpeed", changes["holdSpeed"] == nil,
               used.contains(candidate[index].key) { candidate[index].key = "" }
            guard candidate[index].key.isEmpty || used.insert(candidate[index].key).inserted else {
                throw NSError(domain: "SiliconPlayer.ShortcutBackup", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "备份中的快捷键与另一操作冲突。"])
            }
        }
        return try JSONEncoder().encode(candidate)
    }

    func profileShortcutData() throws -> Data? {
        let data = preferences.data(forKey: Self.storageKey)
        guard (data?.count ?? 0) <= 1024 * 1024 else {
            throw NSError(domain: "SiliconPlayer.ShortcutBackup", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "现有快捷键数据超出备份大小上限。"])
        }
        return data
    }

    /// The multi-store coordinator may also write the original malformed bytes
    /// during rollback. Bindings are reloaded only after that transaction ends.
    func writeProfileShortcutData(_ data: Data?) throws {
        guard !verificationWritesClosed else {
            throw NSError(domain: "SiliconPlayer.ShortcutBackup", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "验证会话正在退出，快捷键存储已关闭。"])
        }
        guard (data?.count ?? 0) <= 1024 * 1024 else {
            throw NSError(domain: "SiliconPlayer.ShortcutBackup", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "快捷键数据超出大小上限。"])
        }
        if let data { preferences.set(data, forKey: Self.storageKey) }
        else { preferences.removeObject(forKey: Self.storageKey) }
        // Import/rollback is rare and requires an explicit persistence barrier.
        // This is not a claim that multiple files/UserDefaults commit atomically.
        guard preferences.synchronize(), preferences.data(forKey: Self.storageKey) == data else {
            throw NSError(domain: "SiliconPlayer.ShortcutBackup", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "快捷键偏好未能确认保存，需要恢复事务。"])
        }
    }

    func reloadProfileShortcuts() {
        bindings = InputController(preferences: preferences).bindings
        error = nil
    }

    func handle(_ event: NSEvent, player: PlayerModel) -> Bool {
        guard event.type == .keyDown, let key = Self.key(for: event), !Self.reserved.contains(key),
              let binding = bindings.first(where: { !$0.key.isEmpty && $0.key == key }) else { return false }
        switch binding.action {
        case "togglePause": player.togglePause()
        case "stop": player.stopPlayback()
        case "revertSeek": player.revertSeek()
        case "keyframeBackward": player.jumpKeyframe(-5)
        case "keyframeForward": player.jumpKeyframe(5)
        case "seekBackward": player.jump(-5)
        case "seekForward": player.jump(5)
        case "seekBackwardLarge": player.jump(-30)
        case "seekForwardLarge": player.jump(30)
        case "volumeUp": player.setVolume(player.volume + 5)
        case "volumeDown": player.setVolume(player.volume - 5)
        case "fullscreen": NSApp.keyWindow?.toggleFullScreen(nil)
        case "mute": player.toggleMute()
        case "speedDown": player.setSpeed(player.speed - 0.25)
        case "speedUp": player.setSpeed(player.speed + 0.25)
        case "holdSpeed": return player.beginTemporarySpeed(event)
        case "frameForward": player.frameStep()
        case "frameBackward": player.frameStep(backward: true)
        case "abLoop": player.cycleAB()
        case "screenshot": player.screenshot()
        case "next": player.next()
        case "previous": player.previous()
        case "chapterPrevious": player.jumpChapter(-1)
        case "chapterNext": player.jumpChapter(1)
        case "bookmark": player.addBookmark()
        case "advanced": player.showAdvanced = true
        case "mini": player.toggleMiniMode()
        case "library": player.showLibrary = true
        default: return false
        }
        return true
    }

    private func save() {
        guard !verificationWritesClosed else { error = "验证会话正在退出，不能继续保存快捷键。"; return }
        do { preferences.set(try JSONEncoder().encode(bindings), forKey: Self.storageKey) }
        catch { self.error = "无法保存快捷键：\(error.localizedDescription)" }
    }

    private static func key(for event: NSEvent) -> String? {
        let codes: [UInt16: String] = [
            49: "space", 123: "left", 124: "right", 125: "down", 126: "up", 116: "pageup", 121: "pagedown",
            115: "home", 119: "end", 48: "tab", 36: "return", 76: "return", 53: "escape", 51: "delete", 117: "forwarddelete",
            122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
            101: "f9", 109: "f10", 103: "f11", 111: "f12",
            24: "equal", 27: "minus", 44: "slash", 42: "backslash", 41: "semicolon", 39: "quote", 50: "grave",
            33: "[", 30: "]", 47: ".", 43: ",", 69: "plus", 78: "minus", 81: "equal", 75: "slash"
        ]
        let key: String
        if let mapped = codes[event.keyCode] { key = mapped }
        else if let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1 { key = characters }
        else { return nil }
        let flags = event.modifierFlags
        var modifiers = [String]()
        if flags.contains(.command) { modifiers.append("cmd") }
        if flags.contains(.control) { modifiers.append("ctrl") }
        if flags.contains(.option) { modifiers.append("option") }
        if flags.contains(.shift) { modifiers.append("shift") }
        return Self.normalize((modifiers + [key]).joined(separator: "+"))
    }
}

@MainActor
final class SystemMediaController {
    static let shared = SystemMediaController()
    private weak var player: PlayerModel?
    private var installed = false
    private var targets: [(MPRemoteCommand, Any)] = []
    private let center = MPRemoteCommandCenter.shared()

    func install(player: PlayerModel) {
        self.player = player
        guard !installed else { update(player: player); return }
        installed = true
        register(center.playCommand) { player in if player.loaded && player.paused { player.set("pause", "no") } }
        register(center.pauseCommand) { player in if player.loaded && !player.paused { player.set("pause", "yes") } }
        register(center.togglePlayPauseCommand) { $0.togglePause() }
        register(center.stopCommand) { $0.stopPlayback() }
        register(center.nextTrackCommand) { $0.next() }
        register(center.previousTrackCommand) { $0.previous() }
        let command = center.changePlaybackPositionCommand
        let target = command.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime,
                  position.isFinite, position >= 0 else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let player = self?.player, player.loaded, player.seekable else { return }
                player.seek(min(player.duration > 0 ? player.duration : position, position))
            }
            return .success
        }
        targets.append((command, target))
        update(player: player)
    }

    func update(player: PlayerModel) {
        guard installed else { return }
        let active = player.loaded
        center.playCommand.isEnabled = active
        center.pauseCommand.isEnabled = active
        center.togglePlayPauseCommand.isEnabled = active
        center.stopCommand.isEnabled = active
        center.changePlaybackPositionCommand.isEnabled = active && player.seekable
        center.nextTrackCommand.isEnabled = active && ((player.playlist.currentIndex ?? 0) < player.playlist.items.count - 1 || player.loopPlaylist)
        center.previousTrackCommand.isEnabled = active
        let info = MPNowPlayingInfoCenter.default()
        guard active else { info.nowPlayingInfo = nil; info.playbackState = .stopped; return }
        var metadata: [String: Any] = [
            MPMediaItemPropertyTitle: player.playlist.currentItem?.title ?? "SiliconPlayer",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.position.isFinite ? max(0, player.position) : 0,
            MPNowPlayingInfoPropertyPlaybackRate: player.paused ? 0 : player.speed,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: !player.seekable
        ]
        if player.duration.isFinite && player.duration > 0 { metadata[MPMediaItemPropertyPlaybackDuration] = player.duration }
        info.nowPlayingInfo = metadata
        info.playbackState = player.paused ? .paused : .playing
    }

    private func register(_ command: MPRemoteCommand, action: @escaping @MainActor (PlayerModel) -> Void) {
        let target = command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let player = self?.player else { return }
                action(player)
            }
            return .success
        }
        targets.append((command, target))
    }
}
