import Foundation

public enum MediaPreferenceError: Error, Equatable {
    case invalidIdentity, invalidTrack, invalidGeometry, invalidDocument, tooLarge, invalidBackup, invalidShortcut
}

/// Foundation remains the actual JSON decoder. Structural preflight rejects
/// coalesced duplicate keys and bounds nesting before Codable allocates objects.
enum BoundedProfileJSON {
    static func preflight(_ data: Data, maximumBytes: Int) throws {
        guard !data.isEmpty, data.count <= maximumBytes else { throw MediaPreferenceError.tooLarge }
        var scanner = Scanner(bytes: Array(data))
        try scanner.value(depth: 0)
        scanner.space()
        guard scanner.offset == scanner.bytes.count else { throw MediaPreferenceError.invalidDocument }
        _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    static func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }
    private struct Scanner {
        let bytes: [UInt8]
        var offset = 0
        mutating func space() { while offset < bytes.count, [UInt8(32), 9, 10, 13].contains(bytes[offset]) { offset += 1 } }
        mutating func take(_ expected: UInt8) throws {
            space()
            guard offset < bytes.count, bytes[offset] == expected else { throw MediaPreferenceError.invalidDocument }
            offset += 1
        }
        mutating func text() throws -> String {
            space(); let start = offset
            try take(34)
            var escape = false
            while offset < bytes.count {
                let byte = bytes[offset]; offset += 1
                if escape { escape = false }
                else if byte == 92 { escape = true }
                else if byte == 34 {
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
                }
            }
            throw MediaPreferenceError.invalidDocument
        }
        mutating func value(depth: Int) throws {
            space()
            guard depth <= 32, offset < bytes.count else { throw MediaPreferenceError.invalidDocument }
            switch bytes[offset] {
            case 123:
                offset += 1; space()
                if offset < bytes.count, bytes[offset] == 125 { offset += 1; return }
                var keys = Set<String>()
                while true {
                    guard keys.insert(try text()).inserted else { throw MediaPreferenceError.invalidDocument }
                    try take(58); try value(depth: depth + 1); space()
                    guard offset < bytes.count else { throw MediaPreferenceError.invalidDocument }
                    if bytes[offset] == 125 { offset += 1; return }
                    try take(44)
                }
            case 91:
                offset += 1; space()
                if offset < bytes.count, bytes[offset] == 93 { offset += 1; return }
                while true {
                    try value(depth: depth + 1); space()
                    guard offset < bytes.count else { throw MediaPreferenceError.invalidDocument }
                    if bytes[offset] == 93 { offset += 1; return }
                    try take(44)
                }
            case 34: _ = try text()
            default:
                let start = offset
                while offset < bytes.count, ![UInt8(32), 9, 10, 13, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
                guard offset > start else { throw MediaPreferenceError.invalidDocument }
            }
        }
    }
}
