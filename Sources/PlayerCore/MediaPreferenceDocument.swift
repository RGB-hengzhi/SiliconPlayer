import Foundation

public struct MediaIdentity: Codable, Hashable, Sendable {
    public let originalURL: URL
    public var key: String { originalURL.absoluteString }

    public init(originalURL input: URL) throws {
        let text = input.absoluteString
        guard text.utf8.count <= 8192, !Self.hasControls(text),
              let decoded = text.removingPercentEncoding, !Self.hasControls(decoded),
              var parts = URLComponents(url: input, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil else { throw MediaPreferenceError.invalidIdentity }
        if input.isFileURL {
            guard parts.host == nil || parts.host == "" || parts.host?.lowercased() == "localhost",
                  parts.query == nil, parts.fragment == nil, input.path.hasPrefix("/") else { throw MediaPreferenceError.invalidIdentity }
            originalURL = input.standardizedFileURL
        } else {
            guard let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = parts.host, !host.isEmpty else { throw MediaPreferenceError.invalidIdentity }
            parts.scheme = scheme; parts.host = host.lowercased()
            if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { parts.port = nil }
            let forbidden = Set(["token", "access_token", "api-key", "api_key", "username", "user", "pass", "passwd", "password", "secret", "credential", "credentials", "auth", "session", "authorization", "signature", "sig", "policy", "key-pair-id"])
            guard !(parts.queryItems ?? []).contains(where: {
                var key = $0.name.lowercased()
                for _ in 0..<2 { key = key.removingPercentEncoding?.lowercased() ?? key }
                return forbidden.contains(key) || key.hasPrefix("x-amz-") || key.hasPrefix("x-goog-")
            }), let url = parts.url else { throw MediaPreferenceError.invalidIdentity }
            originalURL = url
        }
    }
    static func hasControls(_ text: String) -> Bool { text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
    private enum CodingKeys: String, CodingKey { case originalURL }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(originalURL: c.decode(URL.self, forKey: .originalURL))
    }
}

public enum MediaTrackKind: String, Codable, Sendable { case audio, subtitle }
public enum MediaTrackSource: Codable, Hashable, Sendable {
    case embedded
    case localFile(URL)
    case webpageSubtitle(language: String, automatic: Bool)

    func validated() throws -> Self {
        switch self {
        case .embedded: return self
        case .localFile(let url):
            let identity = try MediaIdentity(originalURL: url)
            guard identity.originalURL.isFileURL else { throw MediaPreferenceError.invalidTrack }
            return .localFile(identity.originalURL)
        case .webpageSubtitle(let language, let automatic):
            let normalized = try MediaTrackDescriptor.language(language)
            guard !normalized.isEmpty else { throw MediaPreferenceError.invalidTrack }
            return .webpageSubtitle(language: normalized, automatic: automatic)
        }
    }
}

public struct MediaTrackDescriptor: Codable, Hashable, Sendable {
    public let kind: MediaTrackKind
    public let language: String
    public let title: String
    public let codec: String
    public let channels: Int?
    public let channelLayout: String?
    public let source: MediaTrackSource
    public let forced: Bool?
    public let hearingImpaired: Bool?
    public let isDefault: Bool?

