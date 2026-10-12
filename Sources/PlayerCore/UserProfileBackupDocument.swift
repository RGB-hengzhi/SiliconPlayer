import Foundation
import CryptoKit
#if MEDIA_PREFERENCE_PROTOTYPE
import PlayerCore
#endif

public struct BackupShortcut: Codable, Equatable {
    public let action: String
    public let key: String
    public init(action: String, key: String) { self.action = action; self.key = key }
}

/// Import policy belongs to the host's current actions/normalization/reserved
/// keys. Core does not copy AppKit shortcut policy or use UserDefaults.standard.
public typealias BackupShortcutValidator = (String, String) throws -> String

public struct UserProfileBackupDocument: Codable {
    public static let maximumLegacyBytes = 16 * 1024 * 1024
    public static let maximumBytes = maximumLegacyBytes + VideoAssetPortableBundle.maximumBytes
    public let kind: String
    public let version: Int
    public var createdAt: Date
    public var appVersion: String
    public var global: PlaybackSettings
    public var shortcuts: [BackupShortcut]
    public var filters: UserVideoFilterChain
    public var media: MediaPreferenceDocument
    public var web: WebMediaCatalog?
    public var videoAssets: VideoAssetPortableBundle?
    public var includes: [String] { ["global", "shortcuts", "filters", "media"] + (web == nil ? [] : ["web"]) + (videoAssets == nil ? [] : ["videoAssets"]) }

    public init(global: PlaybackSettings, shortcuts: [BackupShortcut], filters: UserVideoFilterChain,
                media: MediaPreferenceDocument, web: WebMediaCatalog? = nil, videoAssets: VideoAssetPortableBundle? = nil, appVersion: String,
                createdAt: Date = Date()) {
        kind = "SiliconPlayerUserProfile"; version = 1
        self.global = global; self.shortcuts = shortcuts; self.filters = filters; self.media = media
        self.web = web; self.videoAssets = videoAssets; self.appVersion = appVersion; self.createdAt = createdAt
    }
    public func validated(shortcutValidator: BackupShortcutValidator) throws -> Self {
        guard kind == "SiliconPlayerUserProfile", version == 1, createdAt.timeIntervalSince1970.isFinite,
              !appVersion.isEmpty, appVersion.utf8.count <= 128, !MediaIdentity.hasControls(appVersion),
              global == global.sanitized(), global.secondarySubtitleID == 0,
              shortcuts.count <= 256, Set(shortcuts.map(\.action)).count == shortcuts.count else { throw MediaPreferenceError.invalidBackup }
        var used = Set<String>()
        for shortcut in shortcuts {
            guard shortcut.action.utf8.count <= 128, shortcut.key.utf8.count <= 128,
                  !MediaIdentity.hasControls(shortcut.action), !MediaIdentity.hasControls(shortcut.key),
                  try shortcutValidator(shortcut.action, shortcut.key) == shortcut.key,
                  shortcut.key.isEmpty || used.insert(shortcut.key).inserted else { throw MediaPreferenceError.invalidShortcut }
        }
        _ = try filters.validated()
        guard try JSONEncoder().encode(filters).count <= UserVideoFilterStore.maximumBytes else { throw MediaPreferenceError.tooLarge }
        _ = try media.validated()
        _ = try media.encoded()
        if let web { _ = try WebMediaCatalog.boundedDecode(JSONEncoder().encode(web)) }
        if let videoAssets { _ = try videoAssets.encoded() }
        // Enlarging the envelope for resources never enlarges legacy settings.
        var legacy = self; legacy.videoAssets = nil
        guard try JSONEncoder().encode(legacy).count <= Self.maximumLegacyBytes else { throw MediaPreferenceError.tooLarge }
        return self
    }
    public func encoded(shortcutValidator: BackupShortcutValidator) throws -> Data {
        _ = try validated(shortcutValidator: shortcutValidator)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw MediaPreferenceError.tooLarge }
        return data
    }
    public static func boundedDecode(_ data: Data, shortcutValidator: BackupShortcutValidator) throws -> Self {
        try BoundedProfileJSON.preflight(data, maximumBytes: maximumBytes)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawSettings = object["global"] as? [String: Any],
              Set(object.keys) == Set(["kind","version","createdAt","appVersion","global","shortcuts","filters","media","includes"] + (object["web"] == nil ? [] : ["web"]) + (object["videoAssets"] == nil ? [] : ["videoAssets"])) else { throw MediaPreferenceError.invalidBackup }
        // Decode nested strict schemas before Codable can discard unknown keys.
        if let assets = object["videoAssets"] {
            guard let assetObject = assets as? [String: Any] else { throw MediaPreferenceError.invalidBackup }
            _ = try VideoAssetPortableBundle.decode(JSONSerialization.data(withJSONObject: assetObject))
        }
        let result = try JSONDecoder().decode(Self.self, from: data).validated(shortcutValidator: shortcutValidator)
        // Production PlaybackSettings intentionally tolerates malformed fields.
        // A backup must not silently replace them with defaults/clamped values.
        let decodedSettings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.global))
        guard try BoundedProfileJSON.canonical(rawSettings) == BoundedProfileJSON.canonical(decodedSettings) else { throw MediaPreferenceError.invalidBackup }
        return result
    }
    private enum CodingKeys: String, CodingKey { case kind, version, createdAt, appVersion, global, shortcuts, filters, media, web, videoAssets, includes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind); version = try c.decode(Int.self, forKey: .version)
        createdAt = try c.decode(Date.self, forKey: .createdAt); appVersion = try c.decode(String.self, forKey: .appVersion)
        global = try c.decode(PlaybackSettings.self, forKey: .global)
        shortcuts = try c.decode([BackupShortcut].self, forKey: .shortcuts)
        filters = try c.decode(UserVideoFilterChain.self, forKey: .filters)
        media = try c.decode(MediaPreferenceDocument.self, forKey: .media)
        web = try c.decodeIfPresent(WebMediaCatalog.self, forKey: .web)
        videoAssets = try c.decodeIfPresent(VideoAssetPortableBundle.self, forKey: .videoAssets)
        guard try c.decode([String].self, forKey: .includes) == includes else { throw MediaPreferenceError.invalidBackup }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind); try c.encode(version, forKey: .version)
        try c.encode(createdAt, forKey: .createdAt); try c.encode(appVersion, forKey: .appVersion)
        try c.encode(global, forKey: .global); try c.encode(shortcuts, forKey: .shortcuts)
        try c.encode(filters, forKey: .filters); try c.encode(media, forKey: .media)
        try c.encodeIfPresent(web, forKey: .web); try c.encodeIfPresent(videoAssets, forKey: .videoAssets); try c.encode(includes, forKey: .includes)
    }
}

