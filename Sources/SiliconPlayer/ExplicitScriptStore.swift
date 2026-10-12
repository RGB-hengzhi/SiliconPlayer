import Foundation
import CryptoKit
import Darwin

enum ExplicitScriptError: Error, LocalizedError {
    case unsupported, invalidFile, changedFile, invalidManifest, locked, io, blocked, unavailable, busy
    var errorDescription: String? {
        switch self {
        case .unsupported: return "仅可导入完整的 UTF-8 .lua 或 .js 单文件，最大 1 MiB。"
        case .invalidFile: return "文件必须是本地普通文件；不接受符号链接、特殊文件或链接目录。"
        case .changedFile: return "文件在读取期间变化，或托管副本与记录的 SHA 不符。"
        case .invalidManifest: return "扩展记录损坏；原文件保留，未自动重置或执行。"
        case .locked: return "该配置的扩展目录被另一实例占用。请先退出该实例。"
        case .io: return "扩展文件读写失败；请保留文件并检查目录权限。"
        case .blocked: return "配置恢复尚未完成，扩展写入及执行已阻止。"
        case .unavailable: return "播放内核已关闭或不可用。"
        case .busy: return "已有未确认的扩展命令，不能重复载入。"
        }
    }
}

enum ExplicitScriptLanguage: String, Codable, Sendable { case lua, js }

struct ExplicitScriptRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let language: ExplicitScriptLanguage
    let sha256: String
    let byteCount: Int
    let importedAt: Date
    var enabled: Bool
    var pendingDeletion: Bool
    var fileName: String { "sp_ext_" + id.uuidString.lowercased() + "." + language.rawValue }
}

struct ExplicitScriptDocument: Codable, Sendable {
    var kind = "SiliconPlayerExplicitScripts"
    var version = 1
    var revision = UUID()
    var records: [ExplicitScriptRecord] = []
    func validated() throws -> Self {
        guard kind == "SiliconPlayerExplicitScripts", version == 1, records.count <= 64,
              Set(records.map(\.id)).count == records.count else { throw ExplicitScriptError.invalidManifest }
        for item in records {
            guard (1...1_048_576).contains(item.byteCount), item.title.utf8.count <= 512,
                  !item.title.isEmpty, !item.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  item.sha256.count == 64, item.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  item.importedAt.timeIntervalSince1970.isFinite,
                  !(item.pendingDeletion && item.enabled) else { throw ExplicitScriptError.invalidManifest }
        }
        return self
    }
}

/// Owned, non-autoload directory. The lock remains held for the controller's
/// whole process lifetime, including after an mpv shutdown *request* event.
/// This is bounded local-file management, not an arbitrary-code sandbox.
@MainActor final class ExplicitScriptStore {
    static let scriptLimit = 1_048_576
    private let directory: URL
    private let descriptor: Int32
    private let lockDescriptor: Int32
    private var manifestBytes: Data?
    private(set) var document: ExplicitScriptDocument

    init(directory: URL) throws {
        self.directory = directory
        let root = try Self.openDirectory(directory, create: true)
        let lock = openat(root, "manager.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lock >= 0 else { Darwin.close(root); throw ExplicitScriptError.io }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lock); Darwin.close(root); throw ExplicitScriptError.locked
        }
        do {
            let bytes = try Self.readRegular(parent: root, name: "manifest.json", limit: 131_072, allowMissing: true)
            let doc = try bytes.map { try JSONDecoder().decode(ExplicitScriptDocument.self, from: $0).validated() }
                ?? ExplicitScriptDocument()
            descriptor = root; lockDescriptor = lock; manifestBytes = bytes; document = doc
        } catch {
            Darwin.close(lock); Darwin.close(root)
            throw ExplicitScriptError.invalidManifest
        }
    }
    deinit { Darwin.close(lockDescriptor); Darwin.close(descriptor) }

