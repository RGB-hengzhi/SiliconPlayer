import Foundation
import CoreFoundation

public enum WebMediaError: LocalizedError {
    case unsafeURL, invalidMetadata, unsupportedCollection, drmProtected, tooLarge, tooManyFormats
    case invalidFormat, invalidSubtitle, invalidSelection, invalidQueue

    public var errorDescription: String? {
        switch self {
        case .unsafeURL: return "请输入不含账户凭据或控制字符的 HTTP/HTTPS 网页地址"
        case .invalidMetadata: return "解析器没有返回有效的单个媒体信息"
        case .unsupportedCollection: return "暂不支持整个播放列表、频道或多段合集，请打开单个视频页面"
        case .drmProtected: return "此媒体带有 DRM 标记，当前不支持播放"
        case .tooLarge: return "网页媒体信息超过 16 MiB 上限"
        case .tooManyFormats: return "网页返回的格式数量超过 2000 个上限"
        case .invalidFormat: return "所选格式已失效或格式标识无效，请重新解析网页"
        case .invalidSubtitle: return "所选字幕语言或来源已失效，请重新解析网页"
        case .invalidSelection: return "网页媒体的播放偏好无效"
        case .invalidQueue: return "播放队列内容无效"
        }
    }
}

/// Only original-page display metadata and validated preferences are Codable.
/// Extracted CDN addresses, request headers and cookies are never stored here.
public struct WebMediaSelection: Codable, Hashable, Sendable {
    public let title: String
    public let formatID: String
    public let separateAudio: Bool
    public let subtitleLanguage: String?
    public let includeAutomaticSubtitles: Bool

    public init(title: String, formatID: String = "auto", separateAudio: Bool = false,
                subtitleLanguage: String? = nil, includeAutomaticSubtitles: Bool = false) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 4096, !WebMediaDocument.hasControls(title),
              Self.validIdentifier(formatID), formatID != "auto" || !separateAudio,
              subtitleLanguage.map(Self.validLanguage) ?? true,
              !includeAutomaticSubtitles || subtitleLanguage != nil else { throw WebMediaError.invalidSelection }
        self.title = title; self.formatID = formatID; self.separateAudio = separateAudio
        self.subtitleLanguage = subtitleLanguage; self.includeAutomaticSubtitles = includeAutomaticSubtitles
    }

    public var formatExpression: String {
        if formatID == "auto" { return "bestvideo[height<=2160]+bestaudio/best[height<=2160]/bestvideo+bestaudio/best" }
        return separateAudio ? "\(formatID)+bestaudio/best" : formatID
    }

    static func validIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$", options: .regularExpression) != nil
    }
    static func validLanguage(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$", options: .regularExpression) != nil
    }
    private enum CodingKeys: String, CodingKey { case title, formatID, separateAudio, subtitleLanguage, includeAutomaticSubtitles }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(title: values.decode(String.self, forKey: .title),
                      formatID: values.decode(String.self, forKey: .formatID),
                      separateAudio: values.decodeIfPresent(Bool.self, forKey: .separateAudio) ?? false,
                      subtitleLanguage: values.decodeIfPresent(String.self, forKey: .subtitleLanguage),
                      includeAutomaticSubtitles: values.decodeIfPresent(Bool.self, forKey: .includeAutomaticSubtitles) ?? false)
    }
}
public typealias WebMediaPreference = WebMediaSelection

public struct WebMediaFormat: Identifiable, Hashable, Sendable {
    public let formatID: String
    public var id: String { formatID }
    public let ext: String
    public let width: Int?
    public let height: Int?
    public let fps: Double?
    public let bitrate: Double?
    public let videoCodec: String?
    public let audioCodec: String?
    public let videoExplicitlyAbsent: Bool
    public let audioExplicitlyAbsent: Bool
    public let note: String?
    public var hasVideo: Bool { !videoExplicitlyAbsent && (videoCodec != nil || height != nil || width != nil) }
    public var hasAudio: Bool { audioCodec != nil }
    public var isVideoOnly: Bool { hasVideo && audioExplicitlyAbsent }
    public var displayName: String {
        var parts = [height.map { "\($0)p" } ?? (hasVideo ? "视频" : (hasAudio ? "音频" : "格式未知")), ext.uppercased()]
        if let fps { parts.append("\(Int(fps.rounded())) fps") }
        if isVideoOnly { parts.append("分离音频") }
        if let note, !note.isEmpty { parts.append(note) }
        parts.append("ID \(formatID)")
        return parts.joined(separator: " · ")
    }
}

