import Foundation

public struct MediaChannel: Identifiable, Codable, Hashable {
    public var id: UUID
    public var name: String
    public var url: URL
    public var group: String
    /// The address is metadata only. Parsing a channel never fetches its logo.
    public var logoURL: URL?
    /// Exact XMLTV identity. Missing in older saved channel documents.
    public var tvgID: String?

    public init(name: String, url: URL, group: String = "", logoURL: URL? = nil, tvgID: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.url = url
        self.group = group
        self.logoURL = logoURL
        self.tvgID = tvgID
    }
}

public enum ChannelDocumentError: LocalizedError {
    case unreadableText
    case invalidAddress(Int)
    case emptyDocument
    case streamingManifest
    case unsafeMetadata

    public var errorDescription: String? {
        switch self {
        case .unreadableText: return "无法读取频道列表的文字编码。"
        case .invalidAddress(let line): return "频道列表第 \(line) 行地址无效，或包含账号密码。"
        case .emptyDocument: return "列表中没有有效频道。"
        case .streamingManifest: return "这是 HLS 播放清单。请直接打开该网络地址播放，无需导入频道。"
        case .unsafeMetadata: return "频道地址无效，不能导出带账号密码的 URL。"
        }
    }
}

public struct ChannelDocument {
    public var channels: [MediaChannel]
    public init(channels: [MediaChannel]) { self.channels = channels }

    public static func read(from url: URL) throws -> ChannelDocument {
        guard url.isFileURL else { throw ChannelDocumentError.invalidAddress(0) }
        return try parse(data: Data(contentsOf: url), baseURL: url)
    }

    public static func parse(data: Data, baseURL: URL) throws -> ChannelDocument {
        guard let text = DocumentTextDecoder.decode(data) else { throw ChannelDocumentError.unreadableText }
        return try parse(text, baseURL: baseURL)
    }

