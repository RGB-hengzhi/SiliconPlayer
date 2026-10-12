// Production EPG service/cache/preferences tests; no player or GUI startup.
import AppKit
import CryptoKit
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

private enum CheckFailure: Error { case failed(String) }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try value() == false { throw CheckFailure.failed(message) }
}
private func guide(_ title: String, logo: String = "") -> Data {
    Data("<tv><channel id='news'><display-name>新闻</display-name>\(logo)</channel><programme channel='news' start='20261004080000 +0800' stop='20261004090000 +0800'><title>\(title)</title></programme></tv>".utf8)
}

/// Deliberately ignores cancellation: service generation must reject its late reply.
private actor ControlledSource: EPGSourceTransport {
    private var pending: [String: CheckedContinuation<EPGHTTPPayload, Error>] = [:]
    private(set) var requestCount = 0
    func document(at url: URL) async throws -> EPGHTTPPayload {
        requestCount += 1
        return try await withCheckedThrowingContinuation { pending[url.path] = $0 }
    }
    func has(_ path: String) -> Bool { pending[path] != nil }
    func finish(_ path: String, data: Data) {
        pending.removeValue(forKey: path)?.resume(returning: EPGHTTPPayload(data: data, finalURL: URL(string: "http://127.0.0.1" + path)!))
    }
    func fail(_ path: String) { pending.removeValue(forKey: path)?.resume(throwing: EPGServiceError.httpStatus(404)) }
    func cleanup() { for value in pending.values { value.resume(throwing: CancellationError()) }; pending.removeAll() }
}

private actor MockLogo: EPGLogoTransport {
    private var body: Data
    private var failure = false
    private var delay: UInt64
    private(set) var requests = 0
    private(set) var active = 0
    private(set) var peak = 0
    init(_ body: Data, delay: UInt64 = 0) { self.body = body; self.delay = delay }
    func configure(body: Data? = nil, failure: Bool? = nil) {
        if let body { self.body = body }; if let failure { self.failure = failure }
    }
    func logo(at url: URL, maximumBytes: Int) async throws -> Data {
        requests += 1; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        try Task.checkCancellation()
        if failure { throw EPGServiceError.httpStatus(404) }
        return body
    }
}
private struct FailingPublication: EPGLogoPublication {
    func publish(_ data: Data, to target: URL) throws { throw EPGServiceError.cacheFailure }
}
private final class SwitchablePreferencesPublication: EPGPreferencesPublication, @unchecked Sendable {
    private let lock = NSLock()
    private var failure = false
    func fail() { lock.lock(); failure = true; lock.unlock() }
    func publish(_ data: Data, to target: URL) throws {
        lock.lock(); let shouldFail = failure; lock.unlock()
        if shouldFail { throw EPGPreferencesError.unavailable }
        try data.write(to: target, options: .atomic)
    }
}
private func png(width: Int = 256, height: Int = 64, red: CGFloat = 0.7, noise: Bool = false) throws -> Data {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CheckFailure.failed("fixture context") }
    context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if noise, let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
        var value: UInt32 = 0x13579bdf
        for index in 0..<(width * height) {
            for component in 0..<3 {
                value = value &* 1_664_525 &+ 1_013_904_223
                pixels[index * 4 + component] = UInt8(truncatingIfNeeded: value >> 24)
            }
            pixels[index * 4 + 3] = 255
        }
    }
    let data = NSMutableData()
    guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CheckFailure.failed("fixture PNG") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CheckFailure.failed("fixture encode") }
    return data as Data
}
private func cacheFiles(_ directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "png" }
}
private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

