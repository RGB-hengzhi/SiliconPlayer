import Foundation
import Darwin
import PlayerCore

private struct NetworkCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main struct NetworkBoundaryChecks {
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NetworkCheckFailure(description: message) }
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 2 else { throw NetworkCheckFailure(description: "expected port file") }
        let port = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = URL(string: "http://127.0.0.1:" + port + "/")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("network-boundaries-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Data("<propfind xmlns=\"DAV:\"><allprop/></propfind>".utf8)
        var failures = 0
        let cases: [(String, () async throws -> Void)] = [
            ("same-origin PROPFIND redirect retains method, body, Depth and authentication", {
                let client = try NetworkHTTPClient(origin: origin, username: "fixture", password: "fixture")
                let (data, base) = try await client.document(at: origin.appendingPathComponent("dav-redirect", isDirectory: true), method: "PROPFIND", body: body)
                let listing = try WebDAVDocumentParser.parse(data, baseURL: base)
                try expect(base.absoluteString.hasSuffix("/dav-valid/") && listing.resources.count == 1, "redirect lost method/body or response")
                try expect(listing.resources[0].url.path == "/dav-valid/file.mp4" && listing.resources[0].size == 19, "redirect base was not used")
            }),
            ("WebDAV CDATA href and successful properties resolve as ordinary XML text", {
                let client = try NetworkHTTPClient(origin: origin, username: "fixture", password: "fixture")
                let (data, base) = try await client.document(at: origin.appendingPathComponent("dav-cdata", isDirectory: true), method: "PROPFIND", body: body)
                let listing = try WebDAVDocumentParser.parse(data, baseURL: base)
                try expect(listing.resources.count == 1, "valid CDATA response was dropped")
                try expect(listing.resources[0].url.path == "/dav-cdata/中文 影片.mp4" && listing.resources[0].name == "中文影片" && listing.resources[0].size == 19, "CDATA href/properties lost")
            }),
            ("WebDAV 403, 404 and 405 directory failures remain HTTP errors", {
                for status in [403, 404, 405] {
                    let client = try NetworkHTTPClient(origin: origin, username: "fixture", password: "fixture")
                    do {
                        _ = try await client.document(at: origin.appendingPathComponent("dav-\(status)", isDirectory: true), method: "PROPFIND", body: body)
                        throw NetworkCheckFailure(description: "accepted directory HTTP \(status)")
                    } catch NetworkMediaError.httpStatus(let actual) { try expect(actual == status, "wrong HTTP status") }
                }
            }),
            ("malformed DAV response throws instead of creating an empty successful directory", {
                let client = try NetworkHTTPClient(origin: origin, username: "fixture", password: "fixture")
                let (data, base) = try await client.document(at: origin.appendingPathComponent("dav-malformed", isDirectory: true), method: "PROPFIND", body: body)
                do { _ = try WebDAVDocumentParser.parse(data, baseURL: base); throw NetworkCheckFailure(description: "accepted malformed XML") }
                catch NetworkMediaError.invalidDAV {}
            }),
            ("DAV external entity declarations cannot cause an additional HTTP request", {
                let client = try NetworkHTTPClient(origin: origin, username: "fixture", password: "fixture")
                let (data, base) = try await client.document(at: origin.appendingPathComponent("dav-entity", isDirectory: true), method: "PROPFIND", body: body)
                do { _ = try WebDAVDocumentParser.parse(data, baseURL: base) } catch NetworkMediaError.invalidDAV {}
                let metricsClient = try NetworkHTTPClient(origin: origin)
                let (metrics, _) = try await metricsClient.document(at: origin.appendingPathComponent("metrics"))
                let rows = try JSONSerialization.jsonObject(with: metrics) as! [[String: Any]]
                try expect(!rows.contains(where: { $0["path"] as? String == "/external-entity" }), "XML parser fetched an external entity")
            }),
            ("same-origin media redirect preserves credentials without persisting server cookies", {
                let client = try NetworkHTTPClient(origin: origin, username: "fixture", password: "fixture", resourceTimeout: 24 * 3600)
                let file = directory.appendingPathComponent("redirected.mp4")
                try await client.download(at: origin.appendingPathComponent("same-origin-redirect"), to: file)
                try expect(try Data(contentsOf: file) == Data("boundary-media-data".utf8), "redirected download corrupted")
                let metricsClient = try NetworkHTTPClient(origin: origin)
                let (metrics, _) = try await metricsClient.document(at: origin.appendingPathComponent("metrics"))
                let rows = try JSONSerialization.jsonObject(with: metrics) as! [[String: Any]]
                let final = rows.filter { $0["path"] as? String == "/plain-media" }.last!
                try expect(final["authorized"] as? Bool == true && final["cookie_present"] as? Bool == false, "redirect auth or cookie isolation failed")
            }),
            ("downloads without Content-Length complete with unknown-size progress", {
                var unknownProgress = false
                var progressCallbacks = 0
                let client = try NetworkHTTPClient(origin: origin, resourceTimeout: 24 * 3600, onProgress: { fraction in
                    progressCallbacks += 1
                    if fraction == nil { unknownProgress = true }
                })
                let file = directory.appendingPathComponent("unknown.mp4")
                try await client.download(at: origin.appendingPathComponent("unknown-size"), to: file)
                try await Task.sleep(nanoseconds: 50_000_000)
                let size = try Data(contentsOf: file).count
                try expect(size == 16 * 65536, "unknown-length download bytes=\(size)")
                print("DETAIL unknown-length progress callbacks=\(progressCallbacks), indeterminate callback=\(unknownProgress); UI can remain indeterminate without a callback")
            }),
            ("known-size download delivers live percentage progress before completion", {
                var progress: [Double] = []
                let client = try NetworkHTTPClient(origin: origin, resourceTimeout: 24 * 3600, onProgress: { fraction in
                    if let fraction { progress.append(fraction) }
                })
                let file = directory.appendingPathComponent("known.mp4")
                try await client.download(at: origin.appendingPathComponent("known-size"), to: file)
                try await Task.sleep(nanoseconds: 50_000_000)
                try expect(try Data(contentsOf: file).count == 16 * 65536, "known-length download incomplete")
                try expect(progress.contains(where: { $0 > 0 && $0 < 1 }) && progress.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }), "known-size progress callbacks=\(progress.count); no live percentage delivered")
            }),
            ("a new operation cannot reuse authentication from a previous protected download", {
                let first = try NetworkHTTPClient(origin: origin, username: "fixture", password: "fixture")
                let file = directory.appendingPathComponent("protected.mp4")
                try await first.download(at: origin.appendingPathComponent("protected-media"), to: file)
                try expect(try Data(contentsOf: file) == Data("boundary-protected-media".utf8), "protected fixture download failed")
                let second = try NetworkHTTPClient(origin: origin)
                do { _ = try await second.document(at: origin.appendingPathComponent("protected-media")); throw NetworkCheckFailure(description: "new operation reused prior authentication") }
                catch NetworkMediaError.httpStatus(let code) { try expect(code == 401, "new operation failed with a different error") }
            }),
            ("truncated downloads fail without leaving a destination; existing files stay untouched", {
                let client = try NetworkHTTPClient(origin: origin, resourceTimeout: 25)
                let file = directory.appendingPathComponent("truncated.mp4")
                var failed = false
                do { try await client.download(at: origin.appendingPathComponent("truncated-download"), to: file) } catch { failed = true }
                try expect(failed && !FileManager.default.fileExists(atPath: file.path), "partial video was committed")
                let previous = Data("keep existing media".utf8)
                try previous.write(to: file)
                let second = try NetworkHTTPClient(origin: origin)
                failed = false
                do { try await second.download(at: origin.appendingPathComponent("plain-media"), to: file) } catch { failed = true }
                try expect(failed && (try Data(contentsOf: file)) == previous, "existing destination was overwritten")
            }),
            ("60 cancellations before start, after actor handoff and during transfer do not leak destinations", {
                func retainedFiles() throws -> Set<String> {
                    Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
                        .filter { $0.hasPrefix("SiliconPlayerNetwork-") && $0.hasSuffix(".download") })
                }
                let previousRetained = try retainedFiles()
                for iteration in 0..<60 {
                    let client = try NetworkHTTPClient(origin: origin, resourceTimeout: 25)
                    let destination = directory.appendingPathComponent("cancel-race-\(iteration).mp4")
                    let task = Task { try await client.download(at: origin.appendingPathComponent("known-size"), to: destination) }
                    if iteration % 3 == 1 { await Task.yield() }
                    if iteration % 3 == 2 { try await Task.sleep(nanoseconds: 1_000_000) }
                    task.cancel()
                    do {
                        try await task.value
                        throw NetworkCheckFailure(description: "cancelled transfer \(iteration) returned success")
                    } catch is CancellationError {} catch let error as URLError where error.code == .cancelled {}
                    try expect(!FileManager.default.fileExists(atPath: destination.path), "cancelled transfer \(iteration) leaked destination")
                }
                try await Task.sleep(nanoseconds: 200_000_000)
                try expect(try retainedFiles() == previousRetained, "cancel races leaked a retained download file")
            }),
            ("90 fast completion/cancellation races leave only complete accepted files and no retained temporary bodies", {
                func retainedFiles() throws -> Set<String> {
                    Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
                        .filter { $0.hasPrefix("SiliconPlayerNetwork-") && $0.hasSuffix(".download") })
                }
                let previousRetained = try retainedFiles()
                var completed = 0
                var canceled = 0
                for iteration in 0..<90 {
                    let client = try NetworkHTTPClient(origin: origin)
                    let destination = directory.appendingPathComponent("completion-race-\(iteration).mp4")
                    let task = Task { try await client.download(at: origin.appendingPathComponent("plain-media"), to: destination) }
                    if iteration % 3 == 1 { await Task.yield() }
                    if iteration % 3 == 2 { try await Task.sleep(nanoseconds: 1_000_000) }
                    task.cancel()
                    do {
                        try await task.value
                        completed += 1
                        try expect(try Data(contentsOf: destination) == Data("boundary-media-data".utf8), "accepted race file was partial")
                    } catch is CancellationError {
                        canceled += 1
                        try expect(!FileManager.default.fileExists(atPath: destination.path), "canceled completion race kept destination")
                    } catch let error as URLError where error.code == .cancelled {
                        canceled += 1
                        try expect(!FileManager.default.fileExists(atPath: destination.path), "URL-canceled completion race kept destination")
                    }
                }
                try await Task.sleep(nanoseconds: 300_000_000)
                try expect(try retainedFiles() == previousRetained, "fast completion races leaked a retained download file")
                print("DETAIL fast races: accepted complete=\(completed), canceled cleanly=\(canceled)")
            }),
            ("chunked documents exceed the 8 MiB bound even without a length header", {
                let client = try NetworkHTTPClient(origin: origin)
                do { _ = try await client.document(at: origin.appendingPathComponent("chunked-large")); throw NetworkCheckFailure(description: "unbounded chunked document accepted") }
                catch NetworkMediaError.documentTooLarge {}
            })
        ]
        for (name, body) in cases {
            do { try await body(); print("PASS " + name) }
            catch { failures += 1; print("FAIL " + name + ": " + String(describing: error)) }
        }
        print("\(cases.count - failures)/\(cases.count) network boundary groups passed; loopback server and disk downloads")
        if failures > 0 { exit(1) }
    }
}
