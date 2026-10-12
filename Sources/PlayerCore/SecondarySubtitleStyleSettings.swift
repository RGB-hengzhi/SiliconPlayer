import Foundation

/// nil in PlaybackSettings means legacy inherited styling. A nonnil disabled
/// value explicitly preserves inherited styling for this media/default scope.
public struct SecondarySubtitleStyleSettings: Codable, Hashable, Sendable {
    public var enabled = false
    public var font = "Heiti SC"
    public var size = 40.0
    public var color = "#FFFFFFFF"
    public var outlineColor = "#FF000000"
    public var outline = 2.0
    public var background = false
    public var backColor = "#AF000000"
    public var assOverride = "strip"
    public init() {}
    public init(primary: PlaybackSettings) {
        let p = primary.sanitized()
        font = p.subtitleFont; size = p.subtitleSize
        color = "#FF" + p.subtitleColor.dropFirst()
        outline = p.subtitleOutline; background = p.subtitleBackground
    }
    public func sanitized() -> Self {
        var p = self
        let clean = font.components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var boundedFont = ""
        for character in clean.prefix(128) {
            guard boundedFont.utf8.count + String(character).utf8.count <= 512 else { break }
            boundedFont.append(character)
        }
        p.font = boundedFont.isEmpty ? "Heiti SC" : boundedFont
        p.size = size.isFinite ? min(100, max(12, size)) : 40
        p.outline = outline.isFinite ? min(10, max(0, outline)) : 2
        p.color = Self.canonicalColor(color) ?? "#FFFFFFFF"
        p.outlineColor = Self.canonicalColor(outlineColor) ?? "#FF000000"
        p.backColor = Self.canonicalColor(backColor) ?? "#AF000000"
        p.assOverride = ["no", "yes", "scale", "force", "strip"].contains(assOverride) ? assOverride : "strip"
        return p
    }
    public func validated() throws -> Self {
        guard self == sanitized(), font.utf8.count <= 512 else {
            throw SecondarySubtitleStyleFailure.invalidPreference
        }
        return self
    }
    public static func canonicalColor(_ raw: String) -> String? {
        let p = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard [7, 9].contains(p.count), p.first == "#",
              p.dropFirst().allSatisfy({ "0123456789ABCDEF".contains($0) }) else { return nil }
        return p.count == 7 ? "#FF" + p.dropFirst() : p
    }
}

public enum SecondarySubtitleStyleFailure: Error, LocalizedError {
    case invalidPreference, unavailable, missing(String), invalidValue(String), write(String), contextChanged
    public var errorDescription: String? {
        switch self {
        case .invalidPreference: return "副字幕样式数据无效"
        case .unavailable: return "当前播放内核不支持独立副字幕样式"
        case .missing(let name): return "副字幕样式属性不可用：\(name)"
        case .invalidValue(let name): return "副字幕样式属性类型或读回不符：\(name)"
        case .write(let name): return "副字幕样式设置失败：\(name)"
        case .contextChanged: return "副字幕样式的播放内核已关闭或改变"
        }
    }
}
