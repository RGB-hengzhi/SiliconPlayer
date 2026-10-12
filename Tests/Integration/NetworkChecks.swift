import Foundation
import Darwin
import PlayerCore

@main struct NetworkChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 2 else { throw NetworkMediaError.invalidResponse }
        let port = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = URL(string: "http://127.0.0.1:" + port + "/")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("network-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let m3uURL = origin.appendingPathComponent("channels.m3u8")
        let m3uClient = try NetworkHTTPClient(origin: origin)
        let (m3uData, m3uBase) = try await m3uClient.document(at: m3uURL)
        let channels = try ChannelDocument.parse(data: m3uData, baseURL: m3uBase)
        precondition(channels.channels.count == 2)
        precondition(channels.channels[0].name == "电影,频道" && channels.channels[0].group == "中文频道")
        precondition(channels.channels[0].logoURL?.path == "/logo.png")
        precondition(channels.channels[0].url.path == "/dav/中文 影片.mp4")
        let roundtrip = try ChannelDocument.parse(channels.m3u8Text(), baseURL: m3uURL)
        precondition(roundtrip.channels.map(\.name) == channels.channels.map(\.name))
        precondition(roundtrip.channels.map(\.group) == ["中文频道", "*"])
        let plsClient = try NetworkHTTPClient(origin: origin)
        let (plsData, plsURL) = try await plsClient.document(at: origin.appendingPathComponent("channels.pls"))
        let pls = try ChannelDocument.parse(data: plsData, baseURL: plsURL)
        precondition(pls.channels.map(\.name) == ["First", "Second"])
        print("PASS HTTP M3U/PLS, Chinese/relative URLs, names/groups/logo metadata, export roundtrip")

        let xmlClient = try NetworkHTTPClient(origin: origin, username: "fixture", password: "fixture")
        let davURL = origin.appendingPathComponent("dav", isDirectory: true)
        let (xmlData, xmlBase) = try await xmlClient.document(at: davURL, method: "PROPFIND", body: Data("<propfind xmlns=\"DAV:\"><allprop/></propfind>".utf8))
        let listing = try WebDAVDocumentParser.parse(xmlData, baseURL: xmlBase)
        precondition(listing.resources.count == 2 && listing.resources[0].isCollection)
        let file = listing.resources[1]
        precondition(file.url.path == "/dav/中文 影片.mp4" && file.name == "Chinese video")
        precondition(file.size == 18 && file.modifiedAt != nil && !file.isCollection)
        print("PASS real Depth:1 PROPFIND, DAV namespace, successful propstat, folder/file, size/date, href resolution")

        let downloadClient = try NetworkHTTPClient(origin: davURL, username: "fixture", password: "fixture", resourceTimeout: 24 * 3600)
        let downloaded = directory.appendingPathComponent("downloaded.mp4")
        try await downloadClient.download(at: file.url, to: downloaded)
        let downloadedData = try Data(contentsOf: downloaded)
        precondition(downloadedData == Data("fixture-media-data".utf8))
        print("PASS authenticated disk-backed download")

        let denied = try NetworkHTTPClient(origin: origin)
        do { _ = try await denied.document(at: origin.appendingPathComponent("unauthorized")); preconditionFailure("accepted 401") }
        catch NetworkMediaError.httpStatus(let code) { precondition(code == 401) }
        let redirected = try NetworkHTTPClient(origin: origin, username: "fixture", password: "fixture")
        do { _ = try await redirected.document(at: origin.appendingPathComponent("redirect")); preconditionFailure("forwarded credentials") }
        catch NetworkMediaError.redirectBlocked {}
        let large = try NetworkHTTPClient(origin: origin)
        do { _ = try await large.document(at: origin.appendingPathComponent("large")); preconditionFailure("accepted oversized list") }
        catch NetworkMediaError.documentTooLarge {}
        for invalid in ["ftp://example.com/file", "https://user:secret@example.com/media"] {
            do { _ = try HTTPMediaAddress.validated(invalid); preconditionFailure("accepted unsafe input") }
            catch is NetworkMediaError {}
        }
        print("PASS 401, credential redirect rejection, bounded list and address validation")

        let slow = try NetworkHTTPClient(origin: origin)
        let canceled = Task { try await slow.document(at: origin.appendingPathComponent("slow")) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let cancelStart = Date()
        canceled.cancel()
        do { _ = try await canceled.value; preconditionFailure("cancel did not stop request") }
        catch { precondition(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        precondition(Date().timeIntervalSince(cancelStart) < 2)
        let slowDownload = try NetworkHTTPClient(origin: origin, resourceTimeout: 24 * 3600)
        let canceledFile = directory.appendingPathComponent("canceled.mp4")
        let canceledDownload = Task { try await slowDownload.download(at: origin.appendingPathComponent("download-slow"), to: canceledFile) }
        try await Task.sleep(nanoseconds: 100_000_000)
        canceledDownload.cancel()
        do { try await canceledDownload.value; preconditionFailure("download cancel did not stop") }
        catch { precondition(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        precondition(!FileManager.default.fileExists(atPath: canceledFile.path))
        print("PASS real request/download cancellation and destination cleanup")

        let metricsClient = try NetworkHTTPClient(origin: origin)
        let (metricsData, _) = try await metricsClient.document(at: origin.appendingPathComponent("metrics"))
        let metrics = try JSONSerialization.jsonObject(with: metricsData) as! [String: Int]
        precondition(metrics["/logo.png"] == nil && metrics["/redirect-target"] == nil)
        print("PASS logo never requested and credential redirect target never contacted")

        let idleTimeout = Task {
            let client = try NetworkHTTPClient(origin: origin)
            return try await client.document(at: origin.appendingPathComponent("timeout"))
        }
        let longClient = try NetworkHTTPClient(origin: origin, resourceTimeout: 24 * 3600)
        let longFile = directory.appendingPathComponent("long-download.mp4")
        let longStart = Date()
        try await longClient.download(at: origin.appendingPathComponent("download-long"), to: longFile)
        let received = try Data(contentsOf: longFile)
        precondition(received.count == 28 && Date().timeIntervalSince(longStart) > 25)
        print("PASS continuous download exceeds 25 seconds while resource timeout permits completion")
        do { _ = try await idleTimeout.value; preconditionFailure("idle request did not time out") }
        catch { precondition((error as? URLError)?.code == .timedOut) }
        print("PASS real 25-second directory request timeout")
        print("8 real network test groups passed")
    }
}
