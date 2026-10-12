import Foundation

public enum ScreenshotMode: String, Codable, CaseIterable, Identifiable {
    case subtitles, video, window
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .subtitles: return "视频与字幕"
        case .video: return "仅视频"
        case .window: return "当前渲染画面"
        }
    }
}

public struct ScreenshotPreferences: Codable, Equatable {
    public var mode: ScreenshotMode = .subtitles
    /// Empty uses the user's Pictures/SiliconPlayer directory.
    public var directory = ""
    public var quality = 90
    public init() {}

    public func sanitized() -> Self {
        var result = self
        // Keep legitimate spaces in paths. Never interpret a shell expression.
        if !directory.isEmpty && (!directory.hasPrefix("/") || directory.utf8.count > 4096 || directory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })) {
            result.directory = ""
        }
        result.quality = min(100, max(1, quality))
        return result
    }

    public static func filename(title: String, format: String, date: Date = Date(), token: UUID = UUID()) -> String {
        let cleaned = title.components(separatedBy: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\"))).joined(separator: "_")
        let name = String(cleaned.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let time = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        let suffix = ["png", "jpg", "webp"].contains(format) ? format : "png"
        return "\(name.isEmpty ? "SiliconPlayer" : name)_\(time)_\(token.uuidString.prefix(8)).\(suffix)"
    }
}
