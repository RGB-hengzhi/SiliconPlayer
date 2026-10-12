import SwiftUI
import PlayerCore

@MainActor
struct MediaPreferencesView: View {
    @ObservedObject var controller: MediaPreferencesController
    let saveCurrent: @MainActor () -> Void
    let restoreCurrent: @MainActor () -> Void
    let clearCurrent: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("此媒体的设置", systemImage: "slider.horizontal.3").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if controller.currentTitle.isEmpty {
                ContentUnavailableView("尚未打开媒体", systemImage: "play.rectangle",
                    description: Text("打开并加载媒体后，可以保存音轨、字幕、延迟与画面设置。"))
            } else {
                Text(controller.currentTitle).font(.headline).lineLimit(3).textSelection(.enabled)
                Text(controller.hasSavedCurrent ? "此媒体已有保存的设置" : "此媒体尚未保存设置")
                    .foregroundStyle(.secondary)
                if let record = controller.savedCurrent {
                    GroupBox("已保存") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("保存于 \(record.savedAt.formatted(date: .abbreviated, time: .shortened))")
                            Text("音轨：\(trackText(record.audio))")
                            Text("字幕：\(trackText(record.primarySubtitle))")
                            Text("第二字幕：\(trackText(record.secondarySubtitle))")
                            if let geometry = record.geometry {
                                Text("画面：旋转 \(geometry.rotation)°，比例 \(geometry.aspect == "-1" ? "自动" : geometry.aspect)，投影 \(geometry.projection.rawValue)")
                            }
                            Text("音频延迟 \(delay(record.audioDelay))；字幕延迟 \(delay(record.subtitleDelay))")
                        }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Toggle("加载媒体时自动恢复已保存设置", isOn: Binding(
                get: { controller.document.automaticallyRestore },
                set: { _ = controller.setAutomaticallyRestore($0) }))
                .disabled(controller.blocksPersistence)
            Text("保存当前音轨与字幕的描述、延迟、画面几何和投影视角。更换媒体或停止播放会清除本次播放的修改；其他播放设置沿用全局默认。")
                .font(.caption).foregroundStyle(.secondary)
            if !controller.status.isEmpty { Text(controller.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if let error = controller.errorText {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            }
            if controller.blocksPersistence {
                Text("导入恢复尚未完成，请重新启动后再保存设置。").font(.callout).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
            HStack {
                Button("清除此媒体的设置", action: clearCurrent)
                    .disabled(!controller.hasSavedCurrent || controller.blocksPersistence)
                Spacer()
                Button("恢复已保存", action: restoreCurrent)
                    .disabled(!controller.isLoaded || !controller.hasSavedCurrent || controller.blocksPersistence)
                Button("保存当前设置", action: saveCurrent)
                    .disabled(!controller.canSave)
            }
        }
        .padding(22).frame(minWidth: 600, minHeight: 400)
    }
    private func trackText(_ preference: MediaTrackPreference?) -> String {
        switch preference {
        case nil: return "沿用默认"
        case .automatic?: return "自动选择"
        case .disabled?: return "关闭"
        case .match(let descriptor)?:
            let label = [descriptor.title, descriptor.language, descriptor.codec].filter { !$0.isEmpty }.joined(separator: " · ")
            return label.isEmpty ? "按轨道描述匹配" : label
        }
    }
    private func delay(_ value: Double?) -> String { value.map { String(format: "%+.2f 秒", $0) } ?? "默认" }
}