    public init(kind: MediaTrackKind, language: String = "", title: String = "", codec: String = "",
                channels: Int? = nil, channelLayout: String? = nil, source: MediaTrackSource = .embedded,
                forced: Bool? = nil, hearingImpaired: Bool? = nil, isDefault: Bool? = nil) throws {
        self.kind = kind; self.language = try Self.language(language)
        self.title = try Self.text(title, limit: 1024)
        self.codec = try Self.text(codec, limit: 128).lowercased()
        guard channels.map({ (1...32).contains($0) }) ?? true else { throw MediaPreferenceError.invalidTrack }
        self.channels = channels
        self.channelLayout = try channelLayout.map { try Self.text($0, limit: 128).lowercased() }
        self.source = try source.validated()
        if case .webpageSubtitle = self.source, kind != .subtitle { throw MediaPreferenceError.invalidTrack }
        self.forced = forced; self.hearingImpaired = hearingImpaired; self.isDefault = isDefault
    }
    static func text(_ input: String, limit: Int) throws -> String {
        guard input.utf8.count <= limit, !MediaIdentity.hasControls(input) else { throw MediaPreferenceError.invalidTrack }
        return input.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func language(_ input: String) throws -> String {
        let value = try text(input, limit: 64).lowercased().replacingOccurrences(of: "_", with: "-")
        guard value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }) else { throw MediaPreferenceError.invalidTrack }
        let aliases = ["zho": "zh", "chi": "zh", "eng": "en", "jpn": "ja", "kor": "ko", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de", "spa": "es"]
        return aliases[value] ?? value
    }
    func sameContent(as other: Self) -> Bool {
        kind == other.kind && language == other.language && title == other.title && codec == other.codec
        && channels == other.channels && channelLayout == other.channelLayout && source == other.source
    }
    /// mpv may infer a language from a raw local filename but omit it when the
    /// identical file is later preloaded through a file URL. Only absent observed
    /// language may relax; known differing languages and other sources stay strict.
    func sameLocalFileWithMissingLanguage(as other: Self) -> Bool {
        guard case .localFile(let original) = source, case .localFile(let observed) = other.source,
              !language.isEmpty, other.language.isEmpty else { return false }
        return original.standardizedFileURL.path == observed.standardizedFileURL.path
            && kind == other.kind && title == other.title && codec == other.codec
            && channels == other.channels && channelLayout == other.channelLayout
    }
    private enum CodingKeys: String, CodingKey { case kind, language, title, codec, channels, channelLayout, source, forced, hearingImpaired, isDefault }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(kind: c.decode(MediaTrackKind.self, forKey: .kind), language: c.decode(String.self, forKey: .language),
                      title: c.decode(String.self, forKey: .title), codec: c.decode(String.self, forKey: .codec),
                      channels: c.decodeIfPresent(Int.self, forKey: .channels), channelLayout: c.decodeIfPresent(String.self, forKey: .channelLayout),
                      source: c.decode(MediaTrackSource.self, forKey: .source), forced: c.decodeIfPresent(Bool.self, forKey: .forced),
                      hearingImpaired: c.decodeIfPresent(Bool.self, forKey: .hearingImpaired), isDefault: c.decodeIfPresent(Bool.self, forKey: .isDefault))
    }
}

public enum MediaTrackPreference: Codable, Hashable, Sendable {
    case automatic, disabled, match(MediaTrackDescriptor)
    func validate(kind: MediaTrackKind) throws {
        if case .match(let descriptor) = self, descriptor.kind != kind { throw MediaPreferenceError.invalidTrack }
    }
}
public struct MediaTrackCandidate: Sendable {
    public let runtimeID: Int
    public let descriptor: MediaTrackDescriptor
    public init(runtimeID: Int, descriptor: MediaTrackDescriptor) throws {
        guard runtimeID > 0 else { throw MediaPreferenceError.invalidTrack }
        self.runtimeID = runtimeID; self.descriptor = descriptor
    }
}
public enum MediaTrackMatch: Equatable, Sendable { case automatic, disabled, matched(Int), missing, ambiguous }
public enum MediaTrackMatcher {
    public static func match(_ preference: MediaTrackPreference, candidates: [MediaTrackCandidate]) -> MediaTrackMatch {
        switch preference {
        case .automatic: return .automatic
        case .disabled: return .disabled
        case .match(let wanted):
            guard candidates.count <= 2000 else { return .ambiguous }
            let matchingKind = candidates.filter { $0.descriptor.kind == wanted.kind }
            // mpv namespaces IDs by track type: audio:1 and subtitle:1 are
            // simultaneously valid. Duplicate IDs within one kind are invalid.
            guard Set(matchingKind.map(\.runtimeID)).count == matchingKind.count else { return .ambiguous }
            let exact = matchingKind.filter { $0.descriptor == wanted }
            if exact.count == 1 { return .matched(exact[0].runtimeID) }
            if exact.count > 1 { return .ambiguous }
            let fallback = matchingKind.filter { wanted.sameContent(as: $0.descriptor) }
            if fallback.count == 1 { return .matched(fallback[0].runtimeID) }
            if fallback.count > 1 { return .ambiguous }
            let local = matchingKind.filter { wanted.sameLocalFileWithMissingLanguage(as: $0.descriptor) }
            if local.count == 1 { return .matched(local[0].runtimeID) }
            return local.isEmpty ? .missing : .ambiguous
        }
    }
}

public enum MediaProjection: String, Codable, Sendable { case off, equirect, c3x2, eac }
public struct MediaGeometryPreference: Codable, Hashable, Sendable {
    public var rotation = 0
    public var aspect = "-1"
    public var zoom = 0.0
    public var panX = 0.0
    public var panY = 0.0
    public var flipHorizontal = false
    public var flipVertical = false
    public var projection = MediaProjection.off
    public var yaw = 0.0
    public var pitch = 0.0
    public var fieldOfView = 90.0
    public var cropWidth = 1.0
    public var cropHeight = 1.0
    public init() {}
    public func validated() throws -> Self {
        guard [0,90,180,270].contains(rotation), ["-1","16:9","4:3","2.35:1","1:1"].contains(aspect) else { throw MediaPreferenceError.invalidGeometry }
        let numbers: [(Double, ClosedRange<Double>)] = [(zoom,-2...4),(panX,-1...1),(panY,-1...1),(yaw,-180...180),(pitch,-90...90),(fieldOfView,30...150),(cropWidth,0.1...1),(cropHeight,0.1...1)]
        guard numbers.allSatisfy({ $0.0.isFinite && $0.1.contains($0.0) }) else { throw MediaPreferenceError.invalidGeometry }
        return self
    }
}

