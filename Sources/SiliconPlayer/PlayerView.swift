import SwiftUI
import AppKit
import PlayerCore

private final class ScrubState: ObservableObject {
    @Published var value = 0.0
    @Published var isEditing = false
    @Published var search = ""
    @Published var preview: NSImage?
    var previewWork: DispatchWorkItem?
}

private final class QueueViewState: ObservableObject {
    @Published var selection: Set<UUID> = []
    @Published var canvasDropTargeted = false
    @Published var playlistDropTargeted = false
    let dragSession = UUID()
}

// Opt-in private manual-suite diagnostics; never synthesize or consume an event.
@MainActor private enum QueueDragTrace {
    static let enabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["SILICONPLAYER_VERIFY_MODE"] == "native-ui-manual"
            && env["SILICONPLAYER_VERIFY_QUEUE_DRAG_TRACE"] == "1"
            && InputController.verificationSuiteName(environment: env) != nil
    }()
    private static var sequence = 0
    private static var stageCounts: [String: Int] = [:]
    static func record(_ stage: String, _ fields: [String: Any] = [:]) {
        guard enabled, sequence < 768 else { return }
        let count = stageCounts[stage, default: 0]
        guard count < 64 else { return }
        stageCounts[stage] = count + 1
        sequence += 1
        var row = fields
        row["stage"] = stage; row["sequence"] = sequence
        row["uptime"] = ProcessInfo.processInfo.systemUptime
        row["pid"] = ProcessInfo.processInfo.processIdentifier
        row["stageSample"] = count + 1
        row["stageLimit"] = 64; row["totalLimit"] = 768
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        NSLog("SPQueueDragTrace %@", line)
    }
    static func indexes(_ value: IndexSet) -> [Int] { Array(value.prefix(128)) }
    static func uuids<S: Sequence>(_ value: S) -> [String] where S.Element == UUID {
        value.prefix(128).map(\.uuidString)
    }
}

private let accent = Color(red: 0.41, green: 0.88, blue: 0.75)

struct PlayerView: View {
    @ObservedObject var player: PlayerModel
    @StateObject private var scrubState = ScrubState()
    @StateObject private var queueState = QueueViewState()
    private let capabilities = AppCapabilities.current
    private var expandedTools: Bool { capabilities.profile == .full }
    private var showsTimelineFrames: Bool { expandedTools && capabilities.hasMediaTools }
    private var timelinePreviewWidth: CGFloat { showsTimelineFrames ? 180 : 84 }
    private var hasVideo: Bool { player.loaded && player.tracks.contains { $0.type == "video" } }

