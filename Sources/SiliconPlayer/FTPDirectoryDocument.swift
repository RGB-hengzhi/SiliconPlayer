import Foundation
import CryptoKit

enum FTPBrowserFailure: LocalizedError {
    case invalidAddress, unsupportedProtocol, invalidCredentials, malformedListing, documentTooLarge
    case native(stage: String, code: Int, reply: Int), cleanupPending, cancelled, stalePlayback
    case keychain(Int32), cacheUnavailable, playbackOpenFailed
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请输入不含凭据、查询或片段的完整 ftp:// 或 ftps:// 目录地址。"
        case .unsupportedProtocol: return "本机原生网络库未提供所选 FTP/TLS 协议；SFTP 尚未接入。"
        case .invalidCredentials: return "凭据为空或过长，或包含控制字符。"
        case .malformedListing: return "服务器没有返回受支持的 UTF-8 MLSD 清单；不猜测 LIST 的文本格式。"
        case .documentTooLarge: return "目录超过 8 MiB、20000 项或单行 64 KiB 限制。"
        case .native(let stage, let code, let reply): return "FTP 请求失败（\(stage)，网络代码 \(code)，响应 \(reply)）。可检查连接后重试。"
        case .cleanupPending: return "原生请求或缓存文件尚未确认释放；本任务仍受持有，可再次取消或退出。"
        case .cancelled: return "请求已取消；旧清单保留。"
        case .stalePlayback: return "下载完成，但播放上下文已变化；文件保留，可明确点击播放本机副本。"
        case .keychain(let status): return "钥匙串操作未完成（状态 \(status)）；未使用其他服务的凭据。"
        case .playbackOpenFailed: return "本机副本的打开请求未确认提交；缓存保留，没有声称播放或加入队列成功。"
        case .cacheUnavailable: return "本机专用缓存目录不可用。"
        }
    }
}

struct FTPDirectoryAddress: Hashable, Sendable {
    let url: URL
    let requireTLS: Bool
    var effectivePort: Int { url.port ?? (url.scheme == "ftps" ? 990 : 21) }
    static func hasControls(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    init(_ text: String, requireTLS: Bool = true) throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 8192, !Self.hasControls(value),
              var c = URLComponents(string: value), ["ftp", "ftps"].contains(c.scheme?.lowercased() ?? ""),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.port == nil || (1...65535).contains(c.port!),
              let decoded = c.percentEncodedPath.removingPercentEncoding, !Self.hasControls(decoded),
              !decoded.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              c.percentEncodedPath.range(of: "%2f|%5c", options: [.regularExpression, .caseInsensitive]) == nil
        else { throw FTPBrowserFailure.invalidAddress }
        c.scheme = c.scheme?.lowercased(); c.host = host.lowercased()
        // Re-encode real path components so curl's ;type= suffix cannot change
        // file transfer semantics. A slash remains a path separator.
        c.percentEncodedPath = "/" + decoded.split(separator: "/", omittingEmptySubsequences: true)
            .map { Self.encodeComponent(String($0)) }.joined(separator: "/") + "/"
        if c.percentEncodedPath == "//" { c.percentEncodedPath = "/" }
        guard let url = c.url else { throw FTPBrowserFailure.invalidAddress }
        self.url = url; self.requireTLS = requireTLS || c.scheme == "ftps"
    }
    private init(url: URL, requireTLS: Bool) { self.url = url; self.requireTLS = requireTLS }
    static func encodeComponent(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }
    func child(_ name: String, directory: Bool) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !Self.hasControls(name), name.utf8.count <= 4096,
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw FTPBrowserFailure.malformedListing }
        c.percentEncodedPath += Self.encodeComponent(name) + (directory ? "/" : "")
        guard let u = c.url else { throw FTPBrowserFailure.malformedListing }; return u
    }
    var parent: FTPDirectoryAddress? {
        guard url.path != "/" else { return nil }
        return try? FTPDirectoryAddress(url.deletingLastPathComponent().absoluteString, requireTLS: requireTLS)
    }
    func accepts(_ value: URL) -> Bool {
        guard let c = URLComponents(url: value, resolvingAgainstBaseURL: false),
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.scheme == url.scheme, c.host?.lowercased() == url.host?.lowercased(),
              (c.port ?? (c.scheme == "ftps" ? 990 : 21)) == effectivePort else { return false }
        return value.deletingLastPathComponent().standardized.absoluteString == url.standardized.absoluteString
    }
    func keychainAccount(username: String) -> String {
        let tuple = [url.scheme ?? "", url.host ?? "", String(effectivePort), requireTLS ? "tls-required" : "plain", username]
        let bytes = (try? JSONEncoder().encode(tuple)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct FTPDirectoryResource: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL, name: String
    let isDirectory: Bool
    let bytes: Int64?
    let modified: Date?
}

enum FTPDirectoryDocument {
    static func parse(_ data: Data, at address: FTPDirectoryAddress) throws -> [FTPDirectoryResource] {
        guard data.count <= 8 * 1_048_576 else { throw FTPBrowserFailure.documentTooLarge }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\u{0000}") else { throw FTPBrowserFailure.malformedListing }
        var result: [FTPDirectoryResource] = [], known = Set<URL>(), recordCount = 0
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty { continue }
            recordCount += 1
            guard line.utf8.count <= 65_536, recordCount <= 20_000 else { throw FTPBrowserFailure.documentTooLarge }
            guard let space = line.firstIndex(of: " "), space != line.startIndex else { throw FTPBrowserFailure.malformedListing }
            let factsText = line[..<space], name = String(line[line.index(after: space)...])
            guard factsText.hasSuffix(";") else { throw FTPBrowserFailure.malformedListing }
            var facts: [String: String] = [:]
            for item in factsText.split(separator: ";") {
                guard let equal = item.firstIndex(of: "="), equal != item.startIndex else { throw FTPBrowserFailure.malformedListing }
                let key = String(item[..<equal]).lowercased()
                guard facts[key] == nil else { throw FTPBrowserFailure.malformedListing }
                facts[key] = String(item[item.index(after: equal)...])
            }
            let type = facts["type"]?.lowercased()
            if type == "cdir" || type == "pdir" { continue }
            // Links / OS.unix=slink and unknown types are never followed.
            guard type == "file" || type == "dir" else { continue }
            let u = try address.child(name, directory: type == "dir")
            guard known.insert(u).inserted else { throw FTPBrowserFailure.malformedListing }
            var size: Int64?
            if let value = facts["size"] {
                guard let v = Int64(value), v >= 0 else { throw FTPBrowserFailure.malformedListing }; size = v
            }
            var date: Date?
            if let value = facts["modify"] {
                let head = String(value.prefix(14))
                guard head.count == 14, head.allSatisfy(\.isNumber) else { throw FTPBrowserFailure.malformedListing }
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyyMMddHHmmss"
                guard let parsed = f.date(from: head) else { throw FTPBrowserFailure.malformedListing }; date = parsed
            }
            result.append(.init(url: u, name: name, isDirectory: type == "dir", bytes: size, modified: date))
        }
        return result.sorted { if $0.isDirectory != $1.isDirectory { return $0.isDirectory }; return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