    private static func openDirectory(_ url: URL, create: Bool) throws -> Int32 {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { throw ExplicitScriptError.invalidFile }
        let parts = url.path.split(separator: "/").map(String.init)
        guard !parts.contains("."), !parts.contains("..") else { throw ExplicitScriptError.invalidFile }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard current >= 0 else { throw ExplicitScriptError.io }
        do {
            for part in parts {
                var next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(current, part, 0o700) == 0 || errno == EEXIST else { throw ExplicitScriptError.io }
                    next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                }
                guard next >= 0 else { throw ExplicitScriptError.invalidFile }
                Darwin.close(current); current = next
            }
            return current
        } catch { Darwin.close(current); throw error }
    }

    private static func readRegular(parent: Int32, name: String, limit: Int, allowMissing: Bool = false) throws -> Data? {
        guard !name.isEmpty, !name.contains("/"), !name.utf8.contains(0), name != ".", name != ".." else { throw ExplicitScriptError.invalidFile }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT, allowMissing { return nil }
        guard fd >= 0 else { throw ExplicitScriptError.invalidFile }
        defer { Darwin.close(fd) }
        var first = stat(), last = stat()
        guard fstat(fd, &first) == 0, first.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              first.st_size >= 0, first.st_size <= limit else { throw ExplicitScriptError.invalidFile }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= limit {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, limit + 1 - data.count)) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ExplicitScriptError.io }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= limit, fstat(fd, &last) == 0,
              first.st_dev == last.st_dev, first.st_ino == last.st_ino, first.st_size == last.st_size,
              first.st_mtimespec.tv_sec == last.st_mtimespec.tv_sec,
              first.st_mtimespec.tv_nsec == last.st_mtimespec.tv_nsec,
              first.st_ctimespec.tv_sec == last.st_ctimespec.tv_sec,
              first.st_ctimespec.tv_nsec == last.st_ctimespec.tv_nsec,
              data.count == last.st_size else { throw ExplicitScriptError.changedFile }
        return data
    }

    static func readImport(_ url: URL) throws -> (Data, ExplicitScriptLanguage, String) {
        guard let language = ExplicitScriptLanguage(rawValue: url.pathExtension.lowercased()) else { throw ExplicitScriptError.unsupported }
        let parent = try openDirectory(url.deletingLastPathComponent(), create: false)
        defer { Darwin.close(parent) }
        guard let data = try readRegular(parent: parent, name: url.lastPathComponent, limit: scriptLimit),
              !data.isEmpty, !data.contains(0), String(data: data, encoding: .utf8) != nil else { throw ExplicitScriptError.unsupported }
        let name = String(url.lastPathComponent.filter { !($0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)) }.prefix(128))
        guard !name.isEmpty, name.utf8.count <= 512 else { throw ExplicitScriptError.unsupported }
        return (data, language, name)
    }

    private func writeExclusive(_ data: Data, name: String) throws {
        let fd = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ExplicitScriptError.io }
        var success = false
        defer { Darwin.close(fd); if !success { _ = unlinkat(descriptor, name, 0) } }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ExplicitScriptError.io }
            offset += count
        }
        guard fsync(fd) == 0 else { throw ExplicitScriptError.io }
        success = true
    }

    func verifyManifestUnchanged() throws {
        guard try Self.readRegular(parent: descriptor, name: "manifest.json", limit: 131_072, allowMissing: true) == manifestBytes
            else { throw ExplicitScriptError.changedFile }
    }
    private func commit(_ value: ExplicitScriptDocument) throws {
        let next = try value.validated()
        try verifyManifestUnchanged()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(next)
        guard bytes.count <= 131_072 else { throw ExplicitScriptError.invalidManifest }
        let temporary = ".manifest-" + UUID().uuidString + ".json"
        try writeExclusive(bytes, name: temporary)
        defer { _ = unlinkat(descriptor, temporary, 0) }
        guard renameat(descriptor, temporary, descriptor, "manifest.json") == 0 else { throw ExplicitScriptError.io }
        // Publish the actual written state even if directory durability cannot
        // be confirmed, preventing a later write from using the previous base.
        document = next; manifestBytes = bytes
        guard fsync(descriptor) == 0 else { throw ExplicitScriptError.io }
    }

    func importFile(_ url: URL) throws -> ExplicitScriptRecord {
        guard document.records.count < 64 else { throw ExplicitScriptError.invalidManifest }
        let (data, language, title) = try Self.readImport(url)
        let item = ExplicitScriptRecord(id: UUID(), title: title, language: language,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: data.count, importedAt: Date(), enabled: false, pendingDeletion: false)
        try writeExclusive(data, name: item.fileName)
        do {
            var next = document; next.revision = UUID(); next.records.append(item)
            try commit(next)
        } catch {
            // If publication happened, preserve the referenced managed copy.
            if !document.records.contains(where: { $0.id == item.id }) { _ = unlinkat(descriptor, item.fileName, 0) }
            throw error
        }
        return item
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) throws {
        guard let index = document.records.firstIndex(where: { $0.id == id }), !document.records[index].pendingDeletion
            else { throw ExplicitScriptError.invalidManifest }
        var next = document; next.revision = UUID(); next.records[index].enabled = enabled
        try commit(next)
    }

    func loadURL(_ id: UUID) throws -> URL {
        try verifyManifestUnchanged()
        guard let item = document.records.first(where: { $0.id == id }), item.enabled, !item.pendingDeletion,
              let data = try Self.readRegular(parent: descriptor, name: item.fileName, limit: Self.scriptLimit),
              data.count == item.byteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == item.sha256
            else { throw ExplicitScriptError.changedFile }
        return directory.appendingPathComponent(item.fileName)
    }

    func markDeleted(_ id: UUID) throws {
        guard let index = document.records.firstIndex(where: { $0.id == id }) else { throw ExplicitScriptError.invalidManifest }
        var next = document; next.revision = UUID()
        next.records[index].enabled = false; next.records[index].pendingDeletion = true
        try commit(next)
    }

    /// Only entries never submitted in this process can be purged. At a later
    /// App launch, the exclusive lock proves the previous manager is gone.
    func purgeDeleted(retaining submitted: Set<UUID>) throws {
        try verifyManifestUnchanged()
        let eligible = document.records.filter { $0.pendingDeletion && !submitted.contains($0.id) }
        for item in eligible {
            if let data = try Self.readRegular(parent: descriptor, name: item.fileName, limit: Self.scriptLimit, allowMissing: true) {
                guard data.count == item.byteCount,
                      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == item.sha256
                    else { throw ExplicitScriptError.changedFile }
                guard unlinkat(descriptor, item.fileName, 0) == 0 else { throw ExplicitScriptError.io }
            }
        }
        guard !eligible.isEmpty else { return }
        var next = document; next.revision = UUID()
        let removing = Set(eligible.map(\.id)); next.records.removeAll { removing.contains($0.id) }
        try commit(next)
    }
}
