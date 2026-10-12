import Foundation
import Combine
import PlayerCore

struct MediaPreferenceSnapshot {
    var audio: MediaTrackPreference = .automatic
    var primarySubtitle: MediaTrackPreference = .automatic
    var secondarySubtitle: MediaTrackPreference = .disabled
    var audioDelay = 0.0
    var subtitleDelay = 0.0
    var secondarySubtitleDelay = 0.0
    var secondarySubtitleStyle: SecondarySubtitleStyleSettings?
    var geometry = MediaGeometryPreference()
}

struct MediaPreferenceRestoration {
    let audio: MediaTrackMatch?
    let primarySubtitle: MediaTrackMatch?
    let secondarySubtitle: MediaTrackMatch?
    let audioDelay: Double?
    let subtitleDelay: Double?
    let secondarySubtitleDelay: Double?
    let notices: [String]
}

/// Owns documents and a playback context, but never issues mpv commands. The host
/// binds the token to its actual entry/load generation and supplies readback data.
@MainActor
final class MediaPreferencesController: ObservableObject {
    @Published private(set) var document = MediaPreferenceDocument()
    @Published private(set) var identity: MediaIdentity?
    @Published private(set) var currentTitle = ""
    @Published private(set) var isLoaded = false
    @Published private(set) var status = ""
    @Published private(set) var errorText: String?
    @Published private(set) var blocksPersistence = false
    private(set) var token = UUID()
    private var currentItemID: UUID?
    /// Playback request identity; independent of the UI queue selection.
    var boundItemID: UUID? { currentItemID }
    private var didRestoreTracks = false
    private enum TrackField: CaseIterable { case audio, primary, secondary }
    private var completedFields = Set<TrackField>()
    private var restorationDeadline: TimeInterval?
    private var restoredDelays = false
    private var activeRecord: MediaPreferenceRecord?
    private var session = MediaPreferenceSettingsSession()
    private let store: MediaPreferenceStore

    init(fileURL: URL, loadImmediately: Bool = true) {
        store = MediaPreferenceStore(fileURL: fileURL)
        if loadImmediately { loadDocument() }
    }
    var baseSnapshot: PlaybackSettings { session.baseSnapshot }
    var effectiveSettings: PlaybackSettings { session.effectiveSettings }
    var isActive: Bool { session.isActive }
    var canSave: Bool { isLoaded && identity != nil && !blocksPersistence }
    var hasSavedCurrent: Bool { identity.map { document.record(for: $0) != nil } ?? false }
    var savedCurrent: MediaPreferenceRecord? { identity.flatMap { document.record(for: $0) } }
    var restoredPlaybackProgram: PlaybackProgram? { activeRecord?.playbackProgram }
    var hasPendingTrackRestoration: Bool { isLoaded && !didRestoreTracks }
    var currentExternalFiles: [(kind: MediaTrackKind, url: URL)] {
        guard let activeRecord else { return [] }
        var result: [(MediaTrackKind, URL)] = []
        for preference in [activeRecord.audio, activeRecord.primarySubtitle, activeRecord.secondarySubtitle] {
            if case .match(let descriptor)? = preference, case .localFile(let url) = descriptor.source,
               !result.contains(where: { $0.0 == descriptor.kind && $0.1 == url }) { result.append((descriptor.kind, url)) }
        }
        return result
    }

    @discardableResult func loadDocument() -> Bool {
        do { document = try store.load(); errorText = nil; return true }
        catch { errorText = "媒体设置无法读取，原文件已保留"; return false }
    }
    func installBaseSettings(_ value: PlaybackSettings) {
        session.installBaseSettings(value)
        if currentItemID != nil {
            // Reset/import replaces global defaults without turning a loaded
            // media into an idle global-edit context. Old pending restoration
            // must not reapply a pre-reset record over the replacement defaults.
            activeRecord = nil; completedFields = Set(TrackField.allCases)
            restorationDeadline = nil; restoredDelays = true; didRestoreTracks = true
            try? session.prepareForLoad(record: nil)
        }
    }
    func setPersistenceBlocked(_ value: Bool) { blocksPersistence = value }
    func updateSettings(_ edit: (inout PlaybackSettings) -> Void) {
        let before = effectiveSettings
        var after = before; edit(&after)
        adoptEffectiveEdit(from: before, to: after)
    }
    func adoptEffectiveEdit(from before: PlaybackSettings, to after: PlaybackSettings) {
        do { try session.adoptEffectiveEdit(from: before, to: after) }
        catch { errorText = "设置修改未应用" }
    }