public struct MediaPreferenceRecord: Codable, Hashable, Sendable {
    public let identity: MediaIdentity
    public var savedAt: Date
    public var audio: MediaTrackPreference?
    public var primarySubtitle: MediaTrackPreference?
    public var secondarySubtitle: MediaTrackPreference?
    public var audioDelay: Double?
    public var subtitleDelay: Double?
    public var secondarySubtitleDelay: Double?
    public var secondarySubtitleStyle: SecondarySubtitleStyleSettings?
    public var geometry: MediaGeometryPreference?
    public var playbackProgram: PlaybackProgram?
    public init(identity: MediaIdentity, savedAt: Date = Date()) { self.identity = identity; self.savedAt = savedAt }
    public func validated() throws -> Self {
        guard savedAt.timeIntervalSince1970.isFinite else { throw MediaPreferenceError.invalidDocument }
        try audio?.validate(kind: .audio); try primarySubtitle?.validate(kind: .subtitle); try secondarySubtitle?.validate(kind: .subtitle)
        for delay in [audioDelay,subtitleDelay,secondarySubtitleDelay].compactMap({ $0 }) {
            guard delay.isFinite, (-600...600).contains(delay) else { throw MediaPreferenceError.invalidDocument }
        }
        _ = try geometry?.validated()
        _ = try secondarySubtitleStyle?.validated()
        _ = try playbackProgram?.validated()
        return self
    }
}

public struct MediaPreferenceDocument: Codable, Equatable, Sendable {
    public static let maximumEntries = 5000
    public static let maximumBytes = 8 * 1024 * 1024
    public private(set) var version = 1
    public var automaticallyRestore = true
    public private(set) var entries: [String: MediaPreferenceRecord] = [:]
    public init() {}
    public func record(for identity: MediaIdentity) -> MediaPreferenceRecord? { entries[identity.key] }
    public mutating func save(_ record: MediaPreferenceRecord) throws {
        _ = try record.validated()
        guard entries[record.identity.key] != nil || entries.count < Self.maximumEntries else { throw MediaPreferenceError.tooLarge }
        entries[record.identity.key] = record
    }
    public mutating func remove(for identity: MediaIdentity) { entries.removeValue(forKey: identity.key) }
    public func validated() throws -> Self {
        guard version == 1, entries.count <= Self.maximumEntries else { throw MediaPreferenceError.invalidDocument }
        for (key, record) in entries {
            guard key == record.identity.key else { throw MediaPreferenceError.invalidDocument }
            _ = try record.validated()
        }
        return self
    }
    public static func boundedDecode(_ data: Data) throws -> Self {
        try BoundedProfileJSON.preflight(data, maximumBytes: maximumBytes)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.isEmpty || Set(object.keys) == Set(["version","automaticallyRestore","entries"]) else { throw MediaPreferenceError.invalidDocument }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }
    public func encoded() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw MediaPreferenceError.tooLarge }
        return data
    }
    private enum CodingKeys: String, CodingKey { case version, automaticallyRestore, entries }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.allKeys.isEmpty { return }
        version = try c.decode(Int.self, forKey: .version)
        automaticallyRestore = try c.decode(Bool.self, forKey: .automaticallyRestore)
        entries = try c.decode([String: MediaPreferenceRecord].self, forKey: .entries)
        _ = try validated()
    }
}

/// Pure application-owned single document store; no runtime mpv apply/backup
/// multi-store transaction is implemented by this single-document store.
public final class MediaPreferenceStore {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public func load() throws -> MediaPreferenceDocument {
        guard fileURL.isFileURL else { throw MediaPreferenceError.invalidDocument }
        guard let data = try BoundedProfileFile.read(fileURL,maximumBytes: MediaPreferenceDocument.maximumBytes,allowMissing: true) else { return .init() }
        return try MediaPreferenceDocument.boundedDecode(data)
    }
    public func save(_ document: MediaPreferenceDocument) throws {
        guard fileURL.isFileURL else { throw MediaPreferenceError.invalidDocument }
        let data = try document.encoded()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
