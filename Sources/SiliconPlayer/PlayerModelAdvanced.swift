import AppKit
import CMPV
import PlayerCore
import UniformTypeIdentifiers

struct AudioOutputDevice: Identifiable {
    let id: String
    let name: String
    let description: String
}
struct MediaChapter: Identifiable {
    let id: Int
    let title: String
    let time: Double
}

extension PlayerModel {
    var playerWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "player" }
            ?? NSApp.windows.first { $0.title == "SiliconPlayer" && $0.sheetParent == nil }
    }
    private typealias QueueDocument = PlaybackQueueDocument
    var recentMedia: [PlaybackHistoryEntry] { Array(history.recentEntries.prefix(200)) }
    private static var queueURL: URL { preferenceURL.deletingLastPathComponent().appendingPathComponent("queue.json") }
    func restoreQueue() {
        guard let data = try? Data(contentsOf: Self.queueURL) else { return }
        do {
            let queue = try JSONDecoder().decode(QueueDocument.self, from: data)
            let restoredItems = queue.items.map { item -> MediaItem in
                guard item.webMedia == nil,
                      let selection = webMediaCatalog.selection(for: item.url),
                      let restored = try? MediaItem(webPageURL: item.url, selection: selection, id: item.id) else { return item }
                return restored
            }
            playlist.add(items: restoredItems)
            if let index = queue.selectedIndex, queue.items.indices.contains(index),
               let restored = playlist.items.first(where: { $0.url == queue.items[index].url }) {
                _ = playlist.select(id: restored.id)
            }
        } catch { toast("上次播放列表无法恢复") }
    }
    func persistQueue() {
        do {
            try FileManager.default.createDirectory(at: Self.queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(QueueDocument(items: playlist.items, selectedIndex: playlist.currentIndex)).write(to: Self.queueURL, options: .atomic)
        } catch { toast("播放列表保存失败") }
    }
    func removePlaylistItems(_ ids: Set<UUID>) {
        let valid = ids.intersection(Set(playlist.items.map(\.id)))
        guard !valid.isEmpty else { return }
        let intendedStart = continuousAudioEnabled ? nativeAudioQueue.currentIntent : nil
        let removesCurrent = playlist.currentItem.map { valid.contains($0.id) } ?? false
        if removesCurrent { saveHistory() }
        let count = playlist.remove(ids: valid)
        if removesCurrent {
            if playlist.currentItem != nil { playSelected(startPlaying: intendedStart) }
            else { stopPlayback() }
        }
        persistQueue()
        toast("已移出 \(count) 项")
    }
    @discardableResult
    func movePlaylistItems(_ ids: Set<UUID>, to target: PlaylistMoveTarget) -> Bool {
        guard playlist.move(ids: ids, to: target) else { return false }
        persistQueue()
        return true
    }
    var currentURL: URL? { playlist.currentItem?.url }
    static var supportDirectory: URL {
        if ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_REPORT"] != nil,
           let path = ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_STORAGE"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiliconPlayer", isDirectory: true)
    }
    static var preferenceURL: URL {
        supportDirectory.appendingPathComponent("preferences.json")
    }
    func restorePreferences() {
        do {
            if FileManager.default.fileExists(atPath: Self.preferenceURL.path) {
                settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data(contentsOf: Self.preferenceURL)).sanitized()
            }
        } catch { toast("设置文件无法读取，已使用默认设置") }
        installGlobalBaseSettings(settings)
        applySettings()
    }
    func updateSettings(_ edit: (inout PlaybackSettings) -> Void) {
        guard !profileStoresBlocked else { return }
        let oldSecondary = settings.secondarySubtitleID
        let oldSecondaryDelay = settings.processing.secondarySubtitleDelay
        mediaPreferences.updateSettings { value in
            edit(&value)
            if sameMediaTrackStream(Int(string("sid")) ?? 0, value.secondarySubtitleID, kind: .subtitle) {
                value.secondarySubtitleID = 0
            }
        }
        synchronizeMediaPreferenceSettings()
        if oldSecondary != settings.secondarySubtitleID && !applyingMediaPreferenceRestoration {
            mediaPreferences.markTrackSelectionEdited(kind: .subtitle, secondary: true)
        }
        if oldSecondaryDelay != settings.processing.secondarySubtitleDelay && !applyingMediaPreferenceRestoration {
            mediaPreferences.cancelPendingTrackRestoration()
        }
        settingsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applySettings(); self.persistSettings()
        }
        settingsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    func resetSettings() {
        guard !profileStoresBlocked else { return }
        guard secondarySubtitleStyle.apply(nil) else { error = secondarySubtitleStyle.status; return }
        var defaults = PlaybackSettings()
        if let owned = Self.privateManualScreenshotDirectory(environment: ProcessInfo.processInfo.environment) {
            defaults.screenshot.directory = owned.path
        }
        installGlobalBaseSettings(defaults); userVideoFilters.cancelPending(reason: "已恢复默认设置")
        userVideoFilters.removeAll(); applySettings(); persistSettings()
    }
    func persistSettings() { _ = persistSettingsChecked() }
    @discardableResult func persistSettingsChecked() -> Bool {
        guard !profileStoresBlocked else { return false }
        do {
            try FileManager.default.createDirectory(at: Self.preferenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(mediaPreferences.baseSnapshot).write(to: Self.preferenceURL, options: .atomic)
            return true
        } catch { toast("设置保存失败：\(error.localizedDescription)"); return false }
    }
    func applySettings() {
        let display = videoHost?.video
        guard display?.beginBaseSettingsUpdate() ?? true else {
            error = "显示色彩事务仍在处理，设置尚未应用"; return
        }
        defer { display?.endBaseSettingsUpdate() }
        var s = settings.sanitized()
        // Limit this application only; the full edition's saved choices remain
        // in settings/baseSnapshot and are not rewritten by the core profile.
        if AppCapabilities.current.profile == .core {
            s.processing.pitchSemitones = 0
            s.processing.audioSampleRate = 0
            s.processing.audioExclusive = false
        }
        let p = s.processing
        if !secondarySubtitleStyle.apply(s.secondarySubtitleStyle) { error = secondarySubtitleStyle.status }
        let properties: [String: String] = [
            "brightness": String(s.brightness), "contrast": String(s.contrast), "saturation": String(s.saturation),
            "gamma": String(s.gamma), "hue": String(s.hue), "video-rotate": String(s.rotation),
            "video-aspect-override": s.aspect == "2.35:1" ? "2.35" : s.aspect,
            "video-zoom": String(s.zoom), "video-pan-x": String(s.panX), "video-pan-y": String(s.panY),
            "sharpen": String(s.sharpen), "deinterlace": s.deinterlace ? "yes" : "no",
            "audio-channels": s.channelMode, "audio-device": s.audioDevice,
            "sub-font": s.subtitleFont, "sub-font-size": String(s.subtitleSize), "sub-pos": String(s.subtitlePosition),
            "sub-color": s.subtitleColor, "sub-outline-size": String(s.subtitleOutline),
            "sub-border-style": s.subtitleBackground ? "background-box" : "outline-and-shadow",
            "sub-visibility": s.subtitleVisible ? "yes" : "no",
            "secondary-sid": s.secondarySubtitleID == 0 ? "no" : String(s.secondarySubtitleID),
            "secondary-sub-pos": String(s.secondarySubtitlePosition), "alang": s.preferredAudioLanguages,
            "slang": s.preferredSubtitleLanguages, "screenshot-format": s.screenshotFormat,
            "screenshot-jpeg-quality": String(s.screenshot.quality), "screenshot-webp-quality": String(s.screenshot.quality),
            "demuxer-max-bytes": String(s.cacheMB * 1024 * 1024),
            "deband": p.deband ? "yes" : "no", "scale": p.scaler,
            "interpolation": p.interpolation ? "yes" : "no", "video-sync": p.interpolation ? "display-resample" : "audio",
            "tone-mapping": p.toneMapping, "target-prim": p.forceSDR ? "bt.709" : "auto",
            "target-trc": p.forceSDR ? "srgb" : "auto",
            "sub-ass-override": p.assOverride, "sub-codepage": p.subtitleEncoding, "sub-fps": String(p.subtitleFPS),
            "secondary-sub-delay": String(p.secondarySubtitleDelay),
            "audio-exclusive": p.audioExclusive ? "yes" : "no", "audio-samplerate": String(p.audioSampleRate),
            "audio-pitch-correction": p.pitchCorrection ? "yes" : "no"
        ]
        for (key, value) in properties { set(key, value) }
        let videoStatus = applyVideoFilterProperties(settings: s, userFragments: candidateVideoFilters ?? userVideoFilters.effectiveFragments)
        if videoStatus < 0 { error = "视频滤镜设置失败：\(String(cString: mpv_error_string(videoStatus)))" }
        var audioFilters: [String] = []
        if s.equalizerEnabled {
            for (frequency, gain) in zip([32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000], s.equalizer) {
                // Preserve gain headroom for integer PCM before the limiter.
                audioFilters.append("equalizer=f=\(frequency):t=o:w=1:g=\(gain):precision=f64")
            }
        }
        if s.normalizeAudio { audioFilters.append("dynaudnorm=f=150:g=15") }
        if p.swapChannels { audioFilters.append("aformat=channel_layouts=stereo"); audioFilters.append("pan=stereo|c0=c1|c1=c0") }
        if p.pitchSemitones != 0 { audioFilters.append("rubberband=pitch=\(pow(2, p.pitchSemitones / 12))") }
        if p.crossfeed { audioFilters.append("aformat=channel_layouts=stereo"); audioFilters.append("bs2b") }
        if p.limiter && !audioFilters.isEmpty { audioFilters.append("alimiter=level=disabled:latency=1") }
        set("af", audioFilters.isEmpty ? "" : "lavfi=[\(audioFilters.joined(separator: ","))]")
        NSApp.windows.filter { $0.identifier?.rawValue == "player" || $0.title == "SiliconPlayer" }.forEach {
            $0.level = s.keepOnTop || miniMode ? .floating : .normal
        }
        if !s.preventSleep, let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity); self.sleepActivity = nil }
    }
    func refreshAdvancedState() {
        if Date().timeIntervalSince(lastAdvancedRefresh) < 1 { return }
        lastAdvancedRefresh = Date()
        SystemMediaController.shared.update(player: self)
        seekable = loaded && flag("seekable")
        if loaded, let rows = jsonProperty("chapter-list") as? [[String: Any]] {
            chapters = rows.enumerated().map { index, row in
                MediaChapter(id: index, title: row["title"] as? String ?? "章节 \(index + 1)", time: row["time"] as? Double ?? 0)
            }
        } else { chapters = [] }
        chapterID = loaded ? Int(string("chapter")) ?? -1 : -1
        if let rows = jsonProperty("audio-device-list") as? [[String: Any]] {
            audioDevices = rows.compactMap {
                guard let name = $0["name"] as? String else { return nil }
                return AudioOutputDevice(id: name, name: name, description: $0["description"] as? String ?? name)
            }
        }
        statistics = loaded ? [
            "容器": string("file-format"), "视频编码": string("video-codec"), "音频编码": string("audio-codec"),
            "尺寸": "\(Int(number("width"))) × \(Int(number("height")))",
            "帧率": String(format: "%.3f fps", number("estimated-vf-fps")),
            "视频码率": String(format: "%.0f kb/s", number("video-bitrate") / 1000),
            "音频码率": String(format: "%.0f kb/s", number("audio-bitrate") / 1000),
            "解码器": decoder, "丢帧": string("decoder-frame-drop-count"), "渲染丢帧": string("frame-drop-count"),
            "A/V 同步": String(format: "%+.3f s", number("avsync")), "色彩原色": string("video-params/primaries"),
            "传递函数": string("video-params/gamma"), "缓存": String(format: "%.1f s", number("demuxer-cache-duration"))
        ] : [:]
        if loaded && !paused && settings.preventSleep && sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled], reason: "媒体播放")
        } else if (!loaded || paused || !settings.preventSleep), let sleepActivity {
            ProcessInfo.processInfo.endActivity(sleepActivity); self.sleepActivity = nil
        }
        if let sleepDeadline, Date() >= sleepDeadline {
            set("pause", "yes"); self.sleepDeadline = nil; toast("睡眠定时已暂停播放")
        }
    }
    func setSleepTimer(minutes: Int) {
        sleepDeadline = minutes > 0 ? Date().addingTimeInterval(Double(minutes * 60)) : nil
        toast(minutes > 0 ? "将在 \(minutes) 分钟后暂停" : "睡眠定时已取消")
    }
    func goToChapter(_ index: Int) {
        guard loaded, chapters.contains(where: { $0.id == index }) else { return }
        rememberSeekOrigin(); SubtitleSpeechController.shared.stop()
        set("chapter", String(index))
    }
    func jumpChapter(_ direction: Int) { goToChapter(min(chapters.count - 1, max(0, chapterID + direction))) }
    func toggleMiniMode() {
        guard let window = playerWindow else { return }
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil); return }
        miniMode.toggle()
        if miniMode {
            regularWindowFrame = window.frame
            window.minSize = NSSize(width: 360, height: 220)
            window.level = .floating
            let origin = NSPoint(x: window.frame.maxX - 460, y: window.frame.maxY - 320)
            window.setFrame(NSRect(origin: origin, size: NSSize(width: 460, height: 320)), display: true, animate: true)
        } else {
            window.minSize = NSSize(width: 760, height: 500)
            window.level = settings.keepOnTop ? .floating : .normal
            if let frame = regularWindowFrame { window.setFrame(frame, display: true, animate: true) }
        }
    }
    func newPlayerInstance() {
        let config = NSWorkspace.OpenConfiguration(); config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
    }
    func goToTimePanel() {
        let alert = NSAlert(); alert.messageText = "跳转到时间"; alert.informativeText = "输入秒数或 时:分:秒"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24)); alert.accessoryView = field
        alert.addButton(withTitle: "跳转"); alert.addButton(withTitle: "取消"); alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let parts = field.stringValue.split(separator: ":", omittingEmptySubsequences: false)
            let components = parts.compactMap { Double($0) }
            guard !components.isEmpty, components.count == parts.count, components.count <= 3 else { error = "时间格式无效"; return }
            let time = components.reduce(0) { $0 * 60 + $1 }
            guard time.isFinite, time >= 0 else { error = "时间格式无效"; return }; seek(time)
        }
    }
    func attachAudio() {
        let panel = NSOpenPanel(); panel.title = "加载外部音轨"; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            nativeAudioManualTrackChoice = true; nativeAudioQueue.configurationChanged()
            mediaPreferences.markTrackSelectionEdited(kind: .audio)
            panel.urls.forEach { url in
                if let id = existingExternalTrack(url, kind: .audio) { selectAudio(id) }
                else { command(["audio-add", url.path, "select"]) }
            }; updateTracks()
        }
    }
    func addBookmark() {
        guard let url = currentURL, loaded else { return }
        _ = library.addBookmark(url: url, position: position, title: "\(playlist.currentItem?.title ?? "媒体") · \(TimeText.format(position))")
        library.flush(); libraryRevision += 1; toast("已添加书签")
    }
    func toggleFavorite() {
        guard let url = currentURL else { return }
        let added = library.toggleFavorite(url: url); library.flush(); libraryRevision += 1
        toast(added ? "已加入收藏" : "已取消收藏")
    }
    func removeBookmark(_ id: UUID) { library.removeBookmark(id: id); library.flush(); libraryRevision += 1 }
    func removeSavedPlaylist(_ id: UUID) { library.removeSavedPlaylist(id: id); library.flush(); libraryRevision += 1 }
    @discardableResult
    func updateBookmark(_ id: UUID, title: String, position: Double) -> Bool {
        let saved = library.updateBookmark(id: id, title: title, position: position)
        libraryRevision += 1
        if saved { toast("书签已更新") }
        return saved
    }
    @discardableResult
    func renameSavedPlaylist(_ id: UUID, name: String) -> Bool {
        let saved = library.renameSavedPlaylist(id: id, name: name)
        libraryRevision += 1
        if saved { toast("列表已重命名") }
        return saved
    }
    func openBookmark(_ bookmark: PlaybackBookmark) {
        _ = open([bookmark.url], resumeAt: bookmark.position)
    }
    func saveNamedPlaylist() {
        let alert = NSAlert(); alert.messageText = "保存播放列表"; let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = "我的播放列表"; alert.accessoryView = field; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            _ = library.savePlaylist(name: field.stringValue, urls: playlist.items.map(\.url)); library.flush(); libraryRevision += 1
        }
    }
    func importPlaylist() {
        let panel = NSOpenPanel(); panel.title = "导入 M3U / M3U8 / PLS 播放列表"
        if panel.runModal() == .OK, let url = panel.url {
            _ = open([url])
        }
    }
    func exportPlaylist(format: PlaylistDocument.Format = .m3u8) {
        guard !playlist.items.isEmpty else { error = "播放列表为空，无法导出。"; return }
        let fileExtension = format == .pls ? "pls" : "m3u8"
        let panel = NSSavePanel()
        panel.title = "导出 \(fileExtension.uppercased()) 播放列表"
        panel.nameFieldStringValue = "播放列表.\(fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                if format == .pls { try PlaylistDocument.writePLS(urls: playlist.items.map(\.url), to: url) }
                else { try PlaylistDocument.writeM3U8(urls: playlist.items.map(\.url), to: url) }
                toast("播放列表已导出")
            } catch { self.error = error.localizedDescription }
        }
    }
    func openSubtitleEditor() {
        let panel = NSOpenPanel(); panel.title = "编辑 SRT / VTT / ASS / SSA 字幕"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Bind to the actually loaded Core item, independently of queue UI
        // selection. Same-URL reloads are distinct controller/load tokens.
        let observedPlayerTime: (() throws -> Int64)?
        let seekPlayer: ((Int64) throws -> Void)?
        if let itemID = mediaPreferences.boundItemID,
           mediaPreferences.token == mediaPreferenceToken, loaded, !isLoading {
            let loadToken = mediaPreferenceToken
            observedPlayerTime = { [weak self] in
                guard let self, self.mediaPreferenceToken == loadToken,
                      self.mediaPreferences.token == loadToken,
                      self.mediaPreferences.boundItemID == itemID,
                      self.loaded, !self.isLoading, !self.flag("seeking"),
                      let time = Double(self.string("time-pos")) else {
                    throw SubtitlePreservationError.invalid("播放器已换片、停止或尚未完成定位；请手动填入视频锚点")
                }
                return try SubtitleExactClock.observedPlayerSeconds(time)
            }
            seekPlayer = { [weak self] target in
                guard let self, self.mediaPreferenceToken == loadToken,
                      self.mediaPreferences.token == loadToken,
                      self.mediaPreferences.boundItemID == itemID,
                      self.loaded, !self.isLoading,
                      self.seekable, self.flag("seekable"), target >= 0,
                      target <= SubtitleExactClock.maximumMicroseconds else {
                    throw SubtitlePreservationError.invalid("绑定的媒体已变更或不能定位")
                }
                let seconds = Double(target) / 1_000_000
                if let end = Double(self.string("duration")), end.isFinite, end > 0, seconds > end {
                    throw SubtitlePreservationError.invalid("所选字幕起点超过当前媒体时长")
                }
                self.seek(seconds)
            }
        } else {
            // Offline authoring remains available without a guessed binding.
            observedPlayerTime = nil; seekPlayer = nil
        }
        SubtitleAuthoringWindow.show(url: url, observedPlayerTime: observedPlayerTime, seekPlayer: seekPlayer)
    }
    func shufflePlaylist() {
        let current = playlist.currentItem?.id
        playlist.shuffle()
        if let current { _ = playlist.select(id: current) }
    }
    func sortPlaylist() {
        let current = playlist.currentItem?.id
        playlist.sortByTitle()
        if let current { _ = playlist.select(id: current) }
    }
    func cyclePlaylistLoop() {
        loopPlaylist.toggle(); toast(loopPlaylist ? "列表循环开启" : "列表循环关闭")
    }
}
