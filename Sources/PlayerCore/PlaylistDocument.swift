import Foundation
import CoreFoundation

public enum PlaylistDocumentError: LocalizedError {
    case unsupportedFormat(String)
    case unreadableText
    case invalidEntry(line: Int, value: String)
    case streamingManifest
    case unsafeExportEntry

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format): return "不支持的播放列表格式：\(format)。请选择 M3U、M3U8 或 PLS。"
        case .unreadableText: return "无法读取播放列表的文字编码。"
        case .invalidEntry(let line, let value): return "播放列表第 \(line) 行地址无效：\(value)"
        case .streamingManifest: return "这是 HLS 流媒体清单。请直接打开清单地址播放，不能作为普通播放列表导入。"
        case .unsafeExportEntry: return "媒体地址含换行符，无法安全导出播放列表。"
        }
    }
}

/// Imports local playlist documents only. Remote media URLs inside documents
/// remain URLs and are never downloaded during import or export.
public enum PlaylistDocument {
    public enum Format: String { case m3u, m3u8, pls }

    public static func read(from url: URL) throws -> [URL] {
        guard url.isFileURL else { throw PlaylistDocumentError.invalidEntry(line: 0, value: url.absoluteString) }
        guard Format(rawValue: url.pathExtension.lowercased()) != nil else {
            throw PlaylistDocumentError.unsupportedFormat(url.pathExtension)
        }
        return try read(data: Data(contentsOf: url), from: url)
    }

    /// Reuses the exact document decoder after a caller has bound/read a bounded
    /// regular file. Relative paths still resolve against the original input URL.
    public static func read(data: Data, from url: URL) throws -> [URL] {
        guard url.isFileURL else { throw PlaylistDocumentError.invalidEntry(line: 0, value: url.absoluteString) }
        guard let format = Format(rawValue: url.pathExtension.lowercased()) else {
            throw PlaylistDocumentError.unsupportedFormat(url.pathExtension)
        }
        guard let text = DocumentTextDecoder.decode(data) else { throw PlaylistDocumentError.unreadableText }
        return try parse(text, baseURL: url, format: format)
    }

    public static func parse(_ text: String, baseURL: URL, format: Format = .m3u8) throws -> [URL] {
        let lines = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if format == .pls {
            var files: [Int: (String, Int)] = [:]
            for (offset, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let equals = line.firstIndex(of: "=") else { continue }
                let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                guard key.hasPrefix("file"), let index = Int(key.dropFirst(4)), index > 0 else { continue }
                files[index] = (String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces), offset + 1)
            }
            return try files.keys.sorted().map { key in
                let (entry, line) = files[key]!
                return try resolve(entry, baseURL: baseURL, line: line)
            }
        }
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#EXT-X-") }) {
            throw PlaylistDocumentError.streamingManifest
        }
        return try lines.enumerated().compactMap { offset, raw -> URL? in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            return try resolve(line, baseURL: baseURL, line: offset + 1)
        }
    }

    public static func m3u8(urls: [URL]) throws -> String {
        var lines = ["#EXTM3U"]
        for url in urls {
            let location = url.isFileURL ? url.path : url.absoluteString
            let title = MediaItem(url: url).title.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            guard !location.contains("\n"), !location.contains("\r") else { throw PlaylistDocumentError.unsafeExportEntry }
            lines.append("#EXTINF:-1,\(title)")
            // A file URL prevents a filename beginning with '#' from becoming a comment.
            lines.append(url.isFileURL ? url.standardizedFileURL.absoluteString : location)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func writeM3U8(urls: [URL], to url: URL) throws {
        try m3u8(urls: urls).write(to: url, atomically: true, encoding: .utf8)
    }

    public static func pls(urls: [URL]) throws -> String {
        var lines = ["[playlist]", "NumberOfEntries=\(urls.count)"]
        for (offset, url) in urls.enumerated() {
            let location = url.isFileURL ? url.path : url.absoluteString
            guard !location.contains("\n"), !location.contains("\r") else { throw PlaylistDocumentError.unsafeExportEntry }
            let index = offset + 1
            let title = MediaItem(url: url).title.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            lines.append("File\(index)=\(url.isFileURL ? url.standardizedFileURL.absoluteString : location)")
            lines.append("Title\(index)=\(title)")
            lines.append("Length\(index)=-1")
        }
        lines.append("Version=2")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func writePLS(urls: [URL], to url: URL) throws {
        try pls(urls: urls).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func resolve(_ entry: String, baseURL: URL, line: Int) throws -> URL {
        guard !entry.isEmpty, !entry.contains("\u{0000}") else { throw PlaylistDocumentError.invalidEntry(line: line, value: entry) }
        if entry.hasPrefix("/") { return URL(fileURLWithPath: entry).standardizedFileURL }
        if entry.hasPrefix("~") { return URL(fileURLWithPath: (entry as NSString).expandingTildeInPath).standardizedFileURL }
        if entry.range(of: "^[A-Za-z]:[\\\\/]", options: .regularExpression) != nil {
            throw PlaylistDocumentError.invalidEntry(line: line, value: entry)
        }
        if let url = URL(string: entry), let scheme = url.scheme {
            guard scheme.lowercased() == "file" || url.host != nil else { throw PlaylistDocumentError.invalidEntry(line: line, value: entry) }
            return MediaItem.normalized(url)
        }
        if baseURL.isFileURL {
            let directory = baseURL.hasDirectoryPath ? baseURL : baseURL.deletingLastPathComponent()
            return directory.appendingPathComponent(entry).standardizedFileURL
        }
        guard let url = URL(string: entry, relativeTo: baseURL)?.absoluteURL, url.host != nil else {
            throw PlaylistDocumentError.invalidEntry(line: line, value: entry)
        }
        return url
    }
}

enum DocumentTextDecoder {
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        if let text = String(data: data, encoding: .utf8) { return text }
        let chinese = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        for encoding in [chinese, .windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }
}
