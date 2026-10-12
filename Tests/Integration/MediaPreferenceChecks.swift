import Foundation
import PlayerCore
import Darwin

private struct CheckFailure: Error { let message: String }
private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw CheckFailure(message: message) }
}
private func rejected(_ action: () throws -> Void, _ message: String) throws {
    do { try action() } catch { return }
    throw CheckFailure(message: message)
}
private func identity(_ text: String) throws -> MediaIdentity { try .init(originalURL: URL(string: text)!) }
private func mutatedJSON(_ data: Data, _ edit: (inout [String: Any]) -> Void) throws -> Data {
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    edit(&object)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
private func validator(_ action: String, _ key: String) throws -> String {
    // Host injection contract only; this is not AppKit InputController coverage.
    guard ["togglePause","stop","screenshot"].contains(action), ["space","v","option+s",""].contains(key) else { throw MediaPreferenceError.invalidShortcut }
    return key
}
private func sampleBackup() throws -> UserProfileBackupDocument {
    var settings = PlaybackSettings(); settings.subtitleFont = "Heiti SC"; settings.processing.projection = "equirect"
    var media = MediaPreferenceDocument()
    var item = MediaPreferenceRecord(identity: try identity("https://example.test/watch?v=中文&lang=zh"), savedAt: Date(timeIntervalSince1970: 1000))
    item.audio = .match(try MediaTrackDescriptor(kind: .audio, language: "chi", title: "原声", codec: "aac", channels: 2))
    item.primarySubtitle = .disabled; item.audioDelay = 0.25
    var geometry = MediaGeometryPreference(); geometry.projection = .equirect; geometry.yaw = 45
    item.geometry = geometry; try media.save(item)
    var web = WebMediaCatalog()
    try web.remember(pageURL: item.identity.originalURL, selection: WebMediaSelection(title: "中文网页", formatID: "18"))
    return .init(global: settings, shortcuts: [.init(action: "togglePause",key: "space"),.init(action: "stop",key: "v")],
                 filters: .init(filters: [.init(kind: .horizontalFlip)]), media: media, web: web,
                 appVersion: "0.5.0-prototype", createdAt: Date(timeIntervalSince1970: 1000))
}
@MainActor private final class SuiteShortcuts: ProfileShortcutStorage {
    let defaults: UserDefaults
    let suiteName: String
    var failNext = false
    init() {
        suiteName = "SiliconPlayer.MediaPrototype." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
    }
    func read() throws -> Data? { defaults.data(forKey: "prototype.shortcuts") }
    func write(_ data: Data?) throws {
        if failNext { failNext = false; throw CheckFailure(message: "injected shortcut write failure") }
        if let data { defaults.set(data, forKey: "prototype.shortcuts") }
        else { defaults.removeObject(forKey: "prototype.shortcuts") }
    }
    func clean() { defaults.removePersistentDomain(forName: suiteName) }
}
private final class FailingPublication: ProfilePublication {
    let directory: URL
    let failName: String
    var failuresLeft: Int
    private let atomic = AtomicProfilePublication()
    init(directory: URL, failName: String, failures: Int) { self.directory = directory; self.failName = failName; failuresLeft = failures }
    func publish(_ data: Data, to target: URL) throws {
        if target.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path && target.lastPathComponent == failName && failuresLeft > 0 {
            failuresLeft -= 1; throw CheckFailure(message: "injected publication failure")
        }
        try atomic.publish(data, to: target)
    }
    func remove(_ target: URL) throws { try atomic.remove(target) }
}
private final class FailingRemoval: ProfilePublication {
    var failures = 1
    let atomic = AtomicProfilePublication()
    func publish(_ data: Data,to target: URL) throws { try atomic.publish(data,to: target) }
    func remove(_ target: URL) throws {
        if target.lastPathComponent == "profile-import-journal.json", failures > 0 {
            failures -= 1; throw CheckFailure(message: "injected journal cleanup failure")
        }
        try atomic.remove(target)
    }
}
@MainActor private func prepareOld(_ directory: URL, _ shortcuts: SuiteShortcuts) throws -> [String: Data] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let files = ["preferences.json":Data("old-global".utf8), "user-video-filters.json":Data("old-filters".utf8),
                 "media-preferences.json":Data("old-media".utf8), "web-media-preferences.json":Data("old-web".utf8)]
    for (name,data) in files { try data.write(to: directory.appendingPathComponent(name)) }
    try shortcuts.write(Data("old-shortcuts".utf8)); return files
}
@MainActor private func expectOld(_ files: [String: Data], _ directory: URL, _ shortcuts: SuiteShortcuts) throws {
    for (name,data) in files { try expect(Data(contentsOf: directory.appendingPathComponent(name)) == data, "old file changed: " + name) }
    try expect(shortcuts.read() == Data("old-shortcuts".utf8), "old shortcut data changed")
}