    var body: some View {
        VStack(spacing: 0) {
            if !player.miniMode { header }
            HStack(spacing: 0) {
                ZStack {
                    VideoSurface(player: player)
                    if [.entering, .active, .exiting].contains(player.systemPiPState) {
                        VStack(spacing: 14) {
                            Image(systemName: "pip").font(.system(size: 36)).foregroundStyle(accent)
                            Text(player.systemPiPState == .active ? "正在画中画中播放" : player.systemPiPState == .entering ? "正在进入画中画…" : "正在返回主窗口…")
                            Button("返回主窗口") { player.toggleSystemPiP() }.disabled(player.systemPiPState != .active)
                        }.padding(26).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    if !player.loaded && !player.isLoading { welcome }
                    if player.isLoading {
                        VStack(spacing: 16) {
                            ProgressView()
                            Text(player.currentIsWebMedia ? "正在解析并加载网页媒体…" : "正在加载媒体…").foregroundStyle(.secondary)
                            Button("取消加载") { player.stopPlayback() }
                        }
                            .padding(28).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                    if !player.message.isEmpty {
                        VStack { Spacer(); Text(player.message).font(.callout).padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule()).padding(.bottom, 20) }
                            .allowsHitTesting(false)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contextMenu { playbackContextMenu }
                    .onDrop(of: [.fileURL, .url], isTargeted: $queueState.canvasDropTargeted) { providers in
                        DropLoader.load(providers) { player.open($0, append: false) }
                        return !providers.isEmpty
                    }
                    .overlay {
                        if queueState.canvasDropTargeted {
                            Rectangle().strokeBorder(accent, lineWidth: 2).allowsHitTesting(false)
                        }
                    }
                if player.showPlaylist && !player.miniMode { playlistPanel.frame(width: 260) }
            }
            if !player.miniMode { controls }
            else { miniControls }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .foregroundStyle(.primary)
        .tint(accent)
        .preferredColorScheme(player.settings.theme == "dark" ? .dark : player.settings.theme == "light" ? .light : nil)
        .frame(minWidth: player.miniMode ? 360 : 760, minHeight: player.miniMode ? 220 : 500)
        .background(WindowAccessor())
        .alert("播放提示", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) {
            Button("好", role: .cancel) { player.error = nil }
        } message: { Text(player.error ?? "") }
        .sheet(isPresented: $player.showInspector) { MediaInspectorView(player: player) }
        .sheet(isPresented: Binding(
            get: { player.showAdvanced && !AdvancedWindowDiagnosticPresenter.enabled },
            set: { if !AdvancedWindowDiagnosticPresenter.enabled { player.showAdvanced = $0 } })) { AdvancedControlsView(player: player) }
        .onAppear {
            if AdvancedWindowDiagnosticPresenter.enabled {
                AdvancedWindowDiagnosticPresenter.shared.requestSynchronization(player: player)
            }
        }
        .onReceive(player.$showAdvanced) { _ in
            if AdvancedWindowDiagnosticPresenter.enabled {
                AdvancedWindowDiagnosticPresenter.shared.requestSynchronization(player: player)
            }
        }
        .sheet(isPresented: $player.showLibrary) { LibraryToolsView(player: player) }
        .sheet(isPresented: $player.showShortcuts) { ShortcutSettingsView(player: player) }
        .sheet(isPresented: $player.showTools) { MediaToolsView(player: player) }
        .sheet(isPresented: $player.showCapture) { CaptureToolsView(player: player) }
        .sheet(isPresented: $player.showTranslation) { SubtitleTranslationView(player: player) }
        .sheet(isPresented: $player.showLiveASR) { LiveASRView(player: player, controller: player.liveASR) }
        .sheet(isPresented: $player.showThumbnails) { ThumbnailToolsView(player: player) }
        .sheet(isPresented: $player.showNetwork) { NetworkMediaView(player: player) }
        .sheet(isPresented: $player.showWebMedia) { WebMediaView(player: player) }
        .sheet(isPresented: $player.showMediaPreferences) {
            MediaPreferencesView(controller: player.mediaPreferences,
                saveCurrent: { _ = player.saveCurrentMediaPreferences() },
                restoreCurrent: { player.restoreCurrentMediaPreferences() },
                clearCurrent: { _ = player.clearCurrentMediaPreferences() })
        }
        .sheet(isPresented: $player.showProfileBackup) { UserProfileBackupView(controller: player.profileBackup) }
        .sheet(isPresented: $player.showScriptExtensions) {
            ExplicitScriptView(controller: player.explicitScripts) { player.showScriptExtensions = false }
        }
        .disabled(player.profileRecoveryBlocked)
        .onChange(of: player.playlist.items.map(\.id)) { _, _ in pruneQueueSelection(); player.persistQueue() }
        .onChange(of: player.playlist.currentIndex) { _, _ in player.persistQueue() }
        .onChange(of: scrubState.search) { _, _ in pruneQueueSelection() }
        .onChange(of: scrubState.value) { _, _ in updateTimelinePreview() }
        .onChange(of: scrubState.isEditing) { _, editing in
            if editing { updateTimelinePreview() }
            else { scrubState.previewWork?.cancel(); scrubState.preview = nil; if !ThumbnailTools.shared.generatingSheet { ThumbnailTools.shared.cancel() } }
        }
        .onChange(of: player.currentURL) { _, _ in scrubState.previewWork?.cancel(); scrubState.preview = nil }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.square.stack.fill").font(.title3).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.playlist.currentItem?.title ?? "SiliconPlayer").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(player.loaded ? player.videoInfo : capabilities.profile == .core ? "Apple Silicon · 日常播放版" : "为 Apple Silicon 构建的原生播放器")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if player.loaded {
                Text(player.decoder.uppercased()).font(.system(size: 9, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 5).foregroundStyle(accent)
                    .background(accent.opacity(0.09), in: Capsule())
            } else {
                Text("ARM64").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }
            iconButton("books.vertical", "书签与收藏") { player.showLibrary = true }
            iconButton("pip", "系统画中画", active: player.systemPiPState == .active) { player.toggleSystemPiP() }
                .disabled(!player.systemPiPAvailable || [.entering, .exiting].contains(player.systemPiPState)
                          || !player.loaded || !player.tracks.contains(where: { $0.type == "video" }))
            iconButton("slider.horizontal.3", "播放设置 ⌘,") { player.showAdvanced = true }
            iconButton("folder", "打开媒体 ⌘O") { player.openPanel() }
            iconButton("info.circle", "媒体信息 ⌘I") { player.showInspector = true }
            iconButton("sidebar.right", "播放列表 ⌘L", active: player.showPlaylist) { player.showPlaylist.toggle() }
        }.padding(.horizontal, 18).padding(.vertical, 12)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1) }
    }
    private var welcome: some View {
        VStack(spacing: 18) {
            if !player.restoredQueueOnStartup {
                ZStack {
                    RoundedRectangle(cornerRadius: 24).fill(accent.opacity(0.08)).frame(width: 94, height: 94)
                    Image(systemName: "play.fill").font(.system(size: 34)).foregroundStyle(accent).offset(x: 3)
                }
            }
            if player.restoredQueueOnStartup, let item = player.playlist.currentItem {
                Text("已恢复 \(player.playlist.items.count) 项播放列表").font(.system(size: 25, weight: .semibold))
                Text(item.title).font(.system(size: 13)).foregroundStyle(.secondary)
                    .lineLimit(2).padding(.horizontal, 28)
                Button { player.togglePause() } label: {
                    Label("继续上次", systemImage: "play.fill").padding(.horizontal, 14).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent)
                    .accessibilityLabel("继续上次播放")
            } else {
                Text("让每一帧，流畅呈现").font(.system(size: 25, weight: .semibold))
                Text("拖入视频、音频或文件夹，即刻播放").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { player.openPanel() } label: { Label("打开媒体", systemImage: "folder").padding(.horizontal, 14).padding(.vertical, 5) }.buttonStyle(.borderedProminent)
                Button { player.openURLPanel() } label: { Label("网络地址", systemImage: "link").padding(.vertical, 5) }.buttonStyle(.bordered)
                if capabilities.hasWebMediaExtractor {
                    Button { player.showWebMedia = true } label: { Label("网页视频", systemImage: "globe").padding(.vertical, 5) }.buttonStyle(.bordered)
                }
            }.padding(.top, 4)
            Text("MKV · MP4 · MOV · FLAC · ASS / SRT").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).padding(.top, 12)
            Text("空格 暂停   ← → 快进退   F 全屏").font(.system(size: 11)).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.white).background(Color.black)
    }
    private var playlistPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("播放列表").font(.system(size: 12, weight: .semibold))
                Text("\(player.playlist.items.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                iconButton("plus", "添加媒体 ⇧⌘O") { player.openPanel(append: true) }
            }.padding(16)
            HStack(spacing: 6) {
                TextField("筛选播放列表", text: $scrubState.search).textFieldStyle(.roundedBorder)
                if !scrubState.search.isEmpty {
                    Button { scrubState.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("清除播放列表筛选").help("清除筛选")
                }
            }.padding(.horizontal, 12).padding(.bottom, 10)
            if player.playlist.items.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("你的下一段精彩").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("添加文件，连续播放").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
            } else {
                if visibleQueueRows.isEmpty {
                    Text("没有匹配的媒体").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    QueueTableView(rows: visibleQueueRows, allItems: player.playlist.items,
                                   currentID: player.playlist.currentItem?.id, selection: $queueState.selection,
                                   dragSession: queueState.dragSession,
                                   play: { player.select($0) }, remove: { player.removePlaylistItems($0) },
                                   move: { player.movePlaylistItems($0, to: $1) },
                                   failed: { player.error = $0 },
                                   appendMedia: { player.open($0, append: true) != nil })
                }
            }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button("全选") { queueState.selection = Set(visibleQueueRows.map { $0.item.id }) }
                        .disabled(visibleQueueRows.isEmpty)
                    Text("已选 \(queueState.selection.count) 项").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button { removeQueueSelection() } label: { Image(systemName: "trash") }
                        .disabled(queueState.selection.isEmpty).help("移出选中的媒体（Delete）")
                }.buttonStyle(.borderless)
                Text("⌘ / ⇧ 多选 · 双击播放 · 拖动排序").font(.system(size: 9)).foregroundStyle(.tertiary)
            }.padding(12)
        }.background(Color.primary.opacity(0.035))
        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1) }
        .onDrop(of: [.fileURL, .url], isTargeted: $queueState.playlistDropTargeted) { providers in
            DropLoader.load(providers) { player.open($0, append: true) }
            return !providers.isEmpty
        }
        .overlay {
            if queueState.playlistDropTargeted {
                Rectangle().strokeBorder(accent, lineWidth: 2).allowsHitTesting(false)
            }
        }
    }
    private var visibleQueueRows: [QueueRow] {
        player.playlist.items.enumerated().compactMap { index, item in
            guard scrubState.search.isEmpty || item.title.localizedCaseInsensitiveContains(scrubState.search) else { return nil }
            return QueueRow(index: index, item: item)
        }
    }
    private func pruneQueueSelection() {
        queueState.selection.formIntersection(Set(visibleQueueRows.map { $0.item.id }))
    }
    private func removeQueueSelection() {
        player.removePlaylistItems(queueState.selection.intersection(Set(visibleQueueRows.map { $0.item.id })))
        queueState.selection.removeAll()
    }
    private var controls: some View {
        VStack(spacing: 13) {
            HStack(spacing: 12) {
                Text(TimeText.format(scrubState.isEditing ? scrubState.value : player.position)).frame(width: 55, alignment: .trailing)
                Slider(value: Binding(get: { scrubState.isEditing ? scrubState.value : player.position }, set: { scrubState.value = $0 }), in: 0...max(1, player.duration)) { editing in
                    if editing { scrubState.value = player.position; scrubState.isEditing = true }
                    else { player.seek(scrubState.value); scrubState.isEditing = false }
                }.disabled(!player.seekable || player.duration <= 0)
                .accessibilityLabel("播放进度")
                .overlay {
                    GeometryReader { geometry in
                        if scrubState.isEditing && player.currentURL?.isFileURL == true {
                            VStack(spacing: 5) {
                                if showsTimelineFrames {
                                    if let image = scrubState.preview { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 168, height: 94) }
                                    else { ProgressView().frame(width: 168, height: 94) }
                                }
                                Text(TimeText.format(scrubState.value)).font(.caption.monospacedDigit())
                            }.padding(6).frame(width: timelinePreviewWidth)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .offset(x: min(max(0, geometry.size.width - timelinePreviewWidth), max(0, geometry.size.width * scrubState.value / max(1, player.duration) - timelinePreviewWidth / 2)), y: showsTimelineFrames ? -137 : -38)
                        }
                    }.allowsHitTesting(false)
                }
                Text(TimeText.format(player.duration)).foregroundStyle(.secondary).frame(width: 55, alignment: .leading)
            }.font(.system(size: 11, design: .monospaced))
            HStack(spacing: 17) {
                iconButton("backward.end.fill", "上一个") { player.previous() }.disabled(player.playlist.items.isEmpty)
                iconButton("gobackward.5", "后退 5 秒 ←") { player.jump(-5) }.disabled(!player.seekable)
                Button { player.togglePause() } label: {
                    Image(systemName: player.paused ? "play.fill" : "pause.fill").font(.system(size: 19, weight: .semibold))
                        .frame(width: 42, height: 36).foregroundStyle(Color.black).background(accent, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).disabled(!player.loaded && (player.isLoading || player.playlist.currentItem == nil))
                    .accessibilityLabel(player.paused ? "播放" : "暂停").help("播放 / 暂停 空格")
                iconButton("stop.fill", "停止并清空画面 V") { player.stopPlayback() }.disabled(!player.loaded && !player.isLoading)
                iconButton("goforward.5", "快进 5 秒 →") { player.jump(5) }.disabled(!player.seekable)
                iconButton("forward.end.fill", "下一个") { player.next() }.disabled(player.playlist.items.isEmpty)
                Divider().frame(height: 18)
                iconButton(player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", "静音 M") { player.toggleMute() }
                Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0...100).frame(width: 78)
                    .accessibilityLabel("音量").help("音量（0–100%）")
                Spacer(minLength: 0)
                Menu {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4], id: \.self) { value in
                        Button(String(format: "%.2g× %@", value, player.speed == value ? "✓" : "")) { player.setSpeed(value) }
                    }
                } label: { Text(String(format: "%.2g×", player.speed)).font(.system(size: 12, weight: .medium, design: .monospaced)) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("播放速度").help("播放速度")
                Menu {
                    Button("关闭字幕\(player.subtitleID == 0 ? " ✓" : "")") { player.selectSubtitle(0) }
                    ForEach(player.tracks.filter { $0.type == "sub" }) { track in
                        Button(track.label + (player.subtitleID == track.id ? " ✓" : "")) { player.selectSubtitle(track.id) }
                    }
                    Divider()
                    Button("加载外部字幕…") { player.openPanel(subtitles: true) }
                    Button("字幕样式与双字幕…") { player.openSubtitleSettings() }
                    if capabilities.hasLiveSpeechRecognition { Button("实时中文字幕…") { player.showLiveASR = true } }
                } label: { Image(systemName: "captions.bubble") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("字幕").help("字幕")
                Menu {
                    ForEach(player.tracks.filter { $0.type == "audio" }) { track in
                        Button(track.label + (player.audioID == track.id ? " ✓" : "")) { player.selectAudio(track.id) }
                    }
                    if !player.tracks.contains(where: { $0.type == "audio" }) { Text("没有音轨") }
                    Divider()
                    Button("加载外部音轨…") { player.attachAudio() }.disabled(!player.loaded)
                    Button("均衡器与输出设备…") { openAudioSettings() }
                } label: { Image(systemName: "waveform") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("音轨").help("音轨")
                iconButton("repeat.1", "单文件循环", active: player.loopFile) { player.toggleLoop() }
                iconButton("a.circle", "设置 A / B / 清除循环", active: player.abStart != nil) { player.cycleAB() }.disabled(!player.seekable)
                iconButton("camera", "截图 ⌘S") { player.screenshot() }.disabled(player.screenshotBusy || !hasVideo)
                iconButton("arrow.up.left.and.arrow.down.right", "全屏 F") { NSApp.keyWindow?.toggleFullScreen(nil) }
            }.font(.system(size: 14))
        }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 18)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1) }
    }
    private func updateTimelinePreview() {
        scrubState.previewWork?.cancel()
        guard showsTimelineFrames,
              scrubState.isEditing, let source = player.currentURL, source.isFileURL,
              player.tracks.contains(where: { $0.type == "video" }), !ThumbnailTools.shared.generatingSheet else { return }
        let time = scrubState.value
        let work = DispatchWorkItem {
            ThumbnailTools.shared.frame(source: source, time: time) { image in
                if scrubState.isEditing && player.currentURL == source { scrubState.preview = image }
            }
        }
        scrubState.previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("媒体与同步设置").font(.title2.weight(.semibold)); Spacer(); Button("完成") { player.showInspector = false }.keyboardShortcut(.defaultAction) }
            GroupBox("当前媒体") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(player.playlist.currentItem?.title ?? "未打开媒体").font(.headline)
                    Text(player.videoInfo).foregroundStyle(.secondary)
                    Text("解码：\(player.decoder) · 引擎：\(player.string("mpv-version"))").font(.caption).foregroundStyle(.secondary)
                    Text("首版使用 OpenGL 渲染；HDR 输出尚未验证。").font(.caption).foregroundStyle(.secondary)
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox("字幕与声音") {
                VStack(spacing: 16) {
                    HStack { Text("字幕延迟"); Spacer(); Text(String(format: "%+.1f 秒", player.subtitleDelay)).monospacedDigit(); Stepper("", value: Binding(get: { player.subtitleDelay }, set: { player.setSubtitleDelay($0) }), in: -60...60, step: 0.1).labelsHidden() }
                    HStack { Text("声音延迟"); Spacer(); Text(String(format: "%+.1f 秒", player.audioDelay)).monospacedDigit(); Stepper("", value: Binding(get: { player.audioDelay }, set: { player.setAudioDelay($0) }), in: -10...10, step: 0.1).labelsHidden() }
                    HStack { Text("字幕大小"); Slider(value: Binding(get: { player.subtitleScale }, set: { player.setSubtitleScale($0) }), in: 0.5...2); Text(String(format: "%.0f%%", player.subtitleScale * 100)).monospacedDigit() }
                    HStack { Button("加载字幕…") { player.openPanel(subtitles: true) }; Spacer(); Button("重置同步") { player.setSubtitleDelay(0); player.setAudioDelay(0); player.setSubtitleScale(1) } }
                }.padding(8)
            }
            GroupBox("快捷键") {
                Text("空格 播放/暂停    ← → 跳转5秒    ↑ ↓ 音量\nF 全屏    M 静音    [ ] 倍速    . 逐帧    A 设置AB循环\n⌘O 打开文件    ⌘L 播放列表    ⌘S 截图").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }.padding(24).frame(width: 500).preferredColorScheme(.dark)
    }

    private var miniControls: some View {
        HStack {
            Button { player.togglePause() } label: { Image(systemName: player.paused ? "play.fill" : "pause.fill") }
                .accessibilityLabel(player.paused ? "播放" : "暂停")
                .help("播放 / 暂停 空格")
            Text(player.playlist.currentItem?.title ?? "SiliconPlayer").lineLimit(1).font(.caption)
            Spacer()
            Button { player.toggleMiniMode() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .accessibilityLabel("恢复播放器窗口")
                .help("恢复播放器窗口 ⇧⌘P")
        }.buttonStyle(.plain).padding(12)
    }
    @ViewBuilder private var playbackContextMenu: some View {
        Button(player.paused ? "播放" : "暂停") { player.togglePause() }
        Button("停止并清空画面") { player.stopPlayback() }.disabled(!player.loaded && !player.isLoading)
        Menu("播放") {
            Button("定位到时间…") { player.goToTimePanel() }.disabled(!player.seekable)
            Button("撤销 / 恢复上次跳转") { player.revertSeek() }.disabled(player.seekReturnPosition == nil || !player.loaded)
            Button("按关键帧后退 5 秒") { player.jumpKeyframe(-5) }.disabled(!player.seekable)
            Button("按关键帧快进 5 秒") { player.jumpKeyframe(5) }.disabled(!player.seekable)
            Button("前一帧") { player.frameStep(backward: true) }.disabled(!hasVideo || !player.seekable)
            Button("后一帧") { player.frameStep() }.disabled(!hasVideo || !player.seekable)
            Button("A / B 区间循环") { player.cycleAB() }.disabled(!player.seekable)
            Button("单文件循环") { player.toggleLoop() }
            Button("播放列表循环") { player.cyclePlaylistLoop() }
        }
        Menu("章节") { ForEach(player.chapters) { c in Button(c.title + " · " + TimeText.format(c.time)) { player.goToChapter(c.id) } } }.disabled(player.chapters.isEmpty)
        Menu("字幕") {
            Button("加载字幕…") { player.openPanel(subtitles: true) }
            Button("编辑字幕…") { player.openSubtitleEditor() }.disabled(!player.loaded)
            Button("字幕样式与双字幕…") { player.openSubtitleSettings() }
            if capabilities.hasLiveSpeechRecognition { Button("实时中文字幕…") { player.showLiveASR = true } }
        }
        Menu("音频") {
            Button("加载外部音轨…") { player.attachAudio() }.disabled(!player.loaded)
            ForEach(player.tracks.filter { $0.type == "audio" }) { t in Button(t.label) { player.selectAudio(t.id) } }
            Button("均衡器与声音处理…") { openAudioSettings() }
        }
        Button("添加当前位置书签") { player.addBookmark() }.disabled(!player.loaded)
        Button("收藏 / 取消收藏") { player.toggleFavorite() }.disabled(player.currentURL == nil)
        Divider()
        Button("画面、音频与播放设置…") { player.showAdvanced = true }
        Button("截图") { player.screenshot() }.disabled(player.screenshotBusy || !hasVideo)
        Button("迷你悬浮播放器") { player.toggleMiniMode() }
        Button("媒体统计") { player.showInspector = true }
    }

    private func openAudioSettings() {
        player.advancedSettingsInitialTab = "audio"
        player.showAdvanced = true
    }

    private func iconButton(_ icon: String, _ help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).foregroundStyle(active ? accent : Color.primary.opacity(0.75)).frame(minWidth: 17, minHeight: 22) }
            .buttonStyle(.plain).accessibilityLabel(help).help(help)
    }
}

