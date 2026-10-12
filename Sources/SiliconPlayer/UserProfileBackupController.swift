import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers
import PlayerCore

@MainActor
private struct InputProfileShortcutStorage: ProfileShortcutStorage {
    let input: InputController
    func read() throws -> Data? { try input.profileShortcutData() }
    func write(_ data: Data?) throws { try input.writeProfileShortcutData(data) }
}

struct ProfileStartupState {
    let recovery: ProfileRecoveryOutcome
    let global: PlaybackSettings
    let filters: UserVideoFilterChain
    let media: MediaPreferenceDocument
    let web: WebMediaCatalog
    let notices: [String]
}

/// File commit precedes live adoption. The host applies engine configuration
/// once after adopting all typed documents; it never republishes their stores.
@MainActor
final class UserProfileBackupController: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var isImporting = false
    @Published private(set) var status = ""
    @Published private(set) var errorText: String?
    @Published private(set) var pendingImport: UserProfileBackupDocument?
    @Published private(set) var pendingName = ""
    @Published private(set) var blocksPersistence = false
    private let directory: URL
    private let input: InputController
    private let media: MediaPreferencesController
    private let filters: @MainActor () -> UserVideoFilterChain
    private let web: @MainActor () -> WebMediaCatalog?
    private let appVersion: String
    private let didCommit: @MainActor (UserProfileBackupDocument) -> Void
    private let beforeCommit: @MainActor () -> Void
    typealias AssetCommit = @MainActor (Data?,@escaping @Sendable (Data?) async throws -> Void,@escaping @MainActor () -> Bool) async throws -> ProfileImportOutcome
    private let assetsSnapshot: @MainActor () async throws -> VideoAssetPortableBundle
    private let assetsImport: @MainActor (UserProfileBackupDocument,@escaping AssetCommit) async throws -> ProfileImportOutcome
    private var closing=false
    private var previewWork:Task<Void,Never>?
    private var snapshotInProgress=false
    var hasActiveJobs:Bool {busy || previewWork != nil || snapshotInProgress}
    private var generation = UUID()

    init(directory: URL, input: InputController, media: MediaPreferencesController,
         filters: @escaping @MainActor () -> UserVideoFilterChain,
         web: @escaping @MainActor () -> WebMediaCatalog?, appVersion: String,
         assetsSnapshot: @escaping @MainActor () async throws -> VideoAssetPortableBundle,
         assetsImport: @escaping @MainActor (UserProfileBackupDocument,@escaping AssetCommit) async throws -> ProfileImportOutcome,
         beforeCommit: @escaping @MainActor () -> Void = {},
         didCommit: @escaping @MainActor (UserProfileBackupDocument) -> Void) {
        self.directory = directory; self.input = input; self.media = media
        self.filters = filters; self.web = web; self.appVersion = appVersion
        self.beforeCommit = beforeCommit; self.didCommit = didCommit
        self.assetsSnapshot = assetsSnapshot;self.assetsImport = assetsImport
    }
    func setPersistenceBlocked(_ value: Bool) { blocksPersistence = value; media.setPersistenceBlocked(value) }

    /// Invoke before preferences/catalog/queue restore. Existing stored-let
    /// controllers may already contain pre-recovery values: adopt this result in
    /// full, including filters, after journal recovery and before runtime apply.
    static func startUpRecovery(directory: URL, input: InputController) throws -> ProfileStartupState {
        let coordinator = UserProfileImportCoordinator(directory: directory, shortcuts: InputProfileShortcutStorage(input: input))
        let recovery = try coordinator.recoverPendingImport()
        if recovery != .none { input.reloadProfileShortcuts() }
        var notices: [String] = []
        func load<T>(_ name: String, maximum: Int, fallback: T, decode: (Data) throws -> T) -> T {
            do {
                guard let data = try BoundedProfileFile.read(directory.appendingPathComponent(name), maximumBytes: maximum, allowMissing: true) else { return fallback }
                return try decode(data)
            } catch { notices.append("\(name) 无法读取，原文件已保留"); return fallback }
        }
        let global = load("preferences.json", maximum: 1024 * 1024, fallback: PlaybackSettings()) {
            var result = try JSONDecoder().decode(PlaybackSettings.self, from: $0).sanitized()
            result.secondarySubtitleID = 0; return result
        }
        let filters = load("user-video-filters.json", maximum: UserVideoFilterStore.maximumBytes, fallback: UserVideoFilterChain()) {
            try JSONDecoder().decode(UserVideoFilterChain.self, from: $0).validated()
        }
        let media = load("media-preferences.json", maximum: MediaPreferenceDocument.maximumBytes, fallback: MediaPreferenceDocument(), decode: MediaPreferenceDocument.boundedDecode)
        let web = load("web-media-preferences.json", maximum: WebMediaCatalog.maximumBytes, fallback: WebMediaCatalog(), decode: WebMediaCatalog.boundedDecode)
        return ProfileStartupState(recovery: recovery, global: global, filters: filters, media: media, web: web, notices: notices)
    }

    /// Capture small typed host values once, then validate/hash full resource
    /// bytes on their actor and encode the bounded envelope off MainActor.
    func snapshotForExport() async throws -> UserProfileBackupDocument {
        guard !blocksPersistence,!closing,!snapshotInProgress else {throw ProfileImportError.pendingRecovery}
        snapshotInProgress=true;defer {snapshotInProgress=false}
        var global=media.baseSnapshot;global.secondarySubtitleID=0
        let base=UserProfileBackupDocument(global:global,
            shortcuts:input.bindings.map{BackupShortcut(action:$0.action,key:$0.key)},
            filters:filters(),media:media.document,web:web(),appVersion:appVersion)
        _=try input.encodedBackupShortcuts(base.shortcuts.map{($0.action,$0.key)})
        let resources=try await assetsSnapshot()
        guard !closing,!Task.isCancelled else {throw CancellationError()}
        var complete=base;complete.videoAssets=resources
        return try await Task.detached(priority:.userInitiated) {
            _=try complete.encoded(shortcutValidator:{_,key in key});return complete
        }.value
    }
    @discardableResult func export(to url:URL) async -> Bool {
        guard !busy,!closing,!blocksPersistence,url.isFileURL else {return false}
        let token=UUID();generation=token;busy=true;errorText=nil
        defer {busy=false}
        do {
            let backup=try await snapshotForExport()
            let data=try await Task.detached(priority:.userInitiated) {
                try backup.encoded(shortcutValidator:{_,key in key})
            }.value
            guard generation==token,!closing,!Task.isCancelled else {throw CancellationError()}
            // No detached late publication: keep ownership until the actual
            // atomic write completes; shutdown waits for busy to become false.
            try await Task.detached(priority:.userInitiated) {try data.write(to:url,options:.atomic)}.value
            if generation==token,!closing {status="已导出包含完整视频资源的设置备份"}
            return true
        } catch {if !closing {errorText="备份未导出，原文件已保留"};return false}
    }
    func chooseExport() {
        guard !busy else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "SiliconPlayer-settings.json"
        panel.title = "导出设置备份"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in _ = await self?.export(to: url) }
        }
    }
    func chooseImport() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "选择设置备份"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in self?.prepareImport(from: url) }
        }
    }
    /// Bounded nonblocking regular-file reading occurs off the main actor. A
    /// cancelled or superseded read cannot publish a late preview.
    func prepareImport(from url: URL) {
        guard !busy, !closing, !blocksPersistence, url.isFileURL else { return }
        let token = UUID(); generation = token; busy = true; pendingImport = nil
        pendingName = ""; errorText = nil; status = "正在读取备份"
        previewWork = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<UserProfileBackupDocument, Error> in
                Result {
                    guard let data = try BoundedProfileFile.read(url, maximumBytes: UserProfileBackupDocument.maximumBytes) else { throw MediaPreferenceError.invalidBackup }
                    return try UserProfileBackupDocument.boundedDecode(data,shortcutValidator:{_,key in key})
                }
            }.value
            guard let self else {return}
            guard self.generation == token,!self.closing else {self.busy=false;self.previewWork=nil;return}
            defer { self.busy = false;self.previewWork=nil }
            do {
                let backup = try result.get()
                _ = try self.input.encodedBackupShortcuts(backup.shortcuts.map { ($0.action, $0.key) })
                self.pendingImport = backup; self.pendingName = url.lastPathComponent
                self.status = "备份已验证，点击导入后替换所列设置"
            } catch { self.errorText = "备份无效或无法读取，当前设置未修改"; self.status = "" }
        }
    }
    func cancelPendingImport() {
        generation=UUID();previewWork?.cancel();pendingImport=nil;pendingName="";status=""
        // Never make a live read/commit look idle by clearing its owner flag.
    }
    @discardableResult func commitImport() async -> Bool {
        guard !busy,!closing,!blocksPersistence,let backup=pendingImport else {return false}
        let token=UUID();generation=token;busy=true;isImporting=true;errorText=nil
        let previousEditingBlocked=input.editingBlocked;input.editingBlocked=true
        defer {busy=false;isImporting=false;input.editingBlocked=blocksPersistence || previousEditingBlocked}
        do {
            let shortcutData=try input.encodedBackupShortcuts(backup.shortcuts.map{($0.action,$0.key)})
            let prepared=try await Task.detached(priority:.userInitiated) {
                try PreparedUserProfileStores.prepare(backup,shortcuts:shortcutData)
            }.value
            guard generation==token,!closing,!Task.isCancelled else {throw CancellationError()}
            beforeCommit()
            let coordinator=UserProfileImportCoordinator(directory:directory,shortcuts:InputProfileShortcutStorage(input:input))
            let outcome=try await assetsImport(backup,{[weak self] previous,publish,assetCurrent in
                guard let self,self.generation==token,!self.closing else {throw CancellationError()}
                return try await coordinator.applyPrepared(prepared,previousAssetManifest:previous,
                    publishAssetManifest:publish,isCurrent:{[weak self] in self?.generation==token && self?.closing==false && assetCurrent()})
            })
            // Disk truth is already committed. Late UI close must not undo it.
            input.reloadProfileShortcuts();setPersistenceBlocked(false);didCommit(backup)
            pendingImport=nil;pendingName=""
            guard !blocksPersistence else {errorText="设置文件已提交，运行时应用尚未完成；请重新启动";return false}
            status=outcome.cleanupPending ? "设置与完整资源已导入，临时记录将在下次启动清理" : "设置与完整资源已导入"
            return true
        } catch ProfileImportError.recoveryRequired {
            setPersistenceBlocked(true);errorText="导入未完成，恢复记录已保留；请重新启动以恢复上次设置"
        } catch ProfileImportError.pendingRecovery {
            setPersistenceBlocked(true);errorText="有尚未恢复的导入记录，请重新启动后再导入"
        } catch {if !closing {errorText="导入失败，已保留上次设置与资源"}}
        return false
    }
    func beginTermination() {closing=true;generation=UUID();previewWork?.cancel();pendingImport=nil}
    func shutdown() async -> Bool {
        beginTermination();await previewWork?.value
        let deadline=ProcessInfo.processInfo.systemUptime+3
        while hasActiveJobs && ProcessInfo.processInfo.systemUptime<deadline {try? await Task.sleep(nanoseconds:50_000_000)}
        // A pending recovery blocks writes; it must still permit a real quit/restart.
        return !hasActiveJobs
    }
    func resumeAfterCancelledTermination() {guard !hasActiveJobs else {return};closing=false}

}
