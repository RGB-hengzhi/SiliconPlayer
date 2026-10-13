import AppKit
import Combine
import CMPV
import PlayerCore

struct MediaTrack: Identifiable, Equatable {
    let id: Int
    let type: String
    let title: String
    let language: String
    let codec: String
    var label: String {
        [title.isEmpty ? "轨道 \(id)" : title, language, codec].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

@MainActor
final class PlayerModel: ObservableObject {
    static let shared = PlayerModel()
    let handle: OpaquePointer?
    @Published var playlist = Playlist() {
        didSet {
            if playlist.items.isEmpty && restoredQueueOnStartup { restoredQueueOnStartup = false }
            if playlist.items != oldValue.items || playlist.currentIndex != oldValue.currentIndex {
                ordinaryOpenQueueRevision &+= 1
                if !nativeAudioPublishing { nativeAudioQueue.logicalChanged() }
            }
        }
    }
    // Welcome-only state: a restored list does not imply a media load or autoplay.
    // Never persist this marker or reuse it after an explicit load/Stop.
    @Published var restoredQueueOnStartup = false
    private var ordinaryOpenQueueRevision: UInt64 = 0
    lazy var ordinaryMediaOpen = OrdinaryMediaOpenController(
        snapshot: { [weak self] in self?.ordinaryMediaOpenContext() },
        commit: { [weak self] expansion, append, resumeAt in
            self?.commitExpandedOrdinaryOpen(expansion, append: append, resumeAt: resumeAt) ?? false },
        reportError: { [weak self] text in self?.error = text })
    @Published var loaded = false
    @Published var paused = true
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var volume = 80.0
    @Published var muted = false
    @Published var speed = 1.0
    lazy var temporaryPlaybackSpeed = TemporaryPlaybackSpeedController(
        snapshot: { [weak self] in self?.temporarySpeedSnapshot() },
        write: { [weak self] value in self?.setChecked("speed", String(value)) ?? MPV_ERROR_UNINITIALIZED.rawValue },
        publish: { [weak self] value in self?.speed = value })
    @Published var tracks: [MediaTrack] = []
    @Published var audioID = 0
    @Published var subtitleID = 0
    @Published var subtitleDelay = 0.0
    @Published var audioDelay = 0.0
    @Published var subtitleScale = 1.0
    @Published var decoder = "待播放"
    @Published var videoInfo = ""
    @Published var message = ""
    @Published var error: String?
    @Published var screenshotBusy = false
    @Published var screenshotStatus = ""
    lazy var screenshotJobs = AsyncScreenshotJobs(player: self)
    @Published var showPlaylist = true
    @Published var showInspector = false
    @Published var loopFile = false { didSet { nativeAudioQueue.loopsChanged() } }
    @Published var abStart: Double? { didSet { nativeAudioQueue.loopsChanged() } }
    @Published var abEnd: Double? { didSet { nativeAudioQueue.loopsChanged() } }
    @Published var isLoading = false
    @Published var settings = PlaybackSettings() {
        didSet {
            if !nativeAudioPublishing && settings != oldValue { nativeAudioQueue.configurationChanged() }
            guard mediaPreferenceTrackingReady, !synchronizingMediaSettings else { return }
            mediaPreferences.adoptEffectiveEdit(from: oldValue, to: settings)
            synchronizeMediaPreferenceSettings()
        }
    }
    // Explicit session opt-in. This flag is never inferred from opening audio,
    // and isn't encoded into the global/profile/queue documents.
    @Published var continuousAudioEnabled = false
    @Published var continuousAudioStatus = "连续音频已关闭"
    lazy var nativeAudioQueue = MPVNativeAudioQueueController(player: self)
    private lazy var playbackProgramNativeJournal = PlaybackProgramNativeJournal()
    lazy var playbackProgram: PlaybackProgramController = {
        let journal: PlaybackProgramController.Journal?
        if playbackProgramNativeJournal.enabled {
            journal = { [weak self] event, details in self?.recordPlaybackProgramNativeJournal(event, details: details) }
        } else { journal = nil }
        return PlaybackProgramController(host: self, journal: journal)
    }()
    var playbackProgramOwnSeek = false
    var nativeAudioPublishing = false
    var nativeAudioManualTrackChoice = false
    var nativeAudioCompleteAB: Bool {
        guard let a = abStart, let b = abEnd else { return false }
        return a.isFinite && b.isFinite && a >= 0 && b > a
    }
    private var mediaPreferenceTrackingReady = false
    private var synchronizingMediaSettings = false
    lazy var mediaPreferences = MediaPreferencesController(
        fileURL: Self.supportDirectory.appendingPathComponent("media-preferences.json"), loadImmediately: false)
    var mediaPreferenceToken = UUID()
    var applyingMediaPreferenceRestoration = false
    private var profileBlockObservation: AnyCancellable?
    lazy var profileBackup: UserProfileBackupController = {
        let controller = UserProfileBackupController(directory: Self.supportDirectory,
        input: InputController.shared, media: mediaPreferences,
        filters: { [weak self] in self?.userVideoFilters.chain ?? UserVideoFilterChain() },
        web: { [weak self] in self?.webMediaCatalog },
        appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
        assetsSnapshot: { [weak self] in
            guard let self else {throw CancellationError()};return try await self.videoAssets.snapshotForProfile()
        },
        assetsImport: { [weak self] backup,commit in
            guard let self else {throw CancellationError()};return try await self.videoAssets.importProfile(backup,commit:commit)
        },
        beforeCommit: { [weak self] in self?.prepareForProfileImport() },
        didCommit: { [weak self] value in self?.adoptImportedProfile(value) })
        profileBlockObservation = controller.$blocksPersistence.dropFirst().sink { [weak self] blocked in
            self?.profileRecoveryBlocked = blocked
            InputController.shared.editingBlocked = blocked
        }
        return controller
    }()
    @Published var showMediaPreferences = false
    @Published var showProfileBackup = false
    @Published var showScriptExtensions = false
    var explicitScriptController: ExplicitScriptController?
    var scriptExecutionAvailable: Bool { handle != nil && !coreShutdownComplete }
    @Published var profileRecoveryBlocked = false
    private(set) var profileRuntimeAdoptionCount = 0
    func didAdoptProfileRuntime() { profileRuntimeAdoptionCount += 1 }
    @Published var showAdvanced = false
    @Published var advancedSettingsInitialTab = "video"
    lazy var secondarySubtitleStyle = SecondarySubtitleStyleRuntime(player: self)
    @Published var showTools = false
    @Published var showShortcuts = false
    @Published var showCapture = false
    @Published var showTranslation = false
    @Published var showLiveASR = false
    let liveASRHostState = LiveASRMPVHostState()
    lazy var liveASR = LiveASRController(host: self, factory: LiveASRProcessBackendFactory(
        workRootURL: FileManager.default.temporaryDirectory.appendingPathComponent("SiliconPlayer-LiveASR", isDirectory: true),
        captureDiagnostics: InputController.verificationSuiteName(environment: ProcessInfo.processInfo.environment) != nil,
        configurationProvider: { try await LiveASRToolsResolver.resolve(bundleURL: Bundle.main.bundleURL) }),
        linearFactory: LiveASRLinearProcessBackendFactory(
            workRoot:FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("SiliconPlayer-LiveASR-Linear",isDirectory:true),
            capture:InputController.verificationSuiteName(environment:ProcessInfo.processInfo.environment) != nil,
            providerSourceSHA256:LiveASRLinearToolsResolver.providerSourceSHA256,
            configuration:{
                let env=ProcessInfo.processInfo.environment
                let candidate=await MainActor.run {
                    InputController.verificationSuiteName(environment:env) != nil
                        && env["SILICONPLAYER_LONG_ASR_CANDIDATE"]=="1"
                }
                return try await LiveASRLinearToolsResolver.resolve(bundleURL:Bundle.main.bundleURL,privateCandidate:candidate)
            }))
    @Published var showThumbnails = false
    @Published var showNetwork = false
    @Published var showWebMedia = false
    @Published var showLibrary = false
    @Published var miniMode = false
    @Published private(set) var systemPiPState: SystemPiPController.State = .idle
    @Published private(set) var systemPiPAvailable = false
    weak var videoHost: MPVVideoHost?
    lazy var systemPiP: SystemPiPController = {
        let controller = SystemPiPController()
        controller.onPlay = { [weak self] in self?.set("pause", "no") }
        controller.onPause = { [weak self] in self?.set("pause", "yes") }
        controller.onStop = { [weak self] in self?.stopPlayback() }
        controller.onSkip = { [weak self] seconds in self?.jump(seconds) }
        controller.onRedraw = { [weak self] in self?.videoHost?.video.requestRedraw() }
        controller.onSurfaceWillMove = { [weak self] in self?.videoHost?.video.prepareForSurfaceMove() }
        controller.onSurfaceDidMove = { [weak self] in self?.videoHost?.video.requestRedraw() }
        controller.onStateChanged = { [weak self, weak controller] state in
            self?.systemPiPState = state
            self?.systemPiPAvailable = controller?.available ?? false
        }
        return controller
    }()
    var regularWindowFrame: NSRect?
    @Published var libraryRevision = 0
    @Published var seekable = false
    @Published var chapters: [MediaChapter] = []
    @Published var chapterID = -1
    @Published var audioDevices: [AudioOutputDevice] = []
    @Published var statistics: [String: String] = [:]
    @Published var loopPlaylist = false { didSet { nativeAudioQueue.loopsChanged() } }
    @Published var sleepDeadline: Date?
    @Published private(set) var seekReturnPosition: Double?
    let library = LibraryStore(fileURL: PlayerModel.supportDirectory.appendingPathComponent("library.json"))
    lazy var videoAssets = VideoAssetsService(player: self, directory: Self.supportDirectory.appendingPathComponent("video-assets", isDirectory: true))
    let userVideoFilters = UserVideoFiltersController(fileURL: PlayerModel.supportDirectory.appendingPathComponent("user-video-filters.json"))
    var candidateVideoFilters: [String]?
    var videoFilterGeneration = UUID()
    // These tickets are process-local and change even for a same-URL reload.
    // RenderProgress counts render updates, including redraws; it is combined
    // with seek timing/core state rather than treated as a physical-frame proof.
    struct VideoSeekBarrier {
        let epoch: UUID
        let submittedAt: TimeInterval
        let renderedBefore: UInt64
        let exactTarget: Double?
        let speed: Double
    }
    struct PendingVideoConfiguration {
        let requestID: UUID
        let epoch: UUID
        let decoder: String
        let filter: String
        let submittedAt: TimeInterval
        let renderedBefore: UInt64
    }
    struct VideoConfigurationResult {
        let requestID: UUID
        let epoch: UUID
        let status: Int32
        let executed: Bool
        let renderedBefore: UInt64
        // Equal effective options need a real forced drawable, not a fictitious
        // new UPDATE_FRAME event. Changed options still require frame progress.
        let effectiveUnchanged: Bool
    }
    var videoConfigurationEpoch = UUID()
    var videoConfigurationRequestID = UUID()
    var videoSeekBarrier: VideoSeekBarrier?
    var pendingVideoConfiguration: PendingVideoConfiguration?
    var videoConfigurationResult: VideoConfigurationResult?
    var videoConfigurationApplyCount: UInt64 = 0
    var videoConfigurationClosing = false
    var videoFilterFailure: String?
    let renderProgress = RenderProgress()
    var frameStepRequests: [Bool] = []
    var frameStepGeneration = UUID()
    var frameStepTask: Task<Void, Never>?
    var hasPendingFrameSteps: Bool { frameStepTask != nil }
    var settingsWork: DispatchWorkItem?
    var lastAdvancedRefresh = Date.distantPast
    var sleepActivity: NSObjectProtocol?
    var pendingBookmarkPosition: Double?
    var pendingBookmarkURL: URL?
    private var timer: Timer?
    private var resume: Double?
    private var activeURL: URL?
    private var lastSavedAt = Date.distantPast
    private var openedAt = Date.distantPast
    private var handledEOF = false
    private var pendingSubtitles: [URL] = []
    private var rendererReady = false
    private var pendingLoad: MediaItem?
    /// A request owns its playback choice. Explicit Play can upgrade this
    /// request without changing the preference for subsequent ordinary opens.
    private struct LoadPlaybackIntent {
        let itemID: UUID
        var startPlaying: Bool
    }
    private var loadPlaybackIntent: LoadPlaybackIntent?
    var hasPendingRendererLoad: Bool { pendingLoad != nil }
    private var requestedEntryID: Int64?
    private var eventEntryID: Int64?
    private var playbackStopped = false
    private var coreShutdownComplete = false
    var liveASRCoreClosed: Bool { coreShutdownComplete }
    // Keep cleanup enabled after Stop/timeout, until the core has actually
    // reaped any hook subprocess. Model loading state alone is insufficient.
    private(set) var hasUsedWebPlayback = false
    let history = HistoryStore(fileURL: PlayerModel.supportDirectory.appendingPathComponent("history.json"))
    var webMediaCatalog = WebMediaCatalog()
    private var notifications: [NSObjectProtocol] = []
    private let mpvConfigurationDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("siliconplayer-mpv-config-\(UUID().uuidString)", isDirectory: true)
    private var webHookExecutable: URL?

    static var webToolsDirectory: URL? {
        guard AppCapabilities.current.hasWebMediaExtractor else { return nil }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("WebTools", isDirectory: true)
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/WebTools", isDirectory: true)
        // Packaged applications must stand on their bundled dependencies.
        // Only an unbundled developer binary may use the source-tree tools.
        let candidates = Bundle.main.bundleURL.pathExtension == "app" ? [bundled] : [bundled, development]
        return candidates.compactMap { $0 }.first {
            FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("yt-dlp/yt-dlp_macos").path)
                && FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("deno").path)
                && FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("web-extractor").path)
        }
    }

    init() {
        do {
            try FileManager.default.createDirectory(at: mpvConfigurationDirectory, withIntermediateDirectories: true)
        } catch {
            handle = nil
            self.error = "无法创建独立播放配置目录：\(error.localizedDescription)"
            return
        }
        if let fonts = Bundle.main.url(forResource: "fonts", withExtension: "conf") {
            setenv("FONTCONFIG_FILE", fonts.path, 1)
        }
        handle = mpv_create()
        guard let handle else { error = "无法创建 mpv 播放内核"; return }
        var options = [
            "vo": "libmpv", "hwdec": "videotoolbox", "video-timing-offset": "0", "config": "no", "terminal": "no",
            "config-dir": mpvConfigurationDirectory.path, "load-scripts": "no", "ytdl": AppCapabilities.current.hasWebMediaExtractor ? "yes" : "no",
            "input-default-bindings": "no", "input-vo-keyboard": "no", "osc": "no",
            "keep-open": "yes", "idle": "yes", "sub-auto": "fuzzy", "audio-file-auto": "fuzzy",
            "sub-font-provider": "fontconfig", "osd-font-provider": "fontconfig", "sub-font": "Heiti SC", "osd-font": "Heiti SC",
            "volume": "80", "volume-max": "100", "screenshot-format": "png",
            "screenshot-directory": Self.screenshotDirectory.path,
            "demuxer-max-bytes": "134217728", "demuxer-max-back-bytes": "33554432"
        ]
        if let tools = Self.webToolsDirectory {
            // Lua's helper-path list splits literal colons. An owned alias in
            // the private APFS temp directory works even after app relocation
            // into a path containing colons, commas, spaces or Unicode.
            let alias = mpvConfigurationDirectory.appendingPathComponent("web-extractor")
            do {
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: tools.appendingPathComponent("web-extractor"))
                webHookExecutable = alias
                options["script-opts"] = Self.mpvOptionList([
                    "ytdl_hook-ytdl_path": alias.path,
                    "ytdl_hook-all_formats": "no", "ytdl_hook-thumbnails": "none"
                ])
            } catch {
                NSLog("Web helper alias unavailable: %@", error.localizedDescription)
            }
        }
        for (key, value) in options {
            let result = mpv_set_option_string(handle, key, value)
            if result < 0 { NSLog("mpv option %@: %s", key, mpv_error_string(result)) }
        }
        let result = mpv_initialize(handle)
        guard result >= 0 else { error = "mpv 初始化失败：\(String(cString: mpv_error_string(result)))"; return }
        mpv_observe_property(handle, 1, "track-list", MPV_FORMAT_NONE)
        do {
            // Recover a prepared transaction before any participating store is
            // read or applied. Stored-let filters may have read a partial file;
            // overwrite their in-memory value with the recovered typed state.
            let recovered = try UserProfileBackupController.startUpRecovery(directory: Self.supportDirectory, input: InputController.shared)
            let preserved = try Self.preserveRejectedProfileStores(notices: recovered.notices)
            installGlobalBaseSettings(recovered.global)
            try mediaPreferences.adoptCommittedProfile(recovered.media)
            try userVideoFilters.adoptCommittedProfile(recovered.filters)
            webMediaCatalog = recovered.web
            if !preserved.isEmpty { toast("损坏设置的原始数据已保存至 PreservedPreferences，当前使用默认设置。") }
        } catch {
            profileRecoveryBlocked = true
            profileBackup.setPersistenceBlocked(true)
            installGlobalBaseSettings(PlaybackSettings())
            self.error = "设置导入的恢复尚未完成，原文件和恢复记录已保留；请重新启动以恢复设置。"
        }
        installUserVideoFilters()
        applySettings()
        if !profileRecoveryBlocked { restoreQueue() }
        for item in playlist.items {
            if let selection = item.webMedia, webMediaCatalog.selection(for: item.url) == nil {
                rememberWebMediaPreference(pageURL: item.url, selection: selection)
            }
        }
        refreshAdvancedState()
        mpv_request_log_messages(handle, ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_REPORT"] == nil ? "warn" : "v")
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelScreenshotsForShutdown(); self?.saveHistory(); self?.history.flush()
                self?.library.flush(); self?.persistSettings(); self?.persistQueue()
                SubtitleSpeechController.shared.stop()
                InputController.clearVerificationPreferences(environment: ProcessInfo.processInfo.environment)
                if let directory = self?.mpvConfigurationDirectory { try? FileManager.default.removeItem(at: directory) }
            }
        })
        if ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_REPORT"] != nil,
           ProcessInfo.processInfo.environment["SILICONPLAYER_VERIFY_MODE"] == "playback-intent" {
            // Opt-in fixture setup before AppKit creates the real renderer.
            // The verifier then checks the resulting real media/time/frames.
            PlaybackIntentVerifier.prepareInitialRendererRequest(player: self)
        }
    }

    static var screenshotDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        let dir = pictures.appendingPathComponent("SiliconPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func command(_ args: [String], report: Bool = true) {
        let result = executeCommand(args)
        if result < 0, report { error = "操作失败：\(String(cString: mpv_error_string(result)))" }
    }

    func executeCommand(_ args: [String]) -> Int32 {
        guard let handle else { return MPV_ERROR_UNINITIALIZED.rawValue }
        if args.first == "quit" || args.first == "stop" {
            if args.first == "stop", !finishTemporarySpeed(reason: "core-command-stop") {
                return MPV_ERROR_GENERIC.rawValue
            }
            playbackProgram.invalidate(reason: args.first == "quit" ? "core-command-quit" : "core-command-stop")
            liveASR.invalidate(reason: args.first == "quit" ? .quit : .stop)
            liveASRHostState.loadedFingerprint = nil
            _ = nativeAudioQueue.retire(reason: .manualStop)
            cancelVideoConfigurationTransition()
        }
        if ["audio-add", "audio-remove", "sub-add", "sub-remove"].contains(args.first ?? "") {
            nativeAudioManualTrackChoice = true
            nativeAudioQueue.configurationChanged()
        }
        let externalCandidate = liveASRExternalAudioCandidate(args)
        let removedExternalURL: URL?
        if args.first == "audio-remove", args.count >= 2, let id = Int(args[1]) {
            let row = (jsonProperty("track-list") as? [[String: Any]] ?? []).first {
                ($0["type"] as? String) == "audio" && ($0["id"] as? Int) == id && ($0["external"] as? Bool) == true
            }
            removedExternalURL = (row?["external-filename"] as? String).flatMap(LiveASRMPVHostState.localAudioURL)
        } else { removedExternalURL = nil }
        let seekAt = ProcessInfo.processInfo.systemUptime
        let seekFrames = renderProgress.frames
        let strings = args.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var pointers = strings.map { $0.map { UnsafePointer<CChar>($0) } }
        pointers.append(nil)
        let dispatch = { pointers.withUnsafeMutableBufferPointer { mpv_command(handle, $0.baseAddress) } }
        let status = args.first == "quit"
            ? closingAfterTemporarySpeedRestore(operation: dispatch)
            : dispatch()
        if status >= 0, let externalCandidate { liveASRHostState.commitExternalAudio(externalCandidate) }
        if status >= 0, args.first == "audio-remove" { liveASRHostState.removeExternalAudio(removedExternalURL) }
        if status >= 0, args.first == "quit" { videoConfigurationClosing = true }
        if status >= 0, loaded, let name = args.first,
           ["seek", "sub-seek", "frame-step", "frame-back-step", "revert-seek"].contains(name) {
            if !playbackProgramOwnSeek { playbackProgram.manualSeekAccepted() }
            liveASRAcceptedSeek()
            let flags = args.count > 2 ? args[2].split(separator: "+").map(String.init) : []
            let target = name == "seek" && flags.contains("absolute") && flags.contains("exact") && args.count > 1 ? Double(args[1]) : nil
            recordVideoSeekBarrier(at: seekAt, renderedBefore: seekFrames, exactTarget: target)
        }
        return status
    }

    func executeAsyncCommand(_ args: [String], replyID: UInt64) -> Int32 {
        guard let handle else { return MPV_ERROR_UNINITIALIZED.rawValue }
        let strings = args.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var pointers = strings.map { $0.map { UnsafePointer<CChar>($0) } }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { mpv_command_async(handle, replyID, $0.baseAddress) }
    }

    func set(_ name: String, _ value: String) {
        let result = setChecked(name, value)
        if result < 0 { error = "\(name)：\(String(cString: mpv_error_string(result)))" }
        else if name == "pause", isLoading, value == "yes" || value == "no" {
            // A sleep deadline or explicit pause during loading must supersede
            // the initial start choice when FILE_LOADED is later delivered.
            loadPlaybackIntent?.startPlaying = value == "no"
        }
    }

    func setChecked(_ name: String, _ value: String) -> Int32 {
        guard let handle else { return MPV_ERROR_UNINITIALIZED.rawValue }
        let seekAt = ProcessInfo.processInfo.systemUptime
        let seekFrames = renderProgress.frames
        let status = mpv_set_property_string(handle, name, value)
        if status >= 0, loaded, ["time-pos", "percent-pos", "chapter"].contains(name) {
            if !playbackProgramOwnSeek { playbackProgram.manualSeekAccepted() }
            // Property setters do not promise the absolute+exact precision of
            // the player's seek command, so they carry no tight target guard.
            liveASRAcceptedSeek()
            recordVideoSeekBarrier(at: seekAt, renderedBefore: seekFrames, exactTarget: nil)
        }
        return status
    }

    func string(_ name: String) -> String {
        guard let handle, let raw = mpv_get_property_string(handle, name) else { return "" }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }

    func number(_ name: String) -> Double {
        guard let handle else { return 0 }
        var value: Double = 0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 && value.isFinite ? value : 0
    }

    func flag(_ name: String) -> Bool { string(name) == "yes" }

    func ordinaryMediaOpenContext() -> OrdinaryMediaOpenContext {
        .init(queueRevision: ordinaryOpenQueueRevision, currentItemID: playlist.currentItem?.id,
              loadToken: mediaPreferenceToken, preferenceToken: mediaPreferences.token,
              boundItemID: mediaPreferences.boundItemID)
    }
    @discardableResult
    func open(_ urls: [URL], append: Bool = false, resumeAt: Double? = nil) -> UUID? {
        guard !profileRecoveryBlocked, OrdinaryMediaOpenController.canAcceptRequests else { return nil }
        guard !urls.isEmpty, urls.count <= OrdinaryMediaOpenExpansionWorker.maximumInputs,
              resumeAt == nil || (resumeAt!.isFinite && resumeAt! >= 0) else {
            error = "一次最多打开 128 个路径；定位时间须是非负有限数。"; return nil
        }
        // Explicit replacement intent cancels old transient jobs before the
        // asynchronous metadata boundary; it does not change the queue/Core token.
        if !append {
            liveASR.invalidate(reason: .load)
            cancelVideoConfigurationTransition()
            cancelScreenshotsForMediaChange()
        }
        let request = ordinaryMediaOpen.submit(urls, append: append, resumeAt: resumeAt)
        if request != nil && urls.contains(where: { $0.hasDirectoryPath || ["m3u", "m3u8", "pls"].contains($0.pathExtension.lowercased()) }) {
            // URL directory flag/extension access only; no filesystem lookup.
            OrdinaryMediaOpenWindow.show(controller: ordinaryMediaOpen)
        }
        return request
    }
    func openAndWaitForCommit(_ urls: [URL], append: Bool = false, resumeAt: Double? = nil) async throws {
        guard let request = open(urls, append: append, resumeAt: resumeAt) else { throw DirectoryLibraryFailure(error ?? "Open request rejected") }
        try await ordinaryMediaOpen.waitForCommit(request)
    }
    /// Only the pre-renderer fixture verifier uses this exact prepared URL. It
    /// exercises actual pending load/Play before a real renderer exists; it does
    /// not claim to test the asynchronous ordinary-open metadata path.
    func preparePlaybackIntentRendererFixture(_ source: URL) -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard InputController.verificationSuiteName(environment: env) != nil,
              env["SILICONPLAYER_VERIFY_MODE"] == "playback-intent", !rendererReady,
              let path = env["SILICONPLAYER_VERIFY_INTENT_FIRST"], path.hasPrefix("/"),
              source == URL(fileURLWithPath: path).standardizedFileURL,
              !profileRecoveryBlocked, OrdinaryMediaOpenController.canAcceptRequests else { return false }
        return commitExpandedOrdinaryOpen(.init(media: [source], subtitles: [], rejectedAddresses: 0, visited: 0), append: false)
    }
    @discardableResult
    private func commitExpandedOrdinaryOpen(_ expansion: OrdinaryMediaOpenExpansion, append: Bool, resumeAt: Double? = nil) -> Bool {
        guard !profileRecoveryBlocked else { return false }
        let media = expansion.media, subtitles = expansion.subtitles
        if expansion.rejectedAddresses > 0 { toast("部分地址类型暂不支持；带账号的资源请使用网络浏览器") }
        if !media.isEmpty {
            let original = playlist
            saveHistory()
            var replacement = append ? playlist : Playlist()
            replacement.add(items: media.map(knownWebMediaItem))
            playlist = replacement
            if !append || !loaded {
                if let item = playlist.currentItem {
                    let oldBookmark = (pendingBookmarkPosition, pendingBookmarkURL)
                    if let resumeAt {
                        // Publish only at this exact accepted commit, not while
                        // the old Core is still running metadata preparation.
                        pendingBookmarkPosition = resumeAt; pendingBookmarkURL = item.url
                    }
                    if !load(item, resumeAt: resumeAt) {
                        // This restores queue identity, not retired Core playback.
                        pendingBookmarkPosition = oldBookmark.0; pendingBookmarkURL = oldBookmark.1
                        playlist = original
                        return false
                    }
                }
            } else { toast("已加入 \(media.count) 个文件") }
        }
        if isLoading { pendingSubtitles.append(contentsOf: subtitles) }
        else { for subtitle in subtitles { addSubtitle(subtitle) } }
        return true
    }

    func select(_ id: UUID) {
        let intent = continuousAudioEnabled ? nativeAudioQueue.currentIntent : nil
        saveHistory()
        if let item = playlist.select(id: id) { load(item, startPlaying: intent) }
    }

    func rendererDidBecomeReady() {
        rendererReady = true
        if let item = pendingLoad {
            let startPlaying = loadPlaybackIntent?.itemID == item.id ? loadPlaybackIntent?.startPlaying : nil
            pendingLoad = nil
            let subtitles = pendingSubtitles
            load(item, startPlaying: startPlaying, resumeAt: resume)
            pendingSubtitles = subtitles
        }
    }
    @discardableResult
    private func load(_ item: MediaItem, startPlaying: Bool? = nil, resumeAt: Double? = nil) -> Bool {
        // Synchronous replacement is an intentional boundary; no queued async
        // native append can survive it. Old loaded receipts are settled first.
        guard finishTemporarySpeed(reason: "replacement-load") else { return false }
        guard nativeAudioQueue.retire(reason: .newRequest) else { return false }
        if restoredQueueOnStartup { restoredQueueOnStartup = false }
        playbackProgram.invalidate(reason: "replacement-load")
        liveASR.invalidate(reason: .load)
        liveASRHostState.prepareLoad(item.url)
        nativeAudioQueue.reserveOrdinaryAddress(item.url)
        nativeAudioManualTrackChoice = false
        cancelVideoConfigurationTransition()
        systemPiP.exit()
        mediaPreferenceToken = mediaPreferences.prepareForLoad(item: item)
        synchronizeMediaPreferenceSettings()
        cancelScreenshotsForMediaChange()
        cancelPendingFrameSteps()
        videoFilterGeneration = UUID(); candidateVideoFilters = nil
        userVideoFilters.resumeForNewMedia()
        SubtitleSpeechController.shared.stop()
        playbackStopped = false
        loadPlaybackIntent = LoadPlaybackIntent(itemID: item.id, startPlaying: startPlaying ?? settings.autoplay)
        nativeAudioQueue.ordinaryRequest(startPlaying: loadPlaybackIntent?.startPlaying == true)
        resume = resumeAt ?? history.resumePosition(for: item.url)
        seekReturnPosition = nil
        if pendingBookmarkURL != item.url { pendingBookmarkPosition = nil; pendingBookmarkURL = nil }
        guard rendererReady else {
            pendingLoad = item; isLoading = true; openedAt = Date(); return true
        }
        pendingLoad = nil
        error = nil
        handledEOF = false
        pendingSubtitles = []
        loaded = false
        isLoading = true
        position = 0
        duration = 0
        tracks = []
        abStart = nil; abEnd = nil
        set("ab-loop-a", "no"); set("ab-loop-b", "no"); set("ab-loop-count", "inf")
        set("pause", loadPlaybackIntent?.startPlaying == true ? "no" : "yes")
        set("sid", "auto"); set("aid", "auto")
        settings.secondarySubtitleID = 0; set("secondary-sid", "no")
        set("sub-delay", "0"); set("audio-delay", "0")
        subtitleDelay = 0; audioDelay = 0
        activeURL = item.url
        openedAt = Date()
        applySettings()
        var fileOptions = ["ytdl": "no"]
        for (kind, name) in [(MediaTrackKind.audio, "audio-files"), (.subtitle, "sub-files")] {
            let files = mediaPreferences.currentExternalFiles.filter { $0.kind == kind }
                .map(\.url).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            if kind == .audio {
                // Capture each saved external source before the file-local
                // load request. A later readback must name this same file.
                for url in files {
                    if let receipt = liveASRCaptureExternalAudio(url) { liveASRHostState.commitExternalAudio(receipt) }
                }
            }
            if !files.isEmpty {
                // File-local ownership prevents a delayed sub-add/audio-add
                // command from attaching an old track to replacement media.
                // mpv's path-list parser only unescapes separators, rather
                // than C escapes. File URLs encode literal backslashes; all
                // literal colons (including those in a name) remain escaped.
                fileOptions[name] = files.map { $0.absoluteString
                    .replacingOccurrences(of: ":", with: "\\:") }.joined(separator: ":")
            }
        }
        var mediaAddress = item.url.isFileURL ? item.url.path : item.url.absoluteString
        if let selection = item.webMedia {
            guard let tools = Self.webToolsDirectory, webHookExecutable != nil else {
                loadPlaybackIntent = nil; isLoading = false; playbackStopped = true
                error = "网页解析工具不可用，请使用包含完整依赖的应用。"
                return false
            }
            // The queue/history retain the original page. Only this request
            // gains the hook prefix and file-local extractor preferences.
            mediaAddress = "ytdl://" + item.url.absoluteString
            hasUsedWebPlayback = true
            var extractorOptions = [
                "ignore-config": "", "no-plugin-dirs": "", "no-remote-components": "",
                "no-cookies-from-browser": "", "no-update": "", "no-cache-dir": "",
                "socket-timeout": "15", "retries": "1", "proxy": "",
                "js-runtimes": "deno:" + tools.appendingPathComponent("deno").path,
                "sub-langs": selection.subtitleLanguage ?? "-all"
            ]
            if selection.includeAutomaticSubtitles { extractorOptions["write-auto-subs"] = "" }
            if let mediaTools = MediaTools.toolsDirectory { extractorOptions["ffmpeg-location"] = mediaTools.path }
            fileOptions["ytdl"] = "yes"
            fileOptions["ytdl-format"] = selection.formatExpression
            fileOptions["ytdl-raw-options"] = Self.mpvOptionList(extractorOptions)
            fileOptions["force-media-title"] = selection.title
        }
        let status = executeLoadfile(mediaAddress, options: fileOptions)
        guard status >= 0 else {
            invalidateMediaPreferencePlayback()
            loadPlaybackIntent = nil; isLoading = false; playbackStopped = true
            error = "操作失败：\(String(cString: mpv_error_string(status)))"
            return false
        }
        requestedEntryID = Int64(string("playlist/0/id"))
        return true
    }

    var currentIsWebMedia: Bool { playlist.currentItem?.webMedia != nil }

    /// An in-flight hook owns subprocesses inside mpv, independently of the
    /// Swift pre-parser. Let the core cancel/reap them before AppKit exits.
    func shutdownWebPlayback() async {
        cancelVideoConfigurationTransition()
        guard !coreShutdownComplete else { return }
        command(["quit"], report: false)
        let deadline = Date().addingTimeInterval(3)
        while !coreShutdownComplete, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @discardableResult
    func openWebMedia(pageURL: URL, selection: WebMediaSelection, append: Bool = false) -> Bool {
        do {
            let page = try WebMediaDocument.validatedPageURL(pageURL.absoluteString)
            guard Self.webToolsDirectory != nil, webHookExecutable != nil else {
                error = "网页解析工具不可用，请使用包含完整依赖的应用。"
                return false
            }
            rememberWebMediaPreference(pageURL: page, selection: selection)
            if append {
                let wasEmpty = playlist.items.isEmpty
                let item = try playlist.upsertWebMedia(pageURL: page, selection: selection)
                if wasEmpty { _ = playlist.select(id: item.id); load(item) }
                persistQueue()
                toast("已将网页加入播放列表")
                return true
            }
            let samePlayingPage = (loaded || isLoading) && currentURL == page && currentIsWebMedia
            let previousPosition = samePlayingPage ? (loaded ? position : resume) : nil
            let startPlaying = samePlayingPage ? (loaded ? !paused : loadPlaybackIntent?.startPlaying ?? !paused) : true
            saveHistory()
            if !samePlayingPage { playlist = Playlist() }
            let item = try playlist.upsertWebMedia(pageURL: page, selection: selection)
            _ = playlist.select(id: item.id)
            let accepted = load(item, startPlaying: startPlaying, resumeAt: previousPosition)
            persistQueue()
            return accepted
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func next() {
        saveHistory()
        let intent = continuousAudioEnabled ? nativeAudioQueue.currentIntent : nil
        if let item = playlist.next(wrap: loopPlaylist) { load(item, startPlaying: intent) }
    }
    func previous() {
        if position > 3 { seek(0); return }
        saveHistory()
        let intent = continuousAudioEnabled ? nativeAudioQueue.currentIntent : nil
        if let item = playlist.previous(wrap: false) { load(item, startPlaying: intent) }
    }
    func remove(_ id: UUID) {
        let wasCurrent = playlist.currentItem?.id == id
        let intent = continuousAudioEnabled ? nativeAudioQueue.currentIntent : nil
        saveHistory()
        playlist.remove(id: id)
        if wasCurrent {
            if let item = playlist.currentItem { load(item, startPlaying: intent) }
            else { stopPlayback() }
        }
    }
    func playSelected(startPlaying: Bool? = nil) { if let item = playlist.currentItem { load(item, startPlaying: startPlaying) } }
    func togglePause() {
        cancelPendingFrameSteps()
        if loaded && flag("eof-reached"), let item = playlist.currentItem {
            // Explicit Play at the end starts this original UUID from the head.
            // Normal pause and in-flight Play intent keep their existing paths.
            saveHistory()
            _ = load(item, startPlaying: true, resumeAt: 0)
            return
        }
        if !loaded {
            if isLoading {
                // The visible action is Play until a media request has loaded.
                // Repeated clicks upgrade one request, rather than reopening it.
                loadPlaybackIntent?.startPlaying = true
            } else if let item = playlist.currentItem {
                load(item, startPlaying: true)
            }
            return
        }
        SubtitleSpeechController.shared.stop(); command(["cycle", "pause"])
    }
    func stopPlayback() {
        guard finishTemporarySpeed(reason: "stop") else { return }
        if restoredQueueOnStartup { restoredQueueOnStartup = false }
        saveHistory()
        _ = nativeAudioQueue.retire(reason: .manualStop)
        cancelVideoConfigurationTransition()
        systemPiP.exit()
        invalidateMediaPreferencePlayback()
        cancelScreenshotsForMediaChange()
        cancelPendingFrameSteps()
        videoFilterGeneration = UUID(); candidateVideoFilters = nil
        userVideoFilters.cancelPending(reason: "播放已停止，未完成的滤镜更改已取消")
        saveHistory(); history.flush()
        SubtitleSpeechController.shared.stop()
        playbackStopped = true; handledEOF = true
        pendingLoad = nil; pendingSubtitles = []; resume = nil
        loadPlaybackIntent = nil
        pendingBookmarkPosition = nil; pendingBookmarkURL = nil
        requestedEntryID = nil; eventEntryID = nil; activeURL = nil
        loaded = false; isLoading = false; paused = true
        position = 0; duration = 0; tracks = []; audioID = 0; subtitleID = 0
        chapters = []; chapterID = -1; statistics = [:]; seekable = false
        abStart = nil; abEnd = nil; seekReturnPosition = nil; sleepDeadline = nil
        decoder = "待播放"; videoInfo = ""
        command(["stop"]); set("pause", "yes")
        _ = applyVideoFilterProperties(settings: settings.sanitized(), userFragments: userVideoFilters.effectiveFragments)
        set("ab-loop-a", "no"); set("ab-loop-b", "no")
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity); self.sleepActivity = nil }
        SystemMediaController.shared.update(player: self)
        toast("已停止，播放列表已保留")
    }
    func rememberSeekOrigin() {
        if loaded && seekable { seekReturnPosition = max(0, number("time-pos")) }
    }
    /// FFmpeg's MPEG-TS demuxer can land after an exact target. Decode from an
    /// earlier point for seekable local TS; file-local scope restores the normal
    /// zero offset on the next file, without slowing other formats or live input.
    private func configureExactSeekPreroll() {
        let formats = string("file-format").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard activeURL?.isFileURL == true, flag("seekable"), formats.contains("mpegts") else { return }
        let result = setChecked("file-local-options/hr-seek-demuxer-offset", "0.5")
        if result < 0 {
            NSLog("MPEG-TS exact seek preroll: %s", mpv_error_string(result))
        }
    }
    func seek(_ seconds: Double, remember: Bool = true) {
        cancelPendingFrameSteps()
        guard loaded, seconds.isFinite else { return }
        if remember { rememberSeekOrigin() }
        SubtitleSpeechController.shared.stop(); handledEOF = false
        command(["seek", String(max(0, duration > 0 ? min(duration, seconds) : seconds)), "absolute+exact"])
    }
    func jump(_ seconds: Double) {
        cancelPendingFrameSteps()
        guard loaded, seekable, seconds.isFinite else { return }
        rememberSeekOrigin(); SubtitleSpeechController.shared.stop(); handledEOF = false
        command(["seek", String(seconds), "relative+exact"])
    }
    func jumpKeyframe(_ seconds: Double) {
        cancelPendingFrameSteps()
        guard loaded, seekable, seconds.isFinite else { return }
        rememberSeekOrigin(); SubtitleSpeechController.shared.stop(); handledEOF = false
        command(["seek", String(seconds), "relative+keyframes"])
    }
    func revertSeek() {
        guard loaded, seekable, let target = seekReturnPosition else { return }
        let current = max(0, number("time-pos"))
        seek(target, remember: false); seekReturnPosition = current
        toast("已返回 \(TimeText.format(target))")
    }
    func seekSubtitle(_ direction: Int) {
        cancelPendingFrameSteps()
        guard loaded, seekable else { return }
        rememberSeekOrigin(); SubtitleSpeechController.shared.stop(); handledEOF = false
        command(["sub-seek", String(direction)])
    }
    func setVolume(_ value: Double) { volume = min(100, max(0, value)); set("volume", String(volume)) }
    func toggleMute() { command(["cycle", "mute"]) }
    func setSpeed(_ value: Double) {
        guard value.isFinite else { return }
        let requested = min(4, max(0.25, value))
        nativeAudioQueue.configurationChanged()
        let status = setChecked("speed", String(requested))
        guard status >= 0 else { error = "速度设置失败：\(String(cString: mpv_error_string(status)))"; return }
        // An accepted explicit intent wins even if numerically equal to the
        // active temporary value. A failed setter keeps the restoration lease.
        let actual = number("speed")
        guard actual.isFinite, abs(actual - requested) <= 0.00000001 else {
            error = "速度设置已回复，但实际速度未确认。"; return
        }
        temporaryPlaybackSpeed.permanentChangeAccepted()
        speed = actual
        toast(String(format: "播放速度 %.2g×", speed))
    }
    func selectAudio(_ id: Int) {
        if !applyingMediaPreferenceRestoration { nativeAudioManualTrackChoice = true; nativeAudioQueue.configurationChanged() }
        if !applyingMediaPreferenceRestoration { mediaPreferences.markTrackSelectionEdited(kind: .audio) }
        set("aid", id == 0 ? "no" : String(id))
    }
    func selectSubtitle(_ id: Int) {
        if !applyingMediaPreferenceRestoration { nativeAudioManualTrackChoice = true; nativeAudioQueue.configurationChanged() }
        if !applyingMediaPreferenceRestoration { mediaPreferences.markTrackSelectionEdited(kind: .subtitle, secondary: false) }
        if sameMediaTrackStream(id, settings.secondarySubtitleID, kind: .subtitle) {
            if !applyingMediaPreferenceRestoration { mediaPreferences.markTrackSelectionEdited(kind: .subtitle, secondary: true) }
            settings.secondarySubtitleID = 0; set("secondary-sid", "no")
        }
        set("sid", id == 0 ? "no" : String(id))
    }
    func setSubtitleDelay(_ value: Double) {
        guard value.isFinite else { return }
        if !applyingMediaPreferenceRestoration { nativeAudioQueue.configurationChanged() }
        if !applyingMediaPreferenceRestoration { mediaPreferences.cancelPendingTrackRestoration() }
        subtitleDelay = value; set("sub-delay", String(value))
    }
    func setAudioDelay(_ value: Double) {
        guard value.isFinite else { return }
        if !applyingMediaPreferenceRestoration { nativeAudioQueue.configurationChanged() }
        if !applyingMediaPreferenceRestoration { mediaPreferences.cancelPendingTrackRestoration() }
        audioDelay = value; set("audio-delay", String(value))
    }
    func setSubtitleScale(_ value: Double) { subtitleScale = value; set("sub-scale", String(value)) }
    func toggleLoop() { loopFile.toggle(); set("loop-file", loopFile ? "inf" : "no"); toast(loopFile ? "单文件循环开启" : "单文件循环关闭") }
    func cancelPendingFrameSteps() {
        frameStepGeneration = UUID(); frameStepRequests.removeAll()
        frameStepTask?.cancel(); frameStepTask = nil
    }
    func frameStep(backward: Bool = false) {
        guard loaded, tracks.contains(where: { $0.type == "video" }) else { return }
        SubtitleSpeechController.shared.stop(); set("pause", "yes")
        guard frameStepRequests.count < 32 else { return }
        frameStepRequests.append(backward)
        guard frameStepTask == nil else { return }
        let token = frameStepGeneration
        frameStepTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.frameStepGeneration == token { self.frameStepTask = nil } }
            while !self.frameStepRequests.isEmpty && !Task.isCancelled && self.frameStepGeneration == token && self.loaded {
                // Give a newly submitted seek time to enter the core's seeking
                // state, then wait for it instead of issuing a lost frame step.
                try? await Task.sleep(nanoseconds: 50_000_000)
                var waits = 0
                while self.flag("seeking") && waits < 100 && !Task.isCancelled && self.frameStepGeneration == token {
                    try? await Task.sleep(nanoseconds: 50_000_000); waits += 1
                }
                guard !Task.isCancelled && self.frameStepGeneration == token && self.loaded else { return }
                guard !self.flag("seeking") else {
                    self.frameStepRequests.removeAll(); self.error = "定位尚未完成，请稍后再逐帧"; return
                }
                let reverse = self.frameStepRequests.removeFirst()
                self.command([reverse ? "frame-back-step" : "frame-step"])
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
    func cycleAB() {
        guard loaded else { return }
        if playbackProgram.manualABRequested() { toast("播放程序区间已清除"); return }
        set("ab-loop-count", "inf") // The existing manual button keeps infinite-loop semantics.
        // Clearing an existing interval does not need an available timestamp.
        if abStart != nil && abEnd != nil {
            abStart = nil; abEnd = nil; set("ab-loop-a", "no"); set("ab-loop-b", "no"); toast("A–B 循环已清除")
            return
        }
        guard let mark = Double(string("time-pos")), mark.isFinite, mark >= 0 else {
            toast("当前播放位置暂不可用"); return
        }
        if abStart == nil {
            let result = setChecked("ab-loop-a", String(mark))
            guard result >= 0 else { error = "无法设置 A 点：\(String(cString: mpv_error_string(result)))"; return }
            abStart = mark; toast("A 点：\(TimeText.format(mark))")
        } else if let start = abStart, mark > start {
            let result = setChecked("ab-loop-b", String(mark))
            guard result >= 0 else { error = "无法设置 B 点：\(String(cString: mpv_error_string(result)))"; return }
            abEnd = mark
            // Setting B behind already decoded audio does not guarantee a
            // rewind. Start the selected interval using the existing exact
            // seek path without changing pause/speed or seek-return history.
            seek(start, remember: false)
            if error == nil { toast("A–B 循环开启") }
        } else { abStart = nil; abEnd = nil; set("ab-loop-a", "no"); set("ab-loop-b", "no"); toast("A–B 循环已清除") }
    }
    func screenshot() {
        saveScreenshotAsync()
    }
    func addSubtitle(_ url: URL) {
        guard url.isFileURL else { error = "字幕请使用本地文件"; return }
        if isLoading { pendingSubtitles.append(url); return }
        guard loaded else { toast("请先打开视频，再加载字幕"); return }
        mediaPreferences.markTrackSelectionEdited(kind: .subtitle, secondary: false)
        if let id = existingExternalTrack(url, kind: .subtitle) {
            selectSubtitle(id); toast("已选择已加载的字幕：\(url.lastPathComponent)"); return
        }
        command(["sub-add", url.path, "select"]); updateTracks(); toast("已加载字幕：\(url.lastPathComponent)")
    }
    func openPanel(append: Bool = false, subtitles: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = !subtitles
        panel.allowsMultipleSelection = true
        panel.title = subtitles ? "加载字幕" : (append ? "添加到播放列表" : "打开媒体")
        panel.prompt = subtitles ? "加载" : "打开"
        if panel.runModal() == .OK {
            if subtitles { panel.urls.forEach(addSubtitle) }
            else { open(panel.urls, append: append) }
        }
    }
    func openURLPanel() {
        let alert = NSAlert()
        alert.messageText = "打开网络媒体"
        alert.informativeText = "输入可直接播放的 HTTP / HTTPS / RTSP 媒体地址"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        field.placeholderString = "https://example.com/video.mp4"
        alert.accessoryView = field
        alert.addButton(withTitle: "播放"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["https", "http", "rtsp", "rtmp", "rtsps"].contains(scheme), url.host != nil else {
                error = "请输入完整且有效的媒体地址"; return
            }
            open([url])
        }
    }
    func toast(_ text: String) {
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.message == text { self?.message = "" }
        }
    }
    func saveHistory() {
        if nativeAudioQueue.saveActiveHistory() { return }
        if let url = activeURL, loaded { history.record(url: url, position: position, duration: duration) }
    }
    func updateTracks() {
        guard let rows = jsonProperty("track-list") as? [[String: Any]] else { return }
        let retained = restorationMediaTrackCandidates()
        let allLocal = mediaTrackCandidates().filter { if case .localFile = $0.descriptor.source { return true }; return false }
        let localKeys = Set(allLocal.map { ($0.descriptor.kind == .audio ? "audio:" : "sub:") + String($0.runtimeID) })
        let retainedKeys = Set(retained.map { ($0.descriptor.kind == .audio ? "audio:" : "sub:") + String($0.runtimeID) })
        tracks = rows.compactMap { row in
            guard let id = row["id"] as? Int, let type = row["type"] as? String else { return nil }
            let key = type + ":" + String(id)
            guard !localKeys.contains(key) || retainedKeys.contains(key) else { return nil }
            return MediaTrack(id: id, type: type, title: row["title"] as? String ?? "", language: row["lang"] as? String ?? "", codec: row["codec"] as? String ?? "")
        }
        restoreMediaPreferencesAfterTrackUpdate()
    }
    func jsonProperty(_ name: String) -> Any? {
        guard let handle else { return nil }
        var node = mpv_node()
        guard mpv_get_property(handle, name, MPV_FORMAT_NODE, &node) >= 0 else { return nil }
        defer { mpv_free_node_contents(&node) }
        return decode(node)
    }
    private func decode(_ node: mpv_node) -> Any? {
        switch node.format {
        case MPV_FORMAT_STRING: return node.u.string.map { String(cString: $0) }
        case MPV_FORMAT_FLAG: return node.u.flag != 0
        case MPV_FORMAT_INT64: return Int(node.u.int64)
        case MPV_FORMAT_DOUBLE: return node.u.double_
        case MPV_FORMAT_NODE_ARRAY:
            guard let list = node.u.list?.pointee, let values = list.values else { return [Any]() }
            return (0..<Int(list.num)).compactMap { decode(values[$0]) }
        case MPV_FORMAT_NODE_MAP:
            guard let list = node.u.list?.pointee, let keys = list.keys, let values = list.values else { return [String: Any]() }
            var result: [String: Any] = [:]
            for i in 0..<Int(list.num) { if let key = keys[i], let value = decode(values[i]) { result[String(cString: key)] = value } }
            return result
        default: return nil
        }
    }
    private var drainingCoreEvents = false
    /// Preserve the ordinary handlers and consume the same client queue. true
    /// means this exact handle actually returned NONE within the bounded drain.
    @discardableResult func drainCoreEventsToEmpty(expectedHandle: OpaquePointer, maximum: Int = 100) -> Bool {
        guard handle == expectedHandle, !coreShutdownComplete, !drainingCoreEvents,
              (1...512).contains(maximum) else { return false }
        drainingCoreEvents = true; defer { drainingCoreEvents = false }
        for _ in 0..<maximum {
            guard handle == expectedHandle, !coreShutdownComplete,
                  let event = mpv_wait_event(expectedHandle, 0)?.pointee else { return false }
            if event.event_id == MPV_EVENT_NONE { return true }
            switch event.event_id {
            case MPV_EVENT_COMMAND_REPLY:
                // Copy scalar reply data before the next wait_event invalidates
                // event storage. Image IO is dispatched by the jobs controller.
                screenshotJobs.commandReply(id: event.reply_userdata, status: event.error)
                if let controller = explicitScriptController, controller.ownsReply(event.reply_userdata) {
                    controller.commandReply(id: event.reply_userdata, status: event.error,
                        clientID: Self.explicitScriptClientID(from: event.data))
                }
            case MPV_EVENT_SHUTDOWN:
                playbackProgram.invalidate(reason: "native-shutdown-event")
                temporaryPlaybackSpeed.coreClosed()
                cancelVideoConfigurationTransition()
                videoConfigurationClosing = true
                cancelScreenshotsForShutdown()
                coreShutdownComplete = true
                explicitScriptController?.shutdownRequested()
                secondarySubtitleStyle.coreClosed()
                liveASR.invalidate(reason: .quit)
                liveASRHostState.loadedFingerprint = nil
                nativeAudioQueue.coreDestroyed()
            case MPV_EVENT_SEEK:
                liveASRNativeSeekReceipt()
            case MPV_EVENT_PLAYBACK_RESTART:
                liveASRNativeRestartReceipt()
                playbackProgram.playbackRestartObserved()
            case MPV_EVENT_PROPERTY_CHANGE:
                if event.reply_userdata == 1 && loaded { updateTracks() }
            case MPV_EVENT_START_FILE:
                cancelVideoConfigurationTransition()
                if let data = event.data?.assumingMemoryBound(to: mpv_event_start_file.self).pointee {
                    let id = data.playlist_entry_id // Copy before wait_event invalidates C storage.
                    if nativeAudioQueue.receive(.start(id)) { break }
                    eventEntryID = id
                }
            case MPV_EVENT_FILE_LOADED:
                if nativeAudioQueue.receive(.loaded) { break }
                if playbackStopped { break }
                if let requestedEntryID, eventEntryID != requestedEntryID { break }
                error = nil; loaded = true; isLoading = false
                configureExactSeekPreroll()
                let explicitProgramStart = (resume ?? 0) > 0 || (pendingBookmarkPosition != nil && pendingBookmarkURL == activeURL)
                if let resume, resume > 0 { seek(resume, remember: false); toast("已恢复到 \(TimeText.format(resume))") }
                resume = nil
                if let pendingBookmarkPosition, pendingBookmarkURL == activeURL { seek(pendingBookmarkPosition, remember: false) }
                pendingBookmarkPosition = nil; pendingBookmarkURL = nil
                updateTracks()
                pendingSubtitles.forEach(addSubtitle); pendingSubtitles = []
                if let intent = loadPlaybackIntent, intent.itemID == playlist.currentItem?.id {
                    // Restore/bookmark seeks are submitted before honoring the
                    // current request's final Play choice. Old requests cannot
                    // publish an intent after Stop or a replacement load.
                    set("pause", intent.startPlaying ? "no" : "yes")
                }
                loadPlaybackIntent = nil
                playbackProgram.mediaLoaded(explicitStart: explicitProgramStart)
                videoAssets.mediaLoaded()
            case MPV_EVENT_END_FILE:
                if let data = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
                    let id = data.playlist_entry_id, reason = data.reason, failure = data.error
                    // One actual copied EOF can be delayed only by the isolated
                    // native-audio history verifier. Ordinary launches are inert.
                    if NativeAudioQueueVerifier.captureRealEnd(player: self, id: id, reason: reason, error: failure) { break }
                    if nativeAudioQueue.receive(.end(id, reason, failure)) { break }
                    if playbackStopped { break }
                    if let requestedEntryID, data.playlist_entry_id != requestedEntryID { break }
                    if data.reason == MPV_END_FILE_REASON_ERROR {
                        cancelVideoConfigurationTransition()
                        systemPiP.exit()
                        invalidateMediaPreferencePlayback()
                        loaded = false; isLoading = false
                        loadPlaybackIntent = nil; pendingLoad = nil
                        if !userVideoFilters.effectiveFragments.isEmpty {
                            userVideoFilters.suspendForCurrentMedia(reason: "本次播放失败，已暂时停用用户滤镜；设置已保留，可重新打开媒体重试。")
                            candidateVideoFilters = nil; applySettings()
                        }
                        error = "无法播放媒体：\(String(cString: mpv_error_string(data.error)))"
                    } else if data.reason == MPV_END_FILE_REASON_EOF, !loopFile, !nativeAudioQueue.blocksOrdinaryAdvance {
                        cancelVideoConfigurationTransition()
                        systemPiP.exit()
                        if !handledEOF { advanceAfterLiveASREOF() }
                    }
                }
            case MPV_EVENT_LOG_MESSAGE:
                if let log = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee, let text = log.text {
                    // Scan at most the documented diagnostic budget before
                    // copying a core-owned C string. Invalid or oversized logs
                    // are omitted; neither system logs nor UI keep the raw URL.
                    let length = strnlen(text, MediaDiagnosticRedactor.maximumInputBytes + 1)
                    let message: String
                    if length > MediaDiagnosticRedactor.maximumInputBytes {
                        message = "[oversized diagnostic omitted]"
                    } else {
                        message = MediaDiagnosticRedactor.redactUTF8(Data(bytes: text, count: length))
                    }
                    NSLog("mpv: %@", message)
                    let prefix = Self.boundedLogTag(log.prefix)
                    let level = Self.boundedLogTag(log.level)
                    videoAssets.observeLog(prefix: prefix, level: level, message: message)
                    if (prefix.contains("vf") || prefix.contains("lavfi")) && (["error", "fatal"].contains(level) || message.contains("Disabling filter")) {
                        videoFilterFailure = message.trimmingCharacters(in: .whitespacesAndNewlines)
                        if candidateVideoFilters == nil && !userVideoFilters.effectiveFragments.isEmpty {
                            userVideoFilters.suspendForCurrentMedia(reason: videoFilterFailure!)
                            applySettings()
                        }
                    }
                }

            default: break
            }
        }
        return false
    }
    private func poll() {
        guard let handle else { return }
        observeTemporarySpeed()
        _ = drainCoreEventsToEmpty(expectedHandle: handle)
        guard self.handle == handle, !coreShutdownComplete else { return }
        if loaded {
            if mediaPreferences.hasPendingTrackRestoration { restoreMediaPreferencesAfterTrackUpdate() }
            position = number("time-pos"); duration = number("duration")
            paused = flag("pause"); muted = flag("mute"); volume = number("volume"); speed = number("speed")
            audioID = Int(string("aid")) ?? 0; subtitleID = Int(string("sid")) ?? 0
            let hw = string("hwdec-current")
            decoder = hw == "no" || hw.isEmpty ? "软件解码" : hw
            let width = Int(number("width")); let height = Int(number("height"))
            let codec = string("video-codec")
            videoInfo = width > 0 ? "\(width) × \(height) · \(codec)" : "音频播放"
            if !flag("eof-reached") { handledEOF = false }
            if flag("eof-reached"), !handledEOF, !loopFile, !nativeAudioQueue.ownsEvents, !nativeAudioQueue.blocksOrdinaryAdvance {
                systemPiP.exit()
                advanceAfterLiveASREOF()
            }
            if Date().timeIntervalSince(lastSavedAt) > 5 { saveHistory(); history.flush(); lastSavedAt = Date() }
        }
        // Read updated state, then at most one native queue mutation. The
        // existing poll cadence remains 0.15s; no extra timer/thread is added.
        playbackProgram.journalNativePoll()
        playbackProgram.observe()
        nativeAudioQueue.poll()
        consumePendingVideoConfiguration()
        if liveASR.needsHostObservation { liveASR.observe(liveASRSnapshot()) }
        refreshAdvancedState()
        systemPiP.playing = loaded && !paused
        if loaded && number("width") > 0 && number("height") > 0 {
            systemPiP.aspectRatio = NSSize(width: number("width"), height: number("height"))
        }
        let loadingTimeout: TimeInterval = currentIsWebMedia ? 60 : 20
        if isLoading && Date().timeIntervalSince(openedAt) > loadingTimeout {
            cancelVideoConfigurationTransition()
            systemPiP.exit()
            invalidateMediaPreferencePlayback()
            loadPlaybackIntent = nil; pendingLoad = nil; playbackStopped = true
            isLoading = false
            error = currentIsWebMedia ? "网页媒体加载超时，请重新解析页面或检查网络。" : "媒体加载超时，请检查文件或网络地址"
            command(["stop"], report: false)
        }
    }


    /// Conservative metadata preflight uses the actual option list, including
    /// the isolated config subdirectory. An unavailable list refuses native
    /// preparation rather than silently substituting an empty search path.
    func nativeAudioDiscoveryDirectories(for source: URL) -> [URL]? {
        guard source.isFileURL, string("options/config-dir") == mpvConfigurationDirectory.path else { return nil }
        var result = [source.deletingLastPathComponent(), mpvConfigurationDirectory.appendingPathComponent("sub")]
        for name in ["audio-file-paths", "sub-file-paths"] {
            guard let paths = jsonProperty("options/" + name) as? [String], paths.count <= 16 else { return nil }
            for path in paths {
                guard path.utf8.count <= 4096,
                      !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      !path.contains("://"), !path.hasPrefix("~") else { return nil }
                result.append(path.hasPrefix("/") ? URL(fileURLWithPath: path)
                    : source.deletingLastPathComponent().appendingPathComponent(path, isDirectory: true))
            }
        }
        return result.count <= 32 ? result : nil
    }
    func nativeAudioCoverNames() -> [String]? {
        guard let names = jsonProperty("options/cover-art-whitelist") as? [String], names.count <= 64,
              names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("/")
                && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { return nil }
        return names
    }
    func nativeAudioPreparationEnvironment(revision: NativeQueueRevision) -> NativeAudioPlanBuilder.Environment? {
        guard !playbackProgram.preventsNativePrefetch,
              loaded, !isLoading, !profileStoresBlocked, flag("seekable"), !flag("seeking"),
              !nativeAudioManualTrackChoice, !userVideoFilters.isApplying,
              !videoAssets.isApplying, videoAssets.effectiveLUTFragments.isEmpty,
              userVideoFilters.effectiveFragments.isEmpty, candidateVideoFilters == nil,
              string("options/gapless-audio") == "weak",
              let trackRows = jsonProperty("track-list") as? [[String: Any]],
              trackRows.count == 1, let audio = trackRows.first,
              audio["type"] as? String == "audio", audio["external"] as? Bool != true,
              audio["selected"] as? Bool == true,
              let filters = jsonProperty("af") as? [Any], filters.isEmpty,
              let decoded = jsonProperty("audio-params") as? [String: Any],
              let output = jsonProperty("audio-out-params") as? [String: Any],
              let sourceRate = decoded["samplerate"] as? Int, sourceRate > 0,
              let outRate = output["samplerate"] as? Int, outRate == sourceRate,
              let sourceCount = decoded["channel-count"] as? Int, sourceCount > 0,
              output["channel-count"] as? Int == sourceCount,
              let sourceLayout = decoded["channels"] as? String, !sourceLayout.isEmpty,
              output["channels"] as? String == sourceLayout else { return nil }
        for name in ["audio-files", "sub-files", "cover-art-files"] {
            guard let files = jsonProperty("options/" + name) as? [String], files.isEmpty else { return nil }
        }
        return .init(revision: revision, base: mediaPreferences.baseSnapshot,
            effective: settings.sanitized(), activeSpeed: number("speed"),
            audioDelay: number("audio-delay"), subtitleDelay: number("sub-delay"),
            profileBlocked: profileStoresBlocked, currentTrackAutomatic: !nativeAudioManualTrackChoice,
            realAudioFilterEmpty: true, realOutputMatchesSource: true, mediaDocument: mediaPreferences.document,
            observedSampleRate: sourceRate, observedChannels: sourceCount, observedLayout: sourceLayout)
    }
    /// Publishes the real accepted native successor. No loadfile, pause, seek,
    /// AF/audio-device reset, autoplay default, or future-media preference
    /// mutation is allowed before this point.
    func nativeAudioAdoptStart(_ item: MediaItem, entryID: Int64) -> Bool {
        guard !coreShutdownComplete, !profileStoresBlocked,
              let rows = nativeAudioPlaylistReadback(),
              rows.first(where: { $0.playing })?.entryID == entryID,
              rows.first(where: { $0.playing })?.url == item.url,
              playlist.items.contains(where: { $0.id == item.id }) else { return false }
        liveASR.invalidate(reason: .queueAdvance)
        liveASRHostState.prepareLoad(item.url)
        nativeAudioPublishing = true
        defer { nativeAudioPublishing = false }
        cancelVideoConfigurationTransition(); systemPiP.exit()
        cancelScreenshotsForMediaChange(); cancelPendingFrameSteps()
        userVideoFilters.resumeForNewMedia(); SubtitleSpeechController.shared.stop()
        let changedMedia = playlist.currentItem?.id != item.id
        guard playlist.select(id: item.id) != nil else { return false }
        mediaPreferenceToken = mediaPreferences.prepareForLoad(item: item)
        synchronizeMediaPreferenceSettings()
        // Eligibility was bound to this revision and item. Revalidate after
        // actual prepare: imported/saved overlays never disappear silently.
        guard settings == mediaPreferences.baseSnapshot,
              mediaPreferences.currentExternalFiles.isEmpty else { return false }
        activeURL = item.url; requestedEntryID = entryID; eventEntryID = entryID
        loaded = false; isLoading = true; position = 0; duration = 0; tracks = []
        audioID = 0; subtitleID = 0
        handledEOF = false; playbackStopped = false; openedAt = Date()
        pendingLoad = nil; pendingSubtitles = []; resume = nil; loadPlaybackIntent = nil
        pendingBookmarkPosition = nil; pendingBookmarkURL = nil; seekReturnPosition = nil
        // An A-only marker belongs to its media. Complete A/B is an explicit
        // same-media guard and never authorizes a successor START.
        if changedMedia {
            abStart = nil; abEnd = nil
            set("ab-loop-a", "no"); set("ab-loop-b", "no")
        }
        return true
    }
    func nativeAudioAdoptLoaded(duration provenDuration: Double) {
        guard !playbackStopped, !coreShutdownComplete, provenDuration.isFinite, provenDuration > 0 else { return }
        loaded = true; isLoading = false; error = nil; duration = provenDuration
        // Mark the new context loaded and consume its proven-empty defaults
        // without the normal restoration bridge's applySettings()/AO setters.
        // That bridge includes delay=0 even for no record, so simply calling
        // updateTracks first would reset AF/device at every native boundary.
        if let item = playlist.currentItem {
            _ = mediaPreferences.applyRestoredTracksOnUpdate(token: mediaPreferenceToken,
                itemID: item.id, candidates: [])
            mediaPreferences.cancelPendingTrackRestoration()
        }
        updateTracks()
        paused = flag("pause")
        // The core retained actual pause intent. No autoplay assignment, resume
        // seek or applySettings() occurs at the ordinary native boundary.
    }
    func nativeAudioEmergencyStop() {
        liveASR.invalidate(reason: .stop)
        liveASRHostState.loadedFingerprint = nil
        _ = executeNativeAudioEmergencyStop()
        cancelVideoConfigurationTransition(); cancelPendingFrameSteps()
        playbackStopped = true; handledEOF = true; pendingLoad = nil; loadPlaybackIntent = nil
        pendingSubtitles = []; resume = nil; activeURL = nil; requestedEntryID = nil; eventEntryID = nil
        loaded = false; isLoading = false; paused = true; position = 0; duration = 0; tracks = []
        // Preserve the logical UUID queue and sticky loop-cleanup requirement.
        // Explicit Play retries clearing the native list loop before replace.
    }
    func nativeAudioOrdinaryFallback(_ item: MediaItem, startPlaying: Bool, resumeAt: Double? = nil) {
        nativeAudioPublishing = true
        let selected = playlist.select(id: item.id)
        nativeAudioPublishing = false
        guard let selected else { stopPlayback(); return }
        _ = load(selected, startPlaying: startPlaying, resumeAt: resumeAt)
    }

    @discardableResult func startLiveASR(mode: LiveASRController.Mode = .boundedPairs) async -> Bool {
        guard !continuousAudioEnabled, !nativeAudioQueue.ownsEvents else {
            error = "实时字幕暂不支持连续音频模式，请先关闭连续音频。"; return false
        }
        return await liveASR.start(snapshot: liveASRSnapshot(),mode:mode)
    }

    /// Finalize granted old-media PCM before changing its binding. A seek,
    /// replacement load or shutdown while awaiting never advances that media.
    private func advanceAfterLiveASREOF() {
        handledEOF = true
        guard liveASR.isActive else {
            if liveASR.needsHostObservation { liveASR.invalidate(reason: .queueAdvance) }
            if playbackProgram.ownsMediaEnd { position = duration; saveHistory(); playbackProgram.mediaEOF() }
            else { invalidateMediaPreferencePlayback(); position = duration; saveHistory(); next() }
            return
        }
        let token = mediaPreferenceToken, itemID = playlist.currentItem?.id
        let generation = liveASRHostState.seekGeneration
        Task { @MainActor in
            // Validate the observed EOF before touching the currently live ASR
            // session, as well as before advancing after its actual close.
            guard !coreShutdownComplete, !videoConfigurationClosing, !playbackStopped,
                  mediaPreferenceToken == token, playlist.currentItem?.id == itemID,
                  liveASRHostState.seekGeneration == generation, !flag("seeking"),
                  loaded, !isLoading, flag("eof-reached") else { return }
            await liveASR.finishForEOF()
            guard !coreShutdownComplete, !videoConfigurationClosing, !playbackStopped,
                  mediaPreferenceToken == token, playlist.currentItem?.id == itemID,
                  liveASRHostState.seekGeneration == generation, !flag("seeking"),
                  loaded, !isLoading, flag("eof-reached") else { return }
            if playbackProgram.ownsMediaEnd { position = duration; saveHistory(); playbackProgram.mediaEOF() }
            else { invalidateMediaPreferencePlayback(); position = duration; saveHistory(); next() }
        }
    }

    private static func boundedLogTag(_ pointer: UnsafePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        let length = strnlen(pointer, 65)
        guard length <= 64 else { return "" }
        return String(data: Data(bytes: pointer, count: length), encoding: .utf8)?.lowercased() ?? ""
    }
    func toggleSystemPiP() {
        guard systemPiP.state == .active || systemPiP.state == .entering
                || (loaded && tracks.contains(where: { $0.type == "video" })) else { return }
        if !systemPiP.available {
            toast(systemPiP.error ?? "当前系统无法使用画中画")
            return
        }
        systemPiP.playing = !flag("pause")
        systemPiP.toggle()
        if let error = systemPiP.error { toast(error) }
    }
    private func recordPlaybackProgramNativeJournal(_ event: String, details: [String: Any]) {
        playbackProgramNativeJournal.record(event: event, details: details, handle: handle,
            identity: ["boundItemID": mediaPreferences.boundItemID?.uuidString as Any? ?? NSNull(),
                "loadToken": mediaPreferenceToken.uuidString, "preferenceToken": mediaPreferences.token.uuidString,
                "selectedQueueItemID": playlist.currentItem?.id.uuidString as Any? ?? NSNull(),
                "requestedEntryID": requestedEntryID as Any? ?? NSNull(), "eventEntryID": eventEntryID as Any? ?? NSNull(),
                "loaded": loaded, "loading": isLoading, "playbackStopped": playbackStopped,
                "coreShutdownComplete": coreShutdownComplete, "videoConfigurationClosing": videoConfigurationClosing])
    }
    func playbackProgramSnapshot() -> PlaybackProgramSnapshot? {
        guard let handle, loaded, !isLoading, !playbackStopped,
              !coreShutdownComplete, !videoConfigurationClosing,
              mediaPreferences.token == mediaPreferenceToken,
              let itemID = mediaPreferences.boundItemID,
              playlist.currentItem?.id == itemID,
              let source = mediaPreferences.identity?.originalURL, activeURL == source,
              let requestedEntryID, eventEntryID == requestedEntryID,
              let index = Int(string("playlist-pos")), index >= 0,
              Int64(string("playlist/\(index)/id")) == requestedEntryID else { return nil }
        func finite(_ name: String) -> Double? {
            var value = 0.0
            guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0, value.isFinite else { return nil }
            return value
        }
        guard let time = finite("time-pos"), let length = finite("duration"), let rate = finite("speed"),
              let position = PlaybackProgram.microseconds(time), let duration = PlaybackProgram.microseconds(length) else { return nil }
        var remaining: Int64 = 0
        let count: Int64? = mpv_get_property(handle, "remaining-ab-loops", MPV_FORMAT_INT64, &remaining) >= 0 ? remaining : nil
        return .init(itemID: itemID, loadToken: mediaPreferenceToken, entryID: requestedEntryID,
                     position: position, duration: duration, remaining: count, seeking: flag("seeking"),
                     paused: flag("pause"), seekable: flag("seekable"), eof: flag("eof-reached"), forward: rate > 0,
                     configuredStart: Double(string("ab-loop-a")).flatMap(PlaybackProgram.microseconds),
                     configuredEnd: Double(string("ab-loop-b")).flatMap(PlaybackProgram.microseconds),
                     configuredCount: string("ab-loop-count") == "inf" ? -1 : Int64(string("ab-loop-count")))
    }
    func synchronizeMediaPreferenceSettings() {
        synchronizingMediaSettings = true
        settings = mediaPreferences.effectiveSettings
        synchronizingMediaSettings = false
    }
    func installGlobalBaseSettings(_ value: PlaybackSettings) {
        mediaPreferences.installBaseSettings(value)
        mediaPreferenceTrackingReady = true
        synchronizeMediaPreferenceSettings()
    }
    func invalidateMediaPreferencePlayback() {
        playbackProgram.invalidate(reason: "media-preference-playback-invalidated")
        liveASR.invalidate(reason: .load)
        liveASRHostState.loadedFingerprint = nil
        mediaPreferences.invalidatePlayback()
        mediaPreferenceToken = mediaPreferences.token
        synchronizeMediaPreferenceSettings()
    }
}
