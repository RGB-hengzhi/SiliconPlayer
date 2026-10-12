import CMPV
import Foundation

/// Private observation only: no commands, saves, timers, or completion inference.
@MainActor final class PlaybackProgramNativeJournal {
    let enabled: Bool
    private let suite: String?
    private var sequence = 0
    private var byteCount = 0
    private var exhausted = false
    private static let maximumRecords = 8192
    private static let maximumBytes = 16 * 1024 * 1024
    private static let maximumRecordBytes = 32 * 1024
    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        suite = InputController.verificationSuiteName(environment: environment)
        enabled = environment["SILICONPLAYER_VERIFY_MODE"] == "native-ui-manual" && suite != nil
    }
    private func missing(_ name: String, _ format: String, _ reason: String) -> [String: Any] {
        ["property": name, "format": format, "status": NSNull(), "value": NSNull(),
         "valid": false, "unavailableReason": reason]
    }
    private func double(_ name: String, _ handle: OpaquePointer?) -> [String: Any] {
        guard let handle else { return missing(name, "DOUBLE", "no-core-handle") }
        var value = 0.0
        let status = mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value)
        let valid = status >= 0 && value.isFinite
        return ["property": name, "format": "DOUBLE", "status": status,
                "value": valid ? value as Any : NSNull(), "valid": valid,
                "nonfinite": status >= 0 && !value.isFinite]
    }
    private func integer(_ name: String, _ handle: OpaquePointer?) -> (row: [String: Any], value: Int64?) {
        guard let handle else { return (missing(name, "INT64", "no-core-handle"), nil) }
        var value: Int64 = 0
        let status = mpv_get_property(handle, name, MPV_FORMAT_INT64, &value)
        return (["property": name, "format": "INT64", "status": status,
                 "value": status >= 0 ? value as Any : NSNull(), "valid": status >= 0], status >= 0 ? value : nil)
    }
    private func flag(_ name: String, _ handle: OpaquePointer?) -> [String: Any] {
        guard let handle else { return missing(name, "FLAG", "no-core-handle") }
        var raw: Int32 = 0
        let status = mpv_get_property(handle, name, MPV_FORMAT_FLAG, &raw)
        let valid = status >= 0 && (raw == 0 || raw == 1)
        return ["property": name, "format": "FLAG", "status": status,
                "rawValue": status >= 0 ? raw as Any : NSNull(),
                "value": valid ? (raw == 1) as Any : NSNull(), "valid": valid]
    }
    private func string(_ name: String, _ handle: OpaquePointer?) -> [String: Any] {
        guard let handle else { return missing(name, "STRING", "no-core-handle") }
        var pointer: UnsafeMutablePointer<CChar>?
        let status = mpv_get_property(handle, name, MPV_FORMAT_STRING, &pointer)
        defer { if let pointer { mpv_free(pointer) } }
        var text: String?
        var withinBound = false
        if status >= 0, let pointer {
            let length = strnlen(pointer, 129)
            withinBound = length <= 128
            if withinBound { text = String(data: Data(bytes: pointer, count: length), encoding: .utf8) }
        }
        return ["property": name, "format": "STRING", "status": status,
                "value": text as Any? ?? NSNull(), "valid": status >= 0 && text != nil,
                "within128ByteBound": withinBound]
    }
    func record(event: String, details: [String: Any], handle: OpaquePointer?, identity: [String: Any]) {
        guard enabled, !exhausted else { return }
        // Each GET has its own result. This ordered read batch is not atomic.
        let started = ProcessInfo.processInfo.systemUptime
        let playlistIndex = integer("playlist-pos", handle)
        let entry: [String: Any]
        if let index = playlistIndex.value, index >= 0 {
            entry = integer("playlist/\(index)/id", handle).row
        } else { entry = missing("playlist/<actual-index>/id", "INT64", "no-valid-native-playlist-index") }
        let native: [String: Any] = ["positionSeconds": double("time-pos", handle),
            "durationSeconds": double("duration", handle), "speed": double("speed", handle),
            "configuredA": string("ab-loop-a", handle), "configuredB": string("ab-loop-b", handle),
            "configuredCount": string("ab-loop-count", handle),
            "remainingABLoops": integer("remaining-ab-loops", handle).row,
            "paused": flag("pause", handle), "seeking": flag("seeking", handle),
            "seekable": flag("seekable", handle), "eof": flag("eof-reached", handle),
            "playlistIndex": playlistIndex.row, "playlistEntryID": entry]
        let finished = ProcessInfo.processInfo.systemUptime
        guard started.isFinite, finished.isFinite, finished >= started else {
            stop(reason: "invalid-host-monotonic-time"); return
        }
        let row: [String: Any] = ["schemaVersion": 1, "sequence": sequence + 1,
            "event": event, "verificationSuite": suite as Any? ?? NSNull(),
            "readStartedHostUptime": started, "readFinishedHostUptime": finished,
            "snapshotAtomic": false, "identity": identity, "native": native, "controllerState": details]
        guard JSONSerialization.isValidJSONObject(row),
              let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              data.count <= Self.maximumRecordBytes,
              let text = String(data: data, encoding: .utf8) else {
            stop(reason: "record-invalid-or-over-32KiB"); return
        }
        guard sequence < Self.maximumRecords, byteCount + data.count <= Self.maximumBytes else {
            stop(reason: "8192-record-or-16MiB-budget"); return
        }
        sequence += 1; byteCount += data.count
        NSLog("PLAYBACK_PROGRAM_NATIVE_JOURNAL %@", text)
    }
    private func stop(reason: String) {
        guard !exhausted else { return }; exhausted = true
        let row: [String: Any] = ["schemaVersion": 1, "event": "journal-stopped",
            "reason": reason, "recordsEmitted": sequence, "bytesEmitted": byteCount,
            "traceComplete": false]
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { NSLog("PLAYBACK_PROGRAM_NATIVE_JOURNAL %@", text) }
    }
}
