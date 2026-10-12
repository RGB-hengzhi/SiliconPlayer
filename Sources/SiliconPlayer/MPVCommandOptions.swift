import CMPV
import Darwin
import Foundation

/// Owns the storage passed to libmpv for the duration of one synchronous call.
/// A node map keeps commas, spaces and Unicode in option values out of the
/// command parser; each option's own nested list syntax is encoded separately.
private final class CommandNodeStorage {
    private var strings: [UnsafeMutablePointer<CChar>] = []
    private var arrays: [(UnsafeMutablePointer<mpv_node>, Int)] = []
    private var keys: [(UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, Int)] = []
    private var lists: [UnsafeMutablePointer<mpv_node_list>] = []

    func text(_ value: String) -> mpv_node {
        var node = mpv_node()
        node.format = MPV_FORMAT_STRING
        let pointer = strdup(value)!
        strings.append(pointer)
        node.u.string = pointer
        return node
    }

    func integer(_ value: Int64) -> mpv_node {
        var node = mpv_node()
        node.format = MPV_FORMAT_INT64
        node.u.int64 = value
        return node
    }

    func array(_ values: [mpv_node]) -> mpv_node {
        list(values, names: nil)
    }

    func map(_ values: [String: String]) -> mpv_node {
        let names = values.keys.sorted()
        return list(names.map { text(values[$0]!) }, names: names)
    }

    private func list(_ values: [mpv_node], names: [String]?) -> mpv_node {
        let valuePointer = UnsafeMutablePointer<mpv_node>.allocate(capacity: max(1, values.count))
        valuePointer.initialize(from: values, count: values.count)
        arrays.append((valuePointer, values.count))
        var keyPointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        if let names {
            let allocated = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: max(1, names.count))
            let namePointers = names.map { value -> UnsafeMutablePointer<CChar>? in
                let pointer = strdup(value)!
                strings.append(pointer)
                return pointer
            }
            allocated.initialize(from: namePointers, count: namePointers.count)
            keys.append((allocated, namePointers.count))
            keyPointer = allocated
        }
        let pointer = UnsafeMutablePointer<mpv_node_list>.allocate(capacity: 1)
        pointer.initialize(to: mpv_node_list(num: Int32(values.count), values: valuePointer, keys: keyPointer))
        lists.append(pointer)
        var node = mpv_node()
        node.format = names == nil ? MPV_FORMAT_NODE_ARRAY : MPV_FORMAT_NODE_MAP
        node.u.list = pointer
        return node
    }

    deinit {
        for (pointer, count) in arrays { pointer.deinitialize(count: count); pointer.deallocate() }
        for (pointer, count) in keys { pointer.deinitialize(count: count); pointer.deallocate() }
        for pointer in lists { pointer.deinitialize(count: 1); pointer.deallocate() }
        for pointer in strings { free(pointer) }
    }
}

extension PlayerModel {
    /// The public node parser in mpv 0.41 cannot construct its internal command
    /// list. Quoted, raw synchronous commands share one core-locked invocation.
    /// A list's return code does not aggregate failures of its children.
    static func mpvSynchronousCommandString(_ commands: [[String]]) -> String? {
        guard !commands.isEmpty, commands.count <= 64 else { return nil }
        func quote(_ value: String) -> String? {
            guard value.utf8.count <= 1_048_576 else { return nil }
            var output = "\""
            for scalar in value.unicodeScalars {
                switch scalar.value {
                case 0: return nil
                case 9: output += "\\t"
                case 10: output += "\\n"
                case 13: output += "\\r"
                case 34: output += "\\\""
                case 92: output += "\\\\"
                case 1...31, 127: return nil
                default: output.unicodeScalars.append(scalar)
                }
            }
            return output + "\""
        }
        var encoded: [String] = []
        for command in commands {
            guard !command.isEmpty, command.count <= 64 else { return nil }
            var arguments: [String] = []
            for value in command {
                guard let argument = quote(value) else { return nil }
                arguments.append(argument)
            }
            encoded.append("raw no-osd sync " + arguments.joined(separator: " "))
        }
        let result = encoded.joined(separator: "; ")
        return result.utf8.count <= 2_097_152 ? result : nil
    }

