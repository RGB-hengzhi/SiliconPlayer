import Foundation

/// Separates persistent global preferences from this playback's geometry and
/// transient track IDs. Hosts persist only baseSnapshot, never effectiveSettings.
public struct MediaPreferenceSettingsSession {
    public private(set) var baseSnapshot: PlaybackSettings
    public private(set) var isActive = false
    private var geometry: MediaGeometryPreference?
    private var secondaryDelay: Double?
    private var secondaryStyle: SecondarySubtitleStyleSettings?
    private var secondaryID = 0

    public init(base: PlaybackSettings = PlaybackSettings()) {
        baseSnapshot = base.sanitized(); baseSnapshot.secondarySubtitleID = 0
    }
    public var effectiveSettings: PlaybackSettings {
        var value = baseSnapshot
        if let geometry { value = geometry.applying(to: value) }
        if let secondaryDelay { value.processing.secondarySubtitleDelay = secondaryDelay }
        if let secondaryStyle { value.secondarySubtitleStyle = secondaryStyle }
        value.secondarySubtitleID = secondaryID
        return value.sanitized()
    }
    public mutating func installBaseSettings(_ value: PlaybackSettings) {
        self = Self(base: value)
    }
    /// A context may have no saved record: edits still belong to this media until
    /// explicitly saved. Unrelated settings continue to update global defaults.
    public mutating func prepareForLoad(record: MediaPreferenceRecord?) throws {
        _ = try record?.validated()
        isActive = true; geometry = record?.geometry
        secondaryDelay = record?.secondarySubtitleDelay; secondaryStyle = record?.secondarySubtitleStyle; secondaryID = 0
    }
    public mutating func invalidatePlayback() {
        isActive = false; geometry = nil; secondaryDelay = nil; secondaryStyle = nil; secondaryID = 0
    }
    /// Apply only changed leaves to global preferences. Comparing the full
    /// effective document would copy unchanged restored values into the base.
    public mutating func adoptEffectiveEdit(from before: PlaybackSettings, to after: PlaybackSettings) throws {
        let before = before.sanitized(), after = after.sanitized()
        let encoder = JSONEncoder()
        let old = try JSONSerialization.jsonObject(with: encoder.encode(before)) as! [String: Any]
        let new = try JSONSerialization.jsonObject(with: encoder.encode(after)) as! [String: Any]
        var base = try JSONSerialization.jsonObject(with: encoder.encode(baseSnapshot)) as! [String: Any]
        let protected = Self.mediaPaths
        func same(_ a: Any?, _ b: Any?) -> Bool {
            guard let a = a as? NSObject, let b = b as? NSObject else { return a == nil && b == nil }
            return a.isEqual(b)
        }
        func merge(_ old: [String: Any], _ new: [String: Any], _ base: inout [String: Any], _ prefix: String) {
            for (key, value) in new {
                let path = prefix.isEmpty ? key : prefix + "." + key
                if isActive && (path == "secondarySubtitleStyle" || path.hasPrefix("secondarySubtitleStyle.")) { continue }
                if let oldChild = old[key] as? [String: Any], let newChild = value as? [String: Any], var baseChild = base[key] as? [String: Any] {
                    merge(oldChild, newChild, &baseChild, path); base[key] = baseChild
                } else if !same(old[key], value), path != "secondarySubtitleID", !(isActive && protected.contains(path)) {
                    base[key] = value
                }
            }
        }
        merge(old, new, &base, "")
        if !isActive && before.secondarySubtitleStyle != after.secondarySubtitleStyle {
            if let value = new["secondarySubtitleStyle"] { base["secondarySubtitleStyle"] = value }
            else { base.removeValue(forKey: "secondarySubtitleStyle") }
        }
        let nextBase = try JSONDecoder().decode(PlaybackSettings.self, from: JSONSerialization.data(withJSONObject: base))
        let oldGeometry = MediaGeometryPreference(settings: before), newGeometry = MediaGeometryPreference(settings: after)
        if isActive && oldGeometry != newGeometry { geometry = try newGeometry.validated() }
        if isActive && before.processing.secondarySubtitleDelay != after.processing.secondarySubtitleDelay {
            secondaryDelay = after.processing.secondarySubtitleDelay
        }
        if isActive && before.secondarySubtitleStyle != after.secondarySubtitleStyle {
            secondaryStyle = after.secondarySubtitleStyle ?? SecondarySubtitleStyleSettings()
        }
        if before.secondarySubtitleID != after.secondarySubtitleID { secondaryID = after.secondarySubtitleID }
        baseSnapshot = nextBase; baseSnapshot.secondarySubtitleID = 0
    }
    private static let mediaPaths: Set<String> = [
        "rotation", "aspect", "zoom", "panX", "panY", "flipHorizontal", "flipVertical",
        "processing.projection", "processing.yaw", "processing.pitch", "processing.fieldOfView",
        "processing.cropWidth", "processing.cropHeight", "processing.secondarySubtitleDelay"
    ]
}

public extension MediaGeometryPreference {
    init(settings: PlaybackSettings) {
        self.init()
        let value = settings.sanitized()
        rotation = value.rotation; aspect = value.aspect; zoom = value.zoom
        panX = value.panX; panY = value.panY
        flipHorizontal = value.flipHorizontal; flipVertical = value.flipVertical
        projection = MediaProjection(rawValue: value.processing.projection) ?? .off
        yaw = value.processing.yaw; pitch = value.processing.pitch
        fieldOfView = value.processing.fieldOfView
        cropWidth = value.processing.cropWidth; cropHeight = value.processing.cropHeight
    }
    func applying(to base: PlaybackSettings) -> PlaybackSettings {
        var value = base
        value.rotation = rotation; value.aspect = aspect; value.zoom = zoom
        value.panX = panX; value.panY = panY
        value.flipHorizontal = flipHorizontal; value.flipVertical = flipVertical
        value.processing.projection = projection.rawValue
        value.processing.yaw = yaw; value.processing.pitch = pitch
        value.processing.fieldOfView = fieldOfView
        value.processing.cropWidth = cropWidth; value.processing.cropHeight = cropHeight
        return value.sanitized()
    }
}
