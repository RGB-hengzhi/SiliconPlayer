import AppKit
import SwiftUI
import PlayerCore

private enum AdvancedTab: String, CaseIterable, Identifiable {
    case video, audio, subtitles, playback, appearance, processing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .video: return "视频"
        case .audio: return "音频"
        case .subtitles: return "字幕"
        case .playback: return "播放与缓存"
        case .appearance: return "外观与窗口"
        case .processing: return AppCapabilities.current.profile == .full ? "高级处理与 360°" : "滤镜与兼容"
        }
    }
    var icon: String {
        switch self {
        case .video: return "slider.horizontal.3"
        case .audio: return "waveform"
        case .subtitles: return "captions.bubble"
        case .playback: return "play.circle"
        case .appearance: return "macwindow"
        case .processing: return "globe"
        }
    }
    var keywords: String {
        switch self {
        case .video: return "视频 色彩 亮度 对比度 饱和度 伽马 色相 旋转 宽高比 缩放 平移 镜像 翻转 锐化 降噪 去隔行 brightness contrast saturation gamma hue rotation zoom pan sharpen denoise"
        case .audio: return "音频 声音 均衡器 EQ 频段 预设 平直 人声 摇滚 古典 低音 高音 自定义 规范化 音量 声道 单声道 立体声 输出 设备"
        case .subtitles: return "字幕 字体 大小 颜色 描边 背景 位置 双字幕 第二字幕"
        case .playback: return "播放 缓存 硬件 解码 自动 语言 首选 内存 videotoolbox"
        case .appearance: return "外观 主题 浅色 深色 系统 窗口 置顶 防止休眠 截图 格式 png jpg webp"
        case .processing:
            return AppCapabilities.current.profile == .full
                ? "360 3D HDR 色带 插值 采样率 变调 字幕编码 ASS GB18030 裁剪 Crossfeed"
                : "滤镜 锐化 降噪 色带 缩放 SDR 字幕编码 ASS GB18030 Big5 裁剪 Crossfeed 音调 限幅"
        }
    }
}

private final class AdvancedControlsState: ObservableObject {
    @Published var selectedTab: AdvancedTab = .video
    @Published var search = ""
    @Published var fontDraft = ""
    @Published var audioLanguagesDraft = ""
    @Published var subtitleLanguagesDraft = ""
}

/// Each setting writes through PlayerModel so the playback engine and persistence stay in sync.
struct AdvancedControlsView: View {
    let player: PlayerModel
    @StateObject private var observation: AdvancedPanelObservation

    init(player: PlayerModel) {
        self.player = player
        _observation = StateObject(wrappedValue: AdvancedPanelObservation(player: player))
    }
    @StateObject private var state = AdvancedControlsState()
    private let accent = Color(red: 0.41, green: 0.88, blue: 0.75)

