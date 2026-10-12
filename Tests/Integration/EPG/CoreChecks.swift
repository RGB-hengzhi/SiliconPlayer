import Foundation

private enum TestFailure: Error { case failed(String) }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw TestFailure.failed(message) }
}
private func data(_ text: String) -> Data { Data(text.utf8) }
private func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
private func programme(_ channel: String = "one", _ start: String = "20261004100000 +0000", _ stop: String? = "20261004110000 +0000", _ title: String = "中文节目") -> String {
    "<programme channel=\"\(channel)\" start=\"\(start)\"" + (stop.map { " stop=\"\($0)\"" } ?? "") + "><title>\(title)</title></programme>"
}
private func rejected(_ text: String, error expected: XMLTVError? = nil, limits: XMLTVLimits = .init()) throws {
    do { _ = try XMLTVDocument.parse(data(text), limits: limits); throw TestFailure.failed("Invalid document accepted") }
    catch let error as XMLTVError { if let expected { try require(error == expected, "Wrong rejection: \(error)") } }
}

@main
struct EPGTests {
    static func main() {
        var failures = 0
        let scenarios: [(String, () throws -> Void)] = [
            ("stable-id-and-explicit-mapping", {
                let document = try XMLTVDocument.parse(data("<tv><channel id=\"one\"><display-name>重名频道</display-name></channel><channel id=\"two\"><display-name>重名频道</display-name></channel></tv>"))
                let first = EPGChannelReference(mediaURL: URL(string: "https://example.invalid/one.m3u8")!, tvgID: "one", displayName: "重名频道")
                let missing = EPGChannelReference(mediaURL: URL(string: "https://example.invalid/missing.m3u8")!, tvgID: nil, displayName: "重名频道")
                let plain = EPGChannelMapping()
                try require(plain.resolve(first, document: document) == .matched("one", .tvgID), "Exact tvg-id lost")
                try require(plain.resolve(missing, document: document) == .unmapped, "Name incorrectly inferred a channel")
                let manual = EPGChannelMapping(explicitOverrides: [first.stableKey: "two"])
                try require(manual.resolve(first, document: document) == .matched("two", .manual), "Explicit mapping ignored")
                let unavailable = EPGChannelMapping(explicitOverrides: [first.stableKey: "removed"])
                try require(unavailable.resolve(first, document: document) == .unavailable("removed"), "Unavailable manual choice silently fell back")
                let caseSensitive = EPGChannelReference(mediaURL: first.mediaURL, tvgID: "ONE", displayName: "重名频道")
                try require(first.stableKey != caseSensitive.stableKey, "same URL with distinct tvg-id needs separate identity")
                try require(plain.resolve(caseSensitive, document: document) == .unavailable("ONE"), "ID case incorrectly collapsed")
            }),
            ("programmes-without-channel-elements", {
                let document = try XMLTVDocument.parse(data("<tv>" + programme() + "</tv>"))
                try require(document.channels.isEmpty && document.channelIDs == ["one"], "Optional channel metadata became required")
                let reference = EPGChannelReference(mediaURL: URL(string: "https://example.invalid/stream")!, tvgID: "one", displayName: "本地显示名")
                try require(EPGChannelMapping().resolve(reference, document: document) == .matched("one", .tvgID), "Programme-only ID did not map")
            }),
            ("utc-offset-cross-day-and-dst", {
                let text = "<tv>" + programme("utc", "20261004004500", "20261004010000")
                    + programme("nepal", "20261004004500 +0545", "20261004010000 +0545")
                    + programme("first-hour", "20261025023000 +0200", "20261025030000 +0200")
                    + programme("second-hour", "20261025023000 +0100", "20261025030000 +0100") + "</tv>"
                let document = try XMLTVDocument.parse(data(text))
                try require(document.programmes["utc"]!.first!.start == instant("2026-10-04T00:45:00Z"), "Absent timezone was not UTC")
                try require(document.programmes["nepal"]!.first!.start == instant("2026-10-03T19:00:00Z"), "Quarter-hour offset or previous day incorrect")
                let first = document.programmes["first-hour"]!.first!.start
                let second = document.programmes["second-hour"]!.first!.start
                try require(first == instant("2026-10-25T00:30:00Z") && second.timeIntervalSince(first) == 3600, "DST repeated local hour collapsed")
            }),
            ("missing-end-equal-starts-overlap-and-half-open", {
                let text = "<tv>" + programme("one", "20261004100000", nil, "推断结束")
                    + programme("one", "20261004100000", "20261004120000", "重叠节目")
                    + programme("one", "20261004110000", nil, "结束未知") + "</tv>"
                let document = try XMLTVDocument.parse(data(text))
                let before = document.nowAndNext(channelID: "one", at: instant("2026-10-04T10:30:00Z"))
                try require(before.current.map(\.programme.title) == ["推断结束", "重叠节目"], "Same-start programme overwritten")
                try require(before.current[0].endWasInferred && before.current[0].end == instant("2026-10-04T11:00:00Z"), "Missing stop incorrectly inferred")
                let boundary = document.nowAndNext(channelID: "one", at: instant("2026-10-04T11:00:00Z"))
                try require(boundary.current.map(\.programme.title) == ["重叠节目"], "End boundary was inclusive or unknown end claimed current")
                try require(boundary.latestWithUnknownEnd.map(\.title) == ["结束未知"], "Unknown end not distinguished")
                let prior = document.nowAndNext(channelID: "one", at: instant("2026-10-04T09:30:00Z"))
                try require(prior.next.map(\.title) == ["推断结束", "重叠节目"], "Next clumped programmes discarded")
            }),
            ("required-fields-invalid-end-and-precision", {
                for text in ["<tv><programme channel=\"one\"><title>x</title></programme></tv>",
                             "<tv><programme start=\"20261004100000\"><title>x</title></programme></tv>",
                             "<tv><programme channel=\"one\" start=\"20261004100000\"><title> </title></programme></tv>",
                             "<tv>" + programme("one", "20261004100000", "20261004095900") + "</tv>",
                             "<tv>" + programme("one", "202610", nil) + "</tv>"] {
                    try rejected(text, error: .invalidProgramme(1))
                }
            }),
            ("utf8-utf16-cdata-and-relative-logo", {
                let text = "<tv><channel id=\"中文\"><display-name><![CDATA[中文 & 频道]]></display-name><icon src=\"../logos/one.png\"/></channel>" + programme("中文", "20261004100000", nil, "节目 &amp; 音乐") + "</tv>"
                let origin = URL(string: "https://example.invalid/epg/today.xml")!
                let utf8 = try XMLTVDocument.parse(data(text), sourceURL: origin)
                var utf16 = Data([0xff, 0xfe]); utf16.append(text.data(using: .utf16LittleEndian)!)
                let decoded = try XMLTVDocument.parse(utf16, sourceURL: origin)
                try require(utf8 == decoded, "UTF-16 changed document meaning")
                try require(utf8.channels["中文"]!.displayNames == ["中文 & 频道"], "CDATA text lost")
                try require(utf8.channels["中文"]!.logoURL?.absoluteString == "https://example.invalid/logos/one.png", "Relative logo metadata incorrectly resolved")
                try require(utf8.programmes["中文"]!.first!.title == "节目 & 音乐", "Predefined XML entity incorrectly rejected")
            }),
            ("duplicate-channel-and-foreign-namespace", {
                try rejected("<tv><channel id=\"one\"/><channel id=\"one\"/></tv>", error: .duplicateChannel)
                try rejected("<tv><x:channel xmlns:x=\"urn:unrelated\" id=\"one\"/></tv>")
                let spaced = try XMLTVDocument.parse(data("<tv><channel id=\" one\"/></tv>"))
                try require(spaced.channelIDs.contains(" one"), "CDATA identity was silently trimmed")
            }),
            ("dtd-and-entity-declarations-rejected", {
                let documents = ["<!DOCTYPE tv SYSTEM \"https://example.invalid/xmltv.dtd\"><tv/>",
                                 "<!DOCTYPE tv [<!ENTITY external SYSTEM \"file:///nonexistent-owned-test\">]><tv/>",
                                 "<!DOCTYPE tv [<!ENTITY a \"expanded\">]><tv/>" ]
                for text in documents {
                    try rejected(text, error: .forbiddenDeclaration)
                    var utf16 = Data([0xfe, 0xff]); utf16.append(text.data(using: .utf16BigEndian)!)
                    do { _ = try XMLTVDocument.parse(utf16); throw TestFailure.failed("UTF16 DTD accepted") }
                    catch let error as XMLTVError { try require(error == .forbiddenDeclaration, "UTF16 declaration did not fail preflight") }
                }
            }),
            ("malformed-xml-calendar-and-encoding", {
                try rejected("<tv><channel id=\"one\"></tv>")
                try rejected("<wrong-root/>")
                for start in ["20260230100000", "20261004240000", "20261004100060", "20261004100000 +1460"] {
                    try rejected("<tv>" + programme("one", start, nil) + "</tv>", error: .invalidProgramme(1))
                }
                do { _ = try XMLTVDocument.parse(Data([0xff, 0xff, 0xff])); throw TestFailure.failed("Invalid encoding accepted") }
                catch let error as XMLTVError { try require(error == .unsupportedEncoding, "Wrong encoding diagnostic") }
            }),
            ("bytes-field-depth-node-limits", {
                var limits = XMLTVLimits(); limits.maximumBytes = 4
                try rejected("<tv/>", error: .tooLarge, limits: limits)
                limits = .init(); limits.maximumTextBytes = 3
                try rejected("<tv>" + programme("one", "20261004100000", nil, "中文") + "</tv>", error: .textTooLarge, limits: limits)
                limits = .init(); limits.maximumDepth = 2
                try rejected("<tv><channel id=\"one\"><display-name>x</display-name></channel></tv>", error: .tooDeep, limits: limits)
                limits = .init(); limits.maximumNodes = 2
                try rejected("<tv><channel id=\"one\"/><channel id=\"two\"/></tv>", error: .tooManyNodes, limits: limits)
            }),
            ("channel-and-programme-limits", {
                var limits = XMLTVLimits(); limits.maximumChannels = 1
                try rejected("<tv>" + programme("one") + programme("two") + "</tv>", error: .tooManyChannels, limits: limits)
                limits = .init(); limits.maximumProgrammes = 1
                _ = try XMLTVDocument.parse(data("<tv>" + programme() + "</tv>"), limits: limits)
                try rejected("<tv>" + programme() + programme() + "</tv>", error: .tooManyProgrammes, limits: limits)
                limits.maximumDepth = 0
                try rejected("<tv/>", error: .invalidLimits, limits: limits)
            }),
            ("mid-parse-cancellation-retains-snapshot", {
                var catalog = EPGCatalog()
                try catalog.replace(data: data("<tv>" + programme() + "</tv>"))
                let before = catalog.document
                var checks = 0
                do {
                    try catalog.replace(data: data("<tv>" + (0..<30).map { programme("one", "20261004100000", nil, "\($0)") }.joined() + "</tv>"), isCancelled: { checks += 1; return checks >= 8 })
                    throw TestFailure.failed("Cancellation ignored")
                } catch let error as XMLTVError { try require(error == .cancelled, "Cancellation returned unrelated parse failure") }
                try require(checks >= 8 && catalog.document == before, "Cancelled candidate changed prior snapshot")
            }),
            ("invalid-candidate-retained-then-valid-commit", {
                var catalog = EPGCatalog()
                try catalog.replace(data: data("<tv>" + programme() + "</tv>"))
                let before = catalog.document
                do { try catalog.replace(data: data("<tv><programme/></tv>")); throw TestFailure.failed("Bad candidate accepted") }
                catch is XMLTVError {}
                try require(catalog.document == before, "Bad XML replaced prior successful dataset")
                try catalog.replace(data: data("<tv>" + programme("new") + "</tv>"))
                try require(catalog.document!.channelIDs == ["new"], "Valid replacement merged stale programme data")
            }),
            ("explicit-named-zone-subset-and-minutes", {
                let document = try XMLTVDocument.parse(data("<tv>" + programme("utc", "202610041000 UTC", nil) + programme("bst", "20261004100000 BST", nil) + "</tv>"))
                try require(document.programmes["utc"]!.first!.start == instant("2026-10-04T10:00:00Z"), "Minute precision failed")
                try require(document.programmes["bst"]!.first!.start == instant("2026-10-04T09:00:00Z"), "XMLTV BST mapping incorrect")
                try rejected("<tv>" + programme("one", "20261004100000 CST", nil) + "</tv>", error: .invalidProgramme(1))
            }),
            ("reverse-order-scale-and-missing-channel-query", {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss"
                let origin = instant("2026-10-04T00:00:00Z")
                let entries = (0..<1000).reversed().map { offset in programme("one", formatter.string(from: origin.addingTimeInterval(Double(offset * 60))), nil, "\(offset)") }.joined()
                let document = try XMLTVDocument.parse(data("<tv>" + entries + "</tv>"))
                try require(document.programmes["one"]!.count == 1000 && document.programmes["one"]!.first!.title == "0" && document.programmes["one"]!.last!.title == "999", "Scale index not sorted or data lost")
                let query = document.nowAndNext(channelID: "one", at: origin.addingTimeInterval(500 * 60 + 30))
                try require(query.current.first?.programme.title == "500" && query.next.first?.title == "501", "Sorted scale query returned wrong programme")
                let missing = document.nowAndNext(channelID: "absent", at: origin)
                try require(missing.current.isEmpty && missing.next.isEmpty && missing.latestWithUnknownEnd.isEmpty, "Missing channel produced invented programme")
            })
        ]
        for (name, body) in scenarios {
            do { try body(); print("PASS epg/\(name)") }
            catch { failures += 1; print("FAIL epg/\(name): \(error)") }
        }
        print("EPG scenarios=\(scenarios.count) passed=\(scenarios.count - failures) failed=\(failures)")
        if failures > 0 { exit(1) }
    }
}
