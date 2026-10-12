import SwiftUI
import AppKit

struct PlayerMenus: Commands {
    @ObservedObject var player: PlayerModel
    private let capabilities = AppCapabilities.current
    private var expandedTools: Bool { capabilities.profile == .full }
    private var hasVideo: Bool { player.loaded && player.tracks.contains { $0.type == "video" } }

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button(expandedTools ? "高级播放设置…" : "播放设置…") { player.showAdvanced = true }.keyboardShortcut(",")
            Button("快捷键设置…") { player.showShortcuts = true }
            Button("此媒体的设置…") { player.showMediaPreferences = true }
            Button("播放区间与结束动作…") { player.openPlaybackProgram() }.disabled(!player.loaded)
            Button("设置备份与恢复…") { player.showProfileBackup = true }
        }
        CommandMenu("视频") {
            Button("画面与滤镜设置…") {
                player.advancedSettingsInitialTab = "video"
                player.showAdvanced = true
            }
            if expandedTools { Button("GLSL 与 LUT 资源…") { player.showVideoAssetsPanel() } }
            Button("顺时针旋转 90°") { player.updateSettings { $0.rotation = ($0.rotation + 90) % 360 } }
            Button("水平镜像") { player.updateSettings { $0.flipHorizontal.toggle() } }
            Button("垂直翻转") { player.updateSettings { $0.flipVertical.toggle() } }
            Button("去隔行") { player.updateSettings { $0.deinterlace.toggle() } }
            Divider()
            Button(player.systemPiPState == .active ? "返回主窗口" : "系统画中画") { player.toggleSystemPiP() }
                .disabled(!player.systemPiPAvailable || [.entering, .exiting].contains(player.systemPiPState)
                          || (!player.loaded && player.systemPiPState != .active)
                          || !player.tracks.contains(where: { $0.type == "video" }))
            Button("迷你悬浮播放器") { player.toggleMiniMode() }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("窗口置顶") { player.updateSettings { $0.keepOnTop.toggle() } }
        }
        CommandMenu("音频") {
            if expandedTools {
            Toggle("连续音频（本次会话）", isOn: Binding(get: { player.continuousAudioEnabled },
                set: { player.nativeAudioQueue.setEnabled($0) }))
                .disabled(player.profileRecoveryBlocked)
            Button(player.continuousAudioStatus) {}.disabled(true)
            Button("连续音频的适用范围…") {
                let alert = NSAlert(); alert.messageText = "连续音频"
                alert.informativeText = "本次会话显式启用。仅预检通过的本地单音轨、同参数 WAV/FLAC 可接续；每段最多 8 首。音频滤镜（含限幅）、外置轨道、保存的媒体设置、恢复点或输出不兼容时保留设置并普通切换。下一段会重新预检。此功能仍需真实输出层验证，不能保证设备端零间隙。"
                alert.addButton(withTitle: "知道了"); alert.runModal()
            }
            Divider()
            }
            Button("音轨、均衡器与输出设备…") {
                player.advancedSettingsInitialTab = "audio"
                player.showAdvanced = true
            }
            Button("加载外部音轨…") { player.attachAudio() }.disabled(!player.loaded)
            Button("静音") { player.toggleMute() }
        }
        CommandMenu("字幕") {
            Button("加载字幕…") { player.openPanel(subtitles: true) }
            Button("显示 / 隐藏字幕") { player.updateSettings { $0.subtitleVisible.toggle() } }
            Button("字幕样式与双字幕…") { player.openSubtitleSettings() }
            Button("字幕编辑器…") { player.openSubtitleEditor() }.disabled(!player.loaded)
            if expandedTools { Button("字幕翻译与朗读…") { player.showTranslation = true } }
            if capabilities.hasLiveSpeechRecognition { Button("实时中文字幕…") { player.showLiveASR = true } }
            Divider()
            Button("字幕提前 0.1 秒") { player.setSubtitleDelay(player.subtitleDelay - 0.1) }.disabled(!player.loaded)
            Button("字幕延后 0.1 秒") { player.setSubtitleDelay(player.subtitleDelay + 0.1) }.disabled(!player.loaded)
            if capabilities.hasOfflineSpeechRecognition { Button("生成语音字幕…") { player.showTools = true } }
        }
        CommandMenu("导航") {
            Button("定位到时间…") { player.goToTimePanel() }.keyboardShortcut("g").disabled(!player.seekable)
            Button("撤销 / 恢复上次跳转") { player.revertSeek() }.disabled(!player.loaded || player.seekReturnPosition == nil)
            Button("按关键帧后退 5 秒") { player.jumpKeyframe(-5) }.disabled(!player.seekable)
            Button("按关键帧快进 5 秒") { player.jumpKeyframe(5) }.disabled(!player.seekable)
            Divider()
            Menu("章节") { ForEach(player.chapters) { c in Button(c.title) { player.goToChapter(c.id) } } }.disabled(player.chapters.isEmpty)
            Button("上一章节") { player.jumpChapter(-1) }.disabled(player.chapters.isEmpty || !player.seekable)
            Button("下一章节") { player.jumpChapter(1) }.disabled(player.chapters.isEmpty || !player.seekable)
            Divider()
            Button("添加当前位置书签") { player.addBookmark() }.keyboardShortcut("b").disabled(!player.loaded)
            Button("收藏 / 取消收藏") { player.toggleFavorite() }.disabled(player.currentURL == nil)
            Button("书签与收藏…") { player.showLibrary = true }.keyboardShortcut("b", modifiers: [.command, .shift])
            Menu("睡眠定时") {
                ForEach([15, 30, 45, 60, 90], id: \.self) { m in Button("\(m) 分钟后暂停") { player.setSleepTimer(minutes: m) } }
                Button("取消定时") { player.setSleepTimer(minutes: 0) }
            }
        }
        CommandMenu("播放列表") {
            Button("导入 M3U / PLS…") { player.importPlaylist() }
            Button("网络频道与 WebDAV…") { player.showNetwork = true }
            if expandedTools { Button("FTP / FTPS 文件…") { FTPBrowserWindow.show(player: player) } }
            Button("目录扫描与监控…") { DirectoryLibraryWindow.show(player: player) }
            Button("导出 M3U8…") { player.exportPlaylist() }.disabled(player.playlist.items.isEmpty)
            Button("导出 PLS…") { player.exportPlaylist(format: .pls) }.disabled(player.playlist.items.isEmpty)
            Button("保存命名播放列表…") { player.saveNamedPlaylist() }.disabled(player.playlist.items.isEmpty)
            Divider()
            Button("按文件名排序") { player.sortPlaylist() }.disabled(player.playlist.items.count < 2)
            Button("随机排列") { player.shufflePlaylist() }.disabled(player.playlist.items.count < 2)
            Button("列表循环") { player.cyclePlaylistLoop() }
            Button("打开另一个播放器") { player.newPlayerInstance() }
        }
        CommandMenu("工具") {
            Button("目录／列表打开进度…") { OrdinaryMediaOpenWindow.show(controller: player.ordinaryMediaOpen) }
            if expandedTools { Button("Lua / JavaScript 扩展…") { player.showScriptExtensions = true } }
            if capabilities.hasMediaTools {
                Button(capabilities.hasOfflineSpeechRecognition ? "录制、导出与语音字幕…" : "片段与音频导出…") { player.showTools = true }
                Button("时间缩略图与拼图…") { player.showThumbnails = true }
            }
            if expandedTools { Button("屏幕与摄像头采集…") { player.showCapture = true } }
            Button("截图（包含字幕）") { player.screenshot() }.disabled(player.screenshotBusy || !hasVideo)
            Button("截图（仅视频）") { player.saveScreenshotAsync(mode: .video) }.disabled(player.screenshotBusy || !hasVideo)
            Button("截图（当前渲染画面）") { player.saveScreenshotAsync(mode: .window) }.disabled(player.screenshotBusy || !hasVideo)
            Button("截图另存为…") { player.screenshotSavePanel() }.disabled(player.screenshotBusy || !hasVideo)
            Button("复制截图到剪贴板") { player.copyScreenshotAsync() }.disabled(player.screenshotBusy || !hasVideo)
            Button("截图目录") { NSWorkspace.shared.open(player.selectedScreenshotDirectory) }
        }
    }
}