    /// Verifies every configured property after the list, then attempts to
    /// restore the original configuration when a requested value did not take
    /// effect. A rejected setter with an already-equal value is not detectable
    /// from final-value readback. This validates
    /// configuration acceptance; decoder availability and frames are separate.
    /// It does not roll back arbitrary derived playback state or wait for seek
    /// completion. Production video transitions use only hwdec and vf.
    func executeCheckedPropertyBatch(_ assignments: [(name: String, value: String)], refreshVideo: Bool = false) -> Int32 {
        guard let handle else { return MPV_ERROR_UNINITIALIZED.rawValue }
        guard !assignments.isEmpty, assignments.count <= 64,
              Set(assignments.map(\.name)).count == assignments.count else {
            return MPV_ERROR_INVALID_PARAMETER.rawValue
        }
        var commands = assignments.map { ["set", $0.name, $0.value] }
        if refreshVideo { commands.append(["seek", "0", "relative+exact"]) }
        guard let encoded = Self.mpvSynchronousCommandString(commands) else {
            return MPV_ERROR_INVALID_PARAMETER.rawValue
        }
        func property(_ name: String) -> String? {
            guard let pointer = mpv_get_property_string(handle, name) else { return nil }
            defer { mpv_free(pointer) }
            return String(cString: pointer)
        }
        func matches(_ name: String, _ expected: String) -> Bool {
            guard name == "vf", expected.isEmpty || (expected.hasPrefix("lavfi=[") && expected.hasSuffix("]")) else {
                return property(name) == expected
            }
            var node = mpv_node()
            guard mpv_get_property(handle, name, MPV_FORMAT_NODE, &node) >= 0 else { return false }
            defer { mpv_free_node_contents(&node) }
            guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list?.pointee else { return false }
            if expected.isEmpty { return list.num == 0 }
            guard list.num == 1, let row = list.values?.pointee,
                  row.format == MPV_FORMAT_NODE_MAP, let rowList = row.u.list?.pointee,
                  let keys = rowList.keys, let values = rowList.values else { return false }
            var filterName: String?
            var graph: String?
            var enabled = true
            for index in 0..<Int(rowList.num) {
                guard let key = keys[index] else { continue }
                let field = String(cString: key), value = values[index]
                if field == "name", value.format == MPV_FORMAT_STRING, let text = value.u.string {
                    filterName = String(cString: text)
                } else if field == "enabled", value.format == MPV_FORMAT_FLAG {
                    enabled = value.u.flag != 0
                } else if field == "params", value.format == MPV_FORMAT_NODE_MAP,
                          let params = value.u.list?.pointee, let paramKeys = params.keys, let paramValues = params.values {
                    for parameter in 0..<Int(params.num) {
                        if let paramKey = paramKeys[parameter], String(cString: paramKey) == "graph",
                           paramValues[parameter].format == MPV_FORMAT_STRING, let text = paramValues[parameter].u.string {
                            graph = String(cString: text)
                        }
                    }
                }
            }
            return enabled && filterName == "lavfi" && graph == String(expected.dropFirst(7).dropLast())
        }
        var originals: [(name: String, value: String)] = []
        for assignment in assignments {
            guard let value = property(assignment.name), value.utf8.count <= 1_048_576 else {
                return MPV_ERROR_PROPERTY_UNAVAILABLE.rawValue
            }
            originals.append((assignment.name, value))
        }
        // Command-list status cannot certify its individual refresh seek.
        // Retire recognition before this internal discontinuity is submitted.
        if refreshVideo { liveASR.invalidate(reason: .discontinuity) }
        let status = mpv_command_string(handle, encoded)
        if status >= 0, assignments.allSatisfy({ matches($0.name, $0.value) }) { return status }

        // Keep rollback in one command list too. A negative result is retained
        // even if restoration succeeds; it cannot masquerade as acceptance.
        var restore = originals.map { ["set", $0.name, $0.value] }
        if refreshVideo { restore.append(["seek", "0", "relative+exact"]) }
        if let rollback = Self.mpvSynchronousCommandString(restore) {
            _ = mpv_command_string(handle, rollback)
        }
        return status < 0 ? status : MPV_ERROR_PROPERTY_ERROR.rawValue
    }

    func executeLoadfile(_ url: String, options: [String: String]) -> Int32 {
        guard let handle else { return MPV_ERROR_UNINITIALIZED.rawValue }
        guard !url.contains("\u{0000}"), options.count <= 128,
              options.allSatisfy({ !$0.key.contains("\u{0000}") && !$0.value.contains("\u{0000}") }) else {
            return MPV_ERROR_INVALID_PARAMETER.rawValue
        }
        let storage = CommandNodeStorage()
        // mpv >=0.38 uses the insertion-index argument before the option map.
        var command = storage.array([
            storage.text("loadfile"), storage.text(url), storage.text("replace"),
            storage.integer(-1), storage.map(options)
        ])
        var result = mpv_node()
        let status = mpv_command_node(handle, &command, &result)
        mpv_free_node_contents(&result)
        return status
    }

