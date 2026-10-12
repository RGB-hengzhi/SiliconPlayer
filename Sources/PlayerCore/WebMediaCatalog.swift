import Foundation

/// Remembers preferences by original web page so URL-only history/library
/// entries can reopen a previously parsed page without persisting CDN inputs.
public struct WebMediaCatalog: Codable, Sendable {
    public static let maximumBytes = 16 * 1024 * 1024
    public static let maximumEntries = 5000
    public private(set) var entries: [String: WebMediaSelection] = [:]

    public init() {}

    public mutating func remember(pageURL: URL, selection: WebMediaSelection) throws {
        let key = try WebMediaDocument.validatedPageURL(pageURL).absoluteString
        guard entries[key] != nil || entries.count < Self.maximumEntries else { throw WebMediaError.invalidQueue }
        entries[key] = selection
    }

    public func selection(for pageURL: URL) -> WebMediaSelection? {
        guard let pageURL = try? WebMediaDocument.validatedPageURL(pageURL) else { return nil }
        return entries[pageURL.absoluteString]
    }

    /// JSONDecoder alone coalesces duplicate object keys. This bounded entry
    /// point rejects ambiguous JSON before decoding the persistent preferences.
    public static func boundedDecode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw WebMediaError.tooLarge }
        var keys = JSONUniqueKeys(data: data)
        try keys.check()
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey { case entries }
    private struct EntryKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.entries) else { return }
        let stored = try values.nestedContainer(keyedBy: EntryKey.self, forKey: .entries)
        guard stored.allKeys.count <= Self.maximumEntries else { throw WebMediaError.invalidQueue }
        var decoded: [String: WebMediaSelection] = [:], pages = Set<URL>()
        for key in stored.allKeys {
            let pageURL = try WebMediaDocument.validatedPageURL(key.stringValue)
            guard key.stringValue == pageURL.absoluteString, pages.insert(pageURL).inserted else { throw WebMediaError.invalidQueue }
            decoded[pageURL.absoluteString] = try stored.decode(WebMediaSelection.self, forKey: key)
        }
        entries = decoded
    }
}

/// Structural preflight only; Foundation remains the actual JSON/Codable
/// decoder. Limit nesting and reject repeated decoded keys in every object.
private struct JSONUniqueKeys {
    let bytes: [UInt8]
    var index = 0
    init(data: Data) { bytes = Array(data) }
    mutating func check() throws {
        try value(depth: 0); whitespace()
        guard index == bytes.count else { throw WebMediaError.invalidQueue }
    }
    mutating func whitespace() { while index < bytes.count, [UInt8(32), 9, 10, 13].contains(bytes[index]) { index += 1 } }
    mutating func consume(_ byte: UInt8) throws {
        whitespace()
        guard index < bytes.count, bytes[index] == byte else { throw WebMediaError.invalidQueue }
        index += 1
    }
    mutating func string() throws -> String {
        whitespace(); let start = index
        try consume(34)
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if escaped { escaped = false }
            else if byte == 92 { escaped = true }
            else if byte == 34 {
                guard let text = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else { throw WebMediaError.invalidQueue }
                return text
            }
        }
        throw WebMediaError.invalidQueue
    }
    mutating func value(depth: Int) throws {
        whitespace()
        guard depth <= 128, index < bytes.count else { throw WebMediaError.invalidQueue }
        switch bytes[index] {
        case 123:
            index += 1; whitespace()
            if index < bytes.count, bytes[index] == 125 { index += 1; return }
            var keys = Set<String>()
            while true {
                let key = try string()
                guard keys.insert(key).inserted else { throw WebMediaError.invalidQueue }
                try consume(58); try value(depth: depth + 1); whitespace()
                guard index < bytes.count else { throw WebMediaError.invalidQueue }
                if bytes[index] == 125 { index += 1; return }
                try consume(44)
            }
        case 91:
            index += 1; whitespace()
            if index < bytes.count, bytes[index] == 93 { index += 1; return }
            while true {
                try value(depth: depth + 1); whitespace()
                guard index < bytes.count else { throw WebMediaError.invalidQueue }
                if bytes[index] == 93 { index += 1; return }
                try consume(44)
            }
        case 34: _ = try string()
        default:
            let start = index
            while index < bytes.count, ![UInt8(32), 9, 10, 13, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard start < index else { throw WebMediaError.invalidQueue }
        }
    }
}
