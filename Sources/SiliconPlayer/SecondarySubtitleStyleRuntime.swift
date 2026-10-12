import Foundation
import Darwin
import Combine
import CMPV
import PlayerCore

@MainActor
private final class MPVSecondaryStyleIO: SecondarySubtitleStylePropertyIO {
    private weak var player: PlayerModel?
    private let capturedHandle: OpaquePointer
    init?(player: PlayerModel) {
        guard let handle = player.handle, !player.liveASRCoreClosed else { return nil }
        self.player = player; capturedHandle = handle
    }
    private func core() throws -> OpaquePointer {
        guard let player, player.handle == capturedHandle, !player.liveASRCoreClosed else {
            throw SecondarySubtitleStyleFailure.contextChanged
        }
        return capturedHandle
    }
    func propertyNames() throws -> Set<String> {
        _ = try core()
        guard let names = player?.jsonProperty("property-list") as? [String], names.count <= 20_000 else {
            throw SecondarySubtitleStyleFailure.missing("property-list")
        }
        return Set(names)
    }
    func read(_ name: String) throws -> SubtitleStyleValue {
        let handle = try core()
        if name == SecondarySubtitleStyleTransaction.mode {
            var value: Int32 = 0
            guard mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 else { throw SecondarySubtitleStyleFailure.invalidValue(name) }
            return .flag(value != 0)
        }
        if ["secondary-sub-font-size", "secondary-sub-outline-size"].contains(name) {
            var value = 0.0
            guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0, value.isFinite else {
                throw SecondarySubtitleStyleFailure.invalidValue(name)
            }
            return .number(value)
        }
        guard let raw = mpv_get_property_string(handle, name) else { throw SecondarySubtitleStyleFailure.missing(name) }
        defer { mpv_free(raw) }
        guard strnlen(raw, 4097) <= 4096, let value = String(validatingUTF8: raw) else {
            throw SecondarySubtitleStyleFailure.invalidValue(name)
        }
        if ["secondary-sub-color", "secondary-sub-outline-color", "secondary-sub-back-color"].contains(name) {
            guard let color = SecondarySubtitleStyleSettings.canonicalColor(value) else { throw SecondarySubtitleStyleFailure.invalidValue(name) }
            return .string(color)
        }
        return .string(value)
    }
    func write(_ name: String, value: SubtitleStyleValue) throws {
        _ = try core()
        guard SecondarySubtitleStyleTransaction.requiredKeys.contains(name), let player else {
            throw SecondarySubtitleStyleFailure.invalidValue(name)
        }
        let text: String
        switch value { case .flag(let p): text = p ? "yes" : "no"
        case .number(let p): guard p.isFinite else { throw SecondarySubtitleStyleFailure.invalidValue(name) }; text = String(p)
        case .string(let p): text = p }
        guard player.setChecked(name, text) >= 0 else { throw SecondarySubtitleStyleFailure.write(name) }
        _ = try core()
    }
}

@MainActor
final class SecondarySubtitleStyleRuntime: ObservableObject {
    @Published private(set) var available = false
    @Published private(set) var status = "正在检查副字幕样式能力"
    @Published private(set) var needsRecovery = false
    private weak var player: PlayerModel?
    private var retainedRecovery: [String: SubtitleStyleValue]?
    private var lastBefore: [String: SubtitleStyleValue]?
    init(player: PlayerModel) { self.player = player }

    /// Called on initialization, ordinary load, restore/reset and profile adoption.
    /// Failed loaded preferences remain visible intent, never claimed applied.
    @discardableResult func apply(_ style: SecondarySubtitleStyleSettings?) -> Bool {
        guard !needsRecovery, let player, let io = MPVSecondaryStyleIO(player: player) else {
            status = needsRecovery ? "副字幕样式回滚尚未确认，请先恢复" : "播放内核尚未就绪"
            return false
        }
        let result = SecondarySubtitleStyleTransaction.apply(style, io: io)
        available = result.supported
        retainedRecovery = result.recovery; needsRecovery = result.recovery != nil
        lastBefore = result.previous
        status = result.message ?? (result.supported ? (style?.enabled == true ? "已应用独立副字幕样式" : "副字幕继承主字幕样式") : "当前内核使用共同字幕样式")
        return result.applied
    }
    func matches(_ style: SecondarySubtitleStyleSettings?) -> Bool {
        guard !needsRecovery, let player, let io = MPVSecondaryStyleIO(player: player) else { return false }
        return SecondarySubtitleStyleTransaction.matches(style, io: io)
    }
    /// UI edits publish/save only after an actual checked engine transaction.
    @discardableResult func change(_ edit: (inout SecondarySubtitleStyleSettings) -> Void) -> Bool {
        guard let player, !player.profileStoresBlocked else { return false }
        var next = player.settings.secondarySubtitleStyle ?? SecondarySubtitleStyleSettings(primary: player.settings)
        edit(&next); next = next.sanitized()
        let previousPreference = player.settings.secondarySubtitleStyle
        guard apply(next) else { player.error = status; return false }
        return commit(next, previousPreference: previousPreference)
    }
    @discardableResult func reset() -> Bool {
        guard let player, !player.profileStoresBlocked else { return false }
        // Reset all independent fields but retain explicit media-level inherit.
        let next = SecondarySubtitleStyleSettings()
        let previousPreference = player.settings.secondarySubtitleStyle
        guard apply(next) else { player.error = status; return false }
        return commit(next, previousPreference: previousPreference)
    }
    private func commit(_ value: SecondarySubtitleStyleSettings,
                        previousPreference: SecondarySubtitleStyleSettings?) -> Bool {
        guard let player else { return false }
        let before = lastBefore
        // Already applied only secondary keys. Do not reapply every primary
        // setting or audio/video option merely to publish this UI change.
        player.mediaPreferences.updateSettings { $0.secondarySubtitleStyle = value }
        player.synchronizeMediaPreferenceSettings()
        // Active playback changes are an unsaved media overlay, not global
        // defaults. The existing explicit media-save owns their publication.
        if player.mediaPreferences.isActive { return true }
        if player.persistSettingsChecked() { return true }
        player.mediaPreferences.updateSettings { $0.secondarySubtitleStyle = previousPreference }
        player.synchronizeMediaPreferenceSettings()
        let restored: Bool
        if let io = MPVSecondaryStyleIO(player: player) {
            if let before { restored = SecondarySubtitleStyleTransaction.restore(before, io: io) }
            else { restored = SecondarySubtitleStyleTransaction.matches(previousPreference, io: io) }
        } else { restored = false }
        if !restored { retainedRecovery = before; needsRecovery = true }
        status = restored ? "副字幕默认样式未保存，已恢复原设置" : "副字幕默认样式未保存，原样式回滚尚未确认"
        player.error = status
        return false
    }
    func coreClosed() {
        // Only called by the actual MPV_EVENT_SHUTDOWN path. No pending async
        // job exists here; a recovery dictionary never prevents native Quit.
        retainedRecovery = nil; lastBefore = nil; needsRecovery = false
        available = false; status = "播放内核已关闭"
    }
    func retryRecovery() {
        guard let saved = retainedRecovery, let player, let io = MPVSecondaryStyleIO(player: player) else { return }
        guard SecondarySubtitleStyleTransaction.restore(saved, io: io) else {
            status = "副字幕样式回滚仍未确认；播放与退出仍可使用"; return
        }
        retainedRecovery = nil; needsRecovery = false
        _ = apply(player.settings.secondarySubtitleStyle)
    }
}
