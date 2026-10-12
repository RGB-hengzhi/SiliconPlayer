import Foundation
import PlayerCore

/// Uses mpv's actual per-load track metadata; persisted descriptors never store
/// runtime IDs. Property contract: https://mpv.io/manual/stable/#track-list
extension PlayerModel {
    /// Two runtime IDs can describe the same stream when fuzzy discovery also
    /// finds an explicitly preloaded external file. Missing indices stay distinct.
    func sameMediaTrackStream(_ first: Int, _ second: Int, kind: MediaTrackKind) -> Bool {
        guard first > 0, second > 0 else { return false }
        if first == second { return true }
        guard let rows = jsonProperty("track-list") as? [[String: Any]] else { return false }
        let type = kind == .audio ? "audio" : "sub"
        func row(_ id: Int) -> [String: Any]? { rows.first { $0["type"] as? String == type && $0["id"] as? Int == id } }
        func local(_ value: [String: Any]) -> URL? {
            guard value["external"] as? Bool == true, let path = value["external-filename"] as? String else { return nil }
            if let url = URL(string: path), url.isFileURL { return url.standardizedFileURL }
            return path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL : nil
        }
        guard let lhs = row(first), let rhs = row(second), let left = local(lhs), let right = local(rhs),
              let firstIndex = lhs["ff-index"] as? Int, let secondIndex = rhs["ff-index"] as? Int else { return false }
        return left.path == right.path && firstIndex == secondIndex && lhs["codec"] as? String == rhs["codec"] as? String
    }

    /// mpv may expose the same external FFmpeg stream twice after explicit
    /// loading plus fuzzy discovery. Keep distinct stream indices intact and
    /// prefer the currently selected duplicate without collapsing distinct streams.
    func restorationMediaTrackCandidates() -> [MediaTrackCandidate] {
        let candidates = mediaTrackCandidates()
        guard let rows = jsonProperty("track-list") as? [[String: Any]] else { return candidates }
        var retained: [String: MediaTrackCandidate] = [:]
        var order: [String] = []
        var selected: [String: Bool] = [:]
        let metadata = Dictionary(rows.compactMap { row -> (String, [String: Any])? in
            guard let type = row["type"] as? String, let id = row["id"] as? Int else { return nil }
            return (type + ":" + String(id), row)
        }, uniquingKeysWith: { first, _ in first })
        for candidate in candidates {
            let type = candidate.descriptor.kind == .audio ? "audio" : "sub"
            let row = metadata[type + ":" + String(candidate.runtimeID)] ?? [:]
            let key: String
            if case .localFile(let url) = candidate.descriptor.source, let index = row["ff-index"] as? Int {
                key = type + "\u{0}" + url.standardizedFileURL.path + "\u{0}" + String(index)
                    + "\u{0}" + candidate.descriptor.codec
            } else { key = type + ":" + String(candidate.runtimeID) }
            let isSelected = row["selected"] as? Bool == true
            if retained[key] == nil { order.append(key); retained[key] = candidate; selected[key] = isSelected }
            else if isSelected && selected[key] != true { retained[key] = candidate; selected[key] = true }
        }
        return order.compactMap { retained[$0] }
    }

