import CMPV
import Darwin
import Foundation
import PlayerCore

// Reads and validates the actual native playlist IDs, paths, and active row.
struct NativeAudioPlaylistRow {
    let entryID: Int64
    let url: URL
    let current: Bool
    let playing: Bool
}

extension PlayerModel {
    func nativeAudioPlaylistReadback() -> [NativeAudioPlaylistRow]? {
        guard let handle else { return nil }
        var node = mpv_node()
        guard mpv_get_property(handle, "playlist", MPV_FORMAT_NODE, &node) >= 0 else { return nil }
        defer { mpv_free_node_contents(&node) }
        guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list?.pointee,
              list.num >= 0, list.num <= 32 else { return nil }
        if list.num == 0 { return [] }
        guard let values = list.values else { return nil }
        func text(_ pointer: UnsafePointer<CChar>?, limit: Int) -> String? {
            guard let pointer else { return nil }
            let count = strnlen(pointer, limit + 1)
            guard count <= limit else { return nil }
            return String(data: Data(bytes: pointer, count: count), encoding: .utf8)
        }
        var result: [NativeAudioPlaylistRow] = []
        for index in 0..<Int(list.num) {
            let node = values[index]
            guard node.format == MPV_FORMAT_NODE_MAP, let row = node.u.list?.pointee,
                  row.num >= 0, row.num <= 32, let keys = row.keys, let fields = row.values else { return nil }
            var seen = Set<String>()
            var id: Int64?
            var filename: String?
            var current = false
            var playing = false
            for field in 0..<Int(row.num) {
                guard let key = text(keys[field], limit: 64), seen.insert(key).inserted else { return nil }
                let value = fields[field]
                switch key {
                case "id":
                    guard value.format == MPV_FORMAT_INT64, value.u.int64 >= 0 else { return nil }
                    id = value.u.int64
                case "filename":
                    guard value.format == MPV_FORMAT_STRING else { return nil }
                    filename = text(value.u.string.map { UnsafePointer($0) }, limit: 8192)
                case "current", "playing":
                    guard value.format == MPV_FORMAT_FLAG else { return nil }
                    if key == "current" { current = value.u.flag != 0 }
                    else { playing = value.u.flag != 0 }
                default: break
                }
            }
            guard let id, let filename,
                  !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            let url: URL
            if filename.hasPrefix("/") { url = URL(fileURLWithPath: filename) }
            else if let parsed = URL(string: filename), parsed.isFileURL { url = parsed }
            else { return nil } // First phase cannot silently import redirects/web entries.
            result.append(NativeAudioPlaylistRow(entryID: id, url: MediaItem.normalized(url),
                                                 current: current, playing: playing))
        }
        guard Set(result.map(\.entryID)).count == result.count,
              result.filter(\.playing).count <= 1 else { return nil }
        return result
    }
}