private struct QueueRow {
    let index: Int
    let item: MediaItem
}

/// AppKit supplies standard Command/Shift selection and an unambiguous insertion row.
private struct QueueTableView: NSViewRepresentable {
    let rows: [QueueRow]
    let allItems: [MediaItem]
    let currentID: UUID?
    @Binding var selection: Set<UUID>
    let dragSession: UUID
    let play: (UUID) -> Void
    let remove: (Set<UUID>) -> Void
    let move: (Set<UUID>, PlaylistMoveTarget) -> Bool
    let failed: (String) -> Void
    var appendMedia: (([URL]) -> Bool)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(coordinator: context.coordinator)
    }

    @MainActor static func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let table = QueueNativeTable()
        table.identifier = NSUserInterfaceItemIdentifier("playlist-queue")
        table.headerView = nil
        table.rowHeight = 64
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("media"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.delegate = coordinator
        table.dataSource = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.playClickedRow(_:))
        table.removeSelection = { [weak coordinator] in coordinator?.removeSelectedRows() }
        table.playSelection = { [weak coordinator] in coordinator?.playSelectedRow() }
        if QueueDragTrace.enabled {
            table.dragTraceContext = { [weak coordinator] in coordinator?.dragTraceContext() ?? [:] }
            QueueDragTrace.record("table-created", coordinator.dragTraceContext())
        }
        table.registerForDraggedTypes([Coordinator.pasteboardType, .fileURL, .URL])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu
        coordinator.table = table
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        updateTable(context.coordinator)
    }

    @MainActor func updateTable(_ coordinator: Coordinator) {
        let needsReload = coordinator.parent.rows.map { $0.item.id } != rows.map { $0.item.id }
            || coordinator.parent.rows.map(\.index) != rows.map(\.index)
            || coordinator.parent.currentID != currentID
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        coordinator.updating = true
        if needsReload || table.numberOfRows != rows.count { table.reloadData() }
        let selectedRows = IndexSet(rows.enumerated().compactMap { selection.contains($0.element.item.id) ? $0.offset : nil })
        if selectedRows != table.selectedRowIndexes { table.selectRowIndexes(selectedRows, byExtendingSelection: false) }
        coordinator.updating = false
        if QueueDragTrace.enabled && needsReload { QueueDragTrace.record("table-order-updated", coordinator.dragTraceContext()) }
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        static let pasteboardType = NSPasteboard.PasteboardType(PlaylistDragPayload.typeIdentifier)
        var parent: QueueTableView
        weak var table: QueueNativeTable?
        var updating = false
        init(_ parent: QueueTableView) { self.parent = parent }
        func dragTraceContext() -> [String: Any] {
            ["session": parent.dragSession.uuidString,
             "visibleCount": parent.rows.count,
             "visibleOrder": QueueDragTrace.uuids(parent.rows.map { $0.item.id }),
             "allCount": parent.allItems.count,
             "allOrder": QueueDragTrace.uuids(parent.allItems.map(\.id)),
             "selectedRows": QueueDragTrace.indexes(table?.selectedRowIndexes ?? []),
             "selectedIDs": QueueDragTrace.uuids(selectedIDs.sorted { $0.uuidString < $1.uuidString }),
             "currentID": parent.currentID?.uuidString ?? "",
             "windowNumber": table?.window?.windowNumber ?? -1,
             "destinationSnapshot": table?.destinationSnapshot() ?? [:]]
        }
        private func traceDrag(_ stage: String, _ fields: [String: Any] = [:]) {
            guard QueueDragTrace.enabled else { return }
            QueueDragTrace.record(stage, dragTraceContext().merging(fields) { _, new in new })
        }
        private func dragInfo(_ info: NSDraggingInfo) -> [String: Any] {
            ["nativeDragSequence": info.draggingSequenceNumber,
             "sourceIsSameTable": (info.draggingSource as? NSTableView) === table,
             "sourceOperationMask": info.draggingSourceOperationMask.rawValue,
             "pasteboardItemCount": info.draggingPasteboard.pasteboardItems?.count ?? 0,
             "hasOurPasteboardType": info.draggingPasteboard.types?.contains(Self.pasteboardType) == true]
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            traceDrag("drag-session-begin", ["rows": QueueDragTrace.indexes(rowIndexes),
                "screenX": screenPoint.x, "screenY": screenPoint.y,
                "actualPoint": table?.pointSnapshot(screenPoint) ?? [:],
                "sourcePasteboard": QueueNativeTable.pasteboardSnapshot(session.draggingPasteboard)])
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            traceDrag("drag-session-end", ["operation": operation.rawValue,
                "screenX": screenPoint.x, "screenY": screenPoint.y,
                "actualPoint": table?.pointSnapshot(screenPoint) ?? [:],
                "sourcePasteboard": QueueNativeTable.pasteboardSnapshot(session.draggingPasteboard)])
        }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.rows.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("queue-row")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? QueueTableCell ?? QueueTableCell()
            cell.identifier = identifier
            let entry = parent.rows[row]
            cell.configure(entry, playing: entry.item.id == parent.currentID)
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating else { return }
            parent.selection = selectedIDs
        }
        var selectedIDs: Set<UUID> {
            guard let table else { return [] }
            return Set(table.selectedRowIndexes.compactMap { row in
                parent.rows.indices.contains(row) ? parent.rows[row].item.id : nil
            })
        }
        @objc func playClickedRow(_ sender: NSTableView) {
            guard parent.rows.indices.contains(sender.clickedRow) else { return }
            parent.play(parent.rows[sender.clickedRow].item.id)
        }
        func playSelectedRow() {
            guard let row = table?.selectedRow, parent.rows.indices.contains(row) else { return }
            parent.play(parent.rows[row].item.id)
        }
        @objc func removeSelectedRows() {
            let ids = selectedIDs
            guard !ids.isEmpty else { return }
            parent.remove(ids)
            parent.selection = []
        }
        func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pasteboard: NSPasteboard) -> Bool {
            traceDrag("write-rows-enter", ["rows": QueueDragTrace.indexes(rowIndexes), "rowCount": rowIndexes.count])
            let ids = rowIndexes.compactMap { row in parent.rows.indices.contains(row) ? parent.rows[row].item.id : nil }
            guard ids.count == rowIndexes.count,
                  let data = try? PlaylistDragPayload(sessionID: parent.dragSession, itemIDs: ids).encoded() else {
                traceDrag("write-rows-rejected", ["mappedCount": ids.count]); return false
            }
            pasteboard.clearContents()
            let result = pasteboard.setData(data, forType: Self.pasteboardType)
            traceDrag("write-rows-result", ["result": result, "payloadBytes": data.count, "ids": QueueDragTrace.uuids(ids)])
            return result
        }
        private func dropIDs(_ info: NSDraggingInfo) throws -> Set<UUID> {
            guard (info.draggingSource as? NSTableView) === table,
                  let data = info.draggingPasteboard.data(forType: Self.pasteboardType) else {
                traceDrag("drop-identity-rejected", dragInfo(info))
                throw PlaylistDragPayload.ValidationError.wrongSession
            }
            do {
                let ids = try PlaylistDragPayload.validatedIDs(data, sessionID: parent.dragSession,
                                                               availableIDs: Set(parent.allItems.map(\.id)))
                traceDrag("drop-payload-valid", dragInfo(info).merging([
                    "payloadBytes": data.count, "ids": QueueDragTrace.uuids(ids.sorted { $0.uuidString < $1.uuidString })
                ]) { _, new in new })
                return ids
            } catch {
                // This validator throws only the bounded PlaylistDragPayload.ValidationError enum.
                traceDrag("drop-payload-rejected", ["errorKind": String(describing: error), "payloadBytes": data.count])
                throw error
            }
        }
        private func externalDropURLs(_ info: NSDraggingInfo) -> [URL]? {
            // Internal rows always remain the UUID/session move route, even if
            // a foreign source supplies extra URL types beside that payload.
            guard parent.appendMedia != nil,
                  (info.draggingSource as? NSTableView) !== table,
                  let types = info.draggingPasteboard.types,
                  !types.contains(Self.pasteboardType),
                  types.contains(.fileURL) || types.contains(.URL),
                  let count = info.draggingPasteboard.pasteboardItems?.count,
                  count > 0, count <= 128,
                  let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil),
                  !objects.isEmpty, objects.count <= 128 else { return nil }
            let urls = objects.compactMap { ($0 as? NSURL).map { $0 as URL } }
            return urls.count == objects.count ? urls : nil
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            traceDrag("validate-enter", dragInfo(info).merging(["proposedRow": row, "dropOperation": dropOperation.rawValue]) { _, new in new })
            if externalDropURLs(info) != nil {
                // External files append to the full queue, not a filtered row's
                // insertion point. AppKit's whole-table marker reflects that.
                tableView.setDropRow(-1, dropOperation: .on)
                return .copy
            }
            guard !parent.rows.isEmpty, (0...parent.rows.count).contains(row), (try? dropIDs(info)) != nil else {
                traceDrag("validate-result", ["accepted": false]); return []
            }
            tableView.setDropRow(row, dropOperation: .above)
            traceDrag("validate-result", ["accepted": true, "effectiveRow": row])
            return .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            traceDrag("accept-enter", dragInfo(info).merging(["row": row, "dropOperation": dropOperation.rawValue]) { _, new in new })
            if let urls = externalDropURLs(info) {
                return parent.appendMedia?(urls) == true
            }
            do {
                let ids = try dropIDs(info)
                guard let target = PlaylistMoveTarget.visibleInsertion(ids: parent.rows.map { $0.item.id }, row: row) else {
                    traceDrag("accept-target-rejected", ["row": row]); return false
                }
                guard parent.move(ids, target) else { throw PlaylistDragPayload.ValidationError.staleItems }
                parent.selection = ids
                traceDrag("accept-result", ["accepted": true])
                return true
            } catch {
                traceDrag("accept-result", ["accepted": false, "errorKind": String(describing: error)])
                parent.failed(error.localizedDescription)
                return false
            }
        }
        func menuWillOpen(_ menu: NSMenu) {
            menu.removeAllItems()
            guard !selectedIDs.isEmpty else { return }
            if selectedIDs.count == 1 {
                addMenuItem("播放", action: #selector(playMenuRow), to: menu)
                if selectedItem?.url.isFileURL == true { addMenuItem("在 Finder 中显示", action: #selector(revealMenuRow), to: menu) }
                menu.addItem(.separator())
            }
            addMenuItem("向上移动", action: #selector(moveUp), to: menu).isEnabled = adjacentTarget(up: true) != nil
            addMenuItem("向下移动", action: #selector(moveDown), to: menu).isEnabled = adjacentTarget(up: false) != nil
            menu.addItem(.separator())
            addMenuItem("移出选中的 \(selectedIDs.count) 项", action: #selector(removeSelectedRows), to: menu)
        }
        @discardableResult private func addMenuItem(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return item
        }
        private var selectedItem: MediaItem? { parent.allItems.first { selectedIDs.contains($0.id) } }
        @objc private func playMenuRow() { if let item = selectedItem { parent.play(item.id) } }
        @objc private func revealMenuRow() { if let item = selectedItem { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } }
        private func adjacentTarget(up: Bool) -> PlaylistMoveTarget? {
            let ids = selectedIDs
            let items = parent.allItems
            if up, let first = items.firstIndex(where: { ids.contains($0.id) }), first > 0 {
                return .before(items[first - 1].id)
            }
            if !up, let last = items.lastIndex(where: { ids.contains($0.id) }), last + 1 < items.count {
                return .after(items[last + 1].id)
            }
            return nil
        }
        @objc private func moveUp() { if let target = adjacentTarget(up: true) { _ = parent.move(selectedIDs, target) } }
        @objc private func moveDown() { if let target = adjacentTarget(up: false) { _ = parent.move(selectedIDs, target) } }
    }
}

@MainActor private final class QueueNativeTable: NSTableView {
    var removeSelection: (() -> Void)?
    var playSelection: (() -> Void)?
    var dragTraceContext: (() -> [String: Any])?
    private static func rectangle(_ value: NSRect) -> [Double] {
        [Double(value.minX), Double(value.minY), Double(value.width), Double(value.height)]
    }
    static func pasteboardSnapshot(_ board: NSPasteboard) -> [String: Any] {
        let items = board.pasteboardItems ?? []
        return ["types": (board.types ?? []).prefix(64).map { String($0.rawValue.prefix(256)) },
                "itemCount": items.count,
                "itemTypes": items.prefix(32).map { $0.types.prefix(64).map { String($0.rawValue.prefix(256)) } },
                "hasOurType": board.types?.contains(NSPasteboard.PasteboardType(PlaylistDragPayload.typeIdentifier)) == true]
    }
    func destinationSnapshot() -> [String: Any] {
        guard QueueDragTrace.enabled else { return [:] }
        let actualSource = dataSource as? NSObject
        let actualDelegate = delegate as? NSObject
        var ancestors: [[String: Any]] = []
        var node: NSView? = self
        for _ in 0..<16 {
            guard let view = node else { break }
            ancestors.append(["class": String(describing: type(of: view)),
                "registeredTypes": view.registeredDraggedTypes.prefix(64).map { String($0.rawValue.prefix(256)) }])
            node = view.superview
        }
        var result: [String: Any] = ["bounds": Self.rectangle(bounds), "visibleRect": Self.rectangle(visibleRect),
            "frameInSuperview": Self.rectangle(frame), "isFlipped": isFlipped, "isHidden": isHidden,
            "registeredTypes": registeredDraggedTypes.prefix(64).map { String($0.rawValue.prefix(256)) },
            "dataSourceClass": actualSource.map { String(describing: type(of: $0)) } ?? "",
            "delegateClass": actualDelegate.map { String(describing: type(of: $0)) } ?? "",
            "sameDelegateAndDataSource": actualSource != nil && actualSource === actualDelegate,
            "respondsWriter": actualSource?.responds(to: NSSelectorFromString("tableView:writeRowsWithIndexes:toPasteboard:")) == true,
            "respondsValidate": actualSource?.responds(to: NSSelectorFromString("tableView:validateDrop:proposedRow:proposedDropOperation:")) == true,
            "respondsAccept": actualSource?.responds(to: NSSelectorFromString("tableView:acceptDrop:row:dropOperation:")) == true,
            "ancestors": ancestors]
        if let window {
            result["windowFrame"] = Self.rectangle(window.frame)
            result["tableScreenRect"] = Self.rectangle(window.convertToScreen(convert(bounds, to: nil)))
            result["visibleScreenRect"] = Self.rectangle(window.convertToScreen(convert(visibleRect, to: nil)))
            result["windowVisible"] = window.isVisible
            result["windowNumber"] = window.windowNumber
            result["screenFrame"] = window.screen.map { Self.rectangle($0.frame) } ?? []
        }
        return result
    }
    func pointSnapshot(_ screenPoint: NSPoint) -> [String: Any] {
        guard QueueDragTrace.enabled, let window else { return [:] }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let local = convert(windowPoint, from: nil)
        var result: [String: Any] = ["localX": local.x, "localY": local.y, "row": row(at: local),
            "inBounds": bounds.contains(local), "inVisibleRect": visibleRect.contains(local)]
        if let content = window.contentView {
            // NSView.hitTest consumes a point in its *superview* coordinates.
            let parentPoint = content.superview.map { $0.convert(windowPoint, from: nil) } ?? windowPoint
            let hit = content.hitTest(parentPoint)
            result["windowHitClass"] = hit.map { String(describing: type(of: $0)) } ?? ""
            result["windowHitIsTableOrDescendant"] = hit.map { $0 === self || $0.isDescendant(of: self) } ?? false
        }
        return result
    }
    private func traceSource(_ stage: String, _ session: NSDraggingSession, fields: [String: Any]) {
        guard QueueDragTrace.enabled else { return }
        var values = dragTraceContext?() ?? [:]
        values.merge(fields) { _, new in new }
        values["nativeDragSequence"] = session.draggingSequenceNumber
        values["sourcePasteboard"] = Self.pasteboardSnapshot(session.draggingPasteboard)
        values["sessionScreenX"] = session.draggingLocation.x
        values["sessionScreenY"] = session.draggingLocation.y
        values["sessionActualPoint"] = pointSnapshot(session.draggingLocation)
        values["mouseScreenX"] = NSEvent.mouseLocation.x
        values["mouseScreenY"] = NSEvent.mouseLocation.y
        values["actualModifierFlags"] = NSEvent.modifierFlags.rawValue
        values["applicationActive"] = NSApp.isActive
        values["ownWindowKey"] = window?.isKeyWindow == true
        values["ownWindowMain"] = window?.isMainWindow == true
        if let event = NSApp.currentEvent {
            values["currentEventType"] = event.type.rawValue
            values["currentEventWindowNumber"] = event.windowNumber
            values["currentEventModifierFlags"] = event.modifierFlags.rawValue
            values["currentEventTimestamp"] = event.timestamp
        }
        QueueDragTrace.record(stage, values)
    }
    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        traceSource("source-mask-before-super", session, fields: ["context": context.rawValue])
        let result = super.draggingSession(session, sourceOperationMaskFor: context)
        traceSource("source-mask-after-super", session, fields: ["context": context.rawValue, "superResult": result.rawValue])
        return result
    }
    override func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        // This protocol callback is optional. Never send a missing selector to
        // the base implementation merely to collect diagnostics.
        let originalExists = NSTableView.instancesRespond(to: NSSelectorFromString("draggingSession:movedToPoint:"))
        let fields: [String: Any] = ["screenX": screenPoint.x, "screenY": screenPoint.y,
            "actualPoint": pointSnapshot(screenPoint), "superImplementationExists": originalExists]
        traceSource("source-moved-before-super", session, fields: fields)
        if originalExists { super.draggingSession(session, movedTo: screenPoint) }
        traceSource("source-moved-after-super", session, fields: fields)
    }
    private func traceDestination(_ stage: String, _ sender: NSDraggingInfo?, result: Any? = nil) {
        guard QueueDragTrace.enabled else { return }
        var fields = dragTraceContext?() ?? [:]
        if let sender {
            fields["nativeDragSequence"] = sender.draggingSequenceNumber
            fields["destinationIsOwnWindow"] = sender.draggingDestinationWindow === window
            fields["sourceIsSameTable"] = (sender.draggingSource as? NSTableView) === self
            fields["sourceOperationMask"] = sender.draggingSourceOperationMask.rawValue
            fields["destinationPasteboard"] = Self.pasteboardSnapshot(sender.draggingPasteboard)
            if let destination = sender.draggingDestinationWindow {
                fields["actualPoint"] = pointSnapshot(destination.convertPoint(toScreen: sender.draggingLocation))
            }
        }
        if let result { fields["superResult"] = result }
        QueueDragTrace.record(stage, fields)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        traceDestination("destination-enter-before-super", sender)
        let result = super.draggingEntered(sender)
        traceDestination("destination-enter-after-super", sender, result: result.rawValue)
        return result
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        traceDestination("destination-update-before-super", sender)
        let result = super.draggingUpdated(sender)
        traceDestination("destination-update-after-super", sender, result: result.rawValue)
        return result
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        traceDestination("destination-exit-before-super", sender)
        super.draggingExited(sender)
        traceDestination("destination-exit-after-super", sender)
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        traceDestination("destination-prepare-before-super", sender)
        let result = super.prepareForDragOperation(sender)
        traceDestination("destination-prepare-after-super", sender, result: result)
        return result
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        traceDestination("destination-perform-before-super", sender)
        let result = super.performDragOperation(sender)
        traceDestination("destination-perform-after-super", sender, result: result)
        return result
    }
    private func traceNative(_ stage: String, _ event: NSEvent) {
        guard QueueDragTrace.enabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        QueueDragTrace.record(stage, (dragTraceContext?() ?? [:]).merging([
            "eventType": event.type.rawValue, "eventNumber": event.eventNumber,
            "eventTimestamp": event.timestamp, "eventWindowNumber": event.windowNumber,
            "buttonNumber": event.buttonNumber, "clickCount": event.clickCount,
            "modifierFlags": event.modifierFlags.rawValue,
            "localX": point.x, "localY": point.y, "hitRow": row(at: point),
            "verticalMotionCanBeginDrag": verticalMotionCanBeginDrag
        ]) { _, new in new })
    }
    override func mouseDown(with event: NSEvent) {
        guard QueueDragTrace.enabled else { super.mouseDown(with: event); return }
        traceNative("native-mouse-down-before-super", event)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] next in
            MainActor.assumeIsolated {
                if let self, let window = self.window, next.window === window {
                    self.traceNative(next.type == .leftMouseDragged ? "native-local-drag" : "native-local-up", next)
                }
                return next
            }
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            traceNative("native-mouse-down-after-super", event)
        }
        super.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        traceNative("native-mouse-dragged-dispatch", event)
        super.mouseDragged(with: event)
    }
    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        let result = super.canDragRows(with: rowIndexes, at: mouseDownPoint)
        QueueDragTrace.record("native-can-drag-rows", (dragTraceContext?() ?? [:]).merging([
            "rows": QueueDragTrace.indexes(rowIndexes), "rowCount": rowIndexes.count,
            "localX": mouseDownPoint.x, "localY": mouseDownPoint.y, "result": result
        ]) { _, new in new })
        return result
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        guard clicked >= 0 else { return nil }
        if !selectedRowIndexes.contains(clicked) { selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false) }
        return super.menu(for: event)
    }
    override func keyDown(with event: NSEvent) {
        if [51, 117].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            removeSelection?()
        } else if [36, 76].contains(event.keyCode) { playSelection?() }
        else { super.keyDown(with: event) }
    }
}

@MainActor private final class QueueTableCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let number = NSTextField(labelWithString: "")
    init() {
        super.init(frame: .zero)
        for view in [icon, title, detail, number] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 2
        detail.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        detail.textColor = .secondaryLabelColor
        number.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        number.textColor = .tertiaryLabelColor
        number.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: number.leadingAnchor, constant: -6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -7),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            number.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            number.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ row: QueueRow, playing: Bool) {
        title.stringValue = row.item.title
        detail.stringValue = row.item.url.isFileURL ? row.item.url.pathExtension.uppercased() : "网络媒体"
        number.stringValue = String(format: "%02d", row.index + 1)
        icon.image = NSImage(systemSymbolName: playing ? "waveform" : "play.rectangle", accessibilityDescription: playing ? "正在播放" : "媒体")
        icon.contentTintColor = playing ? NSColor(red: 0.41, green: 0.88, blue: 0.75, alpha: 1) : .secondaryLabelColor
        setAccessibilityLabel(row.item.title + (playing ? "，正在播放" : ""))
    }
}

private enum DropLoader {
    static func load(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls = [Int: URL]()
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                lock.lock(); if let url { urls[index] = url }; lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls.keys.sorted().compactMap { urls[$0] }) }
    }
}
