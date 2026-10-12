import Foundation
import Darwin

struct EPGPreferences: Codable, Equatable, Sendable {
    var version = 1
    var sourceAddress: String?
    var manualMappings: [String: String] = [:]
    var logosEnabled = false
    static let maximumBytes = 1024 * 1024
    static let maximumMappings = 2000
    static func sourceMayBePersisted(_ url: URL) -> Bool {
        let sensitive: Set<String> = ["username", "user", "password", "passwd", "pwd", "token", "accesstoken", "apikey", "auth", "authorization", "cookie", "signature", "sig", "key"]
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false), value.user == nil, value.password == nil else { return false }
        return !(value.queryItems ?? []).contains { item in
            sensitive.contains(item.name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: ""))
        }
    }

    func validated() throws -> Self {
        guard version == 1, manualMappings.count <= Self.maximumMappings else { throw EPGPreferencesError.invalidDocument }
        if let sourceAddress {
            guard sourceAddress.utf8.count <= 8192, let url = URL(string: sourceAddress), Self.sourceMayBePersisted(url) else { throw EPGPreferencesError.invalidDocument }
            if url.isFileURL {
                guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      value.user == nil, value.password == nil, !url.path.isEmpty,
                      url.host == nil || url.host == "" || url.host == "localhost",
                      !(sourceAddress.removingPercentEncoding ?? sourceAddress).unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw EPGPreferencesError.invalidDocument }
            } else { _ = try EPGAddress.validated(sourceAddress) }
        }
        for (key, id) in manualMappings {
            guard key.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                  !id.isEmpty, id.utf8.count <= 256,
                  !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw EPGPreferencesError.invalidDocument }
        }
        return self
    }
}

enum EPGPreferencesError: Error, LocalizedError {
    case invalidDocument, tooLarge, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidDocument: return "节目单偏好格式或版本无效，仍保留当前设置。"
        case .tooLarge: return "节目单偏好超过保存上限，仍保留当前设置。"
        case .unavailable: return "节目单偏好无法读取或保存，仍保留当前设置。"
        }
    }
}

protocol EPGPreferencesPublication: Sendable {
    /// On a thrown error, the existing target bytes must remain unchanged.
    func publish(_ data: Data, to target: URL) throws
}
struct EPGAtomicPreferencesPublication: EPGPreferencesPublication {
    func publish(_ data: Data, to target: URL) throws { try data.write(to: target, options: .atomic) }
}

/// A distinct versioned file. No username/password/cookies or automatic loading.
/// A rejected candidate never updates the in-memory value or existing disk file.
@MainActor
final class EPGPreferencesStore {
    private(set) var value: EPGPreferences
    private let file: URL
    private let publication: any EPGPreferencesPublication
    init(file: URL, initial: EPGPreferences = .init(), publication: any EPGPreferencesPublication = EPGAtomicPreferencesPublication()) {
        self.file = file.standardizedFileURL; self.value = initial; self.publication = publication
    }
    @discardableResult
    func load() throws -> EPGPreferences {
        let descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return value }
            throw EPGPreferencesError.unavailable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_size <= EPGPreferences.maximumBytes else { throw EPGPreferencesError.tooLarge }
        let data = try handle.read(upToCount: EPGPreferences.maximumBytes + 1) ?? Data()
        guard data.count <= EPGPreferences.maximumBytes else { throw EPGPreferencesError.tooLarge }
        let candidate: EPGPreferences
        do {
            try EPGPreferencesDuplicateKeys.validate(data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: ["version", "sourceAddress", "manualMappings", "logosEnabled"]) else { throw EPGPreferencesError.invalidDocument }
            candidate = try JSONDecoder().decode(EPGPreferences.self, from: data).validated()
        }
        catch let error as EPGPreferencesError { throw error }
        catch { throw EPGPreferencesError.invalidDocument }
        value = candidate
        return candidate
    }
    func save(_ input: EPGPreferences) throws {
        let candidate = try input.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(candidate)
        guard data.count <= EPGPreferences.maximumBytes else { throw EPGPreferencesError.tooLarge }
        let parent = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw EPGPreferencesError.unavailable }
        defer { Darwin.close(descriptor) }
        if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw EPGPreferencesError.unavailable }
        try publication.publish(data, to: file)
        value = candidate
    }
}