    /// mpv's key/value-list parser uses a UTF-8 byte length for percent quoting.
    /// This is needed even when the outer command is already a node map.
    static func mpvOptionList(_ values: [String: String]) -> String {
        values.keys.sorted().map { key in
            let value = values[key]!
            return "\(key)=%\(value.utf8.count)%\(value)"
        }.joined(separator: ",")
    }
}

// Synchronous native queue transport. Parent success alone
// is never a committed playlist/loop proof; the controller immediately reads
// every native ID/URL/current row and the final loop value after each call.
extension PlayerModel {
    func executeNativeAudioAppend(_ path: String, options: [String: String]) -> Int32 {
        guard let handle else { return MPV_ERROR_UNINITIALIZED.rawValue }
        guard path.hasPrefix("/"), path.utf8.count <= 8192, options.count <= 32,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              options.allSatisfy({ $0.key.utf8.count <= 128 && $0.value.utf8.count <= 8192
                && !$0.key.contains("\u{0000}") && !$0.value.contains("\u{0000}") }) else {
            return MPV_ERROR_INVALID_PARAMETER.rawValue
        }
        let storage = CommandNodeStorage()
        var command = storage.array([storage.text("loadfile"), storage.text(path), storage.text("append"),
            storage.integer(-1), storage.map(options)])
        var result = mpv_node()
        let status = mpv_command_node(handle, &command, &result)
        mpv_free_node_contents(&result)
        return status
    }
    func executeNativeAudioPlaylistClear() -> Int32 {
        guard let handle else { return MPV_ERROR_UNINITIALIZED.rawValue }
        // Disable list wrap under the same core command-list invocation before
        // dropping future rows; do not expose a single-row inf-loop interval.
        // The parent status doesn't aggregate child failures: after this call
        // the driver requires loop=no and exactly the original playing ID.
        guard let command = Self.mpvSynchronousCommandString([["set", "loop-playlist", "no"], ["playlist-clear"]]) else {
            return MPV_ERROR_INVALID_PARAMETER.rawValue
        }
        return mpv_command_string(handle, command)
    }
    func executeNativeAudioEmergencyStop() -> Int32 {
        guard let handle else { return MPV_ERROR_UNINITIALIZED.rawValue }
        let storage = CommandNodeStorage()
        var command = storage.array([storage.text("stop")])
        var result = mpv_node()
        let status = mpv_command_node(handle, &command, &result)
        mpv_free_node_contents(&result)
        return status
    }
    func executeNativeAudioLoop(_ enabled: Bool) -> Int32 {
        guard let handle else { return MPV_ERROR_UNINITIALIZED.rawValue }
        let storage = CommandNodeStorage()
        var command = storage.array([storage.text("set"), storage.text("loop-playlist"), storage.text(enabled ? "inf" : "no")])
        var result = mpv_node()
        let status = mpv_command_node(handle, &command, &result)
        mpv_free_node_contents(&result)
        return status
    }
}

// Append in MPVCommandOptions.swift to use its private CommandNodeStorage.
extension PlayerModel {
    func executeLiveASREscapeASS(_ text: String) throws -> String {
        guard let handle else { throw LiveASRFailure("播放内核不可用") }
        let storage = CommandNodeStorage()
        var command = storage.array([storage.text("escape-ass"), storage.text(text)])
        var result = mpv_node()
        let status = mpv_command_node(handle, &command, &result)
        defer { mpv_free_node_contents(&result) }
        guard status >= 0, result.format == MPV_FORMAT_STRING, let pointer = result.u.string,
              strnlen(pointer, 65_537) <= 65_536 else { throw LiveASRFailure("字幕文字转义失败") }
        return String(cString: pointer)
    }

    func executeLiveASROSD(id: Int64, text: String?, width: Int, height: Int) -> Int32 {
        guard let handle else { return MPV_ERROR_UNINITIALIZED.rawValue }
        let storage = CommandNodeStorage()
        var values = [storage.text("osd-overlay"), storage.integer(id), storage.text(text == nil ? "none" : "ass-events"), storage.text(text ?? "")]
        if text != nil {
            values += [storage.integer(Int64(width)), storage.integer(Int64(height)), storage.integer(20)]
        }
        var command = storage.array(values), result = mpv_node()
        let status = mpv_command_node(handle, &command, &result)
        mpv_free_node_contents(&result)
        return status
    }
}
