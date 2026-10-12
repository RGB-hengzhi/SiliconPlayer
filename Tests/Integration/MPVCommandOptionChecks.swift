import CMPV
import Foundation

// Exercise the production command adapter with a real libmpv handle. No window
// or native automation is used by this lower-level regression.
// Typed call spy only. This adapter suite does not certify ASR execution.
@MainActor
final class RecognitionInvalidationSpy {
    private(set) var reasons: [LiveASRInvalidation] = []
    func invalidate(reason: LiveASRInvalidation) { reasons.append(reason) }
}

@MainActor
final class PlayerModel {
    let handle: OpaquePointer?
    let liveASR = RecognitionInvalidationSpy()
    init(handle: OpaquePointer) { self.handle = handle }
}

enum CheckFailure: Error { case failed(String) }

@main
struct MPVCommandOptionChecks {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2,
              let handle = mpv_create() else { throw CheckFailure.failed("fixture/handle missing") }
        defer { mpv_terminate_destroy(handle) }
        for (name, value) in ["config": "no", "load-scripts": "no", "vo": "null", "ao": "null", "pause": "yes"] {
            try require(mpv_set_option_string(handle, name, value) >= 0, "option \(name)")
        }
        try require(mpv_initialize(handle) >= 0, "initialize")
        let player = PlayerModel(handle: handle)
        let path = CommandLine.arguments[1]

        func property(_ name: String) -> String {
            guard let pointer = mpv_get_property_string(handle, name) else { return "" }
            defer { mpv_free(pointer) }
            return String(cString: pointer)
        }
        func waitForLoad() throws {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                guard let event = mpv_wait_event(handle, 0.05) else { continue }
                if event.pointee.event_id == MPV_EVENT_FILE_LOADED { return }
                if event.pointee.event_id == MPV_EVENT_END_FILE,
                   let data = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self),
                   data.pointee.error < 0 { throw CheckFailure.failed("load error \(data.pointee.error)") }
            }
            throw CheckFailure.failed("file load timeout")
        }
        func mapProperty(_ name: String) throws -> [String: String] {
            var node = mpv_node()
            try require(mpv_get_property(handle, name, MPV_FORMAT_NODE, &node) >= 0, "read map \(name)")
            defer { mpv_free_node_contents(&node) }
            try require(node.format == MPV_FORMAT_NODE_MAP, "map type")
            guard let list = node.u.list?.pointee, let keys = list.keys, let values = list.values else { return [:] }
            var result: [String: String] = [:]
            for i in 0..<Int(list.num) {
                guard let key = keys[i], values[i].format == MPV_FORMAT_STRING, let value = values[i].u.string else { continue }
                result[String(cString: key)] = String(cString: value)
            }
            return result
        }

        let title = "中文 标题, = %值；不执行"
        try require(player.executeLoadfile(path, options: ["ytdl": "no", "pause": "yes", "force-media-title": title]) >= 0, "structured load")
        try waitForLoad()
        try require(property("media-title") == title && property("pause") == "yes", "punctuation/Unicode preserved")
        let batchTitle = "中文 😀, = %； ' \" \\ ; set pause no # ${pause} $> ${=media-title}\n换行\r回车\t制表"
        let originalDecoder = property("hwdec")
        try require(player.executeCheckedPropertyBatch([("force-media-title", batchTitle), ("pause", "yes")]) >= 0, "raw synchronous quoted batch")
        try require(property("force-media-title") == batchTitle && property("media-title") == batchTitle,
                    "batch quote round-trip including raw property syntax")
        try require(property("pause") == "yes" && property("hwdec") == originalDecoder,
                    "semicolons/comments/property expansion cannot inject commands")
        print("PASS structured load preserves Unicode and option punctuation")

        let nested = ["js-runtimes": "deno:/测试 目录/含,= %值/deno", "sub-langs": "zh.*,en", "socket-timeout": "15", "ignore-config": "", "no-cache-dir": ""]
        try require(player.executeLoadfile(path, options: ["ytdl": "no", "pause": "yes", "ytdl-raw-options": PlayerModel.mpvOptionList(nested)]) >= 0, "nested load")
        try waitForLoad()
        try require(try mapProperty("ytdl-raw-options") == nested, "nested byte-length quoting")
        print("PASS nested option list round-trips Unicode/comma/equal/percent values")

        try require(player.executeLoadfile(path, options: ["ytdl": "no", "pause": "yes"]) >= 0, "ordinary load")
        try waitForLoad()
        try require(property("media-title") != title && (try mapProperty("ytdl-raw-options")).isEmpty, "file-local options restored")
        try require(player.executeCheckedPropertyBatch([("hwdec", "no"), ("vf", "lavfi=[hflip]")], refreshVideo: true) >= 0,
                    "video batch accepts exact configured graph and decoder")
        try require(property("pause") == "yes" && property("hwdec") == "no", "refresh does not unpause")
        try require(player.liveASR.reasons == [.discontinuity], "video refresh retires recognition before internal seek")
        let configuredVF = property("vf")
        try require(player.executeCheckedPropertyBatch([("vf", "lavfi=[hflip,vflip]"), ("pause", "not-a-boolean")]) < 0,
                    "nonempty graph rollback detects child failure")
        try require(property("vf") == configuredVF && property("pause") == "yes",
                    "canonical nonempty vf snapshot can be restored")
        try require(player.executeCheckedPropertyBatch([("vf", ""), ("hwdec", originalDecoder)]) >= 0,
                    "empty vf is verified from the actual node list")
        print("PASS file-local title and extractor options do not leak into ordinary media")

        let before = property("media-title")
        try require(player.executeLoadfile(path + "\u{0000}ignored", options: [:]) == MPV_ERROR_INVALID_PARAMETER.rawValue, "NUL URL rejected")
        try require(player.executeLoadfile(path, options: ["force-media-title": "bad\u{0000}title"]) == MPV_ERROR_INVALID_PARAMETER.rawValue, "NUL value rejected")
        try require(property("media-title") == before, "rejected input leaves current media")
        try require(player.executeCheckedPropertyBatch([("force-media-title", "bad\u{0000}batch")]) == MPV_ERROR_INVALID_PARAMETER.rawValue,
                    "batch NUL rejected before mutation")
        try require(PlayerModel.mpvSynchronousCommandString([["set", "pause", "bad\u{0001}"]]) == nil,
                    "unsupported internal control rejected")
        let oldVF = property("vf"), oldMute = property("mute"), oldPath = property("path")
        // mpv's parent list reports success even when a set child fails. The
        // production adapter must detect that failure and undo earlier writes.
        try require(player.executeCheckedPropertyBatch([("vf", "lavfi=[hflip]"), ("pause", "not-a-boolean")]) < 0,
                    "child setting failure is not hidden by successful list")
        try require(property("vf") == oldVF && property("pause") == "yes", "earlier valid child rolled back")
        try require(player.executeCheckedPropertyBatch([("pause", "not-a-boolean"), ("mute", "yes")]) < 0,
                    "a later successful child cannot hide earlier failure")
        try require(property("mute") == oldMute && property("path") == oldPath,
                    "later configured child rolled back without replacing source")
        print("PASS NUL input is rejected before libmpv without replacing current media")
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure.failed(message) }
    }
}