@MainActor
private func waitFor(_ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !(await condition()) {
        guard Date() < deadline else { throw CheckFailure.failed("deadline") }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

@main
@MainActor
private struct EPGServiceChecks {
    static func main() async throws {
        let root = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : FileManager.default.temporaryDirectory.appendingPathComponent("epg-service-" + UUID().uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw CheckFailure.failed("report directory must be new") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let logoBody = try png()
        var results: [[String: Any]] = []
        func run(_ name: String, _ test: () async throws -> Void) async {
            do { try await test(); results.append(["case": name, "passed": true]); print("PASS " + name) }
            catch { results.append(["case": name, "passed": false, "error": String(describing: error)]); print("FAIL " + name) }
        }
        func service(_ name: String, source: ControlledSource, logo: MockLogo? = nil, limits: XMLTVLimits = .init()) -> EPGService {
            let cache = EPGLogoCache(directory: root.appendingPathComponent(name), transport: logo ?? MockLogo(logoBody))
            return EPGService(channels: [EPGChannelReference(mediaURL: URL(string: "http://127.0.0.1/media.mp4")!, tvgID: "news", displayName: "新闻")], transport: source, logoCache: cache, limits: limits)
        }
        func load(_ service: EPGService, source: ControlledSource, path: String, title: String) async throws {
            service.address = "http://127.0.0.1" + path; service.loadRemote()
            try await waitFor { await source.has(path) }
            await source.finish(path, data: guide(title))
            try await waitFor { !service.isBusy }
            try require(service.document?.programmes["news"]?.first?.title == title, "committed title")
        }
        await run("successful-load-commits-source-and-document") {
            let source = ControlledSource(), view = service("commit", source: source)
            try await load(view, source: source, path: "/one.xml", title: "第一份")
            try require(view.committedSource?.path == "/one.xml" && view.error == nil, "source identity")
            view.dismiss(); await source.cleanup()
        }
        await run("http-failure-keeps-old-document") {
            let source = ControlledSource(), view = service("http-fail", source: source)
            try await load(view, source: source, path: "/good.xml", title: "旧节目")
            let old = view.document, oldSource = view.committedSource
            view.address = "http://127.0.0.1/missing.xml"; view.loadRemote()
            try await waitFor { await source.has("/missing.xml") }; await source.fail("/missing.xml")
            try await waitFor { !view.isBusy }
            try require(view.document == old && view.committedSource == oldSource && view.error != nil, "failed replacement")
            view.dismiss(); await source.cleanup()
        }
        await run("cancel-rejects-noncooperative-late-response") {
            let source = ControlledSource(), view = service("cancel", source: source)
            try await load(view, source: source, path: "/old.xml", title: "原节目")
            let old = view.document
            view.address = "http://127.0.0.1/slow.xml"; view.loadRemote()
            try await waitFor { await source.has("/slow.xml") }; view.cancel()
            await source.finish("/slow.xml", data: guide("迟到节目")); await Task.yield()
            try require(!view.isBusy && view.document == old && view.committedSource?.path == "/old.xml", "late canceled response")
            await source.cleanup()
        }
        await run("out-of-order-load-keeps-newest-generation") {
            let source = ControlledSource(), view = service("generation", source: source)
            view.address = "http://127.0.0.1/first.xml"; view.loadRemote()
            try await waitFor { await source.has("/first.xml") }
            try await load(view, source: source, path: "/second.xml", title: "最新节目")
            await source.finish("/first.xml", data: guide("过期节目")); await Task.yield()
            try require(view.document?.programmes["news"]?.first?.title == "最新节目" && view.committedSource?.path == "/second.xml", "stale commit")
            view.dismiss(); await source.cleanup()
        }
        await run("edited-source-invalidates-pending-load") {
            let source = ControlledSource(), view = service("edit", source: source)
            view.address = "http://127.0.0.1/pending.xml"; view.loadRemote()
            try await waitFor { await source.has("/pending.xml") }
            view.address = "http://127.0.0.1/other.xml"; view.addressEdited()
            await source.finish("/pending.xml", data: guide("旧地址")); await Task.yield()
            try require(view.document == nil && !view.isBusy, "edited source adopted old document")
            await source.cleanup()
        }
        await run("byte-limit-and-bad-local-keep-old-document") {
            let source = ControlledSource(); var limits = XMLTVLimits(); limits.maximumBytes = 1024
            let view = service("limit", source: source, limits: limits)
            try await load(view, source: source, path: "/bounded.xml", title: "原节目")
            let old = view.document
            view.address = "http://127.0.0.1/large.xml"; view.loadRemote()
            try await waitFor { await source.has("/large.xml") }; await source.finish("/large.xml", data: Data(repeating: 65, count: 1025))
            try await waitFor { !view.isBusy }; try require(view.document == old, "oversize replacement")
            let file = root.appendingPathComponent("bad.xml"); try Data("<tv><broken>".utf8).write(to: file)
            view.loadLocal(file); try await waitFor { !view.isBusy }
            try require(view.document == old && view.committedSource?.path == "/bounded.xml", "local invalid replacement")
            view.dismiss(); await source.cleanup()
        }
        await run("invalid-URL-never-starts-request") {
            let source = ControlledSource(), view = service("address", source: source)
            for address in ["ftp://127.0.0.1/guide.xml", "https://u:p@example.com/x", "https://example.com/%0Aheader"] {
                view.address = address; view.loadRemote(); try require(view.error != nil && !view.isBusy, "invalid address")
            }
            let count = await source.requestCount; try require(count == 0, "invalid URL requested")
        }
        await run("day-schedule-retains-inferred-cross-midnight") {
            let source = ControlledSource(), view = service("day", source: source)
            let data = Data("<tv><programme channel='news' start='20261003233000 +0000'><title>跨夜</title></programme><programme channel='news' start='20261004003000 +0000' stop='20261004010000 +0000'><title>次日</title></programme></tv>".utf8)
            view.address = "http://127.0.0.1/day.xml"; view.loadRemote()
            try await waitFor { await source.has("/day.xml") }; await source.finish("/day.xml", data: data)
            try await waitFor { !view.isBusy }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let date = ISO8601DateFormatter().date(from: "2026-10-04T00:00:00Z")!
            let schedule = view.daySchedule(view.channels[0], on: date, calendar: calendar)
            try require(schedule.count == 2 && schedule[0].programme.title == "跨夜" && schedule[0].endWasInferred, "cross-day inferred end")
            view.dismiss(); await source.cleanup()
        }
        await run("ImageIO-produces-real-bounded-thumbnail") {
            let transport = MockLogo(logoBody), directory = root.appendingPathComponent("image")
            let cache = EPGLogoCache(directory: directory, transport: transport)
            let value = try await cache.thumbnail(at: URL(string: "http://127.0.0.1/logo.png")!)
            try require(value.width == 128 && value.height == 32 && value.png.count > 0 && value.png.count <= 256 * 1024, "thumbnail dimensions")
            let files = try cacheFiles(directory); try require(files.count == 1, "real output")
        }
        await run("bad-image-http-failure-and-publication-retain-old-cache") {
            let transport = MockLogo(logoBody), directory = root.appendingPathComponent("preserve")
            let cache = EPGLogoCache(directory: directory, transport: transport)
            let url = URL(string: "http://127.0.0.1/old.png")!
            _ = try await cache.thumbnail(at: url)
            let target = try cacheFiles(directory)[0], oldSHA = try hash(Data(contentsOf: target))
            await transport.configure(body: Data("<html>not an image</html>".utf8))
            let bad = try await cache.thumbnail(at: url, refresh: true)
            try require(bad.usedPreviousCache && (try hash(Data(contentsOf: target))) == oldSHA, "bad image replaced old file")
            await transport.configure(body: logoBody, failure: true)
            let missing = try await cache.thumbnail(at: url, refresh: true)
            try require(missing.usedPreviousCache && (try hash(Data(contentsOf: target))) == oldSHA, "HTTP failure replaced old file")
            await transport.configure(failure: false)
            let failing = EPGLogoCache(directory: directory, transport: transport, publication: FailingPublication())
            let failed = try await failing.thumbnail(at: url, refresh: true)
            try require(failed.usedPreviousCache && (try hash(Data(contentsOf: target))) == oldSHA, "publication failure replaced old file")
        }
        await run("source-pixels-and-body-byte-limit-reject-candidate") {
            let transport = MockLogo(try png(width: 4097, height: 1)), directory = root.appendingPathComponent("bad-dim")
            let cache = EPGLogoCache(directory: directory, transport: transport)
            do { _ = try await cache.thumbnail(at: URL(string: "http://127.0.0.1/huge.png")!); throw CheckFailure.failed("oversize accepted") }
            catch EPGServiceError.imageTooLarge {}
            await transport.configure(body: Data(repeating: 0, count: 1024 * 1024 + 1))
            do { _ = try await cache.thumbnail(at: URL(string: "http://127.0.0.1/bytes.png")!); throw CheckFailure.failed("bytes accepted") }
            catch EPGServiceError.tooLarge {}
            try require(try cacheFiles(directory).isEmpty, "invalid candidate was written")
        }
        await run("concurrency-limit-and-waiter-cancel-release-permit") {
            let transport = MockLogo(logoBody, delay: 80_000_000), cache = EPGLogoCache(directory: root.appendingPathComponent("parallel"), transport: transport)
            var tasks: [Task<EPGLogoThumbnail, Error>] = []
            for index in 0..<10 { tasks.append(Task { try await cache.thumbnail(at: URL(string: "http://127.0.0.1/\(index).png")!) }) }
            tasks[5].cancel()
            for (index, task) in tasks.enumerated() {
                if index == 5 { do { _ = try await task.value; throw CheckFailure.failed("canceled waiter returned") } catch is CancellationError {} }
                else { _ = try await task.value }
            }
            let peak = await transport.peak, active = await transport.active
            try require(peak <= 2 && active == 0, "unbounded/logo permit leak")
        }
        await run("disk-LRU-protects-recent-cache-entry") {
            let transport = MockLogo(logoBody), directory = root.appendingPathComponent("lru"); var limits = EPGLogoCacheLimits(); limits.maximumDiskEntries = 2
            let cache = EPGLogoCache(directory: directory, transport: transport, limits: limits)
            let a = URL(string: "http://127.0.0.1/a.png")!, b = URL(string: "http://127.0.0.1/b.png")!, c = URL(string: "http://127.0.0.1/c.png")!
            _ = try await cache.thumbnail(at: a); try await Task.sleep(nanoseconds: 20_000_000)
            _ = try await cache.thumbnail(at: b); try await Task.sleep(nanoseconds: 20_000_000)
            _ = try await cache.thumbnail(at: a); try await Task.sleep(nanoseconds: 20_000_000)
            _ = try await cache.thumbnail(at: c)
            let names = Set(try cacheFiles(directory).map(\.lastPathComponent))
            try require(names.count == 2 && names.contains(hash(Data(a.absoluteString.utf8)) + ".png") && names.contains(hash(Data(c.absoluteString.utf8)) + ".png"), "LRU deleted recent entry")
        }
        await run("logo-opt-in-singleflight-and-disable-cancel") {
            let source = ControlledSource(), transport = MockLogo(logoBody, delay: 150_000_000), view = service("singleflight", source: source, logo: transport)
            view.setChannels([EPGChannelReference(mediaURL: URL(string: "http://127.0.0.1/a.mp4")!, tvgID: "news", displayName: "甲", logoURL: URL(string: "http://127.0.0.1/shared.png")!), EPGChannelReference(mediaURL: URL(string: "http://127.0.0.1/b.mp4")!, tvgID: "news", displayName: "乙", logoURL: URL(string: "http://127.0.0.1/shared.png")!)])
            await view.requestLogo(view.channels[0]); let before = await transport.requests; try require(before == 0, "default requested logo")
            view.setLogoEnabled(true)
            async let one: Void = view.requestLogo(view.channels[0]); async let two: Void = view.requestLogo(view.channels[1]); _ = await (one, two)
            let count = await transport.requests; try require(count == 1 && view.memoryImageCount == 1, "duplicate download or missing real image")
            view.refreshVisibleLogos(); let task = Task { await view.requestLogo(view.channels[0]) }
            try await waitFor { await transport.active > 0 }; view.setLogoEnabled(false); await task.value
            try require(view.logoPending == 0 && view.memoryImageCount == 0, "disabled logo published stale image")
            view.dismiss(); await source.cleanup()
        }
        await run("memory-cache-accounting-bounds") {
            let source = ControlledSource(), transport = MockLogo(try png(width: 128, height: 128, noise: true)), view = service("memory", source: source, logo: transport)
            let references = (0..<70).map { EPGChannelReference(mediaURL: URL(string: "http://127.0.0.1/\($0).mp4")!, tvgID: "news", displayName: "\($0)", logoURL: URL(string: "http://127.0.0.1/\($0).png")!) }
            view.setChannels(references); view.setLogoEnabled(true)
            for channel in references { await view.requestLogo(channel) }
            try require(view.memoryImageCount < 64 && view.memoryImageBytes <= 4 * 1024 * 1024 && view.logoPending == 0, "memory byte accounting unbounded")
            view.dismiss(); await source.cleanup()
        }
        await run("cache-directory-and-target-symlinks-fail-closed") {
            let real = root.appendingPathComponent("real"), alias = root.appendingPathComponent("alias")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
            let cache = EPGLogoCache(directory: alias, transport: MockLogo(logoBody))
            do { _ = try await cache.thumbnail(at: URL(string: "http://127.0.0.1/x.png")!); throw CheckFailure.failed("symlink directory accepted") }
            catch EPGServiceError.cacheFailure {}
            try require(try cacheFiles(real).isEmpty, "symlink directory written")
            let external = root.appendingPathComponent("external-protected.txt")
            try Data("保护外部文件".utf8).write(to: external)
            let before = try hash(Data(contentsOf: external)), targetURL = URL(string: "http://127.0.0.1/target.png")!
            let target = real.appendingPathComponent(hash(Data(targetURL.absoluteString.utf8)) + ".png")
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: external)
            let normal = EPGLogoCache(directory: real, transport: MockLogo(logoBody))
            do { _ = try await normal.thumbnail(at: targetURL); throw CheckFailure.failed("target symlink accepted") }
            catch EPGServiceError.cacheFailure {}
            try require(try hash(Data(contentsOf: external)) == before, "target symlink changed external bytes")
        }
        await run("preferences-roundtrip-no-credentials-and-URL-ID-identity") {
            let file = root.appendingPathComponent("preferences/epg.json"), store = EPGPreferencesStore(file: file)
            let a = EPGChannelReference(mediaURL: URL(string: "https://example.invalid/one.m3u8")!, tvgID: "a", displayName: "同名")
            let b = EPGChannelReference(mediaURL: a.mediaURL, tvgID: "b", displayName: "同名")
            try require(a.stableKey != b.stableKey, "tvg-id aliases merged")
            var candidate = EPGPreferences(); candidate.sourceAddress = "https://example.invalid/epg.xml"; candidate.logosEnabled = true
            candidate.manualMappings = [a.stableKey: "manual-a", b.stableKey: "manual-b"]
            try store.save(candidate)
            let loaded = try EPGPreferencesStore(file: file).load(); try require(loaded == candidate, "preference roundtrip")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            try require(Set(object.keys).isSubset(of: ["version", "sourceAddress", "manualMappings", "logosEnabled"]), "credential fields saved")
            let old = try hash(Data(contentsOf: file))
            candidate.sourceAddress = "https://user:password@example.invalid/epg.xml"
            do { try store.save(candidate); throw CheckFailure.failed("credential source saved") } catch EPGPreferencesError.invalidDocument {}
            try require(try hash(Data(contentsOf: file)) == old, "rejected preferences changed file")
        }
        await run("preferences-invalid-version-malformed-oversize-retain-memory") {
            let file = root.appendingPathComponent("invalid-preferences.json"), store = EPGPreferencesStore(file: file)
            var candidate = EPGPreferences(); candidate.sourceAddress = "https://example.invalid/valid.xml"; try store.save(candidate)
            for body in [Data("{".utf8), Data("{\"version\":2,\"manualMappings\":{},\"logosEnabled\":false}".utf8), Data("{\"version\":1,\"manualMappings\":{},\"logosEnabled\":false,\"password\":\"forbidden\"}".utf8), Data(repeating: 65, count: EPGPreferences.maximumBytes + 1)] {
                try body.write(to: file); let before = hash(body)
                do { _ = try store.load(); throw CheckFailure.failed("bad preferences loaded") } catch is EPGPreferencesError {}
                try require(store.value == candidate && (try hash(Data(contentsOf: file))) == before, "load changed active state or rewrote source")
            }
        }
        await run("preferences-publication-failure-protects-disk-and-memory") {
            let file = root.appendingPathComponent("protected-preferences.json"), publication = SwitchablePreferencesPublication()
            let store = EPGPreferencesStore(file: file, publication: publication)
            var candidate = EPGPreferences(); candidate.sourceAddress = "https://example.invalid/old.xml"; try store.save(candidate)
            let before = try hash(Data(contentsOf: file)); publication.fail(); var replacement = candidate; replacement.logosEnabled = true
            do { try store.save(replacement); throw CheckFailure.failed("publication failure ignored") } catch EPGPreferencesError.unavailable {}
            try require(store.value == candidate && (try hash(Data(contentsOf: file))) == before, "failed save replaced state")
        }
        await run("restored-preferences-never-start-source-or-logo-network") {
            let file = root.appendingPathComponent("restored.json"), store = EPGPreferencesStore(file: file)
            var candidate = EPGPreferences(); candidate.sourceAddress = "https://example.invalid/epg.xml"; candidate.logosEnabled = true; try store.save(candidate)
            let source = ControlledSource(), transport = MockLogo(logoBody)
            let channel = EPGChannelReference(mediaURL: URL(string: "http://127.0.0.1/media.mp4")!, tvgID: "news", displayName: "新闻", logoURL: URL(string: "http://127.0.0.1/logo.png")!)
            let view = EPGService(channels: [channel], transport: source, logoCache: EPGLogoCache(directory: root.appendingPathComponent("restored-logos"), transport: transport), preferences: store)
            await view.requestLogo(channel)
            let sources = await source.requestCount, logos = await transport.requests
            try require(sources == 0 && logos == 0 && view.logoEnabled && !view.logoRequestsAuthorized && view.document == nil, "restore triggered network")
            view.refreshVisibleLogos(); await view.requestLogo(channel)
            let after = await transport.requests; try require(after == 1 && view.logoRequestsAuthorized, "explicit action not authorized")
            view.dismiss(); await source.cleanup()
        }
        await run("service-preferences-failure-keeps-source-mapping-logo-choice") {
            let file = root.appendingPathComponent("service-prefs.json"), publication = SwitchablePreferencesPublication()
            let store = EPGPreferencesStore(file: file, publication: publication), source = ControlledSource()
            let channel = EPGChannelReference(mediaURL: URL(string: "http://127.0.0.1/media.mp4")!, tvgID: "news", displayName: "新闻")
            let view = EPGService(channels: [channel], transport: source, logoCache: EPGLogoCache(directory: root.appendingPathComponent("service-prefs-logos"), transport: MockLogo(logoBody)), preferences: store)
            try await load(view, source: source, path: "/committed.xml", title: "原节目")
            let before = try hash(Data(contentsOf: file)), old = view.document; publication.fail()
            view.setMapping(channel, channelID: "news"); view.setLogoEnabled(true)
            try require(view.mapping.explicitOverrides.isEmpty && !view.logoEnabled, "unpersisted setting applied")
            view.address = "http://127.0.0.1/new.xml"; view.loadRemote(); try await waitFor { await source.has("/new.xml") }
            await source.finish("/new.xml", data: guide("候选节目")); try await waitFor { !view.isBusy }
            try require(view.document == old && view.committedSource?.path == "/committed.xml" && (try hash(Data(contentsOf: file))) == before, "failed preference publication committed source")
            view.dismiss(); await source.cleanup()
        }
        await run("weak-registry-shutdown-deadline-is-truthful-and-drains-owned-jobs") {
            let source = ControlledSource(), view = service("shutdown", source: source)
            view.address = "http://127.0.0.1/noncooperative.xml"; view.loadRemote(); try await waitFor { await source.has("/noncooperative.xml") }
            let first = await EPGService.shutdownAll(timeout: 0.02)
            try require(!first && EPGService.hasActiveJobs && !view.isBusy, "shutdown claimed active task completed")
            await source.finish("/noncooperative.xml", data: guide("迟到"))
            let second = await EPGService.shutdownAll(timeout: 1)
            try require(second && !EPGService.hasActiveJobs && view.document == nil, "shutdown did not drain actual task")
            await source.cleanup()
        }
        await run("disk-byte-budget-evicts-before-publication") {
            let directory = root.appendingPathComponent("disk-bytes"), transport = MockLogo(try png(width: 128, height: 128, noise: true))
            var limits = EPGLogoCacheLimits(); limits.maximumDiskBytes = 256 * 1024; limits.maximumDiskEntries = 256
            let cache = EPGLogoCache(directory: directory, transport: transport, limits: limits)
            for index in 0..<10 { _ = try await cache.thumbnail(at: URL(string: "http://127.0.0.1/bytes-\(index).png")!) }
            let files = try cacheFiles(directory), bytes = try files.reduce(0) { $0 + (try Data(contentsOf: $1)).count }
            try require(files.count < 10 && bytes <= limits.maximumDiskBytes, "disk byte cap relied only on entry count")
        }
        await run("sensitive-query-source-is-session-only-normal-query-roundtrips") {
            let file = root.appendingPathComponent("query-preferences.json"), store = EPGPreferencesStore(file: file), source = ControlledSource()
            var initial = EPGPreferences(); initial.sourceAddress = "https://example.invalid/old.xml?v=2&lang=zh&date=20261004"; try store.save(initial)
            try require(try EPGPreferencesStore(file: file).load().sourceAddress == initial.sourceAddress, "normal query lost semantics")
            let before = try hash(Data(contentsOf: file))
            let view = EPGService(channels: [], transport: source, logoCache: EPGLogoCache(directory: root.appendingPathComponent("query-logos"), transport: MockLogo(logoBody)), preferences: store)
            view.address = "http://127.0.0.1/private.xml?username=test-account&password=session-secret"; view.loadRemote()
            try await waitFor { await source.has("/private.xml") }; await source.finish("/private.xml", data: guide("仅本次来源")); try await waitFor { !view.isBusy }
            try require(view.document?.programmes["news"]?.first?.title == "仅本次来源" && view.committedSource?.path == "/private.xml" && view.committedSource?.query?.contains("session-secret") == true, "session source identity lost")
            let data = try Data(contentsOf: file)
            try require(store.value == initial && hash(data) == before && !String(decoding: data, as: UTF8.self).contains("session-secret") && view.status.contains("地址未保存"), "sensitive query persisted or silent mismatch")
            let privateChannel = EPGChannelReference(mediaURL: URL(string: "https://example.invalid/account/secret/media.m3u8?password=mapping-secret")!, tvgID: "news", displayName: "新闻")
            var mapped = initial; mapped.manualMappings = [privateChannel.stableKey: "news"]; try store.save(mapped)
            let publicData = try String(contentsOf: file, encoding: .utf8)
            try require(!publicData.contains("mapping-secret") && !publicData.contains("account/secret") && privateChannel.stableKey.count == 64, "mapping persisted media credential identity")
            view.dismiss(); await source.cleanup()
        }
        await run("preferences-duplicate-decoded-keys-and-invalid-map-keys-rejected") {
            let file = root.appendingPathComponent("duplicate-preferences.json"), store = EPGPreferencesStore(file: file)
            let initial = EPGPreferences(); try store.save(initial)
            let key = String(repeating: "a", count: 64)
            let documents = [
                "{\"version\":1,\"version\":1,\"manualMappings\":{},\"logosEnabled\":false}",
                "{\"version\":1,\"manualMappings\":{\"\(key)\":\"one\",\"\(key)\":\"two\"},\"logosEnabled\":false}",
                "{\"version\":1,\"manualMappings\":{},\"logosEnabled\":false,\"logos\\u0045nabled\":true}",
                "{\"version\":1,\"manualMappings\":{\"not-a-sha-key\":\"one\"},\"logosEnabled\":false}"
            ]
            for text in documents {
                let data = Data(text.utf8); try data.write(to: file)
                do { _ = try store.load(); throw CheckFailure.failed("ambiguous preference document accepted") } catch EPGPreferencesError.invalidDocument {}
                try require(store.value == initial && (try hash(Data(contentsOf: file))) == hash(data), "duplicate rejection changed state or input file")
            }
        }
        let failed = results.filter { ($0["passed"] as? Bool) != true }.count
        let summary: [String: Any] = ["status": failed == 0 ? "passed" : "failed", "uniqueCases": results.count, "passed": results.count - failed, "failed": failed, "appGUIRun": false, "actualHTTPRun": false, "results": results]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("summary.json"))
        if failed > 0 { Darwin.exit(1) }
    }
}
