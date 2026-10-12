import Foundation
import Darwin
import CryptoKit
import PlayerCore

private enum CheckFailure: Error { case condition(String) }
// The exact URL-only Codable schema in archived 0.3.1/build9. This checks its
// decoding contract, without compiling or launching that historical app.
private struct Build9QueueSchema: Decodable { let urls: [URL]; let selectedIndex: Int? }

@main struct WebMediaChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.contains("--fixture-child") { fixtureChild(); return }
        if let address = CommandLine.arguments.last, URL(string: address)?.host == "fixture.invalid" {
            try fixtureHelper(address: address); return
        }
        guard CommandLine.arguments.count == 2 else { throw CheckFailure.condition("expected real extractor probe directory") }
        try modelChecks(probes: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        try await processChecks()
        print("INFO Web media module suite completed; controlled process checks are not live-site playback evidence")
    }

    static func require(_ condition: @autoclosure () throws -> Bool, _ description: String) throws {
        guard try condition() else { throw CheckFailure.condition(description) }
    }
    static func rejects(_ description: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw CheckFailure.condition("accepted " + description)
    }
    static let page = URL(string: "https://example.com/watch?v=中文%20视频")!
    static func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    static func metadata(title: String = "中文视频，格式=选择", unknownHeight: Bool = false) -> [String: Any] {
        ["_type": "video", "title": title, "duration": 81.25, "formats": [
            ["format_id": "v.1", "url": "https://cdn.example/video?signature=temporary", "ext": "mp4",
             "vcodec": "avc1", "acodec": "none", "height": unknownHeight ? NSNull() : 1080, "fps": 29.97],
            ["format_id": "a-1", "url": "https://cdn.example/audio", "ext": "m4a", "vcodec": "none", "acodec": "aac"],
            ["format_id": "mix", "url": "https://cdn.example/mix", "ext": "mp4", "height": 360]
        ], "subtitles": ["zh": [["url": "https://cdn.example/manual.vtt"]], "empty": [], "no-url": [["ext": "vtt"]]],
           "automatic_captions": ["en": [["url": "https://cdn.example/auto.vtt"]], "zh": [["url": "https://cdn.example/zh-auto.vtt"]]],
           "http_headers": ["Authorization": "do-not-persist"], "cookies": "do-not-persist"]
    }

    static func modelChecks(probes: URL) throws {
        let document = try WebMediaDocument.parse(data: json(metadata()), pageURL: page)
        try require(document.title == "中文视频，格式=选择" && document.duration == 81.25, "title/duration")
        try require(document.formats.count == 3 && document.formats[0].isVideoOnly && !document.formats[1].hasVideo, "split formats")
        try require(!document.formats[2].isVideoOnly && document.formats[2].audioCodec == nil, "unknown codec is not audio absent")
        try require(document.subtitleLanguages == ["zh"] && document.automaticSubtitleLanguages == ["en", "zh"], "real subtitle sources only")
        let split = try document.selection(formatID: "v.1", subtitleLanguage: "zh")
        try require(split.formatExpression == "v.1+bestaudio/best" && !split.includeAutomaticSubtitles, "split expression/manual subtitle")
        let mixed = try document.selection(formatID: "mix")
        try require(mixed.formatExpression == "mix", "unknown codec progressive selection")
        let automatic = try document.selection(subtitleLanguage: "en", includeAutomaticSubtitles: true)
        try require(automatic.includeAutomaticSubtitles && automatic.subtitleLanguage == "en", "explicit automatic subtitle")
        try require(try document.selection().formatExpression == "bestvideo[height<=2160]+bestaudio/best[height<=2160]/bestvideo+bestaudio/best", "auto preserves video fallback")
        try rejects("automatic-only subtitle as manual") { _ = try document.selection(subtitleLanguage: "en") }
        try rejects("stale format") { _ = try document.selection(formatID: "expired") }
        try rejects("empty subtitle list as selectable") { _ = try document.selection(subtitleLanguage: "empty") }
        print("PASS production JSON formats, unknown codec, split audio, auto video fallback, manual/automatic subtitle choices")

        let unknown = try WebMediaDocument.parse(data: json(metadata(unknownHeight: true)), pageURL: page)
        try require(unknown.formats[0].height == nil && unknown.formats[0].isVideoOnly, "height-unknown video-only")
        var single: [String: Any] = ["_type": "audio", "title": "音频", "url": "https://cdn.example/audio", "acodec": "opus", "ext": "ogg"]
        let audio = try WebMediaDocument.parse(data: json(single), pageURL: page)
        try require(audio.duration == nil && !audio.formats[0].hasVideo && !audio.formats[0].isVideoOnly, "single audio without duration")
        single["_type"] = "video"; single["live_status"] = "is_live"; single.removeValue(forKey: "acodec")
        let live = try WebMediaDocument.parse(data: json(single), pageURL: page)
        try require(live.isLive && live.formats[0].formatID == "auto" && !live.formats[0].isVideoOnly, "live/unknown codec fallback")
        print("PASS unknown height, audio-only single result, live and unknown duration")

        for name in ["progressive", "dash", "unknown"] {
            let url = probes.appendingPathComponent(name + ".json")
            let data = try Data(contentsOf: url)
            let raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let original = URL(string: raw["webpage_url"] as! String)!
            let real = try WebMediaDocument.parse(data: data, pageURL: original)
            if name == "progressive" {
                try require(real.formats.count == 2 && real.formats.allSatisfy { !$0.isVideoOnly }, "real progressive mixed MP4")
                try require(try real.selection(formatID: "H264_360p", subtitleLanguage: "zh").formatExpression == "H264_360p", "real progressive expression")
            } else if name == "dash" {
                try require(real.formats.first { $0.formatID == "0" }?.isVideoOnly == true, "real DASH explicit audio none")
                try require(try real.selection(formatID: "0").formatExpression == "0+bestaudio/best", "real DASH expression")
            } else {
                try require(real.formats.count == 1 && !real.formats[0].hasVideo && !real.formats[0].hasAudio,
                            "unknown codecs and dimensions are accepted without invented codecs")
                try require(!real.formats[0].isVideoOnly && real.formats[0].displayName.contains("格式未知"), "unknown type display")
                try require(try real.selection(formatID: "0").formatExpression == "0", "unknown progressive direct format")
            }
            print("PASS frozen actual yt-dlp \(name) JSON regression SHA256=\(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())")
        }

        try rejects("malformed JSON") { _ = try WebMediaDocument.parse(data: Data("{broken".utf8), pageURL: page) }
        for kind in ["playlist", "multi_video", "url", "url_transparent"] {
            var raw = metadata(); raw["_type"] = kind
            try rejects(kind) { _ = try WebMediaDocument.parse(data: json(raw), pageURL: page) }
        }
        var collection = metadata(); collection["entries"] = []
        try rejects("entries collection") { _ = try WebMediaDocument.parse(data: json(collection), pageURL: page) }
        for nested in [false, true] {
            var raw = metadata()
            if nested { var rows = raw["formats"] as! [[String: Any]]; rows[0]["has_drm"] = true; raw["formats"] = rows }
            else { raw["is_drm"] = true }
            try rejects("DRM") { _ = try WebMediaDocument.parse(data: json(raw), pageURL: page) }
        }
        var malformedDRM = metadata(); malformedDRM["has_drm"] = 1
        try rejects("non-Boolean DRM marker") { _ = try WebMediaDocument.parse(data: json(malformedDRM), pageURL: page) }
        print("PASS malformed JSON, playlist/multi-video/redirect results and top/format DRM rejection")

        for unsafe in ["file:///tmp/x", "ftp://example.com/a", "https://user:password@example.com/a", "https://example.com/%00", "https://example.com/%0d%0a", "https://example.com/a\u{202E}", "https://example.com/?access_token=secret"] {
            try rejects("unsafe page") { _ = try WebMediaDocument.validatedPageURL(unsafe) }
        }
        for key in ["url", "manifest_url", "fragment_base_url"] {
            var raw = metadata(); var rows = raw["formats"] as! [[String: Any]]; rows[0][key] = "file:///tmp/private"; raw["formats"] = rows
            try rejects("unsafe format " + key) { _ = try WebMediaDocument.parse(data: json(raw), pageURL: page) }
        }
        var fragments = metadata(); var rows = fragments["formats"] as! [[String: Any]]
        rows[0]["fragments"] = [["url": "https://user:secret@example.com/a"]]; fragments["formats"] = rows
        try rejects("unsafe fragment") { _ = try WebMediaDocument.parse(data: json(fragments), pageURL: page) }
        var subtitles = metadata(); subtitles["subtitles"] = ["zh": [["url": "file:///etc/passwd"]]]
        try rejects("unsafe subtitle") { _ = try WebMediaDocument.parse(data: json(subtitles), pageURL: page) }
        print("PASS page/media/manifest/fragment/subtitle URL protocol, credentials and encoded/control-character boundaries")

        try rejects("oversized metadata") { _ = try WebMediaDocument.parse(data: Data(repeating: 32, count: WebMediaDocument.maximumBytes + 1), pageURL: page) }
        var many = metadata(); many["formats"] = (0...2000).map { ["format_id": String($0), "url": "https://cdn.example/a", "vcodec": "avc1"] }
        try rejects("format limit") { _ = try WebMediaDocument.parse(data: json(many), pageURL: page) }
        for identifier in ["v+audio", "best/best", "x[height=1]", "-flag", "a,b", "line\nend"] {
            try rejects("format operators") { _ = try WebMediaSelection(title: "Title", formatID: identifier) }
        }
        try rejects("automatic caption without language") { _ = try WebMediaSelection(title: "Title", includeAutomaticSubtitles: true) }
        let oldPreference = try JSONDecoder().decode(WebMediaSelection.self, from: Data("{\"title\":\"旧偏好\",\"formatID\":\"auto\"}".utf8))
        try require(!oldPreference.includeAutomaticSubtitles && !oldPreference.separateAudio, "legacy preference defaults")
        print("PASS 16 MiB/2000 format caps, selection operator rejection and backwards-compatible preference decoding")

        var playlist = Playlist()
        let local = URL(fileURLWithPath: "/tmp/中文 文件.mp4")
        playlist.add([local, page]); let originalID = playlist.items[1].id
        _ = playlist.select(id: originalID)
        let item = try playlist.upsertWebMedia(pageURL: page, selection: split)
        try require(item.id == originalID && playlist.currentItem?.id == originalID && playlist.items.count == 2, "upsert identity")
        let encoded = try JSONEncoder().encode(PlaybackQueueDocument(items: playlist.items, selectedIndex: playlist.currentIndex))
        let decoded = try JSONDecoder().decode(PlaybackQueueDocument.self, from: encoded)
        try require(decoded.items == playlist.items && decoded.selectedIndex == 1 && decoded.items[1].url == page, "new queue roundtrip")
        let oldReader = try JSONDecoder().decode(Build9QueueSchema.self, from: encoded)
        try require(oldReader.urls == playlist.items.map(\.url) && oldReader.selectedIndex == 1, "build9 schema can restore original URL queue")
        var authority = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        authority["urls"] = ["https://decoy.example/untrusted"]
        let authoritative = try JSONDecoder().decode(PlaybackQueueDocument.self, from: json(authority))
        try require(authoritative.items == playlist.items && authoritative.selectedIndex == 1, "v2 items remain authoritative over URL mirror")
        let text = String(decoding: encoded, as: UTF8.self)
        try require(!text.contains("cdn.example") && !text.contains("Authorization") && !text.contains("do-not-persist"), "no runtime URLs/headers/cookies persisted")
        let legacyData = try json(["urls": [local.absoluteString, "https://user:secret@example.com/a", page.absoluteString, page.absoluteString], "selectedIndex": 3])
        let legacy = try JSONDecoder().decode(PlaybackQueueDocument.self, from: legacyData)
        try require(legacy.items.count == 2 && legacy.selectedIndex == 1 && legacy.items[1].webMedia == nil, "old queue filtered index translation")
        let oldItemData = try json(["id": originalID.uuidString, "url": local.absoluteString])
        let oldItem = try JSONDecoder().decode(MediaItem.self, from: oldItemData)
        try require(oldItem.id == originalID && oldItem.webMedia == nil && oldItem.title == "中文 文件.mp4", "old item identity/title")
        let unsafeItemData = try json(["id": originalID.uuidString, "url": "https://user:secret@example.com/video"])
        try rejects("persisted credentials") { _ = try JSONDecoder().decode(MediaItem.self, from: unsafeItemData) }
        var invalid = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var stored = invalid["items"] as! [[String: Any]]; var pref = stored[1]["webMedia"] as! [String: Any]
        pref["formatID"] = "best+all"; stored[1]["webMedia"] = pref; invalid["items"] = stored
        try rejects("persisted malicious preference") { _ = try JSONDecoder().decode(PlaybackQueueDocument.self, from: json(invalid)) }
        print("PASS production queue legacy migration, stable UUID/current identity, Chinese/space paths and metadata-only persistence")

        var catalog = WebMediaCatalog()
        try catalog.remember(pageURL: page, selection: split)
        let catalogData = try JSONEncoder().encode(catalog)
        let catalogRestored = try WebMediaCatalog.boundedDecode(catalogData)
        try require(catalogRestored.selection(for: page) == split && catalogRestored.entries.count == 1, "original page catalog roundtrip")
        let catalogText = String(decoding: catalogData, as: UTF8.self)
        try require(!catalogText.contains("cdn.example") && !catalogText.contains("Authorization") && !catalogText.contains("do-not-persist"), "metadata-only catalog")
        try catalog.remember(pageURL: page, selection: mixed)
        try require(catalog.entries.count == 1 && catalog.selection(for: page) == mixed, "latest preference replacement")
        print("PASS production web catalog original-page metadata-only roundtrip and latest preference replacement")

        try require(try WebMediaCatalog.boundedDecode(Data("{}".utf8)).entries.isEmpty, "old empty catalog")
        try require(WebMediaCatalog().selection(for: page) == nil, "new absent catalog")
        try rejects("credential catalog key") { _ = try WebMediaCatalog.boundedDecode(json(["entries": ["https://user:secret@example.com/a": ["title": "Bad", "formatID": "auto"]]])) }
        let preferenceText = String(decoding: try JSONEncoder().encode(split), as: UTF8.self)
        let duplicate = "{\"entries\":{\"https://example.com/a\":\(preferenceText),\"https://example.com/a\":\(preferenceText)}}"
        try rejects("duplicate catalog page key") { _ = try WebMediaCatalog.boundedDecode(Data(duplicate.utf8)) }
        let escapedDuplicate = "{\"entries\":{\"https://example.com/a\":\(preferenceText),\"https://example.com/\\u0061\":\(preferenceText)}}"
        try rejects("duplicate escaped key") { _ = try WebMediaCatalog.boundedDecode(Data(escapedDuplicate.utf8)) }
        try rejects("oversized catalog") { _ = try WebMediaCatalog.boundedDecode(Data(repeating: 32, count: WebMediaCatalog.maximumBytes + 1)) }
        var entries: [String: Any] = [:]
        for index in 0...WebMediaCatalog.maximumEntries { entries["https://example.com/\(index)"] = ["title": "Entry", "formatID": "auto"] }
        try rejects("5001 catalog entries") { _ = try WebMediaCatalog.boundedDecode(json(["entries": entries])) }
        let invalidCatalog = ["entries": ["https://example.com/a": ["title": "Bad", "formatID": "best+all"]]]
        try rejects("invalid catalog preference") { _ = try WebMediaCatalog.boundedDecode(json(invalidCatalog)) }
        print("PASS production web catalog old empty defaults, invalid URL/preference, duplicate JSON keys and byte/entry bounds")
    }

    @MainActor static func wait(_ description: String, seconds: Double = 5, until condition: () -> Bool) async throws {
        let start = ProcessInfo.processInfo.systemUptime
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime - start < seconds else { throw CheckFailure.condition("timeout: " + description) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    static func address(_ mode: String, record: URL? = nil, pid: URL? = nil) -> String {
        var components = URLComponents(string: "https://fixture.invalid/" + mode)!
        components.queryItems = [("record", record), ("pid", pid)].compactMap { name, url in url.map { URLQueryItem(name: name, value: $0.path) } }
        return components.url!.absoluteString
    }
    static func processPID(_ file: URL) throws -> pid_t { pid_t(try String(contentsOf: file).trimmingCharacters(in: .whitespacesAndNewlines))! }
    static func absent(_ pid: pid_t) -> Bool { kill(pid, 0) < 0 && errno == ESRCH }

    @MainActor static func processChecks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("网页 模块测试-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("yt-dlp"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let own = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        for target in [directory.appendingPathComponent("yt-dlp/yt-dlp_macos"), directory.appendingPathComponent("deno")] {
            try FileManager.default.copyItem(at: own, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        }
        let record = directory.appendingPathComponent("invocation.json")
        let inherited = ["HTTPS_PROXY", "PYTHONPATH", "YTDLP_PLUGIN_DIRS", "AUTHORIZATION"]
        let old = inherited.map { getenv($0).map { String(cString: $0) } }
        for name in inherited { setenv(name, "must-not-inherit", 1) }
        defer { for (name, value) in zip(inherited, old) { if let value { setenv(name, value, 1) } else { unsetenv(name) } } }
        let resolver = WebMediaResolver(toolsDirectory: directory)
        resolver.resolve(address: address("success", record: record))
        try require(resolver.busy && WebMediaResolver.hasActiveJobs, "registered real job")
        try await wait("success") { !resolver.busy }
        try require(resolver.error == nil && resolver.document?.title == "Controlled success", "controlled metadata success")
        let invocation = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as! [String: Any]
        let arguments = invocation["arguments"] as! [String]
        let expected = ["--ignore-config", "--no-plugin-dirs", "--no-remote-components", "--no-js-runtimes", "--js-runtimes", "deno:" + directory.appendingPathComponent("deno").path,
                        "--no-cookies-from-browser", "--no-update", "--no-cache-dir", "--socket-timeout", "15", "--no-playlist", "--simulate", "--dump-single-json", "--", address("success", record: record)]
        try require(arguments == expected, "ordered argument array/exact Chinese-space helper path")
        let environment = invocation["environment"] as! [String: String]
        try require(inherited.allSatisfy { environment[$0] == nil } && environment["HOME"] == nil, "minimal environment/no HOME override")
        print("INFO controlled helper observed environment keys: " + environment.keys.sorted().joined(separator: ","))
        try require(Set(environment.keys).isSubset(of: Set(["PATH", "LANG", "LC_ALL", "TMPDIR", "DENO_DIR", "__CF_USER_TEXT_ENCODING"])), "no inherited credentials/plugins")
        try require(environment["TMPDIR"].map { !FileManager.default.fileExists(atPath: $0) } == true, "owned temp directory cleaned")
        print("PASS actual controlled helper success, exact argument order, Chinese/space executable path and minimal environment/temp cleanup")

        for (mode, expectedError) in [("badjson", "有效"), ("failure", "登录"), ("stderr", "128 KiB"), ("oversize", "16 MiB")] {
            let start = ProcessInfo.processInfo.systemUptime
            resolver.resolve(address: address(mode))
            try await wait(mode) { !resolver.busy }
            try require(resolver.document == nil && resolver.error?.contains(expectedError) == true, "controlled " + mode)
            try require(!(resolver.error?.contains("secret-extractor-token") ?? false), "diagnostic secrecy")
            try require(ProcessInfo.processInfo.systemUptime - start < 4, "bounded saturated pipe cleanup")
            print("PASS actual controlled helper \(mode), bounded failure and no raw diagnostic/credential disclosure")
        }

        let timed = WebMediaResolver(toolsDirectory: directory, timeout: 0.4)
        let timeoutPID = directory.appendingPathComponent("timeout-child.pid")
        timed.resolve(address: address("hang", pid: timeoutPID))
        try await wait("timeout child started") { FileManager.default.fileExists(atPath: timeoutPID.path) }
        let timedChild = try processPID(timeoutPID)
        try await wait("timeout") { !timed.busy }
        try require(timed.error?.contains("超时") == true, "actual deadline")
        try await wait("timeout descendant death") { absent(timedChild) }
        print("PASS actual deadline and SIGTERM-resistant Deno-shaped descendant exit")

        let cancelPID = directory.appendingPathComponent("cancel-child.pid")
        resolver.resolve(address: address("hang", pid: cancelPID))
        try await wait("cancel child started") { FileManager.default.fileExists(atPath: cancelPID.path) }
        let cancelledChild = try processPID(cancelPID), cancelStart = ProcessInfo.processInfo.systemUptime
        resolver.cancel()
        try require(!resolver.busy && resolver.document == nil && resolver.error == nil && resolver.status == "已取消解析", "cancel UI state")
        try require(ProcessInfo.processInfo.systemUptime - cancelStart < 0.1, "immediate UI cancel")
        try await wait("cancel descendant death") { absent(cancelledChild) }
        await WebMediaResolver.shutdownAll()
        try require(!WebMediaResolver.hasActiveJobs, "cancel registry cleanup")
        print("PASS immediate cancel state and actual owned leader/descendant cleanup")

        let staleRecord = directory.appendingPathComponent("slow.json")
        resolver.resolve(address: address("slow", record: staleRecord))
        try await wait("slow helper started") { FileManager.default.fileExists(atPath: staleRecord.path) }
        resolver.resolve(address: address("success"))
        try await wait("replacement success") { !resolver.busy }
        try await Task.sleep(nanoseconds: 1_700_000_000)
        try require(resolver.document?.title == "Controlled success" && resolver.error == nil, "old callback isolation")
        print("PASS actual in-flight replacement and obsolete generation callback isolation")

        let normalPID = directory.appendingPathComponent("normal-child.pid")
        resolver.resolve(address: address("descendant", pid: normalPID))
        try await wait("normal root exit") { !resolver.busy }
        let normalChild = try processPID(normalPID)
        try require(resolver.document != nil && resolver.error == nil, "successful root with descendant")
        try await wait("normal descendant death") { absent(normalChild) }
        print("PASS successful extractor exit also closes its lingering Deno-shaped descendant")

        let orphanPID = directory.appendingPathComponent("closed-view-child.pid")
        var closedView: WebMediaResolver? = WebMediaResolver(toolsDirectory: directory)
        weak var weakResolver = closedView
        closedView?.resolve(address: address("hang", pid: orphanPID))
        try await wait("closed view child started") { FileManager.default.fileExists(atPath: orphanPID.path) }
        let orphan = try processPID(orphanPID)
        closedView = nil
        try require(weakResolver == nil, "job registry does not retain resolver/view")
        await WebMediaResolver.shutdownAll()
        try require(!WebMediaResolver.hasActiveJobs && absent(orphan), "shutdown awaits active cleanup")
        print("PASS closed resolver is released and application shutdown awaits all owned jobs")

        let missing = WebMediaResolver(toolsDirectory: directory.appendingPathComponent("missing"))
        missing.resolve(address: "https://example.com/a")
        try require(!missing.busy && missing.error?.contains("工具缺失") == true && !WebMediaResolver.hasActiveJobs, "missing tool Chinese error/no process")
        resolver.resolve(address: "https://user:secret@example.com/a")
        try require(!resolver.busy && resolver.document == nil && resolver.error?.contains("账户凭据") == true, "unsafe address never launched")
        print("PASS missing helper and invalid page rejected before process registration")
    }

    static func fixtureHelper(address: String) throws {
        let url = URL(string: address)!, components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        func value(_ name: String) -> String? { components.queryItems?.first { $0.name == name }?.value }
        if let record = value("record") {
            try json(["arguments": Array(CommandLine.arguments.dropFirst()), "environment": ProcessInfo.processInfo.environment])
                .write(to: URL(fileURLWithPath: record))
        }
        if ["hang", "descendant"].contains(url.lastPathComponent) {
            let runtime = CommandLine.arguments[CommandLine.arguments.firstIndex(of: "--js-runtimes")! + 1]
            let path = String(runtime.dropFirst("deno:".count))
            let argv = [path, "--fixture-child", value("pid")!].map { strdup($0) } + [nil]
            let envp = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) } + [nil]
            defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
            var child: pid_t = 0
            let result = argv.withUnsafeBufferPointer { arguments in
                envp.withUnsafeBufferPointer { posix_spawn(&child, path, nil, nil, arguments.baseAddress!, $0.baseAddress!) }
            }
            guard result == 0 else { throw CheckFailure.condition("fixture descendant spawn") }
            // Wait for the actual child to establish its handler/PID breadcrumb.
            for _ in 0..<100 { if FileManager.default.fileExists(atPath: value("pid")!) { break }; usleep(10_000) }
        }
        switch url.lastPathComponent {
        case "hang": signal(SIGTERM, SIG_IGN); while true { usleep(100_000) }
        case "slow": usleep(1_500_000)
        case "badjson": emit(Data("{broken".utf8), fd: STDOUT_FILENO); return
        case "failure": emit(Data("signed URL secret-extractor-token".utf8), fd: STDERR_FILENO); exit(73)
        case "stderr": emit(Data(repeating: 120, count: 1024 * 1024), fd: STDERR_FILENO); return
        case "oversize": emit(Data(repeating: 120, count: WebMediaDocument.maximumBytes + 64 * 1024), fd: STDOUT_FILENO); return
        default: break
        }
        emit(try json(metadata(title: url.lastPathComponent == "slow" ? "Obsolete result" : "Controlled success")), fd: STDOUT_FILENO)
    }
    static func fixtureChild() {
        signal(SIGTERM, SIG_IGN)
        try! String(getpid()).write(toFile: CommandLine.arguments.last!, atomically: true, encoding: .utf8)
        while true { usleep(100_000) }
    }
    static func emit(_ data: Data, fd: Int32) {
        data.withUnsafeBytes { buffer in
            var count = 0
            while count < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if written > 0 { count += written }
                else if errno != EINTR { exit(74) }
            }
        }
    }
}
