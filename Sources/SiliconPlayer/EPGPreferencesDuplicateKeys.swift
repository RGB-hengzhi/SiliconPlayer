import Foundation

/// JSONDecoder/JSONSerialization silently collapse duplicate object keys.
/// This bounded preflight compares decoded keys (including escaped spellings)
/// before decoding the small, versioned preference schema. Arrays are not part
/// of that schema; depth/string/node bounds reject unsupported payloads early.
enum EPGPreferencesDuplicateKeys {
    static func validate(_ data: Data) throws {
        guard data.count <= EPGPreferences.maximumBytes else { throw EPGPreferencesError.tooLarge }
        var scanner = Scanner(bytes: Array(data))
        try scanner.value(depth: 0)
        scanner.whitespace()
        guard scanner.index == scanner.bytes.count else { throw EPGPreferencesError.invalidDocument }
    }
    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        var nodes = 0
        mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func require(_ byte: UInt8) throws {
            whitespace()
            guard index < bytes.count, bytes[index] == byte else { throw EPGPreferencesError.invalidDocument }
            index += 1
        }
        mutating func value(depth: Int) throws {
            whitespace(); nodes += 1
            guard depth <= 3, nodes <= 10_000, index < bytes.count else { throw EPGPreferencesError.invalidDocument }
            switch bytes[index] {
            case 123: try object(depth: depth)
            case 34: _ = try string()
            case 116: try literal(Array("true".utf8))
            case 102: try literal(Array("false".utf8))
            case 110: try literal(Array("null".utf8))
            case 45, 48...57: try number()
            default: throw EPGPreferencesError.invalidDocument
            }
        }
        mutating func object(depth: Int) throws {
            try require(123); whitespace()
            if index < bytes.count, bytes[index] == 125 { index += 1; return }
            var keys = Set<String>()
            while true {
                let key = try string()
                guard keys.insert(key).inserted, keys.count <= EPGPreferences.maximumMappings + 4 else { throw EPGPreferencesError.invalidDocument }
                try require(58); try value(depth: depth + 1); whitespace()
                guard index < bytes.count else { throw EPGPreferencesError.invalidDocument }
                if bytes[index] == 125 { index += 1; return }
                try require(44)
            }
        }
        mutating func string() throws -> String {
            whitespace(); let start = index; try require(34)
            while index < bytes.count {
                guard index - start <= 65_536 else { throw EPGPreferencesError.tooLarge }
                if bytes[index] == 34 {
                    index += 1
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                    catch { throw EPGPreferencesError.invalidDocument }
                }
                guard bytes[index] >= 32 else { throw EPGPreferencesError.invalidDocument }
                if bytes[index] == 92 {
                    index += 2
                    guard index <= bytes.count else { throw EPGPreferencesError.invalidDocument }
                } else { index += 1 }
            }
            throw EPGPreferencesError.invalidDocument
        }
        mutating func literal(_ value: [UInt8]) throws {
            guard index + value.count <= bytes.count, Array(bytes[index..<(index + value.count)]) == value else { throw EPGPreferencesError.invalidDocument }
            index += value.count
        }
        mutating func number() throws {
            let start = index
            while index < bytes.count, [43, 45, 46, 69, 101].contains(bytes[index]) || (48...57).contains(bytes[index]) {
                index += 1
                guard index - start <= 32 else { throw EPGPreferencesError.invalidDocument }
            }
            do { _ = try JSONDecoder().decode(Double.self, from: Data(bytes[start..<index])) }
            catch { throw EPGPreferencesError.invalidDocument }
        }
    }
}
