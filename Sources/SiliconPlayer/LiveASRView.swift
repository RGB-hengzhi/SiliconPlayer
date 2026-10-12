import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PlayerCore
import Combine

struct LiveASRView: View {
    @ObservedObject var player: PlayerModel
    @ObservedObject var controller: LiveASRController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var actions = LiveASRViewActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("实时中文字幕").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("识别当前选中的本地内置音轨或已加载的单音轨 PCM WAV，字幕显示在画面顶部。可连续识别同一已选本地音轨，分段接续保留已确定字幕，支持 0.5–2 倍速；音频延迟须为零。").foregroundStyle(.secondary)
            Toggle("长片持续解码（尚需本包独立验收）",isOn:$actions.persistentProvider)
                .disabled(controller.isActive || controller.busy)
                .accessibilityIdentifier("live-asr-persistent-provider")
            Text("默认保持现有分段模式。持续模式仅在当前工具和完整真实契约验证后允许开始；它不会改写播放速度或媒体偏好。")
                .font(.caption).foregroundStyle(.secondary)
            Text(controller.status).accessibilityIdentifier("live-asr-status")
            if let error = controller.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            GroupBox("正在识别") {
                Text(controller.partialText.isEmpty ? "等待语音…" : controller.partialText)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).textSelection(.enabled)
            }
            GroupBox("已确定字幕（\(controller.finalCues.count)）") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(controller.finalCues) { cue in
                            HStack(alignment: .top) {
                                Text(TimeText.format(cue.start.seconds)).monospacedDigit().foregroundStyle(.secondary)
                                Text(cue.text).textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 180)
            }
            if !actions.exportStatus.isEmpty { Text(actions.exportStatus).foregroundStyle(.secondary) }
            HStack {
                Button("开始识别") {
                    Task { _ = await player.startLiveASR(mode:actions.persistentProvider ? .persistentProvider:.boundedPairs) }
                }.disabled(controller.busy || controller.isActive || !player.loaded)
                    .accessibilityIdentifier("live-asr-start")
                Button("停止识别") { Task { _ = await controller.stop() } }
                    .disabled(!controller.canStop || controller.state == .closing)
                    .accessibilityIdentifier("live-asr-stop")
                Spacer()
                Button(actions.exporting ? "正在导出…" : "导出 SRT…") { exportSRT() }
                    .disabled(controller.finalCues.isEmpty || actions.exporting)
            }
        }.padding(20).frame(width: 620)
    }

    private func exportSRT() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = "实时中文字幕.srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        actions.exporting = true; actions.exportStatus = ""
        Task {
            do { try await controller.export(to: url); actions.exportStatus = "已导出 \(url.lastPathComponent)" }
            catch { actions.exportStatus = error.localizedDescription }
            actions.exporting = false
        }
    }
}

@MainActor final class LiveASRViewActions: ObservableObject {
    @Published var persistentProvider = false
    @Published var exporting = false
    @Published var exportStatus = ""
}
