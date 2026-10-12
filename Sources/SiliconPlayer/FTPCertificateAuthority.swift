import Foundation
import Darwin
import CryptoKit
import Security

/// An explicit, in-memory PEM selection. It does not import a certificate into
/// Keychain or change any system/default trust setting. No arbitrary source URL
/// is retained or passed to libcurl; the native owner writes its own bounded copy.
struct FTPCertificateAuthority: Sendable {
    struct Scope: Equatable, Sendable {
        let scheme: String, host: String
        let port: Int
        let requiresTLS: Bool
        init(_ address: FTPDirectoryAddress) {
            scheme = address.url.scheme!.lowercased()
            host = address.url.host!.lowercased()
            port = address.url.port ?? (scheme == "ftps" ? 990 : 21)
            requiresTLS = address.requireTLS
        }
        var description: String { "\(scheme)://\(host):\(port)（TLS）" }
    }
    let scope: Scope
    let pem: Data
    let name: String
    let sha256: String
    static let maximumBytes = 1_048_576

    /// Call only on a utility worker. Final-component links/FIFO/device input
    /// are rejected; existing ancestor aliases resolve to a real held file.
    /// Before/end identity, size and mtime must agree, including the named file.
    static func load(_ input: URL, scope: Scope) throws -> FTPCertificateAuthority {
        guard input.isFileURL, scope.requiresTLS else { throw FTPCertificateFailure.invalidSource }
        var original = stat()
        guard lstat(input.path, &original) == 0,
              original.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              let pointer = Darwin.realpath(input.path, nil) else { throw FTPCertificateFailure.invalidSource }
        let path = String(cString: pointer); Darwin.free(pointer)
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw FTPCertificateFailure.invalidSource }
        let owner = DirectoryLibraryFD(fd)
        defer { _ = owner.close() } // failed close remains in the real registry
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_dev == original.st_dev, before.st_ino == original.st_ino,
              before.st_size > 0, before.st_size <= off_t(maximumBytes) else { throw FTPCertificateFailure.invalidSource }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw FTPCertificateFailure.invalidSource }
            if count == 0 { break }
            guard data.count + count <= maximumBytes else { throw FTPCertificateFailure.invalidSource }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat(), named = stat(), originalEnd = stat()
        guard fstat(fd, &after) == 0, lstat(path, &named) == 0, lstat(input.path, &originalEnd) == 0,
              same(before, after), same(after, named), same(after, originalEnd), Int64(data.count) == Int64(after.st_size) else {
            throw FTPCertificateFailure.changedSource
        }
        try validatePEM(data)
        guard owner.close() else { throw FTPBrowserFailure.cleanupPending }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return FTPCertificateAuthority(scope: scope, pem: data, name: input.lastPathComponent, sha256: digest)
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        b.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }
    /// Syntax/real X.509 parsing only. Trust and hostname validation remain the
    /// TLS backend's job. A parsed certificate is never described as trusted.
    static func validatePEM(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else {
            throw FTPCertificateFailure.invalidPEM
        }
        let begin = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----"
        var remaining = text[...], certificates = 0
        while !String(remaining).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            remaining = remaining.drop(while: { $0.isWhitespace })
            guard remaining.hasPrefix(begin) else { throw FTPCertificateFailure.invalidPEM }
            remaining = remaining.dropFirst(begin.count)
            guard let closing = remaining.range(of: end) else { throw FTPCertificateFailure.invalidPEM }
            let encoded = remaining[..<closing.lowerBound].filter { !$0.isWhitespace }
            guard encoded.utf8.count <= 90_000,
                  let der = Data(base64Encoded: String(encoded)), !der.isEmpty, der.count <= 65_536,
                  SecCertificateCreateWithData(nil, der as CFData) != nil else { throw FTPCertificateFailure.invalidPEM }
            certificates += 1
            guard certificates <= 16 else { throw FTPCertificateFailure.invalidPEM }
            remaining = remaining[closing.upperBound...]
        }
        guard certificates > 0 else { throw FTPCertificateFailure.invalidPEM }
    }
}

enum FTPCertificateFailure: Error, LocalizedError, Sendable {
    case invalidSource, changedSource, invalidPEM, differentConnection
    var errorDescription: String? {
        switch self {
        case .invalidSource: return "请选择不超过 1 MiB 的本机普通 PEM 证书文件；不接受链接、目录或特殊文件。"
        case .changedSource: return "读取期间证书文件发生变化，未更改当前连接信任。"
        case .invalidPEM: return "只接受 1–16 个可解析 X.509 证书的 PEM；不接受私钥或额外文本。"
        case .differentConnection: return "该 CA 只授权已明确选择的协议、主机、端口与 TLS 模式；请重新选择或恢复系统信任。"
        }
    }
}