@MainActor @main
struct MediaPreferenceChecks {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let work = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        var passed: [String] = [], failed: [String] = []
        func group(_ name: String, _ action: () throws -> Void) {
            do { try action(); passed.append(name); print("PASS " + name) }
            catch { failed.append(name + ": " + String(describing: error)); print("FAIL " + name + ": " + String(describing: error)) }
        }
        group("identity-local-unicode-space-and-distinct-case") {
            let a = try MediaIdentity(originalURL: URL(fileURLWithPath: "/private/tmp/中文 路径/../视频 A.mp4"))
            let b = try MediaIdentity(originalURL: URL(fileURLWithPath: "/private/tmp/视频 A.mp4"))
            try expect(a == b && a.originalURL.path == "/private/tmp/视频 A.mp4", "file canonical path differs")
            try expect(a != MediaIdentity(originalURL: URL(fileURLWithPath: "/private/tmp/视频 a.mp4")), "case merged")
        }
        group("identity-network-normalization-query-order-and-fragment") {
            try expect(identity("HTTPS://EXAMPLE.test:443/Page?v=1&lang=zh#t=3") == identity("https://example.test/Page?v=1&lang=zh#t=3"), "host/default port not normalized")
            try expect(identity("https://example.test/Page?v=1&lang=zh") != identity("https://example.test/Page?lang=zh&v=1"), "query sorted")
            try expect(identity("https://example.test/Page?v=1#t=2") != identity("https://example.test/Page?v=1#t=3"), "fragment discarded")
        }
        group("identity-rejects-credentials-encoded-queries-and-controls") {
            for text in ["https://user:pass@example.test/v", "ftp://example.test/v", "https://example.test/v?%2575ser=bob", "https://example.test/v?session=x", "https://example.test/v?X-Amz-Signature=private", "https://example.test/v?%73ecret=x", "https://example.test/%0aextra"] {
                try rejected({ _ = try identity(text) }, "unsafe URL accepted: " + text)
            }
            _ = try identity("https://example.test/v?v=1&lang=zh&date=2026-10-04")
        }
        group("track-description-reordered-runtime-ids") {
            let wanted = try MediaTrackDescriptor(kind: .audio, language: "chi", title: " 原声 ", codec: "AAC", channels: 2)
            let reopened = try MediaTrackDescriptor(kind: .audio, language: "zh", title: "原声", codec: "aac", channels: 2)
            try expect(MediaTrackMatcher.match(.match(wanted), candidates: [.init(runtimeID: 7, descriptor: reopened)]) == .matched(7), "reopened ID not matched")
            let encoded = try JSONEncoder().encode(wanted)
            try expect(!String(decoding: encoded,as: UTF8.self).contains("runtimeID"), "ephemeral ID persisted")
        }
        group("track-commentary-ambiguity-and-missing-fallback") {
            let wanted = try MediaTrackDescriptor(kind: .audio, language: "zh", title: "导演评论", codec: "aac", channels: 2)
            let other = try MediaTrackDescriptor(kind: .audio, language: "zh", title: "原声", codec: "aac", channels: 2)
            let chosen = try MediaTrackCandidate(runtimeID: 8, descriptor: wanted)
            try expect(MediaTrackMatcher.match(.match(wanted), candidates: [chosen,.init(runtimeID: 3,descriptor: other)]) == .matched(8), "wrong same-language track")
            try expect(MediaTrackMatcher.match(.match(wanted), candidates: [chosen,.init(runtimeID: 4,descriptor: wanted)]) == .ambiguous, "duplicate chose arbitrary ID")
            try expect(MediaTrackMatcher.match(.match(wanted), candidates: [.init(runtimeID: 3,descriptor: other)]) == .missing, "missing retained old ID")
        }
        group("track-auxiliary-flags-and-explicit-off") {
            let wanted = try MediaTrackDescriptor(kind: .subtitle, language: "en", title: "captions",codec: "ass",forced: false)
            let current = try MediaTrackDescriptor(kind: .subtitle, language: "eng", title: "captions",codec: "ass",forced: nil)
            try expect(MediaTrackMatcher.match(.match(wanted), candidates: [.init(runtimeID: 9,descriptor: current)]) == .matched(9), "aux flag prevented unique fallback")
            try expect(MediaTrackMatcher.match(.disabled,candidates: []) == .disabled && MediaTrackMatcher.match(.automatic,candidates: []) == .automatic, "off and auto lost")
        }
        group("track-external-original-and-manual-auto-source") {
            let url = URL(fileURLWithPath: "/private/tmp/中文字幕 test.srt")
            let local = try MediaTrackDescriptor(kind: .subtitle,source: .localFile(url))
            let manual = try MediaTrackDescriptor(kind: .subtitle,source: .webpageSubtitle(language: "zh",automatic: false))
            let automatic = try MediaTrackDescriptor(kind: .subtitle,source: .webpageSubtitle(language: "zh",automatic: true))
            try expect(local.source == .localFile(url) && manual != automatic, "subtitle source conflated")
            try rejected({ _ = try MediaTrackDescriptor(kind: .subtitle,source: .localFile(URL(string: "https://cdn.test/sub?token=x")!)) }, "CDN subtitle original persisted")
        }
        group("track-local-filename-language-missing-compatible-only") {
            for language in ["zh", "en"] {
                let file = URL(fileURLWithPath: "/tmp/同源:斜\\线，中文.\(language).srt")
                let old = try MediaTrackDescriptor(kind: .subtitle, language: language, title: "同源", codec: "subrip", source: .localFile(file), isDefault: false)
                let observed = try MediaTrackDescriptor(kind: .subtitle, title: "同源", codec: "subrip", source: .localFile(file), isDefault: true)
                try expect(MediaTrackMatcher.match(.match(old), candidates: [.init(runtimeID: 17, descriptor: observed)]) == .matched(17), "same original file lost inferred language compatibility")
            }
        }
        group("track-runtime-id-namespace-per-kind-and-total-bound") {
            let audio = try MediaTrackDescriptor(kind: .audio, language: "zh", codec: "aac")
            let subtitle = try MediaTrackDescriptor(kind: .subtitle, language: "zh", codec: "subrip")
            let rows = [try MediaTrackCandidate(runtimeID: 1, descriptor: audio), try MediaTrackCandidate(runtimeID: 1, descriptor: subtitle)]
            try expect(MediaTrackMatcher.match(.match(audio), candidates: rows) == .matched(1), "legal subtitle ID shadowed audio ID")
            try expect(MediaTrackMatcher.match(.match(subtitle), candidates: rows) == .matched(1), "legal audio ID shadowed subtitle ID")
            try expect(MediaTrackMatcher.match(.match(audio), candidates: rows + [rows[0]]) == .ambiguous, "duplicate audio ID accepted")
            try expect(MediaTrackMatcher.match(.match(subtitle), candidates: rows + [rows[1]]) == .ambiguous, "duplicate subtitle ID accepted")
            let many = (1...2001).map { try! MediaTrackCandidate(runtimeID: $0, descriptor: subtitle) }
            try expect(MediaTrackMatcher.match(.match(audio), candidates: many) == .ambiguous, "total candidate bound bypassed by kind filtering")
        }
        group("track-local-language-fallback-rejects-wrong-source-codec-and-ambiguity") {
            let file = URL(fileURLWithPath: "/tmp/同源.zh.srt")
            let wanted = try MediaTrackDescriptor(kind: .subtitle, language: "zh", title: "同源", codec: "subrip", source: .localFile(file))
            for other in [
                try MediaTrackDescriptor(kind: .subtitle, language: "en", title: "同源", codec: "subrip", source: .localFile(file)),
                try MediaTrackDescriptor(kind: .subtitle, title: "同源", codec: "ass", source: .localFile(file)),
                try MediaTrackDescriptor(kind: .subtitle, title: "同源", codec: "subrip", source: .localFile(URL(fileURLWithPath: "/tmp/other.zh.srt"))),
                try MediaTrackDescriptor(kind: .subtitle, title: "other", codec: "subrip", source: .localFile(file))] {
                try expect(MediaTrackMatcher.match(.match(wanted), candidates: [.init(runtimeID: 9, descriptor: other)]) == .missing, "local fallback ignored a known semantic mismatch")
            }
            let unknown = try MediaTrackDescriptor(kind: .subtitle, title: "同源", codec: "subrip", source: .localFile(file))
            try expect(MediaTrackMatcher.match(.match(wanted), candidates: [.init(runtimeID: 3, descriptor: unknown), .init(runtimeID: 4, descriptor: unknown)]) == .ambiguous, "multiple same-file streams arbitrarily selected")
            let embeddedWanted = try MediaTrackDescriptor(kind: .subtitle, language: "zh", title: "同源", codec: "subrip")
            let embeddedObserved = try MediaTrackDescriptor(kind: .subtitle, title: "同源", codec: "subrip")
            try expect(MediaTrackMatcher.match(.match(embeddedWanted), candidates: [.init(runtimeID: 1, descriptor: embeddedObserved)]) == .missing, "embedded track strict language changed")
        }
        group("geometry-delay-bounds-reject-nan-and-cross-kind") {
            var geometry = MediaGeometryPreference(); geometry.projection = .eac; geometry.fieldOfView = 150
            _ = try geometry.validated()
            geometry.yaw = .nan; try rejected({ _ = try geometry.validated() }, "NaN geometry accepted")
            geometry.yaw = 0; geometry.rotation = 45; try rejected({ _ = try geometry.validated() }, "bad rotation accepted")
            var record = MediaPreferenceRecord(identity: try identity("https://example.test/a")); record.audioDelay = 601
            try rejected({ _ = try record.validated() }, "bad delay accepted")
            record.audioDelay = -.infinity; try rejected({ _ = try record.validated() }, "infinite delay accepted")
            record.audioDelay = nil; record.audio = .match(try MediaTrackDescriptor(kind: .subtitle))
            try rejected({ _ = try record.validated() }, "subtitle put in audio role")
        }
        group("media-roundtrip-explicit-save-clear-and-original-page") {
            var doc = MediaPreferenceDocument()
            let identity = try identity("https://example.test/watch?v=7")
            var record = MediaPreferenceRecord(identity: identity); record.audioDelay = -0.25; record.primarySubtitle = .disabled
            try doc.save(record)
            let decoded = try MediaPreferenceDocument.boundedDecode(doc.encoded())
            try expect(decoded == doc && decoded.record(for: identity)?.primarySubtitle == .disabled, "roundtrip changed explicit off")
            try expect(!String(decoding: doc.encoded(),as: UTF8.self).contains("cdn"), "runtime media URL appeared")
            doc.remove(for: identity); try expect(doc.entries.isEmpty, "clear retained item")
        }
        group("media-upsert-and-auto-restore-no-other-media-change") {
            let a = try identity("https://example.test/a"), b = try identity("https://example.test/b")
            var doc = MediaPreferenceDocument(); var r = MediaPreferenceRecord(identity: a); r.audioDelay = 0.5; try doc.save(r)
            let before = doc.record(for: a); try doc.save(MediaPreferenceRecord(identity: b)); doc.automaticallyRestore = false
            try expect(doc.record(for: a) == before && !doc.automaticallyRestore, "other media changed")
            r.audioDelay = 0.25; try doc.save(r); try expect(doc.entries.count == 2 && doc.record(for: a)?.audioDelay == 0.25, "upsert duplicated identity")
        }
        group("media-duplicate-escaped-keys-version-and-key-identity") {
            try rejected({ _ = try MediaPreferenceDocument.boundedDecode(Data(#"{"version":1,"\u0076ersion":1,"automaticallyRestore":true,"entries":{}}"#.utf8)) }, "escaped duplicate accepted")
            let backup = try sampleBackup(); let valid = try backup.media.encoded()
            try rejected({ _ = try MediaPreferenceDocument.boundedDecode(mutatedJSON(valid) { $0["version"] = 2 }) }, "future media version accepted")
            let changed = try mutatedJSON(valid) { object in let entries = object["entries"] as! [String:Any]; object["entries"] = ["https://example.test/other":entries.values.first!] }
            try rejected({ _ = try MediaPreferenceDocument.boundedDecode(changed) }, "wrong identity key accepted")
            try rejected({ _ = try MediaPreferenceDocument.boundedDecode(Data(#"{"unknown":1}"#.utf8)) }, "unknown document treated empty")
        }
        group("media-entry-and-byte-nesting-bounds") {
            var doc = MediaPreferenceDocument()
            for n in 0..<MediaPreferenceDocument.maximumEntries { try doc.save(MediaPreferenceRecord(identity: identity("https://example.test/watch?v=\(n)"))) }
            try rejected({ try doc.save(MediaPreferenceRecord(identity: identity("https://example.test/watch?v=overflow"))) }, "entry bound not enforced")
            try rejected({ _ = try MediaPreferenceDocument.boundedDecode(Data(repeating: 32,count: MediaPreferenceDocument.maximumBytes+1)) }, "byte bound not enforced")
            let deep = String(repeating: "[",count: 34) + "0" + String(repeating: "]",count: 34)
            try rejected({ _ = try MediaPreferenceDocument.boundedDecode(Data(deep.utf8)) }, "nesting bound not enforced")
        }
        group("store-missing-old-empty-and-corrupt-preserves-bytes") {
            let file = work.appendingPathComponent("store/媒体 设置.json")
            let store = MediaPreferenceStore(fileURL: file); try expect(store.load().entries.isEmpty, "missing file not empty")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: file); try expect(store.load().entries.isEmpty, "old empty not compatible")
            let corrupt = Data("{not-json".utf8); try corrupt.write(to: file)
            try rejected({ _ = try store.load() }, "corrupt file accepted")
            try expect(Data(contentsOf: file) == corrupt, "load overwrote bad bytes")
        }
        group("store-real-atomic-roundtrip-rejected-save-preserves") {
            let file = work.appendingPathComponent("valid/store.json"), store = MediaPreferenceStore(fileURL: work.appendingPathComponent("valid/store.json"))
            let doc = try sampleBackup().media; try store.save(doc); try expect(store.load() == doc, "store roundtrip mismatch")
            let old = try Data(contentsOf: file); var invalid = MediaPreferenceRecord(identity: try identity("https://example.test/z")); invalid.subtitleDelay = .nan
            var modified = doc; try rejected({ try modified.save(invalid); try store.save(modified) }, "invalid edit accepted")
            try expect(Data(contentsOf: file) == old, "rejected edit overwrote store")
        }
        group("bounded-read-rejects-fifo-device-symlink-without-blocking") {
            let folder = work.appendingPathComponent("unsafe-files",isDirectory: true)
            try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
            let fifo = folder.appendingPathComponent("pipe.json")
            try expect(mkfifo(fifo.path,mode_t(0o600)) == 0, "fixture FIFO creation failed")
            let started = Date()
            try rejected({ _ = try BoundedProfileFile.read(fifo,maximumBytes: 1024) }, "FIFO accepted")
            try expect(Date().timeIntervalSince(started) < 1, "FIFO blocked regular-file reader")
            let regular = folder.appendingPathComponent("real.json"); let old = Data("old regular bytes".utf8); try old.write(to: regular)
            let link = folder.appendingPathComponent("link.json"); try FileManager.default.createSymbolicLink(at: link,withDestinationURL: regular)
            try rejected({ _ = try BoundedProfileFile.read(link,maximumBytes: 1024) }, "symlink accepted")
            try rejected({ _ = try BoundedProfileFile.read(URL(fileURLWithPath: "/dev/null"),maximumBytes: 1024) }, "device accepted")
            try expect(Data(contentsOf: regular) == old, "rejected read changed target")
        }
        group("backup-actual-settings-filter-chain-and-shortcuts-roundtrip") {
            let backup = try sampleBackup(); let data = try backup.encoded(shortcutValidator: validator)
            let decoded = try UserProfileBackupDocument.boundedDecode(data,shortcutValidator: validator)
            try expect(decoded.global == backup.global && decoded.filters == backup.filters && decoded.shortcuts == backup.shortcuts && decoded.media == backup.media, "backup changed typed production values")
            try expect(decoded.includes == ["global","shortcuts","filters","media","web"], "coverage list wrong")
            try expect(decoded.web?.selection(for: URL(string: "https://example.test/watch?v=中文&lang=zh")!)?.formatID == "18", "catalog preference lost")
        }
        group("backup-strict-global-malformed-and-clamped-rejection") {
            let data = try sampleBackup().encoded(shortcutValidator: validator)
            for bad in ["invalid", 900] as [Any] {
                let changed = try mutatedJSON(data) { var s = $0["global"] as! [String:Any]; s["brightness"] = bad; $0["global"] = s }
                try rejected({ _ = try UserProfileBackupDocument.boundedDecode(changed,shortcutValidator: validator) }, "tolerant production decoder hid invalid backup")
            }
            let missing = try mutatedJSON(data) { var s = $0["global"] as! [String:Any]; s.removeValue(forKey: "theme"); $0["global"] = s }
            try rejected({ _ = try UserProfileBackupDocument.boundedDecode(missing,shortcutValidator: validator) }, "missing global field became default")
        }
        group("backup-invalid-filters-shortcut-reserved-duplicate-version") {
            var backup = try sampleBackup(); backup.shortcuts = [.init(action: "stop",key: "cmd+q")]
            try rejected({ _ = try backup.encoded(shortcutValidator: validator) }, "host reserved shortcut accepted")
            backup.shortcuts = [.init(action: "stop",key: "v"),.init(action: "togglePause",key: "v")]
            try rejected({ _ = try backup.encoded(shortcutValidator: validator) }, "duplicate shortcut accepted")
            backup = try sampleBackup(); var filter = UserVideoFilter(kind: .blur); filter.values["sigma"] = 80; backup.filters = .init(filters: [filter])
            try rejected({ _ = try backup.encoded(shortcutValidator: validator) }, "invalid production filter accepted")
            let valid = try sampleBackup().encoded(shortcutValidator: validator)
            try rejected({ _ = try UserProfileBackupDocument.boundedDecode(mutatedJSON(valid){ $0["version"] = 2 },shortcutValidator: validator) }, "future backup version accepted")
            try rejected({ _ = try UserProfileBackupDocument.boundedDecode(Data(repeating: 32,count: UserProfileBackupDocument.maximumBytes+1),shortcutValidator: validator) }, "backup byte bound accepted")
        }
        group("backup-runtime-id-and-sensitive-url-exclusion") {
            var backup = try sampleBackup(); backup.global.secondarySubtitleID = 9
            try rejected({ _ = try backup.encoded(shortcutValidator: validator) }, "runtime secondary ID accepted")
            let data = try sampleBackup().encoded(shortcutValidator: validator)
            let json = String(decoding: data,as: UTF8.self)
            try expect(!json.contains("runtimeID") && !json.contains("headers") && !json.contains("cdn"), "runtime fields exported")
            try rejected({ _ = try identity("https://example.test/stream?token=private") }, "sensitive media persisted")
        }
        group("transaction-invalid-backup-zero-writes") {
            let suite = SuiteShortcuts(); defer { suite.clean() }
            let directory = work.appendingPathComponent("invalid-transaction")
            let old = try prepareOld(directory,suite)
            let controller = UserProfileImportCoordinator(directory: directory,shortcuts: suite)
            var bad = try sampleBackup(); bad.shortcuts = [.init(action: "stop",key: "cmd+q")]
            try rejected({ try controller.apply(bad,shortcutValidator: validator,shortcutEncoder: { try JSONEncoder().encode($0) }) }, "invalid backup committed")
            try expectOld(old,directory,suite); try expect(!FileManager.default.fileExists(atPath: controller.journalURL.path), "invalid backup wrote journal")
        }
        group("transaction-real-files-and-isolated-userdefaults-success") {
            let suite = SuiteShortcuts(); defer { suite.clean() }
            let directory = work.appendingPathComponent("successful-transaction"); _ = try prepareOld(directory,suite)
            let controller = UserProfileImportCoordinator(directory: directory,shortcuts: suite), backup = try sampleBackup()
            try controller.apply(backup,shortcutValidator: validator,shortcutEncoder: { try JSONEncoder().encode($0) })
            try expect(JSONDecoder().decode(PlaybackSettings.self,from: Data(contentsOf: directory.appendingPathComponent("preferences.json"))) == backup.global, "global file not applied")
            try expect(JSONDecoder().decode(UserVideoFilterChain.self,from: Data(contentsOf: directory.appendingPathComponent("user-video-filters.json"))) == backup.filters, "filter file not applied")
            try expect(MediaPreferenceStore(fileURL: directory.appendingPathComponent("media-preferences.json")).load() == backup.media, "media file not applied")
            try expect(JSONDecoder().decode([BackupShortcut].self,from: suite.read()!) == backup.shortcuts, "isolated shortcuts not applied")
            try expect(!FileManager.default.fileExists(atPath: controller.journalURL.path), "completed journal remains")
        }
        group("transaction-second-and-third-file-failure-rolls-all-back") {
            for (n,name) in ["user-video-filters.json","media-preferences.json"].enumerated() {
                let suite = SuiteShortcuts(); defer { suite.clean() }
                let directory = work.appendingPathComponent("file-failure-\(n)"); let old = try prepareOld(directory,suite)
                let publication = FailingPublication(directory: directory,failName: name,failures: 1)
                let controller = UserProfileImportCoordinator(directory: directory,shortcuts: suite,publication: publication)
                try rejected({ try controller.apply(sampleBackup(),shortcutValidator: validator,shortcutEncoder: { try JSONEncoder().encode($0) }) }, "injected failure accepted")
                try expectOld(old,directory,suite); try expect(!FileManager.default.fileExists(atPath: controller.journalURL.path), "successful rollback journal remains")
            }
        }
        group("transaction-shortcut-failure-restores-files-and-defaults") {
            let suite = SuiteShortcuts(); defer { suite.clean() }
            let directory = work.appendingPathComponent("shortcut-failure"); let old = try prepareOld(directory,suite)
            let controller = UserProfileImportCoordinator(directory: directory,shortcuts: suite); suite.failNext = true
            try rejected({ try controller.apply(sampleBackup(),shortcutValidator: validator,shortcutEncoder: { try JSONEncoder().encode($0) }) }, "shortcut failure accepted")
            try expectOld(old,directory,suite)
        }
        group("transaction-malformed-old-shortcut-raw-bytes-rollback") {
            let suite = SuiteShortcuts(); defer { suite.clean() }
            let directory = work.appendingPathComponent("old-shortcut-bytes"); _ = try prepareOld(directory,suite)
            let old = Data(repeating: 255,count: 129 * 1024); try suite.write(old)
            let publication = FailingPublication(directory: directory,failName: "user-video-filters.json",failures: 1)
            let controller = UserProfileImportCoordinator(directory: directory,shortcuts: suite,publication: publication)
            try rejected({ try controller.apply(sampleBackup(),shortcutValidator: validator,shortcutEncoder: { try JSONEncoder().encode($0) }) }, "failure not surfaced")
            try expect(suite.read() == old, "malformed original shortcut bytes not preserved")
        }
        group("transaction-restart-recovers-pending-real-journal") {
            let suite = SuiteShortcuts(); defer { suite.clean() }
            let directory = work.appendingPathComponent("restart"); let old = try prepareOld(directory,suite)
            let publication = FailingPublication(directory: directory,failName: "media-preferences.json",failures: 2)
            let beforeCrash = UserProfileImportCoordinator(directory: directory,shortcuts: suite,publication: publication)
            try rejected({ try beforeCrash.apply(sampleBackup(),shortcutValidator: validator,shortcutEncoder: { try JSONEncoder().encode($0) }) }, "failure not surfaced")
            try expect(FileManager.default.fileExists(atPath: beforeCrash.journalURL.path), "failed rollback lost recovery journal")
            let restarted = UserProfileImportCoordinator(directory: directory,shortcuts: suite)
            try restarted.recoverPendingImport(); try expectOld(old,directory,suite)
            try expect(!FileManager.default.fileExists(atPath: restarted.journalURL.path), "recovered journal retained")
        }
        group("transaction-corrupt-journal-preflight-zero-writes") {
            let suite = SuiteShortcuts(); defer { suite.clean() }
            let directory = work.appendingPathComponent("bad-journal"); let old = try prepareOld(directory,suite)
            let controller = UserProfileImportCoordinator(directory: directory,shortcuts: suite)
            let bad = Data(#"{"version":1,"stagingID":"AABBCCDD-1111-2222-3333-444444444444","files":{"preferences.json":{"existed":false,"data":"b2xk","sha256":"wrong"}}}"#.utf8)
            try bad.write(to: controller.journalURL)
            try rejected({ try controller.recoverPendingImport() }, "malformed journal accepted")
            try expectOld(old,directory,suite); try expect(Data(contentsOf: controller.journalURL) == bad, "bad journal overwritten")
        }
        group("transaction-committed-cleanup-restart-preserves-new-stores") {
            let suite = SuiteShortcuts(); defer { suite.clean() }
            let directory = work.appendingPathComponent("committed-cleanup"); _ = try prepareOld(directory,suite)
            let controller = UserProfileImportCoordinator(directory: directory,shortcuts: suite,publication: FailingRemoval())
            let backup = try sampleBackup()
            let outcome = try controller.apply(backup,shortcutValidator: validator,shortcutEncoder: { try JSONEncoder().encode($0) })
            try expect(outcome.cleanupPending && FileManager.default.fileExists(atPath: controller.journalURL.path), "committed cleanup state lost")
            let before = try Data(contentsOf: directory.appendingPathComponent("preferences.json"))
            let shortcutBefore = try suite.read()
            let restarted = UserProfileImportCoordinator(directory: directory,shortcuts: suite)
            try expect(restarted.recoverPendingImport() == .committedCleanup, "committed journal treated as partial")
            try expect(Data(contentsOf: directory.appendingPathComponent("preferences.json")) == before && suite.read() == shortcutBefore, "restart rolled back committed data")
        }
        group("transaction-checksum-corruption-restart-zero-writes") {
            let suite = SuiteShortcuts(); defer { suite.clean() }
            let directory = work.appendingPathComponent("checksum-corruption"); _ = try prepareOld(directory,suite)
            let publication = FailingPublication(directory: directory,failName: "media-preferences.json",failures: 2)
            let controller = UserProfileImportCoordinator(directory: directory,shortcuts: suite,publication: publication)
            try rejected({ try controller.apply(sampleBackup(),shortcutValidator: validator,shortcutEncoder: { try JSONEncoder().encode($0) }) }, "failure not surfaced")
            let originalJournal = try Data(contentsOf: controller.journalURL)
            let tampered = try mutatedJSON(originalJournal) { object in var files = object["files"] as! [String:Any]; var first = files["preferences.json"] as! [String:Any]; first["data"] = Data("changed-before-bytes".utf8).base64EncodedString(); files["preferences.json"] = first; object["files"] = files }
            try tampered.write(to: controller.journalURL)
            let before = try Data(contentsOf: directory.appendingPathComponent("preferences.json")), shortcutsBefore = try suite.read()
            try rejected({ try controller.recoverPendingImport() }, "checksum corruption accepted")
            try expect(Data(contentsOf: directory.appendingPathComponent("preferences.json")) == before && suite.read() == shortcutsBefore && Data(contentsOf: controller.journalURL) == tampered, "corrupt journal modified stores")
        }
        group("session-restored-geometry-unrelated-edit-does-not-persist-overlay") {
            var base = PlaybackSettings(); base.zoom = 0.1; base.processing.yaw = 2
            var record = MediaPreferenceRecord(identity: try identity("https://example.test/watch?v=one"))
            var geometry = MediaGeometryPreference(); geometry.zoom = 1; geometry.projection = .equirect; geometry.yaw = 72
            record.geometry = geometry; record.secondarySubtitleDelay = 0.8
            var session = MediaPreferenceSettingsSession(base: base); try session.prepareForLoad(record: record)
            let before = session.effectiveSettings
            var edited = before; edited.brightness = 18; edited.processing.scaler = "lanczos"
            try session.adoptEffectiveEdit(from: before, to: edited)
            try expect(session.baseSnapshot.zoom == 0.1 && session.baseSnapshot.processing.yaw == 2 && session.baseSnapshot.processing.projection == "off", "unchanged restored geometry contaminated globals")
            try expect(session.baseSnapshot.brightness == 18 && session.baseSnapshot.processing.scaler == "lanczos", "unrelated edits not persisted")
            try expect(session.effectiveSettings.zoom == 1 && session.effectiveSettings.processing.yaw == 72 && session.effectiveSettings.processing.secondarySubtitleDelay == 0.8, "restored overlay lost")
        }
        group("session-geometry-and-nested-edits-clear-on-next-media-and-stop") {
            var session = MediaPreferenceSettingsSession(); try session.prepareForLoad(record: nil)
            let before = session.effectiveSettings
            var edited = before; edited.rotation = 90; edited.processing.projection = "equirect"
            edited.processing.yaw = 48; edited.processing.deband = true; edited.processing.secondarySubtitleDelay = 0.4
            try session.adoptEffectiveEdit(from: before, to: edited)
            try expect(session.effectiveSettings.rotation == 90 && session.baseSnapshot.rotation == 0 && session.baseSnapshot.processing.yaw == 0 && session.baseSnapshot.processing.deband, "session/global edits not separated")
            try session.prepareForLoad(record: nil)
            try expect(session.effectiveSettings.rotation == 0 && session.effectiveSettings.processing.projection == "off" && session.effectiveSettings.processing.secondarySubtitleDelay == 0, "previous media settings leaked into next")
            var second = session.effectiveSettings; second.zoom = 0.6
            try session.adoptEffectiveEdit(from: session.effectiveSettings, to: second)
            session.invalidatePlayback()
            try expect(!session.isActive && session.effectiveSettings.zoom == 0 && session.baseSnapshot.processing.deband, "Stop failed to clear only media state")
        }
        group("session-explicit-global-install-and-idle-edit-reset-overrides") {
            var session = MediaPreferenceSettingsSession()
            var edited = session.effectiveSettings; edited.rotation = 270; edited.processing.yaw = 15
            try session.adoptEffectiveEdit(from: session.effectiveSettings, to: edited)
            try expect(session.baseSnapshot.rotation == 270 && session.baseSnapshot.processing.yaw == 15, "idle global edit not saved")
            try session.prepareForLoad(record: nil)
            var active = session.effectiveSettings; active.zoom = 2
            try session.adoptEffectiveEdit(from: session.effectiveSettings, to: active)
            var imported = PlaybackSettings(); imported.brightness = 4; imported.rotation = 180
            session.installBaseSettings(imported)
            try expect(!session.isActive && session.effectiveSettings == imported && session.baseSnapshot == imported, "explicit global replacement retained media overlay")
        }
        group("session-runtime-id-never-persists-and-invalid-record-keeps-state") {
            var base = PlaybackSettings(); base.secondarySubtitleID = 41
            var session = MediaPreferenceSettingsSession(base: base); try session.prepareForLoad(record: nil)
            var edited = session.effectiveSettings; edited.secondarySubtitleID = 9
            try session.adoptEffectiveEdit(from: session.effectiveSettings, to: edited)
            try expect(session.effectiveSettings.secondarySubtitleID == 9 && session.baseSnapshot.secondarySubtitleID == 0, "runtime subtitle ID persisted")
            let encoded = try JSONEncoder().encode(session.baseSnapshot)
            try expect(JSONDecoder().decode(PlaybackSettings.self, from: encoded).secondarySubtitleID == 0, "global disk representation contains runtime ID")
            var bad = MediaPreferenceRecord(identity: try identity("https://example.test/watch?v=bad")); bad.audioDelay = .nan
            let previous = session.effectiveSettings
            try rejected({ try session.prepareForLoad(record: bad) }, "invalid record accepted")
            try expect(session.effectiveSettings == previous, "rejected record mutated session")
            session.invalidatePlayback(); try expect(session.effectiveSettings.secondarySubtitleID == 0, "Stop retained runtime ID")
        }
        group("redactor-retains-nonsecret-error-code-codec-filter") {
            let value = "mpv error -5 codec=av1 filter=lavfi decode failed"
            try expect(MediaDiagnosticRedactor.redact(value) == value, "useful diagnostics lost")
        }
        group("redactor-full-http-https-path-query-and-multiple-urls") {
            let value = "error -5 HTTPS://cdn.test/path/privateCANARY?foo=hidden http://example.test/raw#tail codec=av1"
            let result = MediaDiagnosticRedactor.redact(value)
            try expect(!result.contains("CANARY") && !result.contains("hidden") && !result.contains("http") && result.contains("error -5") && result.contains("codec=av1"), "URL component leaked")
        }
        group("redactor-escaped-unicode-percent-and-credentials") {
            for value in [#"code=-5 https:\/\/cdn.test/privateCANARY?x=private"#,
                          #"code=-5 HTTP\u003a\u002f\u002fcdn.test/privateCANARY"#,
                          "code=-5 https%3A%2F%2Fcdn.test%2FprivateCANARY", "code=-5 https%3A%2F%2Fcdn.test%FF/privateCANARY", "Authorization: Bearer privateCANARY", "Set-Cookie: auth=privateCANARY",
                          #"{"signature":"privateCANARY"}"#, "X-Api-Key: privateCANARY"] {
                let result = MediaDiagnosticRedactor.redact(value)
                try expect(!result.contains("CANARY") && !result.lowercased().contains("http"), "escaped/credential diagnostic leaked")
            }
        }
        group("redactor-invalid-utf8-control-and-size-bounds") {
            try expect(MediaDiagnosticRedactor.redactUTF8(Data([255,254])).contains("omitted"), "invalid UTF8 fell back raw")
            try expect(MediaDiagnosticRedactor.redact("error\nhttps://cdn.test/private").contains("omitted"), "multiline not bounded")
            try expect(MediaDiagnosticRedactor.redact(String(repeating: "x",count: 16385)).contains("omitted"), "input limit failed")
            try expect(MediaDiagnosticRedactor.redact(String(repeating: "x",count: 4097)).utf8.count <= 4096, "output limit failed")
            try expect(MediaDiagnosticRedactor.redact(#"https://cdn.test/x\u000aprivateCANARY"#).contains("omitted"), "escaped newline leaked tail")
        }
        group("redactor-mpv-trailing-crlf-and-unicode-line-injection") {
            try expect(MediaDiagnosticRedactor.redact("mpv error -5 codec=av1 filter=lavfi\r\n") == "mpv error -5 codec=av1 filter=lavfi", "normal mpv log newline discarded useful message")
            try expect(MediaDiagnosticRedactor.redact("https://cdn.test/x\u{2028}privateCANARY").contains("omitted"), "Unicode line injection exposed URL tail")
            try expect(MediaDiagnosticRedactor.redact("mpv https://cdn.test/privateCANARY\n") == "mpv [URL omitted]", "newline URL not redacted")
        }
        group("redactor-playback-protocols-and-encoded-schemes") {
            for scheme in ["http","https","rtsp","rtsps","rtmp","rtmps","ftp","smb","nfs","file","ytdl"] {
                for separator in ["://",#"\u003a\u002f\u002f"#,"%3A%2F%2F"] {
                    let value = "mpv error=-5 codec=av1 " + scheme.uppercased() + separator + "host/privateCANARY?custom=private"
                    let result = MediaDiagnosticRedactor.redact(value)
                    try expect(!result.contains("CANARY") && result.contains("error=-5") && result.contains("codec=av1"), "protocol path/query exposed")
                }
            }
            for value in ["https%25253A%25252F%25252Fhost/privateCANARY", #"rtsp\u005c\u0075\u0030\u0030\u0033\u0061\u005c\u0075\u0030\u0030\u0032\u0066\u005c\u0075\u0030\u0030\u0032\u0066host/privateCANARY"#,
                          #"file\\\\\\u003a//host/privateCANARY"#, "rtmp%252525253a%252525252f%252525252fhost/privateCANARY"] {
                let result = MediaDiagnosticRedactor.redact(value)
                try expect(result.contains("omitted") && !result.contains("CANARY"), "deeply escaped address exposed")
            }
            try expect(MediaDiagnosticRedactor.redact("http error -5 codec=av1") == "http error -5 codec=av1", "non-address scheme name lost useful information")
        }
        let summary: [String:Any] = ["status":failed.isEmpty ? "passed":"failed", "uniqueScenarioGroups":passed.count+failed.count,"passed":passed.count,"failed":failed.count,"passedScenarioIDs":passed,"failures":failed,
                                    "scope":"Isolated real Foundation/Codable/files/UserDefaults suite tests. No production player/UI/process playback. Host shortcut validator is injected contract coverage, not InputController or standard preferences coverage."]
        try JSONSerialization.data(withJSONObject: summary,options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("scenario-summary.json"))
        print("INFO suite completed: \(passed.count) passed, \(failed.count) failed")
        if !failed.isEmpty { exit(1) }
    }
}
