import AppKit
import SwiftUI
import UniformTypeIdentifiers

private final class MediaToolsForm: ObservableObject {
    @Published var startText = "0"
    @Published var endText = "10"
    @Published var transcode = true
    @Published var language = "zh"
}

struct MediaToolsView: View {
    @ObservedObject var player: PlayerModel
    @ObservedObject private var tools = MediaTools.shared
    @StateObject private var form = MediaToolsForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(AppCapabilities.current.hasOfflineSpeechRecognition ? "录制、导出与字幕生成" : "录制与导出").font(.title2.bold())
                Spacer()
                Button("完成") { player.showTools = false }.keyboardShortcut(.defaultAction)
            }
            Text(player.playlist.currentItem?.title ?? "请先打开媒体").font(.headline).lineLimit(1).truncationMode(.middle)
            if player.currentIsWebMedia {
                Text("网页媒体目前支持播放与截图。导出、录制或生成语音字幕，请先打开本地文件或直接媒体地址。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            GroupBox("导出片段") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("开始（秒）")
                        TextField("0", text: $form.startText).textFieldStyle(.roundedBorder).frame(width: 90)
                        Button("当前") { form.startText = String(format: "%.3f", player.position) }
                        Text("结束（秒）")
                        TextField("10", text: $form.endText).textFieldStyle(.roundedBorder).frame(width: 90)
                        Button("当前") { form.endText = String(format: "%.3f", player.position) }
                    }
                    Toggle("精确导出（H.264 硬件编码与 AAC）", isOn: $form.transcode)
                    Text(form.transcode ? "输出 MP4；重新编码可得到准确的开始和结束点。" : "输出 MKV；复制原编码，起点可能落在附近关键帧，不包含播放器叠加字幕或滤镜。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("导出片段…") { exportClip() }
                        Spacer()
                        Button("导出完整音频 WAV…") { save(extension: "wav", suffix: "音频") { source, output in tools.extractAudio(source: source, output: output) } }
                    }
                    Text("WAV 导出完整音频，保留源采样率和声道，保存为 16 位 PCM；开始和结束时间仅用于片段导出。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }.disabled(tools.busy || player.currentURL == nil || player.currentIsWebMedia)
            GroupBox("原码录制") {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("录制直接媒体流为 MKV")
                        Text("保存音视频原编码；按“停止并保存”完成文件。网页地址需要先解析为直接媒体地址。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if tools.isRecording {
                        Button("停止并保存") { tools.stop() }
                    } else {
                        Button("开始录制…") { save(extension: "mkv", suffix: "录制") { source, output in tools.recordStream(source: source, output: output) } }
                            .disabled(tools.busy || player.currentURL == nil || player.currentIsWebMedia)
                    }
                }.padding(8)
            }
            if AppCapabilities.current.hasOfflineSpeechRecognition {
            GroupBox("离线语音字幕") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Picker("识别语言", selection: $form.language) {
                            Text("中文").tag("zh"); Text("自动识别").tag("auto"); Text("英语").tag("en")
                            Text("日语").tag("ja"); Text("韩语").tag("ko"); Text("法语").tag("fr")
                            Text("德语").tag("de"); Text("西班牙语").tag("es"); Text("俄语").tag("ru")
                        }.frame(width: 250)
                        Spacer()
                        Button("生成 SRT 字幕…") { save(extension: "srt", suffix: "识别字幕") { source, output in tools.generateSubtitles(source: source, output: output, language: form.language) } }
                    }
                    Text("使用本地 base 多语言模型，全片完成后保存并加载 SRT。当前采用 CPU / Accelerate，处理时间取决于片长；不提供实时字幕。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }.disabled(tools.busy || !canGenerateSubtitles)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(tools.status).font(.callout)
                    Spacer()
                    if tools.busy { Button("取消") { tools.cancel() } }
                    else if tools.lastOutput != nil { Button("在 Finder 显示结果") { tools.revealOutput() } }
                }
                if tools.busy {
                    if tools.isRecording || tools.progress == 0 { ProgressView().progressViewStyle(.linear) }
                    else { ProgressView(value: tools.progress).progressViewStyle(.linear) }
                }
                if let error = tools.error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled).lineLimit(6) }
            }
        }
        .padding(24).frame(width: 650).preferredColorScheme(.dark)
        .onAppear {
            form.startText = String(format: "%.3f", player.position)
            let end = player.duration > 0 ? min(player.duration, player.position + 10) : player.position + 10
            form.endText = String(format: "%.3f", end)
        }
    }

    private func exportClip() {
        guard !player.currentIsWebMedia, let source = player.currentURL else { return }
        guard let start = Double(form.startText), let end = Double(form.endText), start.isFinite, end.isFinite, start >= 0, end > start else {
            let alert = NSAlert(); alert.messageText = "请输入有效区间"; alert.informativeText = "开始和结束使用秒，结束必须大于开始。"; alert.runModal(); return
        }
        let transcode = form.transcode
        save(extension: transcode ? "mp4" : "mkv", suffix: "片段") { _, output in
            tools.exportClip(source: source, start: start, end: end, output: output, transcode: transcode)
        }
    }

    private var canGenerateSubtitles: Bool {
        guard AppCapabilities.current.hasOfflineSpeechRecognition else { return false }
        guard !player.currentIsWebMedia else { return false }
        guard let source = player.currentURL else { return false }
        return source.isFileURL || player.duration > 0
    }

    private func save(extension ext: String, suffix: String, action: @escaping (URL, URL) -> Void) {
        guard !player.currentIsWebMedia, let source = player.currentURL else { return }
        let panel = NSSavePanel()
        panel.title = "保存\(suffix)"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.nameFieldStringValue = "\(source.deletingPathExtension().lastPathComponent)-\(suffix).\(ext)"
        panel.begin { response in
            if response == .OK, let output = panel.url { action(source, output) }
        }
    }
}