    func existingExternalTrack(_ url: URL, kind: MediaTrackKind) -> Int? {
        let matches = mediaTrackCandidates().filter {
            guard $0.descriptor.kind == kind, case .localFile(let source) = $0.descriptor.source else { return false }
            return source.standardizedFileURL.path == url.standardizedFileURL.path
        }
        let current = Int(string(kind == .audio ? "aid" : "sid"))
        return matches.first(where: { $0.runtimeID == current })?.runtimeID ?? matches.map(\.runtimeID).min()
    }
    func mediaTrackCandidates() -> [MediaTrackCandidate] {
        guard let rows = jsonProperty("track-list") as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? Int,
                  let type = row["type"] as? String,
                  let kind: MediaTrackKind = type == "audio" ? .audio : type == "sub" ? .subtitle : nil else { return nil }
            let source: MediaTrackSource
            if row["external"] as? Bool == true {
                let path = row["external-filename"] as? String
                let parsed = path.flatMap(URL.init(string:))
                if let path, path.hasPrefix("/") || parsed?.isFileURL == true {
                    let url = parsed?.isFileURL == true ? parsed! : URL(fileURLWithPath: path)
                    source = .localFile(url.standardizedFileURL)
                } else if currentIsWebMedia, kind == .subtitle,
                   let selection = playlist.currentItem?.webMedia, let language = selection.subtitleLanguage {
                    source = .webpageSubtitle(language: language, automatic: selection.includeAutomaticSubtitles)
                } else { return nil }
            } else { source = .embedded }
            do {
                let descriptor = try MediaTrackDescriptor(kind: kind, language: row["lang"] as? String ?? "",
                    title: row["title"] as? String ?? "", codec: row["codec"] as? String ?? "",
                    channels: kind == .audio ? row["demux-channel-count"] as? Int : nil,
                    channelLayout: kind == .audio ? row["demux-channels"] as? String : nil,
                    source: source, forced: row["forced"] as? Bool,
                    hearingImpaired: row["hearing-impaired"] as? Bool, isDefault: row["default"] as? Bool)
                return try MediaTrackCandidate(runtimeID: id, descriptor: descriptor)
            } catch { return nil }
        }
    }

    private struct MediaSnapshotFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    func currentMediaPreferenceSnapshot() throws -> MediaPreferenceSnapshot {
        guard loaded, !isLoading, mediaPreferences.isLoaded,
              mediaPreferences.token == mediaPreferenceToken, currentURL != nil else {
            throw MediaSnapshotFailure(message: "媒体尚未加载，设置未保存")
        }
        let candidates = mediaTrackCandidates()
        func selected(_ property: String, kind: MediaTrackKind) throws -> MediaTrackPreference {
            let value = string(property)
            if value == "no" || value == "0" { return .disabled }
            if value == "auto" || value.isEmpty { return .automatic }
            guard let id = Int(value), id > 0,
                  let candidate = candidates.first(where: { $0.runtimeID == id && $0.descriptor.kind == kind }) else {
                throw MediaSnapshotFailure(message: "当前轨道尚无可保存的描述，请等待加载完成；网络外置轨道仅用于本次会话")
            }
            return .match(candidate.descriptor)
        }
        let geometry = try MediaGeometryPreference(settings: settings).validated()
        let expected: [(String, Double)] = [("video-rotate", Double(geometry.rotation)), ("video-zoom", geometry.zoom),
            ("video-pan-x", geometry.panX), ("video-pan-y", geometry.panY)]
        guard expected.allSatisfy({ abs(number($0.0) - $0.1) < 0.0001 }) else {
            throw MediaSnapshotFailure(message: "画面设置尚未生效，媒体设置未保存")
        }
        let aspectParts = geometry.aspect.split(separator: ":").compactMap { Double($0) }
        let expectedAspect = aspectParts.count == 2 ? aspectParts[0] / aspectParts[1] : Double(geometry.aspect) ?? -1
        guard abs(number("video-aspect-override") - expectedAspect) < 0.0001 else {
            throw MediaSnapshotFailure(message: "画面比例尚未生效，媒体设置未保存")
        }
        let expectedGraph = configuredVideoFragments(settings: settings.sanitized(), userFragments: userVideoFilters.effectiveFragments).joined(separator: ",")
        let rows = jsonProperty("vf") as? [[String: Any]] ?? []
        guard candidateVideoFilters == nil, !userVideoFilters.isApplying,
              expectedGraph.isEmpty ? rows.isEmpty : rows.contains(where: {
                  ($0["params"] as? [String: Any])?["graph"] as? String == expectedGraph
              }) else {
            throw MediaSnapshotFailure(message: "画面滤镜尚未生效，媒体设置未保存")
        }
        var snapshot = MediaPreferenceSnapshot()
        snapshot.audio = try selected("aid", kind: .audio)
        snapshot.primarySubtitle = try selected("sid", kind: .subtitle)
        snapshot.secondarySubtitle = try selected("secondary-sid", kind: .subtitle)
        snapshot.audioDelay = number("audio-delay"); snapshot.subtitleDelay = number("sub-delay")
        snapshot.secondarySubtitleDelay = number("secondary-sub-delay"); snapshot.geometry = geometry
        guard secondarySubtitleStyle.matches(settings.secondarySubtitleStyle) else {
            throw MediaSnapshotFailure(message: "副字幕样式尚未确认生效，媒体设置未保存")
        }
        snapshot.secondarySubtitleStyle = settings.secondarySubtitleStyle
        return snapshot
    }

    @discardableResult func saveCurrentMediaPreferences() -> Bool {
        nativeAudioQueue.configurationChanged()
        guard !profileStoresBlocked else { return false }
        do {
            let snapshot = try currentMediaPreferenceSnapshot()
            let saved = mediaPreferences.saveCurrent(snapshot: snapshot, token: mediaPreferenceToken)
            toast(saved ? "已保存此媒体的音轨、字幕、同步与画面设置" : mediaPreferences.errorText ?? "媒体设置未保存")
            return saved
        } catch { toast(error.localizedDescription); return false }
    }
    func applyMediaPreferenceRestoration(_ restored: MediaPreferenceRestoration) {
        guard loaded, !isLoading, mediaPreferences.token == mediaPreferenceToken else { return }
        applyingMediaPreferenceRestoration = true
        defer { applyingMediaPreferenceRestoration = false }
        func apply(_ preference: MediaTrackMatch?, property: String) {
            guard let preference else { return }
            switch preference {
            case .automatic, .missing, .ambiguous: set(property, "auto")
            case .disabled: set(property, "no")
            case .matched(let id): set(property, String(id))
            }
        }
        apply(restored.audio, property: "aid")
        apply(restored.primarySubtitle, property: "sid")
        apply(restored.secondarySubtitle, property: "secondary-sid")
        if let secondary = Int(string("secondary-sid")), let primary = Int(string("sid")),
           sameMediaTrackStream(primary, secondary, kind: .subtitle) {
            set("secondary-sid", "no")
        }
        if let delay = restored.audioDelay { setAudioDelay(delay) }
        if let delay = restored.subtitleDelay { setSubtitleDelay(delay) }
        mediaPreferences.updateSettings {
            $0.secondarySubtitleID = Int(string("secondary-sid")) ?? 0
            if let delay = restored.secondarySubtitleDelay { $0.processing.secondarySubtitleDelay = delay }
        }
        synchronizeMediaPreferenceSettings(); applySettings()
        if !restored.notices.isEmpty { toast(restored.notices.joined(separator: "；")) }
    }
    func restoreCurrentMediaPreferences() {
        guard playbackProgram.configurationWillChange() else { return }
        nativeAudioQueue.configurationChanged()
        guard let restored = mediaPreferences.restoreSavedNow(candidates: restorationMediaTrackCandidates()) else { return }
        synchronizeMediaPreferenceSettings(); applyMediaPreferenceRestoration(restored)
        playbackProgram.mediaLoaded(explicitStart: true)
    }
    @discardableResult func clearCurrentMediaPreferences() -> Bool {
        guard playbackProgram.configurationWillChange() else { return false }
        nativeAudioQueue.configurationChanged()
        guard !profileStoresBlocked else { return false }
        guard mediaPreferences.clearCurrent() else { toast(mediaPreferences.errorText ?? "媒体设置未清除"); return false }
        set("aid", "auto"); set("sid", "auto"); set("secondary-sid", "no")
        setAudioDelay(0); setSubtitleDelay(0)
        synchronizeMediaPreferenceSettings(); applySettings()
        toast("已清除此媒体的设置，恢复全局默认")
        return true
    }
    func restoreMediaPreferencesAfterTrackUpdate() {
        guard loaded, !isLoading, let item = playlist.currentItem,
              let restored = mediaPreferences.applyRestoredTracksOnUpdate(token: mediaPreferenceToken,
                  itemID: item.id, candidates: restorationMediaTrackCandidates()) else { return }
        synchronizeMediaPreferenceSettings(); applyMediaPreferenceRestoration(restored)
    }
}
