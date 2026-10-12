import AppKit
import SwiftUI
import PlayerCore

private final class SecondaryStyleFormState: ObservableObject {
    @Published var font = ""
    @Published private(set) var preference = SecondarySubtitleStyleSettings()
    private var committedFont = ""
    private var context: UUID?
    func matchesContext(_ current: UUID) -> Bool { context == current }
    func synchronize(_ settings: PlaybackSettings, context current: UUID) {
        let next = settings.secondarySubtitleStyle ?? SecondarySubtitleStyleSettings(primary: settings)
        if preference != next { preference = next }
        let actual = next.font
        if context != current || actual != committedFont || font.isEmpty { font = actual; committedFont = actual }
        context = current
    }
}

/// Uses the same plain-card parent as the current subtitle page, not GroupBox.
struct SecondarySubtitleStyleControls: View {
    let player: PlayerModel
    @ObservedObject private var runtime: SecondarySubtitleStyleRuntime
    @StateObject private var form = SecondaryStyleFormState()
    init(player: PlayerModel) { self.player = player; _runtime = ObservedObject(wrappedValue: player.secondarySubtitleStyle) }
    private var preference: SecondarySubtitleStyleSettings { form.preference }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("独立副字幕样式", isOn: binding(\.enabled)).disabled(!runtime.available || runtime.needsRecovery)
            if !runtime.available { Text("当前播放内核仅支持共同字体样式，副字幕位置与延迟仍可独立设置。").font(.caption).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("副字幕字体").frame(width: 86, alignment: .leading)
                    TextField("字体名称", text: $form.font).onSubmit { applyFont() }
                    Button("应用字体") { applyFont() }
                }
                sizeControl("副字幕大小", key: \.size, range: 12...100, step: 1)
                colorControl("副字幕颜色", key: \.color, supportsAlpha: false)
                colorControl("副字幕描边颜色", key: \.outlineColor, supportsAlpha: false)
                sizeControl("副字幕描边宽度", key: \.outline, range: 0...10, step: 0.5)
                Toggle("副字幕背景", isOn: binding(\.background))
                colorControl("副字幕背景颜色", key: \.backColor, supportsAlpha: true)
            }.disabled(!preference.enabled || !runtime.available || runtime.needsRecovery)
            Picker("副字幕 ASS 样式", selection: binding(\.assOverride)) {
                Text("保留内嵌样式").tag("no"); Text("允许覆盖").tag("yes")
                Text("样式与缩放").tag("scale"); Text("强制用户样式").tag("force")
                Text("移除内嵌样式").tag("strip")
            }.disabled(!runtime.available || runtime.needsRecovery)
            Text("ASS/SSA 的内嵌样式在保留模式下优先。位图字幕不能更换字体。输入副字体后按 Return 或“应用字体”。").font(.caption).foregroundStyle(.secondary)
            Text("播放时更改只影响当前媒体；可用“保存此媒体设置”保留。未打开媒体时更改全局默认。").font(.caption).foregroundStyle(.secondary)
            Text(runtime.status).font(.caption).foregroundStyle(runtime.needsRecovery ? Color.orange : Color.secondary)
            HStack {
                Button("恢复副字幕默认并继承") { _ = runtime.reset(); form.synchronize(player.settings, context: player.mediaPreferenceToken) }.disabled(!runtime.available || runtime.needsRecovery)
                if runtime.needsRecovery { Button("重试恢复原样式") { runtime.retryRecovery() } }
            }
        }.onAppear { form.synchronize(player.settings, context: player.mediaPreferenceToken) }
            .onReceive(player.$settings) { form.synchronize($0, context: player.mediaPreferenceToken) }
    }
    private func applyFont() {
        guard form.matchesContext(player.mediaPreferenceToken) else {
            form.synchronize(player.settings, context: player.mediaPreferenceToken)
            player.toast("媒体已更换，请重新编辑副字幕字体")
            return
        }
        _ = runtime.change { $0.font = form.font }
        form.synchronize(player.settings, context: player.mediaPreferenceToken)
    }
    private func binding<T>(_ key: WritableKeyPath<SecondarySubtitleStyleSettings, T>) -> Binding<T> {
        Binding(get: { preference[keyPath: key] }, set: { value in _ = runtime.change { $0[keyPath: key] = value } })
    }
    private func sizeControl(_ title: String, key: WritableKeyPath<SecondarySubtitleStyleSettings, Double>,
                             range: ClosedRange<Double>, step: Double) -> some View {
        HStack {
            Text(title).frame(width: 86, alignment: .leading)
            Slider(value: binding(key), in: range, step: step).accessibilityLabel(title)
            Text(String(format: "%.1f", preference[keyPath: key])).monospacedDigit().frame(width: 48)
        }
    }
    private func colorControl(_ title: String,
                              key: WritableKeyPath<SecondarySubtitleStyleSettings, String>,
                              supportsAlpha: Bool) -> some View {
        let token = player.mediaPreferenceToken
        return HStack {
            Text(title)
            Spacer()
            NativeSubtitleColorWell(selection: colorBinding(key), contextID: token,
                supportsAlpha: supportsAlpha, accessibilityName: title,
                isContextCurrent: {
                    player.mediaPreferenceToken == token && form.matchesContext(token)
                        && runtime.available && !runtime.needsRecovery && preference.enabled
                }).frame(width: 54, height: 26).id(token)
        }
    }
    private func colorBinding(_ key: WritableKeyPath<SecondarySubtitleStyleSettings, String>) -> Binding<Color> {
        Binding(get: {
            let raw = UInt32(preference[keyPath: key].dropFirst(), radix: 16) ?? 0xFFFFFFFF
            return Color(red: Double((raw >> 16) & 255) / 255, green: Double((raw >> 8) & 255) / 255,
                blue: Double(raw & 255) / 255, opacity: Double((raw >> 24) & 255) / 255)
        }, set: { value in
            guard form.matchesContext(player.mediaPreferenceToken) else {
                form.synchronize(player.settings, context: player.mediaPreferenceToken)
                player.toast("媒体已更换，请重新选择副字幕颜色")
                return
            }
            guard let c = NSColor(value).usingColorSpace(.deviceRGB) else { return }
            let text = String(format: "#%02X%02X%02X%02X", Int((c.alphaComponent * 255).rounded()),
                Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
            _ = runtime.change { $0[keyPath: key] = text }
        })
    }
}
