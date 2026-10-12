import Foundation
import CryptoKit
import Darwin

private enum ChannelCheckFailure: Error { case failed(String) }
private func verify(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try value() == false { throw ChannelCheckFailure.failed(message) }
}
@main
private struct ChannelChecks {
    static func main() throws {
        var failures = 0
        let base = URL(string: "https://example.invalid/list.m3u")!
        let media = URL(string: "https://example.invalid/channel.m3u8")!
        let scenarios: [(String, () throws -> Void)] = [
            ("tvg-id-exact-quoted-Unicode-comma-space-roundtrip", {
                for id in ["新闻台", "news\"double", "news'apostrophe", " leading and trailing ", "news,comma", ""] {
                    let input = ChannelDocument(channels: [MediaChannel(name: "新闻", url: media, tvgID: id)])
                    let text = try input.m3u8Text(), output = try ChannelDocument.parse(text, baseURL: base)
                    try verify(output.channels[0].tvgID == id && output.channels[0].url == media, "ID identity changed")
                    if !id.isEmpty {
                        let escaped = id.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
                        let xml = try XMLTVDocument.parse(Data("<tv><channel id=\"\(escaped)\"/></tv>".utf8))
                        let reference = EPGChannelReference(mediaURL: media, tvgID: output.channels[0].tvgID, displayName: "新闻")
                        try verify(EPGChannelMapping().resolve(reference, document: xml) == .matched(id, .tvgID), "XMLTV CDATA identity changed")
                    }
                }
            }),
            ("tvg-id-missing-PLS-and-EXTINF-state-reset", {
                let text = "#EXTM3U\n#EXTINF:-1 tvg-id='one',一\nhttps://example.invalid/1.mp4\n#EXTINF:-1,二\nhttps://example.invalid/2.mp4\n"
                let values = try ChannelDocument.parse(text, baseURL: base).channels
                try verify(values[0].tvgID == "one" && values[1].tvgID == nil, "ID leaked across rows")
                let pls = try ChannelDocument.parse("[playlist]\nFile1=https://example.invalid/one.mp4\nTitle1=频道\n", baseURL: URL(string: "https://example.invalid/list.pls")!)
                try verify(pls.channels[0].tvgID == nil, "PLS invented ID")
            }),
            ("legacy-Codable-without-tvg-id-remains-readable", {
                let id = UUID()
                let old: [String: Any] = ["id": id.uuidString, "name": "旧频道", "url": media.absoluteString, "group": "旧分组"]
                let decoded = try JSONDecoder().decode(MediaChannel.self, from: JSONSerialization.data(withJSONObject: old))
                try verify(decoded.id == id && decoded.url == media && decoded.tvgID == nil && decoded.logoURL == nil, "old channel broke")
                let new = MediaChannel(name: "新频道", url: media, tvgID: "quoted\"ID")
                try verify(try JSONDecoder().decode(MediaChannel.self, from: JSONEncoder().encode(new)) == new, "new saved data lost ID")
            }),
            ("same-media-URL-different-ID-mapping-isolation", {
                let first = EPGChannelReference(mediaURL: media, tvgID: "first", displayName: "同名")
                let second = EPGChannelReference(mediaURL: media, tvgID: "second", displayName: "同名")
                let document = try XMLTVDocument.parse(Data("<tv><channel id='first'/><channel id='second'/><channel id='manual'/></tv>".utf8))
                let mapping = EPGChannelMapping(explicitOverrides: [first.stableKey: "manual"])
                try verify(first.stableKey != second.stableKey && mapping.resolve(first, document: document) == .matched("manual", .manual) && mapping.resolve(second, document: document) == .matched("second", .tvgID), "aliases shared preference")
            }),
            ("unrepresentable-ID-export-failure-preserves-old-target", {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("epg-export-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let target = root.appendingPathComponent("保留频道.m3u8"), original = Data("保护旧频道列表".utf8)
                try original.write(to: target)
                for id in ["has\"both'quotes", "has\ncontrol", String(repeating: "x", count: 257)] {
                    do { try ChannelDocument(channels: [MediaChannel(name: "频道", url: media, tvgID: id)]).writeM3U8(to: target); throw ChannelCheckFailure.failed("unsafe ID written") }
                    catch ChannelDocumentError.unsafeMetadata {}
                    try verify(try Data(contentsOf: target) == original, "rejection changed target bytes")
                }
            }),
            ("duplicate-ID-attribute-rejected-and-parse-field-bounds", {
                for attribute in ["tvg-id='one' tvg-id='two'", "tvg-id='" + String(repeating: "x", count: 257) + "'"] {
                    do { _ = try ChannelDocument.parse("#EXTM3U\n#EXTINF:-1 \(attribute),频道\nhttps://example.invalid/one.mp4\n", baseURL: base); throw ChannelCheckFailure.failed("ambiguous or oversize ID accepted") }
                    catch ChannelDocumentError.unsafeMetadata {}
                }
            }),
            ("XMLTV-both-quote-ID-supported-without-M3U-fabrication", {
                let id = "both\"and'quotes", document = try XMLTVDocument.parse(Data("<tv><channel id=\"both&quot;and'quotes\"/></tv>".utf8))
                let reference = EPGChannelReference(mediaURL: media, tvgID: id, displayName: "频道")
                try verify(EPGChannelMapping().resolve(reference, document: document) == .matched(id, .tvgID), "XMLTV quote ID rejected")
                let value = MediaChannel(name: "频道", url: media, tvgID: id)
                try verify(try JSONDecoder().decode(MediaChannel.self, from: JSONEncoder().encode(value)).tvgID == id, "saved quote identity changed")
            })
        ]
        for (name, run) in scenarios {
            do { try run(); print("PASS epg-channel/" + name) }
            catch { failures += 1; print("FAIL epg-channel/" + name + ": " + String(describing: error)) }
        }
        print("EPG channel scenarios=\(scenarios.count) passed=\(scenarios.count - failures) failed=\(failures)")
        if failures > 0 { Darwin.exit(1) }
    }
}
