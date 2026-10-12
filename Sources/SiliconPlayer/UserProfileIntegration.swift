import Foundation
import PlayerCore

extension PlayerModel {
    /// Startup may repair malformed legacy JSON with defaults, but must keep
    /// its bounded original bytes first. Special/unreadable files and failed
    /// preservation leave all participating stores blocked.
    static func preserveRejectedProfileStores(notices: [String]) throws -> [URL] {
        let limits: [String: Int] = ["preferences.json": 1024 * 1024,
            "user-video-filters.json": UserVideoFilterStore.maximumBytes,
            "media-preferences.json": MediaPreferenceDocument.maximumBytes,
            "web-media-preferences.json": WebMediaCatalog.maximumBytes]
        let names = limits.keys.filter { name in notices.contains { $0.hasPrefix(name + " ") } }.sorted()
        guard !names.isEmpty else { return [] }
        let folder = supportDirectory.appendingPathComponent("PreservedPreferences", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var outputs: [URL] = []
        for name in names {
            let source = supportDirectory.appendingPathComponent(name)
            guard let bytes = try BoundedProfileFile.read(source, maximumBytes: limits[name]!) else {
                throw ProfileImportError.recoveryRequired
            }
            let destination = folder.appendingPathComponent(name)
            try bytes.write(to: destination, options: .withoutOverwriting)
            guard try BoundedProfileFile.read(destination, maximumBytes: limits[name]!) == bytes else {
                throw ProfileImportError.recoveryRequired
            }
            outputs.append(destination)
        }
        return outputs
    }

    var profileStoresBlocked: Bool { profileRecoveryBlocked || profileBackup.blocksPersistence || profileBackup.isImporting }

    func prepareForProfileImport() {
        if !playbackProgram.configurationWillChange() { stopPlayback() }
        // The owned profile transaction keeps the previous asset pipeline for
        // confirmed rollback; do not invalidate its media binding here.
        nativeAudioQueue.configurationChanged()
        settingsWork?.cancel(); settingsWork = nil
        cancelPendingFrameSteps()
        videoFilterGeneration = UUID(); candidateVideoFilters = nil
        userVideoFilters.cancelPending(reason: "正在导入设置")
        mediaPreferences.cancelPendingTrackRestoration()
    }

    func adoptImportedProfile(_ value: UserProfileBackupDocument) {
        do {
            installGlobalBaseSettings(value.global)
            try mediaPreferences.adoptCommittedProfile(value.media)
            try userVideoFilters.adoptCommittedProfile(value.filters)
            if let web = value.web { webMediaCatalog = web }
            synchronizeMediaPreferenceSettings()
            // Apply the complete committed configuration once. Runtime track
            // IDs and this media's old delay never become global defaults.
            set("aid", "auto"); set("sid", "auto"); set("secondary-sid", "no")
            setAudioDelay(0); setSubtitleDelay(0)
            // A profile import must re-resolve the imported record for the
            // actual loaded Core, not the UI queue selection or saved runtime IDs.
            // Delay resets above cancel old restoration; create the new request
            // only after them. This does not reload, seek or change pause intent.
            let restored: MediaPreferenceRestoration?
            if loaded, !isLoading, mediaPreferences.isLoaded,
               mediaPreferences.token == mediaPreferenceToken,
               mediaPreferences.boundItemID != nil,
               mediaPreferences.document.automaticallyRestore {
                restored = mediaPreferences.restoreSavedNow(candidates: restorationMediaTrackCandidates())
            } else { restored = nil }
            synchronizeMediaPreferenceSettings()
            guard secondarySubtitleStyle.apply(settings.secondarySubtitleStyle) else {
                throw SecondarySubtitleStyleFailure.write("profile-runtime-adoption")
            }
            if let restored {
                applyMediaPreferenceRestoration(restored)
                // These exact matches are already resolved against current
                // track-list. Failed setters must not report runtime adoption.
                func selected(_ match: MediaTrackMatch?, property: String) -> Bool {
                    switch match {
                    case .matched(let id): return Int(string(property)) == id
                    case .disabled: return ["no", "0"].contains(string(property))
                    default: return true // Existing auto/missing/ambiguous fallback.
                    }
                }
                guard selected(restored.audio, property: "aid"),
                      selected(restored.primarySubtitle, property: "sid"),
                      selected(restored.secondarySubtitle, property: "secondary-sid") else {
                    throw MediaPreferenceError.invalidTrack
                }
            } else { applySettings() }
            guard secondarySubtitleStyle.matches(settings.secondarySubtitleStyle) else {
                throw SecondarySubtitleStyleFailure.write("profile-runtime-adoption-readback")
            }
            if loaded, !isLoading, mediaPreferences.isLoaded,
               mediaPreferences.token == mediaPreferenceToken, mediaPreferences.boundItemID != nil {
                let effective = settings.sanitized()
                let parts = effective.aspect.split(separator: ":").compactMap { Double($0) }
                let aspect = parts.count == 2 ? parts[0] / parts[1] : Double(effective.aspect) ?? -1
                let expected: [(String, Double)] = [
                    ("audio-delay", restored?.audioDelay ?? 0), ("sub-delay", restored?.subtitleDelay ?? 0),
                    ("secondary-sub-delay", effective.processing.secondarySubtitleDelay),
                    ("video-rotate", Double(effective.rotation)), ("video-zoom", effective.zoom),
                    ("video-pan-x", effective.panX), ("video-pan-y", effective.panY),
                    ("video-aspect-override", aspect)
                ]
                guard expected.allSatisfy({ property, wanted in
                    guard let actual = Double(string(property)), actual.isFinite else { return false }
                    return abs(actual - wanted) < 0.0001
                }) else {
                    throw NSError(domain: "SiliconPlayerProfileRuntime", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "当前媒体同步或画面设置未能确认生效"])
                }
            }
            didAdoptProfileRuntime()
            videoAssets.mediaLoaded()
        } catch {
            profileRecoveryBlocked = true
            profileBackup.setPersistenceBlocked(true)
            toast("设置文件已导入，但应用设置未完成；请重新启动。")
        }
    }
}
