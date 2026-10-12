import AppKit
import CryptoKit
import PlayerCore

/// Opt-in actual application checks. Normal launch never creates this object.
/// API-driven renderer/settings/store checks, not physical input acceptance.
@MainActor
final class MediaProfileVerifier {
    private struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }
    private let player: PlayerModel
    private let report: URL
    private let mode: String
    private var task: Task<Void, Never>?
    private var result: [String: Any]?
    private var observations: [[String: Any]] = []
    private var snapshots: [[String: Any]] = []
    private var images: [String] = []
    private var stage = "setup"
    private var dailyShortcutFingerprint = ""
    private var fixtureRoot: URL!
    private var source: URL!
    private var alternate: URL!
    private var externalAudio: URL!
    private var primary: URL!
    private var secondary: URL!
    private var files: [String] { ["preferences.json", "user-video-filters.json", "media-preferences.json", "web-media-preferences.json"] }

    init(player: PlayerModel, report: URL, mode: String) {
        self.player = player; self.report = report; self.mode = mode
    }
    func tick() -> [String: Any]? {
        if let result { return result }
        guard task == nil else { return nil }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try self.configure()
                switch self.mode {
                case "media-preferences": try await self.verifyPreferences()
                case "media-profile-backup": try await self.verifyBackup()
                case "media-profile-journal-prepare": try await self.prepareJournal()
                case "media-profile-recovery": try await self.verifyRecovery()
                case "media-profile-malformed-startup": try await self.verifyMalformedStartup()
                case "media-profile-lifecycle": try await self.verifyLifecycle()
                default: throw Failure(text: "Unknown media/profile mode")
                }
                self.finish(passed: true)
            } catch { self.finish(passed: false, failure: MediaDiagnosticRedactor.redact(error.localizedDescription)) }
        }
        return nil
    }
    private func configure() throws {
        let env = ProcessInfo.processInfo.environment
        guard let storage = env["SILICONPLAYER_VERIFY_STORAGE"], storage.hasPrefix("/"),
              let reportPath = env["SILICONPLAYER_VERIFY_REPORT"], reportPath == report.path,
              let root = env["SILICONPLAYER_VERIFY_MEDIA_PROFILE_ROOT"], root.hasPrefix("/"),
              PlayerModel.supportDirectory.standardizedFileURL.path == URL(fileURLWithPath: storage).standardizedFileURL.path else {
            throw Failure(text: "Explicit private verification storage required")
        }
        fixtureRoot = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard (try? fixtureRoot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw Failure(text: "Owned fixture directory required")
        }
        func fixture(_ key: String) throws -> URL {
            guard let path = env[key], path.hasPrefix("/") else { throw Failure(text: "Owned local fixture required") }
            // Compare canonical paths together: /private/tmp and /tmp are aliases on macOS.
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(fixtureRoot.path + "/"), (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw Failure(text: "Fixture is not a regular file") }
            return url
        }
        source = try fixture("SILICONPLAYER_VERIFY_MEDIA_PROFILE_SOURCE")
        alternate = try fixture("SILICONPLAYER_VERIFY_MEDIA_PROFILE_ALTERNATE")
        externalAudio = try fixture("SILICONPLAYER_VERIFY_MEDIA_PROFILE_AUDIO")
        primary = try fixture("SILICONPLAYER_VERIFY_MEDIA_PROFILE_PRIMARY")
        secondary = try fixture("SILICONPLAYER_VERIFY_MEDIA_PROFILE_SECONDARY")
        dailyShortcutFingerprint = try standardShortcutFingerprint()
        try check("private-shortcut-suite-selected", InputController.verificationSuiteName(environment: env) != nil)
    }
    private func finish(passed: Bool, failure: String? = nil) {
        let dailyUnchanged = !dailyShortcutFingerprint.isEmpty && (try? standardShortcutFingerprint()) == dailyShortcutFingerprint
        observations.append(["id": "daily-standard-shortcut-key-unmodified", "passed": dailyUnchanged])
        var value: [String: Any] = ["mediaProfilePassed": passed && dailyUnchanged, "mediaProfileChecks": observations,
            "mediaProfileSnapshots": snapshots, "mediaProfileImages": images, "mediaProfileStage": stage,
            "mediaProfileRuntimeAdoptions": player.profileRuntimeAdoptionCount,
            "physicalNativeUIAcceptance": false,
            "scope": "Owned private local fixtures and verification-only InputController suite; actual application APIs, renderer and stores. Internal observations are not separate groups. Journal fault injection verifies process restart recovery, not power-loss durability."]
        if let failure { value["failure"] = failure }
        result = value
    }
    private func check(_ id: String, _ value: Bool) throws {
        observations.append(["id": id, "passed": value])
        if !value { throw Failure(text: "Media/profile check failed: " + id) }
    }
    private func wait(_ label: String, seconds: Double = 12, until predicate: () -> Bool) async throws {
        stage = label
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate() {
            try Task.checkCancellation()
            if ProcessInfo.processInfo.systemUptime >= deadline { throw Failure(text: "Condition timeout: " + label) }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
    private func closeEnough(_ property: String, _ expected: Double) -> Bool { abs(player.number(property) - expected) < 0.0001 }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func standardShortcutFingerprint() throws -> String {
        guard let value = UserDefaults.standard.object(forKey: "SiliconPlayer.shortcuts.v1") else { return "missing" }
        let data = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
        guard data.count <= 1024 * 1024 else { throw Failure(text: "Daily shortcut key exceeds audit limit") }
        return digest(data)
    }
    private func storeFingerprints() throws -> [String: String] {
        var value: [String: String] = [:]
        for name in files {
            value[name] = try BoundedProfileFile.read(PlayerModel.supportDirectory.appendingPathComponent(name), maximumBytes: UserProfileBackupDocument.maximumBytes, allowMissing: true).map(digest) ?? "missing"
        }
        value["shortcuts"] = try InputController.shared.profileShortcutData().map(digest) ?? "missing"
        return value
    }
    private func sample(_ label: String) {
        snapshots.append(["stage": label, "loaded": player.loaded, "loading": player.isLoading,
            "paused": player.flag("pause"), "position": player.number("time-pos"), "renderFrames": player.renderProgress.frames,
            "rotation": player.number("video-rotate"), "zoom": player.number("video-zoom"),
            "aid": player.string("aid"), "sid": player.string("sid"), "secondarySid": player.string("secondary-sid"),
            "audioDelay": player.number("audio-delay"), "subtitleDelay": player.number("sub-delay"), "secondaryDelay": player.number("secondary-sub-delay"),
            "baseRotation": player.mediaPreferences.baseSnapshot.rotation, "baseZoom": player.mediaPreferences.baseSnapshot.zoom,
            "baseBrightness": player.mediaPreferences.baseSnapshot.brightness, "pendingRestoration": player.mediaPreferences.hasPendingTrackRestoration])
    }
    private func open(_ url: URL) async throws {
        try await player.openAndWaitForCommit([url])
        try await wait("actual fixture load") { self.player.loaded && !self.player.isLoading && self.player.currentURL?.standardizedFileURL.path == url.standardizedFileURL.path && self.player.mediaPreferences.isLoaded }
        player.set("pause", "no")
    }
    private func advances(_ id: String) async throws {
        let frames = player.renderProgress.frames, position = player.number("time-pos")
        try await wait("real renderer/time advance", seconds: 6) { self.player.renderProgress.frames >= frames + 10 && self.player.number("time-pos") >= position + 0.25 }
        try check(id, !player.flag("pause") && player.error == nil && player.renderProgress.frames >= frames + 10)
        sample(id)
    }
    private func localTrack(_ url: URL, kind: MediaTrackKind) -> MediaTrackCandidate? {
        player.mediaTrackCandidates().first {
            guard $0.descriptor.kind == kind, case .localFile(let file) = $0.descriptor.source else { return false }
            return file.standardizedFileURL.path == url.standardizedFileURL.path
        }
    }
    private func selectedSource(_ property: String, _ url: URL, kind: MediaTrackKind) -> Bool {
        guard let id = Int(player.string(property)),
              let selected = player.mediaTrackCandidates().first(where: { $0.runtimeID == id && $0.descriptor.kind == kind }),
              case .localFile(let original) = selected.descriptor.source else { return false }
        return original.standardizedFileURL.path == url.standardizedFileURL.path
    }
    private func capture(_ name: String) async throws {
        let destination = report.deletingLastPathComponent().appendingPathComponent(name + ".png")
        player.command(["screenshot-to-file", destination.path, "video"])
        try await wait("actual media PNG") { (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 1024 }
        images.append(destination.path)
    }
    @discardableResult private func saveWithExternalTracks() async throws -> (primaryID: Int, secondaryID: Int) {
        let hold = fixtureRoot.appendingPathComponent("initial-subtitle-hold", isDirectory: true)
        try FileManager.default.createDirectory(at: hold, withIntermediateDirectories: true)
        for subtitle in [primary!, secondary!] { try FileManager.default.moveItem(at: subtitle, to: hold.appendingPathComponent(subtitle.lastPathComponent)) }
        try await open(source)
        for subtitle in [primary!, secondary!] { try FileManager.default.moveItem(at: hold.appendingPathComponent(subtitle.lastPathComponent), to: subtitle) }
        player.command(["audio-add", externalAudio.path, "select"])
        // Opposite order from restore's primary/secondary file list makes runtime
        // subtitle IDs change while saved source descriptors remain identical.
        player.command(["sub-add", secondary.path, "auto"])
        player.command(["sub-add", primary.path, "select"])
        try await wait("actual external metadata") { self.localTrack(self.externalAudio, kind: .audio) != nil && self.localTrack(self.primary, kind: .subtitle) != nil && self.localTrack(self.secondary, kind: .subtitle) != nil }
        let p = localTrack(primary, kind: .subtitle)!, s = localTrack(secondary, kind: .subtitle)!
        player.selectAudio(localTrack(externalAudio, kind: .audio)!.runtimeID); player.selectSubtitle(p.runtimeID)
        player.setAudioDelay(0.35); player.setSubtitleDelay(-0.2)
        player.updateSettings {
            $0.brightness = 7; $0.rotation = 90; $0.zoom = 0.25; $0.panX = 0.1
            $0.processing.projection = "equirect"; $0.processing.yaw = 20
            $0.secondarySubtitleID = s.runtimeID; $0.processing.secondarySubtitleDelay = 0.6
        }
        try await wait("geometry/delays actually apply") { self.closeEnough("video-rotate", 90) && self.closeEnough("video-zoom", 0.25) && self.closeEnough("audio-delay", 0.35) && self.closeEnough("sub-delay", -0.2) && self.closeEnough("secondary-sub-delay", 0.6) && Int(self.player.string("secondary-sid")) == s.runtimeID && self.player.string("vf").contains("v360") }
        guard player.saveCurrentMediaPreferences() else { throw Failure(text: "Actual readback snapshot save rejected") }
        return (p.runtimeID, s.runtimeID)
    }
    private func verifyPreferences() async throws {
        let oldIDs = try await saveWithExternalTracks()
        try check("actual-external-audio-dual-subtitle-save", selectedSource("aid", externalAudio, kind: .audio) && selectedSource("sid", primary, kind: .subtitle) && selectedSource("secondary-sid", secondary, kind: .subtitle))
        let bytes = try Data(contentsOf: PlayerModel.supportDirectory.appendingPathComponent("media-preferences.json"))
        let decoded = try MediaPreferenceDocument.boundedDecode(bytes)
        try check("saved-original-source-and-no-runtime-id", decoded.entries.count == 1 && !String(decoding: bytes, as: UTF8.self).contains("runtimeID") && decoded.entries.values.first?.geometry?.rotation == 90)
        let base = player.mediaPreferences.baseSnapshot
        player.updateSettings { $0.contrast = 13; $0.processing.scaler = "lanczos" }
        player.persistSettings()
        let globals = try JSONDecoder().decode(PlaybackSettings.self, from: Data(contentsOf: PlayerModel.preferenceURL))
        try check("unrelated-edit-persists-base-without-restored-geometry", globals.rotation == base.rotation && globals.zoom == base.zoom && globals.processing.projection == base.processing.projection && globals.contrast == 13 && globals.processing.scaler == "lanczos" && globals.secondarySubtitleID == 0)
        try await open(source)
        try await wait("saved external sources restore") { !self.player.mediaPreferences.hasPendingTrackRestoration && self.selectedSource("aid", self.externalAudio, kind: .audio) && self.selectedSource("sid", self.primary, kind: .subtitle) && self.selectedSource("secondary-sid", self.secondary, kind: .subtitle) }
        try check("reordered-runtime-ids-match-original-descriptors", Int(player.string("sid")) != oldIDs.primaryID && Int(player.string("secondary-sid")) != oldIDs.secondaryID)
        let raw = player.mediaTrackCandidates()
        func localSubtitles(_ file: URL) -> [MediaTrackCandidate] {
            raw.filter { candidate in
                guard candidate.descriptor.kind == .subtitle, case .localFile(let url) = candidate.descriptor.source else { return false }
                return url.standardizedFileURL.path == file.standardizedFileURL.path
            }
        }
        let primaryRows = localSubtitles(primary), secondaryRows = localSubtitles(secondary)
        try check("fuzzy-and-explicit-same-source-rows-remain-inspectable", primaryRows.count >= 2 && secondaryRows.count >= 2)
        try check("real-local-zh-en-inference-and-file-url-missing-language", primaryRows.contains { $0.descriptor.language == "zh" } && primaryRows.contains { $0.descriptor.language.isEmpty } && secondaryRows.contains { $0.descriptor.language == "en" } && secondaryRows.contains { $0.descriptor.language.isEmpty })
        let restoredCandidates = player.restorationMediaTrackCandidates()
        func restoredCount(_ file: URL) -> Int {
            restoredCandidates.filter { candidate in
                guard candidate.descriptor.kind == .subtitle, case .localFile(let url) = candidate.descriptor.source else { return false }
                return url.standardizedFileURL.path == file.standardizedFileURL.path
            }.count
        }
        try check("actual-restoration-deduplicates-same-source-stream", restoredCount(primary) == 1 && restoredCount(secondary) == 1 && !player.mediaPreferences.status.contains("多个匹配"))
        let rows = player.jsonProperty("track-list") as? [[String: Any]] ?? []
        let embedded = rows.filter { ($0["type"] as? String) == "sub" && ($0["external"] as? Bool) != true }
        let embeddedIDs = Set(embedded.compactMap { $0["id"] as? Int })
        let keptEmbedded = restoredCandidates.filter { $0.descriptor.kind == .subtitle && $0.descriptor.source == .embedded }
        try check("different-embedded-stream-indices-retained", embedded.count == 2 && Set(embedded.compactMap { $0["ff-index"] as? Int }).count == 2 && Set(keptEmbedded.map(\.runtimeID)) == embeddedIDs)
        let currentPrimary = Int(player.string("sid"))!
        let duplicatePrimary = primaryRows.first { $0.runtimeID != currentPrimary }!
        player.updateSettings { $0.secondarySubtitleID = duplicatePrimary.runtimeID }
        try await wait("same stream cannot be both subtitle slots") { self.player.settings.secondarySubtitleID == 0 && self.player.string("secondary-sid") == "no" }
        try check("duplicate-original-stream-not-used-as-second-subtitle", selectedSource("sid", primary, kind: .subtitle) && player.settings.secondarySubtitleID == 0)
        let count = raw.count
        player.addSubtitle(primary)
        try await Task.sleep(nanoseconds: 200_000_000)
        try check("manual-existing-original-subtitle-does-not-add-third-copy", player.mediaTrackCandidates().count == count && selectedSource("sid", primary, kind: .subtitle))
        let inferredPrimary = primaryRows.first { $0.descriptor.language == "zh" }!
        let inferredSecondary = secondaryRows.first { $0.descriptor.language == "en" }!
        player.selectSubtitle(inferredPrimary.runtimeID)
        player.updateSettings { $0.secondarySubtitleID = inferredSecondary.runtimeID }
        try await wait("inferred language tracks actually selected") { Int(self.player.string("sid")) == inferredPrimary.runtimeID && Int(self.player.string("secondary-sid")) == inferredSecondary.runtimeID }
        try check("actual-inferred-language-track-selection-saved", player.saveCurrentMediaPreferences())
        // This owned verifier turns fuzzy discovery off for one load to prove
        // saved zh/en survives actual URL-only preload metadata with no language.
        player.set("sub-auto", "no")
        try await open(source)
        try await wait("inferred languages restore URL-only metadata") { !self.player.mediaPreferences.hasPendingTrackRestoration && self.selectedSource("sid", self.primary, kind: .subtitle) && self.selectedSource("secondary-sid", self.secondary, kind: .subtitle) }
        let current = player.mediaTrackCandidates()
        let selectedIDs = [Int(player.string("sid")), Int(player.string("secondary-sid"))].compactMap { $0 }
        try check("saved-inferred-language-restores-file-url-without-language", selectedIDs.count == 2 && current.filter { selectedIDs.contains($0.runtimeID) && $0.descriptor.kind == .subtitle }.allSatisfy { $0.descriptor.language.isEmpty })
        player.set("sub-auto", "fuzzy")
        try check("dual-delays-geometry-and-projection-restored", closeEnough("audio-delay", 0.35) && closeEnough("sub-delay", -0.2) && closeEnough("secondary-sub-delay", 0.6) && closeEnough("video-rotate", 90) && closeEnough("video-zoom", 0.25) && player.string("vf").contains("v360") && player.settings.processing.yaw == 20)
        try await advances("restored-settings-real-time-and-frames")
        try await capture("media-preferences-restored")
        try await open(alternate)
        try check("replacement-inherits-global-not-previous-media", closeEnough("video-rotate", Double(base.rotation)) && closeEnough("video-zoom", base.zoom) && closeEnough("audio-delay", 0) && closeEnough("sub-delay", 0) && player.settings.processing.projection == base.processing.projection && player.settings.secondarySubtitleID == 0)
        try await advances("replacement-real-time-and-frames")
        player.stopPlayback()
    }
    private func verifyBackup() async throws {
        _ = try await saveWithExternalTracks()
        var independent = SecondarySubtitleStyleSettings(primary: player.settings)
        independent.enabled = true; independent.font = "PingFang SC"
        independent.size = 28; independent.background = true
        player.updateSettings { $0.secondarySubtitleStyle = independent }
        try await wait("independent secondary style actually applied") { self.player.secondarySubtitleStyle.matches(independent) }
        guard player.saveCurrentMediaPreferences() else { throw Failure(text: "Actual secondary-style media snapshot save rejected") }
        let importedToken = player.mediaPreferenceToken, importedItem = player.mediaPreferences.boundItemID
        guard importedItem != nil else { throw Failure(text: "Actual loaded Core item binding required") }
        let controller = player.profileBackup, backupFile = fixtureRoot.appendingPathComponent("exported-settings.json")
        guard await controller.export(to: backupFile) else { throw Failure(text: "Actual backup export failed") }
        var backup = try UserProfileBackupDocument.boundedDecode(Data(contentsOf: backupFile), shortcutValidator: InputController.validateBackupShortcut)
        try check("export-actual-base-not-media-overlay", backup.global.rotation == player.mediaPreferences.baseSnapshot.rotation && backup.global.rotation != player.settings.rotation && backup.global.secondarySubtitleID == 0 && backup.media.entries.count == 1 && backup.shortcuts.count == InputController.shared.bindings.count)
        backup.global.brightness = 31; backup.global.rotation = 180
        backup.filters = UserVideoFilterChain(filters: [.init(kind: .horizontalFlip)])
        let incoming = fixtureRoot.appendingPathComponent("incoming-settings.json")
        try backup.encoded(shortcutValidator: InputController.validateBackupShortcut).write(to: incoming)
        let before = try storeFingerprints(), adoptions = player.profileRuntimeAdoptionCount
        controller.prepareImport(from: incoming)
        try await wait("real backup preview") { !controller.busy && controller.pendingImport != nil }
        controller.cancelPendingImport()
        try check("valid-preview-cancel-zero-store-and-runtime-change", try storeFingerprints() == before && player.profileRuntimeAdoptionCount == adoptions && closeEnough("video-rotate", 90))
        let bad = fixtureRoot.appendingPathComponent("invalid-settings.json")
        try Data("{\"kind\":\"SiliconPlayerUserProfile\",\"kind\":\"duplicate\"}".utf8).write(to: bad)
        controller.prepareImport(from: bad)
        try await wait("invalid backup rejection") { !controller.busy }
        try check("invalid-backup-zero-write", controller.pendingImport == nil && controller.errorText != nil && (try storeFingerprints()) == before && player.profileRuntimeAdoptionCount == adoptions)
        controller.prepareImport(from: incoming)
        try await wait("validated import ready") { !controller.busy && controller.pendingImport != nil }
        try check("actual-complete-profile-commit", await controller.commitImport() && !controller.blocksPersistence && !player.profileStoresBlocked)
        try await wait("imported runtime readback") {
            self.closeEnough("brightness", 31) && self.closeEnough("video-rotate", 90)
                && self.closeEnough("video-zoom", 0.25) && self.closeEnough("video-pan-x", 0.1)
                && self.closeEnough("audio-delay", 0.35) && self.closeEnough("sub-delay", -0.2)
                && self.closeEnough("secondary-sub-delay", 0.6)
                && self.selectedSource("aid", self.externalAudio, kind: .audio)
                && self.selectedSource("sid", self.primary, kind: .subtitle)
                && self.selectedSource("secondary-sid", self.secondary, kind: .subtitle)
                && self.player.secondarySubtitleStyle.matches(independent)
                && self.player.string("vf").contains("hflip") && self.player.string("vf").contains("v360")
        }
        try check("one-runtime-adoption-with-all-typed-stores", player.profileRuntimeAdoptionCount == adoptions + 1 && player.mediaPreferences.baseSnapshot == backup.global && player.userVideoFilters.chain == backup.filters && player.mediaPreferences.document == backup.media && closeEnough("audio-delay", 0.35) && closeEnough("sub-delay", -0.2) && closeEnough("secondary-sub-delay", 0.6) && selectedSource("aid", externalAudio, kind: .audio) && selectedSource("sid", primary, kind: .subtitle) && selectedSource("secondary-sid", secondary, kind: .subtitle) && player.settings.secondarySubtitleID == Int(player.string("secondary-sid")) && player.settings.secondarySubtitleStyle == independent && player.secondarySubtitleStyle.matches(independent) && player.mediaPreferenceToken == importedToken && player.mediaPreferences.boundItemID == importedItem && player.loaded && !player.isLoading)
        try await advances("committed-profile-real-time-and-frames")
        try await capture("media-profile-imported")
        // These are subasserts of the same backup group, not new CHECK IDs.
        // Explicitly disabled restoration and a document with no current record
        // must keep imported globals/default track policy rather than old overlay.
        func verifyDefaultFallback(_ value: UserProfileBackupDocument, name: String) async throws {
            let path = fixtureRoot.appendingPathComponent(name + ".json")
            try value.encoded(shortcutValidator: InputController.validateBackupShortcut).write(to: path)
            let beforeAdoptions = player.profileRuntimeAdoptionCount
            controller.prepareImport(from: path)
            try await wait("fallback preview " + name) { !controller.busy && controller.pendingImport != nil }
            guard await controller.commitImport(), !controller.blocksPersistence, !player.profileStoresBlocked else {
                throw Failure(text: "Default fallback import rejected: " + name)
            }
            try await wait("fallback actual readback " + name) {
                self.closeEnough("video-rotate", Double(value.global.rotation))
                    && self.closeEnough("video-zoom", value.global.zoom)
                    && self.closeEnough("audio-delay", 0) && self.closeEnough("sub-delay", 0)
                    && self.closeEnough("secondary-sub-delay", value.global.processing.secondarySubtitleDelay)
                    && ["no", "0"].contains(self.player.string("secondary-sid"))
                    && self.player.secondarySubtitleStyle.matches(value.global.secondarySubtitleStyle)
            }
            guard player.profileRuntimeAdoptionCount == beforeAdoptions + 1,
                  player.mediaPreferences.baseSnapshot == value.global,
                  player.mediaPreferences.document == value.media, player.userVideoFilters.chain == value.filters,
                  player.settings.secondarySubtitleID == 0,
                  player.settings.secondarySubtitleStyle == value.global.secondarySubtitleStyle,
                  player.mediaPreferenceToken == importedToken, player.mediaPreferences.boundItemID == importedItem,
                  player.loaded, !player.isLoading else { throw Failure(text: "Default fallback typed-store/Core binding mismatch: " + name) }
            sample(name)
        }
        var disabled = backup; disabled.media.automaticallyRestore = false
        try await verifyDefaultFallback(disabled, name: "profile-auto-restore-disabled")
        var noMatch = backup; noMatch.media = MediaPreferenceDocument()
        try await verifyDefaultFallback(noMatch, name: "profile-current-record-missing")
        player.stopPlayback()
    }
    private struct ActualShortcuts: ProfileShortcutStorage {
        func read() throws -> Data? { try InputController.shared.profileShortcutData() }
        func write(_ value: Data?) throws { try InputController.shared.writeProfileShortcutData(value) }
    }
    private final class JournalFault: ProfilePublication {
        let directory: URL
        var remaining = 2
        let normal = AtomicProfilePublication()
        init(directory: URL) { self.directory = directory }
        func publish(_ data: Data, to target: URL) throws {
            if target.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path && target.lastPathComponent == "media-preferences.json" && remaining > 0 {
                remaining -= 1; throw Failure(text: "Owned journal publication fault")
            }
            try normal.publish(data, to: target)
        }
        func remove(_ target: URL) throws { try normal.remove(target) }
    }
    private func prepareJournal() async throws {
        _ = try await saveWithExternalTracks()
        var global = player.mediaPreferences.baseSnapshot; global.brightness = 11
        player.installGlobalBaseSettings(global); player.persistSettings()
        try UserVideoFilterStore(fileURL: PlayerModel.supportDirectory.appendingPathComponent("user-video-filters.json")).save(UserVideoFilterChain())
        try InputController.shared.writeProfileShortcutData(InputController.shared.encodedBackupShortcuts(InputController.shared.bindings.map { ($0.action, $0.key) }))
        player.stopPlayback()
        let expected = try storeFingerprints()
        try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]).write(to: PlayerModel.supportDirectory.appendingPathComponent("media-profile-recovery-expected.json"))
        var backup = try await player.profileBackup.snapshotForExport()
        // This existing journal-fault fixture has no resources; keep its
        // original synchronous fault/recovery API contract explicit.
        guard backup.videoAssets?.document.entries.isEmpty != false else {throw Failure(text:"Unexpected asset in journal fixture")}
        backup.videoAssets=nil
        backup.global.brightness = 31; backup.filters = UserVideoFilterChain(filters: [.init(kind: .horizontalFlip)])
        let coordinator = UserProfileImportCoordinator(directory: PlayerModel.supportDirectory, shortcuts: ActualShortcuts(), publication: JournalFault(directory: PlayerModel.supportDirectory))
        var pending = false
        do { try coordinator.apply(backup, shortcutValidator: InputController.validateBackupShortcut, shortcutEncoder: { try InputController.shared.encodedBackupShortcuts($0.map { ($0.action, $0.key) }) }) }
        catch ProfileImportError.recoveryRequired { pending = true }
        player.profileBackup.setPersistenceBlocked(true)
        let actual = try storeFingerprints()
        try check("real-coordinator-prepared-journal-after-failed-rollback", pending && FileManager.default.fileExists(atPath: coordinator.journalURL.path) && actual["preferences.json"] != expected["preferences.json"])
        try check("pending-recovery-blocks-natural-exit-persistence", player.profileStoresBlocked && player.mediaPreferences.blocksPersistence)
    }
    private func verifyRecovery() async throws {
        let expectedPath = PlayerModel.supportDirectory.appendingPathComponent("media-profile-recovery-expected.json")
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: expectedPath))
        try check("second-process-startup-restores-all-original-bytes", try storeFingerprints() == expected && !player.profileStoresBlocked && !FileManager.default.fileExists(atPath: PlayerModel.supportDirectory.appendingPathComponent("profile-import-journal.json").path))
        try check("stored-let-partial-filter-memory-replaced-after-recovery", player.mediaPreferences.baseSnapshot.brightness == 11 && player.userVideoFilters.chain.filters.isEmpty && player.mediaPreferences.document.entries.count == 1)
        try await open(source)
        try await wait("startup saved media restore") { !self.player.mediaPreferences.hasPendingTrackRestoration && self.selectedSource("aid", self.externalAudio, kind: .audio) }
        try check("restored-documents-use-real-playback", closeEnough("video-rotate", 90) && closeEnough("audio-delay", 0.35) && !player.string("vf").contains("hflip"))
        try await advances("recovered-profile-real-time-and-frames")
        player.stopPlayback()
    }
    private func verifyMalformedStartup() async throws {
        let raw = try Data(contentsOf: fixtureRoot.appendingPathComponent("malformed-global-original.json"))
        let preserved = PlayerModel.supportDirectory.appendingPathComponent("PreservedPreferences")
        let paths = FileManager.default.enumerator(at: preserved, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        let original = paths.first { $0.lastPathComponent == "preferences.json" && (try? BoundedProfileFile.read($0, maximumBytes: 1024 * 1024)) == raw }
        try check("malformed-startup-preserves-original-bytes-before-defaults", original != nil && !player.profileStoresBlocked && player.mediaPreferences.baseSnapshot == PlaybackSettings())
        player.updateSettings { $0.brightness = 9 }; player.persistSettings()
        let repaired = try JSONDecoder().decode(PlaybackSettings.self, from: Data(contentsOf: PlayerModel.preferenceURL))
        try check("normal-publication-repairs-store-preserved-copy-remains", repaired.brightness == 9 && (try Data(contentsOf: original!)) == raw)
        try await open(source); try await advances("malformed-fallback-real-time-and-frames"); player.stopPlayback()
    }
    private func verifyLifecycle() async throws {
        _ = try await saveWithExternalTracks()
        guard var record = player.mediaPreferences.savedCurrent, case .match(let original)? = record.audio else { throw Failure(text: "Saved external audio record required") }
        let lateDirectory = fixtureRoot.appendingPathComponent("late-files", isDirectory: true)
        try FileManager.default.createDirectory(at: lateDirectory, withIntermediateDirectories: true)
        let late = lateDirectory.appendingPathComponent(externalAudio.lastPathComponent)
        let wanted = try MediaTrackDescriptor(kind: original.kind, language: original.language, title: original.title, codec: original.codec,
            channels: original.channels, channelLayout: original.channelLayout, source: .localFile(late), forced: original.forced,
            hearingImpaired: original.hearingImpaired, isDefault: original.isDefault)
        record.audio = .match(wanted)
        var document = player.mediaPreferences.document; try document.save(record)
        try MediaPreferenceStore(fileURL: PlayerModel.supportDirectory.appendingPathComponent("media-preferences.json")).save(document)
        try player.mediaPreferences.adoptCommittedProfile(document)
        try await open(source)
        let embedded = player.mediaTrackCandidates().first { $0.descriptor.kind == .audio && $0.descriptor.source == .embedded }!
        try check("missing-external-is-pending-before-user-selection", player.mediaPreferences.hasPendingTrackRestoration)
        player.selectAudio(embedded.runtimeID)
        try FileManager.default.copyItem(at: externalAudio, to: late)
        player.command(["audio-add", late.path, "auto"])
        try await wait("actual late external descriptor") { self.localTrack(late, kind: .audio) != nil }
        let lateCandidate = localTrack(late, kind: .audio)!
        try check("late-track-can-match-saved-description", MediaTrackMatcher.match(.match(wanted), candidates: [lateCandidate]) == .matched(lateCandidate.runtimeID))
        try await Task.sleep(nanoseconds: 2_200_000_000)
        try check("manual-track-selection-wins-over-late-restore", Int(player.string("aid")) == embedded.runtimeID && !player.mediaPreferences.hasPendingTrackRestoration)
        try await advances("manual-track-real-time-and-frames")
        try FileManager.default.removeItem(at: late)
        try await open(source)
        try check("stop-request-during-pending-restore", player.mediaPreferences.hasPendingTrackRestoration)
        player.stopPlayback()
        let stoppedFrames = player.renderProgress.frames
        try await Task.sleep(nanoseconds: 2_200_000_000)
        try check("stop-discards-restoration-without-resurrection", !player.loaded && !player.isLoading && player.flag("pause") && player.position == 0 && !player.mediaPreferences.hasPendingTrackRestoration && !player.mediaPreferences.isActive && player.renderProgress.frames <= stoppedFrames + 2)
        try await open(source)
        try await player.openAndWaitForCommit([alternate])
        try await wait("replacement during pending restore") { self.player.loaded && !self.player.isLoading && self.player.currentURL?.path == self.alternate.path }
        player.set("pause", "no")
        try await Task.sleep(nanoseconds: 2_200_000_000)
        try check("replacement-discards-old-delays-geometry-and-track-ids", closeEnough("audio-delay", 0) && closeEnough("sub-delay", 0) && closeEnough("secondary-sub-delay", player.mediaPreferences.baseSnapshot.processing.secondarySubtitleDelay) && closeEnough("video-rotate", Double(player.mediaPreferences.baseSnapshot.rotation)) && player.settings.secondarySubtitleID == 0 && player.settings.processing.projection == player.mediaPreferences.baseSnapshot.processing.projection)
        try await advances("replacement-after-cancel-real-time-and-frames")
        try await capture("media-profile-lifecycle-replaced")
        player.resetSettings()
        player.updateSettings { $0.rotation = 180; $0.zoom = 0.25 }
        try await wait("post-reset current-media geometry readback") { self.closeEnough("video-rotate", 180) && self.closeEnough("video-zoom", 0.25) }
        try check("global-reset-retains-loaded-media-edit-context", player.mediaPreferences.isActive && player.mediaPreferences.isLoaded && player.settings.rotation == 180)
        player.persistSettings()
        let global = try JSONDecoder().decode(PlaybackSettings.self, from: Data(contentsOf: PlayerModel.preferenceURL))
        try check("post-reset-media-edit-does-not-persist-global-geometry", global.rotation == 0 && global.zoom == 0)
        player.stopPlayback()
        try await open(alternate)
        try check("stop-reopen-after-global-reset-restores-default-geometry", closeEnough("video-rotate", 0) && closeEnough("video-zoom", 0) && player.settings.rotation == 0 && player.settings.zoom == 0)
        try await advances("post-reset-reopen-real-time-and-frames")
        player.stopPlayback()
    }
}
