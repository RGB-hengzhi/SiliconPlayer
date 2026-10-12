import AppKit
import SwiftUI
import UniformTypeIdentifiers

private final class ThumbnailForm: ObservableObject {
    @Published var time = "0"
    @Published var preview: NSImage?
    @Published var previewTime = 0.0
    @Published var count = 12
    @Published var columns = 4
    @Published var width = 1600
}

struct ThumbnailToolsView: View {
    @ObservedObject var player: PlayerModel
    @ObservedObject private var tools = ThumbnailTools.shared
    @StateObject private var form = ThumbnailForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("画面预览与缩略图拼图", systemImage: "rectangle.split.3x3").font(.title2.bold())
                Spacer()
                Button("完成") { player.showThumbnails = false }.keyboardShortcut(.cancelAction)
            }
            Text(player.currentURL?.lastPathComponent ?? "请先打开本地视频").font(.headline).lineLimit(1).truncationMode(.middle)
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black)
                if let image = form.preview { Image(nsImage: image).resizable().scaledToFit().padding(6) }
                else { Label("选择时间点读取预览", systemImage: "photo").foregroundStyle(.secondary) }
            }.frame(height: 260)
            HStack {
                Text("时间（秒）")
                TextField("0", text: $form.time).textFieldStyle(.roundedBorder).frame(width: 110)
                Button("查看") { preview() }
                Button("当前播放时间") { form.time = String(format: "%.3f", player.position); preview() }
                Spacer()
                Button("跳转到预览") { player.seek(form.previewTime) }.disabled(form.preview == nil)
            }.disabled(tools.generatingSheet || !isLocalVideo)
            GroupBox("带时间与文件名的 PNG 拼图") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Picker("张数", selection: $form.count) { ForEach([6, 12, 20, 30, 60], id: \.self) { Text("\($0)").tag($0) } }.frame(width: 125)
                        Picker("列数", selection: $form.columns) { ForEach([2, 3, 4, 5, 6], id: \.self) { Text("\($0)").tag($0) } }.frame(width: 125)
                        Picker("宽度", selection: $form.width) { ForEach([800, 1200, 1600, 2400, 3200], id: \.self) { Text("\($0) px").tag($0) } }.frame(width: 190)
                        Spacer()
                        Button("生成拼图…") { contactSheet() }
                    }
                    Text("均匀采样全片的多个时间点，独立读取单帧。原比例保留；不包含播放器叠加的字幕或滤镜。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }.disabled(tools.busy || !isLocalVideo || player.duration <= 0)
            HStack {
                Text(tools.status).font(.callout)
                Spacer()
                if tools.busy { Button("取消") { tools.cancel() } }
                else if let output = tools.lastOutput { Button("显示拼图") { NSWorkspace.shared.activateFileViewerSelecting([output]) } }
            }
            if tools.busy { ProgressView(value: tools.progress).progressViewStyle(.linear) }
            if let error = tools.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(4) }
        }
        .padding(24).frame(width: 700).preferredColorScheme(.dark)
        .onAppear {
            form.time = String(format: "%.3f", player.position)
            if isLocalVideo { preview() }
        }
        .onChange(of: player.currentURL) { _, _ in
            tools.cancel(); form.preview = nil; form.previewTime = 0; form.time = "0"
        }
    }

    private var isLocalVideo: Bool { player.currentURL?.isFileURL == true }

    private func preview() {
        guard let source = player.currentURL, let time = Double(form.time), time.isFinite, time >= 0 else { return }
        tools.frame(source: source, time: time) { image in
            guard player.currentURL == source else { return }
            form.preview = image
            if image != nil { form.previewTime = time }
        }
    }

    private func contactSheet() {
        guard let source = player.currentURL, player.duration > 0 else { return }
        let duration = player.duration, count = form.count, columns = form.columns, width = form.width
        let panel = NSSavePanel()
        panel.title = "保存缩略图拼图"; panel.allowedContentTypes = [.png]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "-缩略图.png"
        panel.begin { response in
            if response == .OK, let output = panel.url {
                tools.generateContactSheet(source: source, duration: duration, count: count, columns: columns, width: width, output: output)
            }
        }
    }
}
