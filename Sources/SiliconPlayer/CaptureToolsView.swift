import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI
import PlayerCore

struct CaptureToolsView: View {
    @ObservedObject var player: PlayerModel
    @StateObject private var capture = CaptureController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("屏幕与摄像头采集", systemImage: "record.circle").font(.title2.bold())
                Spacer()
                if capture.isRecording {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text(TimeText.format(capture.elapsed)).monospacedDigit()
                }
                Button("完成") { player.showCapture = false }
                    .keyboardShortcut(.cancelAction).disabled(capture.isBusy || capture.isRecording)
            }
            Picker("采集来源", selection: $capture.sourceKind) {
                ForEach(CaptureSourceKind.allCases) { source in Text(source.title).tag(source) }
            }.pickerStyle(.segmented).disabled(capture.isBusy || capture.isRecording)
            HStack(alignment: .top, spacing: 22) {
                sourceOptions.frame(width: 305)
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                if capture.isBusy { ProgressView().controlSize(.small) }
                Text(capture.status).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            if let error = capture.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Button("刷新来源与权限") { Task { await capture.refreshSources() } }.disabled(capture.isBusy || capture.isRecording)
                if capture.isPreviewing && !capture.isRecording {
                    Button("停止预览") { Task { await capture.stopPreview() } }.disabled(capture.isBusy)
                } else if !capture.isRecording {
                    Button("预览") { Task { await capture.startPreview() } }.disabled(capture.isBusy)
                }
                Spacer()
                if capture.isRecording {
                    Button { Task { await capture.stopRecording() } } label: { Label("停止并保存", systemImage: "stop.fill") }
                        .buttonStyle(.borderedProminent).tint(.red).disabled(capture.isBusy)
                } else {
                    Button { Task { await capture.startRecording() } } label: { Label("选择位置并开始录制…", systemImage: "record.circle") }
                        .buttonStyle(.borderedProminent).disabled(capture.isBusy)
                }
            }
            if let url = capture.lastRecordingURL {
                HStack {
                    Text(url.lastPathComponent).font(.caption).lineLimit(1)
                    Spacer()
                    Button("在 Finder 显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("打开播放") { player.open([url]); player.showCapture = false }
                }
            }
            Text("打开本面板不会申请权限。点击刷新、预览或开始时，系统才请求对应访问；停止录制后文件才完成保存。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(minWidth: 900, minHeight: 595)
            .interactiveDismissDisabled(capture.isBusy || capture.isRecording)
            .onChange(of: capture.sourceKind) { _, _ in Task { await capture.dismissPreview() } }
            .onDisappear { Task { await capture.dismissPreview() } }
    }

    private var sourceOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            if capture.sourceKind == .display {
                Picker("屏幕", selection: $capture.selectedDisplayID) {
                    Text("请选择或刷新").tag(Optional<UInt32>.none)
                    ForEach(capture.displays, id: \.displayID) { display in
                        Text("屏幕 \(display.displayID) · \(display.width) × \(display.height)").tag(Optional(display.displayID))
                    }
                }
            } else if capture.sourceKind == .window {
                Picker("窗口", selection: $capture.selectedWindowID) {
                    Text("请选择或刷新").tag(Optional<UInt32>.none)
                    ForEach(capture.windows, id: \.windowID) { window in
                        Text(CaptureController.windowTitle(window)).tag(Optional(window.windowID))
                    }
                }
                Text("仅采集选定窗口；窗口关闭、退出或源失效会结束采集。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("摄像头", selection: $capture.selectedCameraID) {
                    Text("请选择或刷新").tag("")
                    ForEach(capture.cameras, id: \.uniqueID) { camera in Text(camera.localizedName).tag(camera.uniqueID) }
                }
                Toggle("同时录制麦克风", isOn: $capture.includeMicrophone)
                if capture.includeMicrophone {
                    Picker("麦克风", selection: $capture.selectedMicrophoneID) {
                        Text("请选择或刷新").tag("")
                        ForEach(capture.microphones, id: \.uniqueID) { microphone in Text(microphone.localizedName).tag(microphone.uniqueID) }
                    }
                }
                Text("摄像头使用原生 AVFoundation 录制 H.264 MOV，优先 1080p，实际规格取决于设备。麦克风权限仅在开始含声音的录制时请求。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if capture.sourceKind != .camera {
                Picker("视频编码", selection: $capture.codec) {
                    ForEach(CaptureVideoCodec.allCases) { codec in Text(codec.title).tag(codec) }
                }
                Picker("最大长边", selection: $capture.maximumDimension) {
                    Text("1920 像素").tag(1920)
                    Text("2560 像素").tag(2560)
                    Text("3840 像素").tag(3840)
                }
                Picker("目标帧率", selection: $capture.frameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("显示鼠标指针", isOn: $capture.includeCursor)
                Toggle("录制系统声音", isOn: $capture.includeSystemAudio)
                if capture.sourceKind == .display { Toggle("排除播放器画面与声音", isOn: $capture.excludePlayer) }
                Text("画面按比例缩小，保持偶数尺寸；系统声音录制为双声道 AAC。屏幕录制暂不混入麦克风，也不包含 HDR。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if capture.isPreviewing && !capture.isRecording {
                Text("切换来源或采集参数后，停止并重新启动预览即可应用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(capture.isBusy || capture.isRecording)
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.black)
            if let session = capture.cameraSession {
                CameraPreviewSurface(session: session).clipShape(RoundedRectangle(cornerRadius: 10))
            } else if let image = capture.screenPreview {
                Image(nsImage: image).resizable().scaledToFit().padding(6)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: capture.sourceKind == .camera ? "video" : "display").font(.system(size: 38))
                    Text("采集预览").font(.headline)
                    Text("点击预览查看所选来源").font(.caption)
                }.foregroundStyle(.gray)
            }
        }.frame(minWidth: 480, minHeight: 290)
    }
}

private struct CameraPreviewSurface: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: CameraPreviewView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
    }

    static func dismantleNSView(_ view: CameraPreviewView, coordinator: ()) { view.previewLayer.session = nil }
}

private final class CameraPreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); previewLayer.frame = bounds }
}