/// A bounded view of one extractor result. It deliberately has no CDN URL or
/// HTTP-header properties; actual playback re-resolves the original page.
public struct WebMediaDocument: Sendable {
    public static let maximumBytes = 16 * 1024 * 1024
    public let pageURL: URL
    public let title: String
    public let duration: Double?
    public let isLive: Bool
    public let formats: [WebMediaFormat]
    public let subtitleLanguages: [String]
    public var manualSubtitleLanguages: [String] { subtitleLanguages }
    public let automaticSubtitleLanguages: [String]
    public var availableSubtitleLanguages: [String] { Array(Set(subtitleLanguages + automaticSubtitleLanguages)).sorted() }

    static func hasControls(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }
    }
    public static func validatedPageURL(_ address: String) throws -> URL {
        guard !hasControls(address) else { throw WebMediaError.unsafeURL }
        return try checkedURL(address.trimmingCharacters(in: .whitespacesAndNewlines), webpage: true)
    }
    public static func validatedPageURL(_ url: URL) throws -> URL { try checkedURL(url.absoluteString, webpage: true) }
    private static func checkedURL(_ value: String, webpage: Bool = false, base: URL? = nil) throws -> URL {
        guard value.utf8.count <= 16_384, !hasControls(value),
              !(value.removingPercentEncoding.map(hasControls) ?? true),
              let url = URL(string: value, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, !hasControls(host),
              url.user == nil, url.password == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { throw WebMediaError.unsafeURL }
        if webpage {
            let credentials = Set(["password", "passwd", "access_token", "authorization", "cookie", "cookies", "api_key"])
            guard !components.queryItems.orEmpty.contains(where: { credentials.contains($0.name.lowercased()) }) else { throw WebMediaError.unsafeURL }
        }
        return url
    }

    public func selection(formatID: String = "auto", subtitleLanguage: String? = nil,
                          includeAutomaticSubtitles: Bool = false) throws -> WebMediaSelection {
        let separate: Bool
        if formatID == "auto" { separate = false }
        else {
            guard let format = formats.first(where: { $0.formatID == formatID }) else { throw WebMediaError.invalidFormat }
            separate = format.isVideoOnly
        }
        if let subtitleLanguage {
            let languages = includeAutomaticSubtitles ? automaticSubtitleLanguages : self.subtitleLanguages
            guard languages.contains(subtitleLanguage) else { throw WebMediaError.invalidSubtitle }
        } else if includeAutomaticSubtitles { throw WebMediaError.invalidSubtitle }
        return try WebMediaSelection(title: title, formatID: formatID, separateAudio: separate,
                                     subtitleLanguage: subtitleLanguage, includeAutomaticSubtitles: includeAutomaticSubtitles)
    }
    public func validatedSelection(_ preference: WebMediaSelection) throws -> WebMediaSelection {
        try selection(formatID: preference.formatID, subtitleLanguage: preference.subtitleLanguage,
                      includeAutomaticSubtitles: preference.includeAutomaticSubtitles)
    }

    public static func parse(data: Data, pageURL: URL) throws -> Self {
        guard data.count <= maximumBytes else { throw WebMediaError.tooLarge }
        let pageURL = try validatedPageURL(pageURL)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WebMediaError.invalidMetadata }
        if let kind = root["_type"] as? String, !["video", "audio"].contains(kind) { throw WebMediaError.unsupportedCollection }
        guard root["entries"] == nil || root["entries"] is NSNull else { throw WebMediaError.unsupportedCollection }
        guard !(try drm(root)) else { throw WebMediaError.drmProtected }
        let title = cleaned(root["title"] as? String) ?? pageURL.host ?? "网页媒体"
        guard title.utf8.count <= 4096 else { throw WebMediaError.invalidMetadata }
        var rawFormats: [[String: Any]]
        if let values = root["formats"] {
            guard let array = values as? [Any] else { throw WebMediaError.invalidMetadata }
            guard array.count <= 2000 else { throw WebMediaError.tooManyFormats }
            guard let rows = array as? [[String: Any]] else { throw WebMediaError.invalidMetadata }
            rawFormats = rows
        } else { rawFormats = [root] }
        var formats: [WebMediaFormat] = [], identifiers = Set<String>()
        for raw in rawFormats {
            guard !(try drm(raw)) else { throw WebMediaError.drmProtected }
            let video = codec(raw["vcodec"]), audio = codec(raw["acodec"])
            if video == "images" || (raw["vcodec"] as? String == "none" && raw["acodec"] as? String == "none") { continue }
            guard let rawURL = raw["url"] as? String else { continue }
            let mediaURL = try checkedURL(rawURL)
            for key in ["manifest_url", "fragment_base_url"] {
                if let value = raw[key] as? String { _ = try checkedURL(value) }
            }
            if let fragments = raw["fragments"] as? [[String: Any]] {
                let base = (raw["fragment_base_url"] as? String).flatMap { URL(string: $0) } ?? mediaURL
                for fragment in fragments { if let value = fragment["url"] as? String { _ = try checkedURL(value, base: base) } }
            }
            let id = raw["format_id"] as? String ?? (rawFormats.count == 1 ? "auto" : "")
            guard WebMediaSelection.validIdentifier(id), identifiers.insert(id).inserted else { throw WebMediaError.invalidFormat }
            let ext = cleaned(raw["ext"] as? String) ?? "media"
            guard ext.utf8.count <= 32 else { throw WebMediaError.invalidMetadata }
            let width = dimension(raw["width"]), height = dimension(raw["height"])
            formats.append(WebMediaFormat(formatID: id, ext: ext, width: width, height: height,
                fps: positive(raw["fps"], maximum: 1000), bitrate: positive(raw["tbr"], maximum: 1_000_000),
                videoCodec: video, audioCodec: audio,
                videoExplicitlyAbsent: raw["vcodec"] as? String == "none" || (rawFormats.count == 1 && root["_type"] as? String == "audio"),
                audioExplicitlyAbsent: raw["acodec"] as? String == "none",
                note: cleaned(raw["format_note"] as? String).map { String($0.prefix(160)) }))
        }
        guard !formats.isEmpty else { throw WebMediaError.invalidMetadata }
        let manual = try subtitleKeys(root["subtitles"]), automatic = try subtitleKeys(root["automatic_captions"])
        return Self(pageURL: pageURL, title: title, duration: positive(root["duration"], maximum: 10 * 365 * 86400),
                    isLive: bool(root["is_live"]) || ["is_live", "is_upcoming"].contains(root["live_status"] as? String ?? ""),
                    formats: formats, subtitleLanguages: manual, automaticSubtitleLanguages: automatic)
    }

    private static func drm(_ values: [String: Any]) throws -> Bool {
        for key in ["has_drm", "is_drm"] {
            guard let value = values[key], !(value is NSNull) else { continue }
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw WebMediaError.invalidMetadata }
            if number.boolValue { return true }
        }
        return false
    }
    private static func bool(_ value: Any?) -> Bool {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func positive(_ value: Any?, maximum: Double) -> Double? {
        guard let number = number(value), number > 0, number <= maximum else { return nil }; return number
    }
    private static func dimension(_ value: Any?) -> Int? {
        guard let value = positive(value, maximum: 65_536), value.rounded(.down) == value else { return nil }; return Int(value)
    }
    private static func codec(_ value: Any?) -> String? {
        guard let value = cleaned(value as? String), value != "none", value != "null", value.utf8.count <= 128 else { return nil }; return value
    }
    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let filtered = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value) }
        let text = String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    private static func subtitleKeys(_ value: Any?) throws -> [String] {
        guard let value, !(value is NSNull) else { return [] }
        guard let values = value as? [String: Any], values.count <= 200 else { throw WebMediaError.invalidMetadata }
        var available: [String] = []
        for (language, entries) in values {
            guard WebMediaSelection.validLanguage(language), let entries = entries as? [[String: Any]], entries.count <= 100 else { throw WebMediaError.invalidSubtitle }
            var hasURL = false
            for entry in entries { if let address = entry["url"] as? String { _ = try checkedURL(address); hasURL = true } }
            if hasURL { available.append(language) }
        }
        return available.sorted()
    }
}

private extension Optional where Wrapped == [URLQueryItem] { var orEmpty: [URLQueryItem] { self ?? [] } }