@MainActor public protocol ProfileShortcutStorage {
    func read() throws -> Data?
    func write(_ data: Data?) throws
}
public protocol ProfilePublication {
    /// Failed publication must preserve the previous target bytes.
    func publish(_ data: Data, to target: URL) throws
    func remove(_ target: URL) throws
}
public struct AtomicProfilePublication: ProfilePublication {
    public init() {}
    public func publish(_ data: Data, to target: URL) throws { try data.write(to: target, options: .atomic) }
    public func remove(_ target: URL) throws {
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }
}
public enum ProfileImportError: Error { case pendingRecovery, failedAndRolledBack, recoveryRequired, invalidJournal }
public struct ProfileImportOutcome: Sendable {
    public let cleanupPending: Bool
    public init(cleanupPending: Bool) {self.cleanupPending=cleanupPending}
}
public enum ProfileRecoveryOutcome { case none, rolledBack, committedCleanup }

/// Profile persistence transaction. Host must explicitly supply an isolated
/// shortcut storage in verification mode. Runtime/player reapply is not tested.
@MainActor public final class UserProfileImportCoordinator {
    private static let maximumJournalBytes = 64 * 1024 * 1024
    public static let maximumShortcutBytes = 1024 * 1024
    public let directory: URL
    private let shortcuts: any ProfileShortcutStorage
    private let publication: any ProfilePublication
    private let mutex = NSLock()
    private static var asynchronousOwners:[String:UUID]=[:]
    private let resourceRecoveryRoot: URL
    public init(directory: URL, shortcuts: any ProfileShortcutStorage,
                publication: any ProfilePublication = AtomicProfilePublication()) {
        self.directory = directory.standardizedFileURL; self.shortcuts = shortcuts; self.publication = publication
        resourceRecoveryRoot = directory.appendingPathComponent("video-assets", isDirectory: true)
    }
    public var journalURL: URL { directory.appendingPathComponent("profile-import-journal.json") }
    private enum FileKind: String, Codable, CaseIterable {
        case global = "preferences.json", filters = "user-video-filters.json", media = "media-preferences.json", web = "web-media-preferences.json", videoAssets = "video-assets/video-assets.json"
    }
    private struct Previous: Codable { let existed: Bool; let data: Data?; let sha256: String? }
    private enum JournalPhase: String, Codable { case prepared, committed }
    private struct Journal: Codable {
        let version: Int
        let phase: JournalPhase
        let stagingID: UUID
        let files: [String: Previous]
        let shortcuts: Data?
        let shortcutSHA256: String?
    }
    private func checksum(_ data: Data?) -> String? { data.map { SHA256.hash(data: $0).map { String(format: "%02x",$0) }.joined() } }
    private func stageURL(_ id: UUID) -> URL { directory.appendingPathComponent(".profile-import-" + id.uuidString, isDirectory: true) }
    private func boundedRead(_ path: URL, limit: Int) throws -> Data? {
        try BoundedProfileFile.read(path,maximumBytes: limit,allowMissing: true)
    }
    private func validate(_ journal: Journal) throws {
        guard journal.version == 1, !journal.files.isEmpty,
              Set(journal.files.keys).isSubset(of: Set(FileKind.allCases.map(\.rawValue))),
              journal.files.allSatisfy({ name,value in
                  value.existed == (value.data != nil)
                    && (value.data?.count ?? 0) <= (name==FileKind.videoAssets.rawValue ? VideoAssetDocument.maximumManifestBytes : UserProfileBackupDocument.maximumLegacyBytes)
                    && value.sha256 == checksum(value.data)
              }),
              (journal.shortcuts?.count ?? 0) <= Self.maximumShortcutBytes,
              journal.shortcutSHA256 == checksum(journal.shortcuts) else { throw ProfileImportError.invalidJournal }
    }
    private func restore(_ journal: Journal) throws {
        try validate(journal)
        for name in journal.files.keys.sorted() {
            let previous = journal.files[name]!
            let target = directory.appendingPathComponent(name)
            if name == FileKind.videoAssets.rawValue {
                try VideoAssetStore.recoverProfileManifest(previous.data, directory: resourceRecoveryRoot)
            } else if let data = previous.data { try publication.publish(data, to: target) }
            else { try publication.remove(target) }
        }
        try shortcuts.write(journal.shortcuts)
    }
    private func clear(_ journal: Journal) throws {
        // Never trust a backup-supplied path: staging name comes from validated UUID.
        let stage = stageURL(journal.stagingID)
        if FileManager.default.fileExists(atPath: stage.path) { try FileManager.default.removeItem(at: stage) }
        try publication.remove(journalURL)
    }
    @discardableResult public func recoverPendingImport() throws -> ProfileRecoveryOutcome {
        guard Self.asynchronousOwners[directory.path]==nil else {throw ProfileImportError.pendingRecovery}
        mutex.lock(); defer { mutex.unlock() }
        guard let data = try boundedRead(journalURL, limit: Self.maximumJournalBytes) else { return .none }
        try BoundedProfileJSON.preflight(data, maximumBytes: Self.maximumJournalBytes)
        let journal = try JSONDecoder().decode(Journal.self, from: data)
        try validate(journal)
        if journal.phase == .prepared { try restore(journal); try clear(journal); return .rolledBack }
        try clear(journal); return .committedCleanup
    }
    @discardableResult public func apply(_ backup: UserProfileBackupDocument, shortcutValidator: BackupShortcutValidator,
                      shortcutEncoder: ([BackupShortcut]) throws -> Data) throws -> ProfileImportOutcome {
        // Complete semantic and byte-size validation occurs before creating any path.
        // Original synchronous contract remains for legacy callers/tests.
        // Resource-bearing imports must use applyPrepared with an owned lease.
        guard Self.asynchronousOwners[directory.path]==nil else {throw ProfileImportError.pendingRecovery}
        guard backup.videoAssets == nil else { throw MediaPreferenceError.invalidBackup }
        _ = try backup.encoded(shortcutValidator: shortcutValidator)
        let shortcutData = try shortcutEncoder(backup.shortcuts)
        guard shortcutData.count <= Self.maximumShortcutBytes, directory.isFileURL else { throw MediaPreferenceError.invalidBackup }
        let encoder = JSONEncoder()
        var targets: [FileKind: Data] = [.global: try encoder.encode(backup.global), .filters: try encoder.encode(backup.filters), .media: try backup.media.encoded()]
        if let web = backup.web { targets[.web] = try encoder.encode(web) }
        mutex.lock(); defer { mutex.unlock() }
        guard !FileManager.default.fileExists(atPath: journalURL.path) else { throw ProfileImportError.pendingRecovery }
        var previous: [String: Previous] = [:]
        for kind in targets.keys {
            let data = try boundedRead(directory.appendingPathComponent(kind.rawValue), limit: UserProfileBackupDocument.maximumLegacyBytes)
            previous[kind.rawValue] = Previous(existed: data != nil, data: data, sha256: checksum(data))
        }
        let oldShortcuts = try shortcuts.read()
        guard (oldShortcuts?.count ?? 0) <= Self.maximumShortcutBytes else { throw MediaPreferenceError.tooLarge }
        let journal = Journal(version: 1, phase: .prepared, stagingID: UUID(), files: previous, shortcuts: oldShortcuts, shortcutSHA256: checksum(oldShortcuts))
        let journalData = try encoder.encode(journal)
        guard journalData.count <= Self.maximumJournalBytes else { throw MediaPreferenceError.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = stageURL(journal.stagingID)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            for (kind,data) in targets { try publication.publish(data, to: staging.appendingPathComponent(kind.rawValue)) }
            try publication.publish(journalData, to: journalURL)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        do {
            // Stable order matters for meaningful injected second/third-write tests.
            for kind in FileKind.allCases {
                if let data = targets[kind] { try publication.publish(data, to: directory.appendingPathComponent(kind.rawValue)) }
            }
            try shortcuts.write(shortcutData)
            // Mark the whole transaction committed before disposable cleanup.
            // A restart after this point must preserve the successfully applied stores.
            let committed = Journal(version: 1, phase: .committed, stagingID: journal.stagingID,
                                    files: previous, shortcuts: oldShortcuts, shortcutSHA256: checksum(oldShortcuts))
            try publication.publish(encoder.encode(committed), to: journalURL)
        } catch {
            do { try restore(journal); try clear(journal) }
            catch { throw ProfileImportError.recoveryRequired }
            throw ProfileImportError.failedAndRolledBack
        }
        do { try clear(journal); return ProfileImportOutcome(cleanupPending: false) }
        catch { return ProfileImportOutcome(cleanupPending: true) }
    }
    /// Caller holds the resource-store lease and validates the real runtime
    /// before entering. Completion means journal committed, never just queued.
    public func applyPrepared(_ prepared: PreparedUserProfileStores,
                              previousAssetManifest: Data?,
                              publishAssetManifest: @escaping @Sendable (Data?) async throws -> Void,
                              isCurrent: @escaping @MainActor () -> Bool) async throws -> ProfileImportOutcome {
        guard Self.asynchronousOwners[directory.path]==nil else {throw ProfileImportError.pendingRecovery}
        let owner=UUID();Self.asynchronousOwners[directory.path]=owner
        defer {if Self.asynchronousOwners[directory.path]==owner {Self.asynchronousOwners.removeValue(forKey:directory.path)}}
        let previousShortcuts = try shortcuts.read()
        guard (previousShortcuts?.count ?? 0) <= Self.maximumShortcutBytes else { throw MediaPreferenceError.tooLarge }
        let worker = ProfileImportDiskWorker(directory: directory, publication: publication)
        try await worker.prepare(prepared, shortcuts: previousShortcuts, previousAssetManifest: previousAssetManifest)
        do {
            try Task.checkCancellation(); guard isCurrent() else { throw CancellationError() }
            try await worker.publishTargets()
            if let manifest = prepared.videoAssetManifest { try await publishAssetManifest(manifest) }
            try Task.checkCancellation(); guard isCurrent() else { throw CancellationError() }
            try shortcuts.write(prepared.shortcuts)
            try Task.checkCancellation(); guard isCurrent() else { throw CancellationError() }
            try await worker.markCommitted()
        } catch {
            // Rollback is deliberately independent of caller cancellation.
            do {
                try await Task { @MainActor [shortcuts] in
                    try await worker.restoreFiles()
                    if prepared.videoAssetManifest != nil { try await publishAssetManifest(previousAssetManifest) }
                    try shortcuts.write(previousShortcuts)
                    try await worker.clear()
                }.value
            } catch { throw ProfileImportError.recoveryRequired }
            throw ProfileImportError.failedAndRolledBack
        }
        // Never revert runtime after a committed journal, even if cleanup fails.
        do { try await worker.clear(); return ProfileImportOutcome(cleanupPending: false) }
        catch { return ProfileImportOutcome(cleanupPending: true) }
    }

}