    @discardableResult func prepareForLoad(item: MediaItem) -> UUID {
        token = UUID(); currentItemID = item.id; currentTitle = item.title
        isLoaded = false; didRestoreTracks = false; errorText = nil; status = ""
        completedFields = []; restorationDeadline = nil; restoredDelays = false
        identity = try? MediaIdentity(originalURL: item.url)
        activeRecord = document.automaticallyRestore ? identity.flatMap { document.record(for: $0) } : nil
        do { try session.prepareForLoad(record: activeRecord) }
        catch { activeRecord = nil; try? session.prepareForLoad(record: nil); errorText = "已忽略无效媒体设置" }
        if identity == nil { status = "此地址仅使用本次播放设置，不能持久保存" }
        else if activeRecord != nil { status = "已恢复此媒体的画面设置；音轨将在加载后匹配" }
        return token
    }

    /// Called after FILE_LOADED, with the host's captured token and entry ID.
    /// Only unresolved fields may retry for two seconds, allowing externally
    /// added tracks to arrive. Resolved and manually edited fields never retry.
    func applyRestoredTracksOnUpdate(token: UUID, itemID: UUID,
                                    candidates: [MediaTrackCandidate], now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> MediaPreferenceRestoration? {
        guard self.token == token, currentItemID == itemID else { return nil }
        isLoaded = true
        guard !didRestoreTracks else { return nil }
        if restorationDeadline == nil { restorationDeadline = now + 2 }
        return restoration(candidates: candidates, now: now)
    }
    func markTrackSelectionEdited(kind: MediaTrackKind, secondary: Bool? = nil) {
        if kind == .audio { completedFields.insert(.audio) }
        else if let secondary { completedFields.insert(secondary ? .secondary : .primary) }
        else { completedFields.formUnion([.primary, .secondary]) }
        didRestoreTracks = completedFields.count == TrackField.allCases.count
    }
    func cancelPendingTrackRestoration() {
        completedFields = Set(TrackField.allCases); restoredDelays = true
        restorationDeadline = nil; didRestoreTracks = true
    }
    /// Explicit restore/clear/import may ask the host to reapply immediately.
    func restoreSavedNow(candidates: [MediaTrackCandidate]) -> MediaPreferenceRestoration? {
        guard isLoaded, let identity else { return nil }
        activeRecord = document.record(for: identity)
        do { try session.prepareForLoad(record: activeRecord) }
        catch { errorText = "媒体设置无效，未恢复"; return nil }
        completedFields = []; restorationDeadline = ProcessInfo.processInfo.systemUptime + 2; restoredDelays = false; didRestoreTracks = false
        return restoration(candidates: candidates, now: ProcessInfo.processInfo.systemUptime)
    }
    func invalidatePlayback() {
        token = UUID(); currentItemID = nil; identity = nil; currentTitle = ""
        isLoaded = false; didRestoreTracks = false; activeRecord = nil
        completedFields = []; restorationDeadline = nil; restoredDelays = false
        session.invalidatePlayback(); status = ""
    }
    @discardableResult func saveCurrent(snapshot: MediaPreferenceSnapshot, token: UUID) -> Bool {
        guard !blocksPersistence else { errorText = "设置恢复尚未完成，暂不能保存"; return false }
        guard self.token == token, canSave, let identity else {
            errorText = "当前媒体尚未加载，设置未保存"; return false
        }
        var record = document.record(for: identity) ?? MediaPreferenceRecord(identity: identity)
        record.savedAt = Date() // Keep the separately configured playback program.
        record.audio = snapshot.audio; record.primarySubtitle = snapshot.primarySubtitle
        record.secondarySubtitle = snapshot.secondarySubtitle
        record.audioDelay = snapshot.audioDelay; record.subtitleDelay = snapshot.subtitleDelay
        record.secondarySubtitleDelay = snapshot.secondarySubtitleDelay; record.geometry = snapshot.geometry
        record.secondarySubtitleStyle = snapshot.secondarySubtitleStyle
        do {
            var next = document; try next.save(record); try store.save(next)
            document = next; activeRecord = record; errorText = nil; status = "已保存此媒体的设置"
            return true
        } catch { errorText = "媒体设置保存失败，原设置已保留"; return false }
    }
    /// Saves only this media's playback program, preserving every track/delay/geometry field.
    @discardableResult func savePlaybackProgram(_ value: PlaybackProgram?, token: UUID) -> Bool {
        guard !blocksPersistence, self.token == token, canSave, let identity else {
            errorText = "媒体尚未加载或设置恢复未完成，播放程序未保存"; return false
        }
        do {
            _ = try value?.validated()
            var record = document.record(for: identity) ?? MediaPreferenceRecord(identity: identity)
            record.playbackProgram = value; record.savedAt = Date()
            var next = document; try next.save(record); try store.save(next)
            document = next; activeRecord = record; errorText = nil; status = "播放程序已保存"
            return true
        } catch { errorText = "播放程序保存失败，原设置保留"; return false }
    }
    @discardableResult func clearCurrent() -> Bool {
        guard !blocksPersistence else { errorText = "设置恢复尚未完成，暂不能清除"; return false }
        guard let identity else { errorText = "当前地址没有可清除的媒体设置"; return false }
        do {
            var next = document; next.remove(for: identity); try store.save(next)
            document = next; activeRecord = nil; try session.prepareForLoad(record: nil)
            didRestoreTracks = true; errorText = nil; status = "已清除此媒体的设置，恢复全局默认"
            return true
        } catch { errorText = "清除失败，原设置已保留"; return false }
    }
    @discardableResult func setAutomaticallyRestore(_ value: Bool) -> Bool {
        guard !blocksPersistence else { errorText = "设置恢复尚未完成，暂不能保存"; return false }
        do {
            var next = document; next.automaticallyRestore = value; try store.save(next)
            document = next; errorText = nil
            status = value ? "后续加载将自动恢复已保存设置" : "后续加载使用全局默认，已保存设置仍保留"
            return true
        } catch { errorText = "自动恢复选项保存失败"; return false }
    }
    /// The profile transaction already published the file. No second save.
    func adoptCommittedProfile(_ value: MediaPreferenceDocument) throws {
        document = try value.validated(); activeRecord = nil; didRestoreTracks = false
        completedFields = []; restorationDeadline = nil; restoredDelays = false
        try session.prepareForLoad(record: nil)
        if currentItemID == nil { session.invalidatePlayback() }
        errorText = nil; status = "已导入媒体设置"
    }
    private func restoration(candidates: [MediaTrackCandidate], now: TimeInterval) -> MediaPreferenceRestoration? {
        var notices: [String] = []
        func match(_ preference: MediaTrackPreference?, field: TrackField, kind: MediaTrackKind, label: String) -> MediaTrackMatch? {
            guard !completedFields.contains(field) else { return nil }
            guard let preference else { completedFields.insert(field); return nil }
            let result = MediaTrackMatcher.match(preference, candidates: candidates.filter { $0.descriptor.kind == kind })
            if result == .missing, let restorationDeadline, now < restorationDeadline { return nil }
            completedFields.insert(field)
            switch result {
            case .missing: notices.append("\(label)未找到，使用自动选择"); return .automatic
            case .ambiguous: notices.append("\(label)存在多个匹配，使用自动选择"); return .automatic
            default: return result
            }
        }
        let audio = match(activeRecord?.audio, field: .audio, kind: .audio, label: "已保存音轨")
        let primary = match(activeRecord?.primarySubtitle, field: .primary, kind: .subtitle, label: "已保存字幕")
        let secondary = match(activeRecord?.secondarySubtitle, field: .secondary, kind: .subtitle, label: "已保存第二字幕")
        didRestoreTracks = completedFields.count == TrackField.allCases.count
        if !notices.isEmpty { status = notices.joined(separator: "；") }
        else if activeRecord != nil && didRestoreTracks { status = "已恢复此媒体的设置" }
        let includeDelays = !restoredDelays; restoredDelays = true
        guard audio != nil || primary != nil || secondary != nil || includeDelays || !notices.isEmpty else { return nil }
        return MediaPreferenceRestoration(audio: audio, primarySubtitle: primary, secondarySubtitle: secondary,
            audioDelay: includeDelays ? (activeRecord?.audioDelay ?? 0) : nil,
            subtitleDelay: includeDelays ? (activeRecord?.subtitleDelay ?? 0) : nil,
            secondarySubtitleDelay: includeDelays ? effectiveSettings.processing.secondarySubtitleDelay : nil, notices: notices)
    }
}
