import AppKit
import Foundation
import CryptoKit
import Darwin

private enum HTTPCheckFailure: Error { case failed(String) }
private func requireHTTP(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try value() == false { throw HTTPCheckFailure.failed(message) }
}
private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

@MainActor
private func until(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(4)
    while !condition() {
        if Date() > deadline { throw HTTPCheckFailure.failed("deadline") }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

@main
@MainActor
private struct EPGHTTPChecks {
    static func main() async throws {
        guard CommandLine.arguments.count == 4, let origin = URL(string: CommandLine.arguments[1]) else { throw HTTPCheckFailure.failed("arguments") }
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let log = URL(fileURLWithPath: CommandLine.arguments[3])
        guard !FileManager.default.fileExists(atPath: root.path) else { throw HTTPCheckFailure.failed("new report directory") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func url(_ path: String) -> URL { origin.appendingPathComponent(path) }
        var results: [[String: Any]] = []
        func run(_ name: String, _ test: () async throws -> [String: Any]) async {
            do { let values = try await test(); results.append(["case": name, "passed": true, "observations": values]); print("PASS " + name) }
            catch { results.append(["case": name, "passed": false, "error": String(describing: error)]); print("FAIL " + name) }
        }
        func logs() throws -> [[String: Any]] {
            let text = try String(contentsOf: log, encoding: .utf8)
            return try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        }
        await run("production-HTTP-document-and-XMLTV-relative-logo") {
            let payload = try await ProductionEPGSourceTransport().document(at: url("guide.xml"))
            let document = try XMLTVDocument.parse(payload.data, sourceURL: payload.finalURL)
            try requireHTTP(document.channelIDs.count == 2 && document.programmes.values.reduce(0) { $0 + $1.count } == 3, "actual XMLTV parse")
            try requireHTTP(document.channels["news.a"]?.logoURL == url("logo.png"), "relative logo identity")
            return ["bytes": payload.data.count, "channels": 2, "programmes": 3]
        }
        await run("Basic-auth-is-session-only-and-explicit") {
            do { _ = try await ProductionEPGSourceTransport().document(at: url("auth/guide.xml")); throw HTTPCheckFailure.failed("anonymous auth accepted") }
            catch NetworkMediaError.httpStatus(401) {}
            let payload = try await ProductionEPGSourceTransport(username: "fixture", password: "test-only").document(at: url("auth/guide.xml"))
            try requireHTTP(try XMLTVDocument.parse(payload.data).channelIDs.count == 2, "authenticated source")
            let service = EPGService(channels: [], transport: ProductionEPGSourceTransport(username: "fixture", password: "test-only"), logoCache: EPGLogoCache(directory: root.appendingPathComponent("auth-logos")))
            service.address = url("auth/guide.xml").absoluteString; service.loadRemote(); try await until { !service.isBusy }
            let old = service.document; try requireHTTP(old != nil && service.error == nil, "service auth did not load")
            service.dismiss(); service.loadRemote(); try await until { !service.isBusy }
            try requireHTTP(service.error != nil && service.document == old, "closed session retained authorization")
            let requests = try logs().filter { ($0["kind"] as? String) == "request" && ($0["route"] as? String) == "/auth/guide.xml" }
            try requireHTTP((requests.last?["authorizationPresent"] as? Bool) == false, "dismissed service sent private auth header")
            service.dismiss()
            return ["anonymousHTTPStatus": 401, "authenticatedChannels": 2, "dismissClearedCredentialsAndProtectedOldDocument": true]
        }
        await run("source-credentials-block-cross-origin-redirect") {
            do {
                _ = try await ProductionEPGSourceTransport(username: "fixture", password: "test-only").document(at: url("redirect-logo"))
                throw HTTPCheckFailure.failed("credential redirect accepted")
            } catch NetworkMediaError.redirectBlocked {}
            return ["redirectBlocked": true]
        }
        await run("anonymous-logo-cross-origin-and-cookie-isolation") {
            let data = try await AnonymousEPGLogoTransport().logo(at: url("redirect-logo"), maximumBytes: 1024 * 1024)
            let thumb = try EPGLogoCodec.normalize(data, limits: .init())
            try requireHTTP(thumb.width == 128 && thumb.height == 32, "real redirect image")
            let requests = try logs().filter { ($0["kind"] as? String) == "request" && ($0["route"] as? String) == "/logo.png" }
            try requireHTTP(!requests.isEmpty && requests.allSatisfy { ($0["authorizationPresent"] as? Bool) == false && ($0["cookiePresent"] as? Bool) == false && ($0["proxyAuthorizationPresent"] as? Bool) == false }, "logo inherited credentials or cookie")
            return ["width": thumb.width, "height": thumb.height, "allLogoRequestsAnonymous": true]
        }
        await run("actual-declared-and-streamed-byte-limits") {
            for route in ["declared-oversize", "oversize"] {
                do { _ = try await AnonymousEPGLogoTransport().logo(at: url(route), maximumBytes: 1024 * 1024); throw HTTPCheckFailure.failed("oversize accepted") }
                catch EPGServiceError.tooLarge {}
            }
            return ["maximumBytes": 1024 * 1024, "declaredAndUnknownLengthRejected": true]
        }
        await run("actual-slow-source-cancel-bounded-and-recoverable") {
            let task = Task { try await ProductionEPGSourceTransport().document(at: url("slow-guide.xml")) }
            try await Task.sleep(nanoseconds: 120_000_000)
            let start = Date(); task.cancel()
            var completed = false
            do { _ = try await task.value; completed = true }
            catch { guard error is CancellationError || (error as NSError).code == NSURLErrorCancelled else { throw error } }
            try requireHTTP(!completed, "canceled source completed")
            let elapsed = Date().timeIntervalSince(start)
            try requireHTTP(elapsed < 2, "slow source cancel deadline")
            _ = try await ProductionEPGSourceTransport().document(at: url("guide.xml"))
            return ["cancellationSeconds": elapsed, "normalLoadRecovered": true]
        }
        await run("actual-slow-logo-cancel-bounded") {
            let task = Task { try await AnonymousEPGLogoTransport().logo(at: url("slow-logo.png"), maximumBytes: 1024 * 1024) }
            try await Task.sleep(nanoseconds: 120_000_000)
            let start = Date(); task.cancel()
            var completed = false
            do { _ = try await task.value; completed = true }
            catch { guard error is CancellationError || (error as NSError).code == NSURLErrorCancelled else { throw error } }
            try requireHTTP(!completed, "canceled logo completed")
            let elapsed = Date().timeIntervalSince(start)
            try requireHTTP(elapsed < 2, "slow logo cancel deadline")
            return ["cancellationSeconds": elapsed]
        }
        await run("actual-cache-bad-image-404-and-invalid-dimensions-protection") {
            let directory = root.appendingPathComponent("logos"), cache = EPGLogoCache(directory: directory)
            let targetURL = url("logo.png"), thumbnail = try await cache.thumbnail(at: targetURL)
            let target = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "png" }!
            let before = try sha(Data(contentsOf: target))
            for route in ["html-as-image", "corrupt.png", "too-wide.png", "missing.png"] {
                do { _ = try await cache.thumbnail(at: url(route)); throw HTTPCheckFailure.failed("invalid candidate accepted") }
                catch let error as EPGServiceError {
                    switch error { case .invalidImage, .imageTooLarge, .httpStatus(404): break; default: throw error }
                }
            }
            try requireHTTP(try sha(Data(contentsOf: target)) == before, "unrelated failed candidate changed successful cache")
            return ["successfulTargetSHA256": before, "successfulThumbnailWidth": thumbnail.width, "successfulThumbnailHeight": thumbnail.height, "preservedTargetAfterFourInvalidCandidates": true]
        }
        await run("actual-service-generation-cancel-preserves-old-source") {
            let cache = EPGLogoCache(directory: root.appendingPathComponent("service-logos"))
            let channel = EPGChannelReference(mediaURL: url("media-a.mp4"), tvgID: "news.a", displayName: "同名频道")
            let service = EPGService(channels: [channel], transport: ProductionEPGSourceTransport(), logoCache: cache)
            service.address = url("guide.xml").absoluteString; service.loadRemote(); try await until { !service.isBusy }
            let old = service.document; try requireHTTP(old != nil, "actual initial document")
            service.address = url("slow-guide.xml").absoluteString; service.loadRemote()
            try await Task.sleep(nanoseconds: 120_000_000); service.cancel()
            service.address = url("replacement.xml").absoluteString; service.loadRemote(); try await until { !service.isBusy }
            try requireHTTP(service.document?.programmes["news.a"]?.first?.title == "新来源的中文节目" && service.committedSource == url("replacement.xml"), "actual newest source identity")
            service.dismiss(); try await Task.sleep(nanoseconds: 400_000_000)
            try requireHTTP(service.document?.programmes["news.a"]?.first?.title == "新来源的中文节目", "late response overwrote source")
            return ["newestDocumentCommitted": true, "canceledOldRequestCouldNotOverwrite": true]
        }
        await run("actual-cancel-observed-by-server-and-no-private-header-values-logged") {
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline {
                let routes = Set(try logs().filter { ($0["kind"] as? String) == "disconnected" }.compactMap { $0["route"] as? String })
                if routes.contains("/slow-guide.xml") && routes.contains("/slow-logo.png") { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let records = try logs(), routes = Set(records.filter { ($0["kind"] as? String) == "disconnected" }.compactMap { $0["route"] as? String })
            try requireHTTP(routes.contains("/slow-guide.xml") && routes.contains("/slow-logo.png"), "server did not observe cancellation disconnect")
            let text = try String(contentsOf: log, encoding: .utf8)
            try requireHTTP(!text.contains("Basic ") && !text.contains("test-only"), "raw private header value in log")
            return ["sourceAndLogoServerDisconnects": true, "onlyHeaderPresenceBooleans": true]
        }
        await run("actual-same-URL-refresh-failures-preserve-target-bytes") {
            let directory = root.appendingPathComponent("refresh-logos"), cache = EPGLogoCache(directory: directory), targetURL = url("mutable-logo.png")
            _ = try await cache.thumbnail(at: targetURL)
            let target = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "png" }!
            let before = try sha(Data(contentsOf: target))
            for mode in ["bad", "missing"] {
                _ = try await ProductionEPGSourceTransport().document(at: url("control/logo-" + mode))
                let previous = try await cache.thumbnail(at: targetURL, refresh: true)
                try requireHTTP(previous.usedPreviousCache && (try sha(Data(contentsOf: target))) == before, "same-URL failed refresh overwrote file")
            }
            _ = try await ProductionEPGSourceTransport().document(at: url("control/logo-good"))
            let restored = try await cache.thumbnail(at: targetURL, refresh: true)
            try requireHTTP(!restored.usedPreviousCache && restored.width == 128, "refresh not recoverable")
            return ["sameTargetSHA256BeforeAfterFailures": before, "HTMLAnd404KeptOriginalTarget": true, "SuccessfulRefreshRecovered": true]
        }
        let failed = results.filter { ($0["passed"] as? Bool) != true }.count
        let summary: [String: Any] = ["status": failed == 0 ? "passed" : "failed", "uniqueScenarioGroups": results.count, "passed": results.count - failed, "failed": failed, "actualLoopbackHTTPRun": true, "actualAppGUIRun": false, "results": results]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("summary.json"))
        if failed > 0 { Darwin.exit(1) }
    }
}
