import SwiftUI
import PlayerCore

struct ProcessingControlsView: View {
    let player: PlayerModel
    private let expandedTools = AppCapabilities.current.profile == .full
    @StateObject private var observation: AdvancedPanelObservation

    init(player: PlayerModel) {
        self.player = player
        _observation = StateObject(wrappedValue: AdvancedPanelObservation(player: player, processingOnly: true))
    }
    private func bind<T>(_ key: WritableKeyPath<ProcessingSettings, T>) -> Binding<T> {
        Binding(get: { player.settings.processing[keyPath: key] }, set: { value in player.updateSettings { $0.processing[keyPath: key] = value } })
    }
    private func slider(_ label: String, _ key: WritableKeyPath<ProcessingSettings, Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 95, alignment: .leading)
            Slider(value: bind(key), in: range)
            Text(String(format: "%.1f", player.settings.processing[keyPath: key])).monospacedDigit().frame(width: 45, alignment: .trailing)
        }
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 14, content: content).padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            UserVideoFiltersView(controller: player.userVideoFilters)
            card("缩放、色带与 HDR 映射") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("去色带", isOn: bind(\.deband))
                    Picker("缩放算法", selection: bind(\.scaler)) {
                        Text("双线性（省电）").tag("bilinear"); Text("双三次").tag("bicubic")
                        Text("Lanczos").tag("lanczos"); Text("EWA Lanczos Sharp").tag("ewa_lanczossharp")
                    }
                    Toggle("帧混合插值与屏幕同步", isOn: bind(\.interpolation))
                    Toggle("转换到 SDR / BT.709", isOn: bind(\.forceSDR))
                    Picker("色调映射", selection: bind(\.toneMapping)) {
                        ForEach(["auto", "mobius", "reinhard", "hable", "bt.2390", "clip"], id: \.self) { Text($0).tag($0) }
                    }
                    Text("当前输出为 SDR。原生 HDR / EDR 输出仍待专门实现和显示器验收。").font(.caption).foregroundStyle(.secondary)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            if expandedTools {
            card("3D 与 360°视角") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("3D 输入", selection: bind(\.stereoInput)) {
                        Text("关闭").tag("off"); Text("左右（左眼优先）").tag("sbsl"); Text("左右（右眼优先）").tag("sbsr")
                        Text("上下（左眼优先）").tag("abl"); Text("上下（右眼优先）").tag("abr")
                    }
                    Picker("3D 输出", selection: bind(\.stereoOutput)) {
                        Text("仅左眼").tag("ml"); Text("仅右眼").tag("mr"); Text("红青 Dubois").tag("arcd")
                        Text("红青彩色").tag("arcc"); Text("左右").tag("sbsl"); Text("左右交换").tag("sbsr")
                    }
                    Picker("360°输入投影", selection: bind(\.projection)) {
                        Text("关闭").tag("off"); Text("等距柱状 Equirectangular").tag("equirect")
                        Text("Cubemap 3×2").tag("c3x2"); Text("Equi-Angular Cubemap").tag("eac")
                    }
                    slider("水平视角", \.yaw, -180...180); slider("俯仰", \.pitch, -90...90); slider("视野角度", \.fieldOfView, 30...150)
                    Text("360°转换为平面视口；播放画面上拖动可调整方向，滚轮调整视野。采用 CPU 投影，4K / 8K 流畅度尚未验收。").font(.caption).foregroundStyle(.secondary)
                    Button("重置视角") { player.updateSettings { $0.processing.yaw = 0; $0.processing.pitch = 0; $0.processing.fieldOfView = 90 } }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            }
            card("裁剪") {
                VStack(spacing: 12) {
                    slider("保留宽度", \.cropWidth, 0.1...1); slider("保留高度", \.cropHeight, 0.1...1)
                    Button("恢复完整画面") { player.updateSettings { $0.processing.cropWidth = 1; $0.processing.cropHeight = 1 } }
                }.padding(8)
            }
            card("字幕兼容与同步") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("ASS 样式策略", selection: bind(\.assOverride)) {
                        Text("保留脚本样式").tag("no"); Text("保留样式并允许缩放").tag("scale")
                        Text("覆盖字体与位置").tag("force"); Text("纯文本").tag("strip")
                    }
                    Picker("文本编码", selection: bind(\.subtitleEncoding)) {
                        Text("自动").tag("auto"); Text("UTF-8").tag("utf-8"); Text("GB18030").tag("+gb18030")
                        Text("Big5").tag("+big5"); Text("UTF-16").tag("+utf-16")
                    }
                    Text("编码更改适用于重新加载的外部字幕。").font(.caption).foregroundStyle(.secondary)
                    slider("字幕帧率", \.subtitleFPS, 0...60)
                    Text("0 表示按原字幕时间，不转换帧率。").font(.caption).foregroundStyle(.secondary)
                    slider("副字幕延迟", \.secondarySubtitleDelay, -30...30)
                    HStack {
                        Button("上一条字幕") { player.seekSubtitle(-1) }
                        Button("下一条字幕") { player.seekSubtitle(1) }
                    }.disabled(!player.loaded)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            card("音频处理与高级输出") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("倍速时保留音调", isOn: bind(\.pitchCorrection))
                    if expandedTools { slider("变调（半音）", \.pitchSemitones, -12...12) }
                    Toggle("耳机 Crossfeed", isOn: bind(\.crossfeed))
                    Toggle("左右声道交换", isOn: bind(\.swapChannels))
                    Toggle("处理后限幅保护", isOn: bind(\.limiter))
                    if expandedTools {
                    Picker("采样率", selection: bind(\.audioSampleRate)) {
                        Text("跟随音源").tag(0)
                        ForEach([44100, 48000, 96000, 192000], id: \.self) { Text("\($0) Hz").tag($0) }
                    }
                    Toggle("独占音频设备", isOn: bind(\.audioExclusive))
                    Text("独占模式和高采样率需要音频设备支持，可能中断其他应用的声音。").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