    private var matchingTabs: [AdvancedTab] {
        let query = state.search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [state.selectedTab] }
        return AdvancedTab.allCases.filter { $0.keywords.localizedCaseInsensitiveContains(query) }
    }
    private var colorScheme: ColorScheme? {
        switch player.settings.theme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppCapabilities.current.profile == .full ? "高级播放设置" : "播放设置").font(.title2.weight(.semibold))
                    Text("更改会自动应用并保存").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索设置", text: $state.search).textFieldStyle(.plain)
                    if !state.search.isEmpty {
                        Button { state.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }.padding(8).frame(width: 190).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }.padding(20)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    ForEach(AdvancedTab.allCases) { tab in
                        Button {
                            state.selectedTab = tab
                            state.search = ""
                        } label: {
                            Label(tab.title, systemImage: tab.icon)
                                .font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 11)
                                .foregroundStyle(state.selectedTab == tab && state.search.isEmpty ? accent : .primary)
                                .background(state.selectedTab == tab && state.search.isEmpty ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                    Label(player.loaded ? (player.paused ? "已暂停" : "正在播放") : "设置适用于下次播放",
                          systemImage: player.loaded ? (player.paused ? "pause.fill" : "play.fill") : "checkmark.circle")
                        .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8)
                }.padding(10).frame(width: 166).background(.quinary)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if matchingTabs.isEmpty {
                            ContentUnavailableView.search(text: state.search).frame(minHeight: 280)
                        } else {
                            ForEach(matchingTabs) { tab in
                                if !state.search.isEmpty { Text(tab.title).font(.headline).padding(.top, 4) }
                                switch tab {
                                case .video: videoControls
                                case .audio: audioControls
                                case .subtitles: subtitleControls
                                case .playback: playbackControls
                                case .appearance: appearanceControls
                                case .processing: ProcessingControlsView(player: player)
                                }
                            }
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack {
                Button("恢复全部默认") {
                    player.resetSettings()
                    synchronizeDrafts()
                }
                Spacer()
                Button("完成") {
                    player.updateSettings {
                        $0.subtitleFont = state.fontDraft
                        $0.preferredAudioLanguages = state.audioLanguagesDraft
                        $0.preferredSubtitleLanguages = state.subtitleLanguagesDraft
                    }
                    player.showAdvanced = false
                }.keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 760, height: 600)
        .tint(accent)
        .preferredColorScheme(colorScheme)
        .onAppear(perform: synchronizeDrafts)
        .onReceive(player.$advancedSettingsInitialTab) { requested in
            state.selectedTab = AdvancedTab(rawValue: requested) ?? .video
            state.search = ""
        }
    }

    private var videoControls: some View {
        VStack(spacing: 16) {
            card("画面色彩") {
                adjustment("亮度", key: \.brightness, range: -100...100, step: 1)
                adjustment("对比度", key: \.contrast, range: -100...100, step: 1)
                adjustment("饱和度", key: \.saturation, range: -100...100, step: 1)
                adjustment("伽马", key: \.gamma, range: -100...100, step: 1)
                adjustment("色相", key: \.hue, range: -100...100, step: 1)
                HStack { Spacer(); Button("重置色彩") { player.updateSettings { $0.brightness = 0; $0.contrast = 0; $0.saturation = 0; $0.gamma = 0; $0.hue = 0 } } }
            }
            card("画面几何") {
                Picker("旋转", selection: binding(\.rotation)) {
                    Text("原始方向").tag(0); Text("90°").tag(90); Text("180°").tag(180); Text("270°").tag(270)
                }
                Picker("宽高比", selection: binding(\.aspect)) {
                    Text("原始比例").tag("-1"); Text("16∶9").tag("16:9"); Text("4∶3").tag("4:3")
                    Text("2.35∶1").tag("2.35:1"); Text("1∶1").tag("1:1")
                }
                adjustment("缩放", key: \.zoom, range: -2...4, step: 0.05, format: "%.2f")
                adjustment("水平平移", key: \.panX, range: -1...1, step: 0.01, format: "%+.2f")
                adjustment("垂直平移", key: \.panY, range: -1...1, step: 0.01, format: "%+.2f")
                HStack {
                    Toggle("水平镜像", isOn: binding(\.flipHorizontal))
                    Toggle("垂直翻转", isOn: binding(\.flipVertical))
                }
                HStack { Spacer(); Button("重置几何") { player.updateSettings { $0.rotation = 0; $0.aspect = "-1"; $0.zoom = 0; $0.panX = 0; $0.panY = 0; $0.flipHorizontal = false; $0.flipVertical = false } } }
            }
            card("画面处理") {
                adjustment("锐化", key: \.sharpen, range: 0...3, step: 0.1, format: "%.1f")
                adjustment("降噪", key: \.denoise, range: 0...5, step: 0.1, format: "%.1f")
                Toggle("去隔行", isOn: binding(\.deinterlace))
                note("锐化、降噪和翻转可能增加处理耗时。需要软件滤镜的处理会使用可读取视频帧的解码方式。")
            }
        }
    }

    private var audioControls: some View {
        VStack(spacing: 16) {
            card("十段均衡器") {
                Toggle("启用均衡器", isOn: binding(\.equalizerEnabled))
                ForEach(Array(["32 Hz", "64 Hz", "125 Hz", "250 Hz", "500 Hz", "1 kHz", "2 kHz", "4 kHz", "8 kHz", "16 kHz"].enumerated()), id: \.offset) { index, label in
                    HStack(spacing: 10) {
                        Text(label).font(.caption.monospaced()).frame(width: 54, alignment: .leading)
                        Slider(value: equalizerBinding(index), in: -12...12, step: 0.5)
                        Text(String(format: "%+.1f dB", player.settings.equalizer[index])).font(.caption.monospacedDigit()).frame(width: 65, alignment: .trailing)
                    }.disabled(!player.settings.equalizerEnabled)
                }
                HStack {
                    Menu {
                        ForEach(EqualizerPreset.all) { preset in
                            Button(preset.title + (selectedEqualizerPreset?.id == preset.id ? " ✓" : "")) { setEqualizer(preset.gains) }
                        }
                    } label: {
                        Text("预设：\(selectedEqualizerPreset?.title ?? "自定义")")
                    }
                    Spacer()
                    Button("重置频段") { player.updateSettings { $0.equalizer = EqualizerPreset.flat.gains } }
                }
                note("选择预设会启用均衡器；仍可逐段调节，与预设不同时显示为自定义。")
            }
            card("输出与响度") {
                Toggle("自动规范化音量", isOn: binding(\.normalizeAudio))
                note("平衡对白与突发声音的响度，适合夜间观看。")
                Picker("输出声道", selection: binding(\.channelMode)) {
                    Text("自动选择").tag("auto-safe"); Text("立体声").tag("stereo"); Text("单声道").tag("mono")
                    Text("5.1 声道").tag("5.1"); Text("7.1 声道").tag("7.1")
                }
                Picker("音频设备", selection: binding(\.audioDevice)) {
                    Text("系统默认").tag("auto")
                    ForEach(player.audioDevices.filter { $0.id != "auto" }, id: \.id) { device in
                        Text(device.description.isEmpty ? device.name : device.description).tag(device.id)
                    }
                    if player.settings.audioDevice != "auto" && !player.audioDevices.contains(where: { $0.id == player.settings.audioDevice }) {
                        Text("已保存的设备（当前不可用）").tag(player.settings.audioDevice)
                    }
                }
                note("多声道输出需要音源、音频设备和连接方式共同支持。")
            }
        }
    }

    private var subtitleControls: some View {
        VStack(spacing: 16) {
            card("主字幕") {
                Toggle("显示字幕", isOn: binding(\.subtitleVisible))
                Picker("字幕轨道", selection: Binding(get: { player.subtitleID }, set: { player.selectSubtitle($0) })) {
                    Text("关闭").tag(0)
                    ForEach(player.tracks.filter { $0.type == "sub" }) { track in Text(track.label).tag(track.id) }
                }.disabled(!player.loaded)
                HStack { Button("加载外部字幕…") { player.openPanel(subtitles: true) }.disabled(!player.loaded); Spacer() }
                HStack {
                    Text("字体").frame(width: 86, alignment: .leading)
                    TextField("字体名称", text: $state.fontDraft).onSubmit {
                        player.updateSettings { $0.subtitleFont = state.fontDraft }
                        state.fontDraft = player.settings.subtitleFont
                    }
                }
                note("输入本机字体名称后按 Return 应用。")
                adjustment("字体大小", key: \.subtitleSize, range: 12...100, step: 1, format: "%.0f", reset: 40)
                ColorPicker("字幕颜色", selection: subtitleColorBinding, supportsOpacity: false)
                adjustment("描边宽度", key: \.subtitleOutline, range: 0...10, step: 0.5, format: "%.1f", reset: 2)
                Toggle("字幕背景", isOn: binding(\.subtitleBackground))
                adjustment("垂直位置", key: \.subtitlePosition, range: 0...100, step: 1, format: "%.0f%%", reset: 100)
                HStack {
                    Text("主字幕延迟"); Spacer()
                    Text(String(format: "%+.1f 秒", player.subtitleDelay)).monospacedDigit()
                    Stepper("主字幕延迟", value: Binding(get: { player.subtitleDelay },
                        set: { player.setSubtitleDelay($0) }), in: -600...600, step: 0.1)
                        .labelsHidden().accessibilityLabel("主字幕延迟")
                }.disabled(!player.loaded)
                note("位置 0% 为画面顶部，100% 为底部。内嵌 ASS/SSA 字幕可能使用自己的字体和样式。未启用独立副字幕样式时，字体、颜色、描边和背景同时影响两轨。")
            }
            card("第二字幕") {
                Picker("第二字幕轨道", selection: binding(\.secondarySubtitleID)) {
                    Text("关闭").tag(0)
                    ForEach(player.tracks.filter { $0.type == "sub" }) { track in Text(track.label).tag(track.id) }
                }.disabled(!player.loaded)
                adjustment("第二字幕位置", key: \.secondarySubtitlePosition, range: 0...100, step: 1, format: "%.0f%%")
                HStack {
                    Text("副字幕延迟"); Spacer()
                    Text(String(format: "%+.1f 秒", player.settings.processing.secondarySubtitleDelay)).monospacedDigit()
                    Stepper("副字幕延迟", value: Binding(
                        get: { player.settings.processing.secondarySubtitleDelay },
                        set: { delay in player.updateSettings { $0.processing.secondarySubtitleDelay = delay } }),
                        in: -600...600, step: 0.1).labelsHidden().accessibilityLabel("副字幕延迟")
                }
                SecondarySubtitleStyleControls(player: player)
                note("加载两份字幕后，可在此选择另一条轨道。主、副字幕可以分别调整位置和延迟。")
            }
        }
    }

    private var playbackControls: some View {
        VStack(spacing: 16) {
            card("解码与缓存") {
                Picker("视频解码", selection: binding(\.hardwareDecoder)) {
                    Text("Apple 硬件解码").tag("videotoolbox")
                    Text("硬件解码并复制帧").tag("videotoolbox-copy")
                    Text("软件解码").tag("no")
                }
                note("支持的格式使用 Apple 芯片硬件解码；不支持的格式会使用软件解码。")
                HStack {
                    Text("媒体缓存")
                    Spacer()
                    Picker("媒体缓存", selection: binding(\.cacheMB)) {
                        ForEach([16, 32, 64, 128, 256, 512, 1024, 2048], id: \.self) { size in Text("\(size) MB").tag(size) }
                        if ![16, 32, 64, 128, 256, 512, 1024, 2048].contains(player.settings.cacheMB) {
                            Text("\(player.settings.cacheMB) MB").tag(player.settings.cacheMB)
                        }
                    }.labelsHidden().frame(width: 140)
                }
                note("较大的缓存适合网络媒体，也会占用更多统一内存。")
                Toggle("打开媒体后自动播放", isOn: binding(\.autoplay))
            }
            card("首选语言") {
                draftField("音轨语言", text: $state.audioLanguagesDraft) {
                    player.updateSettings { $0.preferredAudioLanguages = state.audioLanguagesDraft }
                    state.audioLanguagesDraft = player.settings.preferredAudioLanguages
                }
                draftField("字幕语言", text: $state.subtitleLanguagesDraft) {
                    player.updateSettings { $0.preferredSubtitleLanguages = state.subtitleLanguagesDraft }
                    state.subtitleLanguagesDraft = player.settings.preferredSubtitleLanguages
                }
                note("按优先顺序输入语言代码，以逗号分隔，再按 Return 应用。例如 zh,zho,chi,en,eng。留空表示自动选择；打开下一份媒体时使用。")
            }
        }
    }

    private var appearanceControls: some View {
        VStack(spacing: 16) {
            card("外观与窗口") {
                Picker("主题", selection: binding(\.theme)) {
                    Text("深色").tag("dark"); Text("跟随系统").tag("system"); Text("浅色").tag("light")
                }
                Toggle("播放器窗口置顶", isOn: binding(\.keepOnTop))
                Toggle("播放时防止系统休眠", isOn: binding(\.preventSleep))
            }
            card("截图") {
                Picker("默认内容", selection: Binding(get: { player.settings.screenshot.mode }, set: { value in player.updateSettings { $0.screenshot.mode = value } })) {
                    ForEach(ScreenshotMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                Picker("保存格式", selection: binding(\.screenshotFormat)) {
                    Text("PNG · 无损").tag("png"); Text("JPEG · 小体积").tag("jpg"); Text("WebP").tag("webp")
                }
                HStack {
                    Text("JPEG / WebP 质量")
                    Slider(value: Binding(get: { Double(player.settings.screenshot.quality) }, set: { value in player.updateSettings { $0.screenshot.quality = Int(value) } }), in: 1...100, step: 1)
                    Text("\(player.settings.screenshot.quality)").monospacedDigit().frame(width: 30)
                }
                Text(player.selectedScreenshotDirectory.path).font(.caption).textSelection(.enabled)
                HStack {
                    Button("选择文件夹…") { player.chooseScreenshotDirectory() }
                    Button("恢复默认位置") { player.updateSettings { $0.screenshot.directory = "" } }
                    Spacer()
                    Button("复制当前截图") { player.copyScreenshotAsync() }.disabled(!player.loaded || player.screenshotBusy)
                }
                if !player.screenshotStatus.isEmpty {
                    HStack {
                        if player.screenshotBusy { ProgressView().controlSize(.small) }
                        Text(player.screenshotStatus).font(.caption).textSelection(.enabled)
                    }
                }
                note("当前渲染画面包含缩放后的视频、字幕和视频 OSD；不会包含播放器按钮。PNG 保持无损，质量设置用于 JPEG / WebP。")
            }
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
    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func binding<Value>(_ key: WritableKeyPath<PlaybackSettings, Value>) -> Binding<Value> {
        Binding(get: { player.settings[keyPath: key] }, set: { value in player.updateSettings { $0[keyPath: key] = value } })
    }
    private func adjustment(_ title: String, key: WritableKeyPath<PlaybackSettings, Double>, range: ClosedRange<Double>, step: Double, format: String = "%+.0f", reset: Double = 0) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 88, alignment: .leading)
            Slider(value: binding(key), in: range, step: step)
                .accessibilityLabel(Text(title))
                .accessibilityIdentifier("advanced.adjustment.\(title).slider")
            Text(String(format: format, player.settings[keyPath: key])).font(.caption.monospacedDigit()).frame(width: 50, alignment: .trailing)
            Button { player.updateSettings { $0[keyPath: key] = reset } } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("重置\(title)")
                .accessibilityLabel(Text("重置\(title)"))
                .accessibilityIdentifier("advanced.adjustment.\(title).reset")
        }
    }
    private func equalizerBinding(_ index: Int) -> Binding<Double> {
        Binding(get: { player.settings.equalizer[index] }, set: { value in player.updateSettings { $0.equalizer[index] = value } })
    }
    private var selectedEqualizerPreset: EqualizerPreset? { EqualizerPreset.matching(gains: player.settings.equalizer) }
    private func setEqualizer(_ values: [Double]) {
        player.updateSettings { $0.equalizer = values; $0.equalizerEnabled = true }
    }
    private func draftField(_ title: String, text: Binding<String>, onSubmit: @escaping () -> Void) -> some View {
        HStack {
            Text(title).frame(width: 86, alignment: .leading)
            TextField("自动选择", text: text).onSubmit(onSubmit)
        }
    }
    private var subtitleColorBinding: Binding<Color> {
        Binding(get: {
            let raw = player.settings.subtitleColor.dropFirst()
            let rgb = UInt32(raw, radix: 16) ?? 0xFFFFFF
            return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        }, set: { value in
            guard let rgb = NSColor(value).usingColorSpace(.deviceRGB) else { return }
            let color = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
            player.updateSettings { $0.subtitleColor = color }
        })
    }
    private func synchronizeDrafts() {
        state.fontDraft = player.settings.subtitleFont
        state.audioLanguagesDraft = player.settings.preferredAudioLanguages
        state.subtitleLanguagesDraft = player.settings.preferredSubtitleLanguages
    }
}