    public static func parse(_ text: String, baseURL: URL) throws -> ChannelDocument {
        let lines = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let isPLS = baseURL.pathExtension.lowercased() == "pls" || lines.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "[playlist]" }
        if isPLS { return try parsePLS(lines, baseURL: baseURL) }
        guard !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#EXT-X-") }) else {
            throw ChannelDocumentError.streamingManifest
        }
        var channels: [MediaChannel] = []
        var name = ""
        var group = ""
        var logo: URL?
        var tvgID: String?
        for (offset, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.uppercased().hasPrefix("#EXTINF:") {
                let metadata = String(line.dropFirst(8))
                let split = metadataSplit(metadata)
                let attributes = try parseAttributes(split.attributes)
                name = split.title.isEmpty ? attributes["tvg-name"] ?? "" : split.title
                group = attributes["group-title"] ?? ""
                logo = attributes["tvg-logo"].flatMap { try? resolvedAddress($0, baseURL: baseURL, line: offset + 1, logo: true) }
                tvgID = attributes["tvg-id"]
                if let id = tvgID {
                    guard id.utf8.count <= 256, !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ChannelDocumentError.unsafeMetadata }
                }
                continue
            }
            if line.uppercased().hasPrefix("#EXTGRP:") {
                group = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard !line.hasPrefix("#") else { continue }
            let url = try resolvedAddress(line, baseURL: baseURL, line: offset + 1)
            let fallback = url.lastPathComponent.isEmpty ? url.host ?? "频道 \(channels.count + 1)" : url.lastPathComponent
            channels.append(MediaChannel(name: name.isEmpty ? fallback : name, url: url, group: group, logoURL: logo, tvgID: tvgID))
            name = ""
            group = ""
            logo = nil
            tvgID = nil
        }
        guard !channels.isEmpty else { throw ChannelDocumentError.emptyDocument }
        return ChannelDocument(channels: channels)
    }

    public func m3u8Text() throws -> String {
        var lines = ["#EXTM3U"]
        for channel in channels {
            guard Self.isValidAddress(channel.url) else { throw ChannelDocumentError.unsafeMetadata }
            var attributes = ""
            if let id = channel.tvgID { attributes += " tvg-id=" + (try Self.exactQuotedIdentity(id)) }
            if !channel.group.isEmpty { attributes += " group-title=\"\(Self.cleanAttribute(channel.group))\"" }
            if let logoURL = channel.logoURL {
                guard Self.isValidAddress(logoURL, logo: true) else { throw ChannelDocumentError.unsafeMetadata }
                attributes += " tvg-logo=\"\(Self.cleanAttribute(logoURL.absoluteString))\""
            }
            let title = channel.name.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            lines.append("#EXTINF:-1\(attributes),\(title)")
            lines.append(channel.url.absoluteString)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func writeM3U8(to url: URL) throws { try m3u8Text().write(to: url, atomically: true, encoding: .utf8) }

    /// Preserve existing percent escapes while encoding raw Unicode/spaces.
    /// Foundation's automatic encoding can otherwise turn a mixed reference
    /// such as `中文%20影片.mp4` into a path containing a literal `%20`.
    public static func resolveReference(_ text: String, relativeTo baseURL: URL) -> URL? {
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let bytes = Array(text.utf8)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=".utf8)
        func isHex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) }
        var encoded = ""
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 37, index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) {
                encoded += String(bytes: bytes[index...(index + 2)], encoding: .utf8)!
                index += 3
                continue
            }
            if allowed.contains(byte) { encoded.append(Character(UnicodeScalar(byte))) }
            else { encoded += String(format: "%%%02X", byte) }
            index += 1
        }
        return URL(string: encoded, relativeTo: baseURL)?.absoluteURL
    }

    private static func parsePLS(_ lines: [String], baseURL: URL) throws -> ChannelDocument {
        var files: [Int: (String, Int)] = [:]
        var names: [Int: String] = [:]
        for (offset, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("file"), let index = Int(key.dropFirst(4)), index > 0 { files[index] = (value, offset + 1) }
            else if key.hasPrefix("title"), let index = Int(key.dropFirst(5)), index > 0 { names[index] = value }
        }
        let channels = try files.keys.sorted().map { index -> MediaChannel in
            let entry = files[index]!
            let url = try resolvedAddress(entry.0, baseURL: baseURL, line: entry.1)
            let title = names[index]?.isEmpty == false ? names[index]! : url.lastPathComponent
            return MediaChannel(name: title.isEmpty ? "频道 \(index)" : title, url: url)
        }
        guard !channels.isEmpty else { throw ChannelDocumentError.emptyDocument }
        return ChannelDocument(channels: channels)
    }

    private static func metadataSplit(_ metadata: String) -> (attributes: String, title: String) {
        var quote: Character?
        for index in metadata.indices {
            let character = metadata[index]
            if let existing = quote { if character == existing { quote = nil } }
            else if character == "\"" || character == "'" { quote = character }
            else if character == "," {
                return (String(metadata[..<index]), String(metadata[metadata.index(after: index)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return (metadata, "")
    }

    private static func parseAttributes(_ text: String) throws -> [String: String] {
        let pattern = #"([A-Za-z0-9_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let source = text as NSString
        var attributes: [String: String] = [:]
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let key = source.substring(with: match.range(at: 1)).lowercased()
            if key == "tvg-id", attributes[key] != nil { throw ChannelDocumentError.unsafeMetadata }
            for index in 2...4 where match.range(at: index).location != NSNotFound {
                attributes[key] = source.substring(with: match.range(at: index))
            }
        }
        return attributes
    }

    private static func resolvedAddress(_ text: String, baseURL: URL, line: Int, logo: Bool = false) throws -> URL {
        guard !text.isEmpty, !text.contains("\u{0000}") else { throw ChannelDocumentError.invalidAddress(line) }
        let url: URL?
        if baseURL.isFileURL, URL(string: text)?.scheme == nil {
            url = text.hasPrefix("/") ? URL(fileURLWithPath: text) : baseURL.deletingLastPathComponent().appendingPathComponent(text).standardizedFileURL
        } else { url = resolveReference(text, relativeTo: baseURL) }
        guard let url, isValidAddress(url, logo: logo) else { throw ChannelDocumentError.invalidAddress(line) }
        return url
    }

    private static func isValidAddress(_ url: URL, logo: Bool = false) -> Bool {
        guard url.user == nil, url.password == nil else { return false }
        if url.isFileURL { return !logo }
        let schemes = logo ? ["http", "https"] : ["http", "https", "rtsp", "rtsps", "rtmp"]
        return schemes.contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
            && !url.absoluteString.contains("\n") && !url.absoluteString.contains("\r")
    }

    private static func cleanAttribute(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
    private static func exactQuotedIdentity(_ text: String) throws -> String {
        guard text.utf8.count <= 256, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ChannelDocumentError.unsafeMetadata }
        if !text.contains("\"") { return "\"" + text + "\"" }
        if !text.contains("'") { return "'" + text + "'" }
        // Extended M3U has no universally supported escaping for both quotes.
        // Reject before atomic write rather than silently changing XMLTV ID.
        throw ChannelDocumentError.unsafeMetadata
    }
}
