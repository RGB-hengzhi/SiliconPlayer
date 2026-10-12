import Foundation
import Darwin
import PlayerCore

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main struct DocumentBoundaryChecks {
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw CheckFailure(description: message) }
    }
    static func rejected(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }
    static func main() throws {
        setbuf(stdout, nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("document-boundaries-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var failures = 0
        let cases: [(String, () throws -> Void)] = [
            ("6000 bilingual subtitles survive disk, shift, scale and SRT reimport", {
                let cues = (0..<6000).map { index in
                    SubtitleCue(start: Double(index) * 2 + 0.125, end: Double(index) * 2 + 1.625,
                        text: "第 \(index + 1) 行中文字幕\nEnglish subtitle \(index + 1)")
                }
                var document = SubtitleDocument(cues: cues)
                let file = directory.appendingPathComponent("多语言长字幕.srt")
                try document.writeSRT(to: file)
                var reopened = try SubtitleDocument.read(from: file)
                try expect(reopened.cues.count == 6000 && reopened.cues.map(\.text) == cues.map(\.text), "lost subtitles or bilingual lines")
                try reopened.shift(offset: 0.875)
                try reopened.scaleTime(factor: 2)
                try reopened.writeSRT(to: file)
                document = try SubtitleDocument.read(from: file)
                try expect(document.cues[5999].start == 23998 && document.cues[5999].end == 24001, "global correction lost timing")
                try expect(document.overlappingCueIndices.isEmpty, "non-overlapping long subtitles marked overlapping")
            }),
            ("long-hour timestamp rollover and overflowing corrections remain atomic", {
                let file = directory.appendingPathComponent("long-hours.srt")
                var document = SubtitleDocument(cues: [.init(start: 1_799_999.9996, end: 1_800_001.125, text: "500小时边界")])
                try document.writeSRT(to: file)
                let roundtrip = try SubtitleDocument.read(from: file)
                try expect(roundtrip.cues[0].start == 1_800_000 && roundtrip.cues[0].end == 1_800_001.125, "hour carry produced invalid time")
                let previous = document.cues
                try expect(rejected { try document.shift(offset: SubtitleDocument.maximumTime) }, "overflowing offset was accepted")
                try expect(document.cues == previous, "failed offset changed cues")
                try expect(rejected { try document.scaleTime(factor: Double.greatestFiniteMagnitude) }, "overflowing factor was accepted")
                try expect(document.cues == previous, "failed scale changed cues")
            }),
            ("UTF16 SRT, VTT metadata and ASS drawing text preserve readable subtitles", {
                let file = directory.appendingPathComponent("UTF16字幕.srt")
                try "1\r\n00:00:01,250 --> 00:00:03,750\r\n中文编码\r\nSecond line\r\n".write(to: file, atomically: true, encoding: .utf16)
                let encoded = try SubtitleDocument.read(from: file)
                try expect(encoded.cues[0].text == "中文编码\nSecond line", "UTF16 text lost")
                let vtt = try SubtitleDocument.parse("WEBVTT\nLanguage: zh\n\nSTYLE\n::cue { color: lime }\n\nREGION\nid:bottom\n\nNOTE test metadata\nignored\n\none\n00:01.250 --> 00:03.750 align:start\n<v 张三><b>中文</b> &amp; English\n\ntwo\n00:04.000 --> 00:05.000\n下一条\n", format: .vtt)
                try expect(vtt.cues.count == 2 && vtt.cues[0].text == "中文 & English" && vtt.losesFormatting, "VTT metadata or text mishandled")
                let ass = try SubtitleDocument.parse("[Events]\nFormat: End, Start, Style, Text\nDialogue: 0:00:03.00,0:00:01.00,Default,{\\p1}m 0 0 l 1 1{\\p0}中文\\NEnglish\n", format: .ass)
                try expect(ass.cues.count == 1 && ass.cues[0].text == "中文\nEnglish" && ass.losesFormatting, "ASS drawing or reordered fields mishandled")
                try expect(try SubtitleDocument.parse(ass.srtText()).cues[0].text == "中文\nEnglish", "ASS text export failed")
            }),
            ("invalid subtitles and filesystem export failures preserve existing documents", {
                let file = directory.appendingPathComponent("existing.srt")
                let previous = Data("existing subtitle document".utf8)
                try previous.write(to: file)
                for cue in [SubtitleCue(start: .nan, end: 3, text: "bad"), .init(start: 1, end: 1.00001, text: "precision"), .init(start: 3, end: 2, text: "reverse")] {
                    let invalid = SubtitleDocument(cues: [cue])
                    try expect(rejected { try invalid.writeSRT(to: file) }, "invalid export succeeded")
                    try expect(try Data(contentsOf: file) == previous, "invalid export replaced original")
                }
                let blocker = directory.appendingPathComponent("not-a-directory")
                try previous.write(to: blocker)
                let valid = SubtitleDocument(cues: [.init(start: 1, end: 3, text: "valid")])
                try expect(rejected { try valid.writeSRT(to: blocker.appendingPathComponent("export.srt")) }, "impossible output directory accepted")
                try expect(try Data(contentsOf: blocker) == previous, "filesystem failure damaged parent")
            }),
            ("partly damaged library recovers valid records without duplicating media", {
                let file = directory.appendingPathComponent("partly-damaged.json")
                let media = directory.appendingPathComponent("中文媒体.mp4")
                let bookmark = PlaybackBookmark(url: media, position: 14.25, title: "保留书签")
                let playlist = SavedPlaylist(name: "保留列表", urls: [media])
                let favorite = MediaItem(url: media)
                func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
                var negative = try object(bookmark) as! [String: Any]
                negative["id"] = UUID().uuidString; negative["position"] = -1
                let data = try JSONSerialization.data(withJSONObject: ["version": 1,
                    "bookmarks": [try object(bookmark), "corrupt", negative, try object(bookmark)],
                    "favorites": [try object(favorite), try object(MediaItem(url: media))],
                    "savedPlaylists": [try object(playlist), ["name": "incomplete"], try object(playlist)]])
                try data.write(to: file)
                let store = LibraryStore(fileURL: file)
                try expect(store.bookmarks == [bookmark] && store.favorites.count == 1 && store.savedPlaylists == [playlist], "valid library data lost or duplicated")
                try expect(store.lastError != nil, "damaged-record warning missing")
                try expect(store.updateBookmark(id: bookmark.id, title: "修复后书签", position: 20), "recovered library cannot be edited")
                let reopened = LibraryStore(fileURL: file)
                try expect(reopened.bookmarks.first?.title == "修复后书签" && reopened.savedPlaylists == [playlist], "library recovery did not persist")
            }),
            ("unsupported and broken library files are not overwritten merely by opening", {
                for text in ["{\"version\":999,\"bookmarks\":[]}", "{broken-json"] {
                    let file = directory.appendingPathComponent(UUID().uuidString + ".json")
                    let previous = Data(text.utf8)
                    try previous.write(to: file)
                    let store = LibraryStore(fileURL: file)
                    store.flush()
                    try expect(store.lastError != nil && store.bookmarks.isEmpty, "invalid library did not report error")
                    try expect(try Data(contentsOf: file) == previous, "read-only opening overwrote invalid library")
                }
            }),
            ("1000-entry PLS and M3U8 disk roundtrips preserve encoded filenames and URL order", {
                let urls = (0..<1000).map { directory.appendingPathComponent("#中文 空格=第\($0).mp4") }
                    + [URL(string: "https://example.org/中文%20影片.mp4?a=b=c&part=2#fragment")!]
                let pls = directory.appendingPathComponent("many.pls")
                let m3u8 = directory.appendingPathComponent("many.m3u8")
                try PlaylistDocument.writePLS(urls: urls, to: pls)
                try PlaylistDocument.writeM3U8(urls: urls, to: m3u8)
                try expect(try PlaylistDocument.read(from: pls) == urls, "PLS reordered or changed URLs")
                try expect(try PlaylistDocument.read(from: m3u8) == urls, "M3U8 reordered or changed URLs")
            }),
            ("channel export rejects credential-bearing media and logos before overwriting file", {
                let file = directory.appendingPathComponent("channels.m3u8")
                let previous = Data("existing channel document".utf8)
                try previous.write(to: file)
                let plain = URL(string: "https://example.org/media.mp4")!
                for channel in [MediaChannel(name: "Bad media", url: URL(string: "https://user:password@example.org/media.mp4")!),
                    MediaChannel(name: "Bad logo", url: plain, logoURL: URL(string: "https://user:password@example.org/logo.png")!)] {
                    try expect(rejected { try ChannelDocument(channels: [channel]).writeM3U8(to: file) }, "credential URL exported")
                    try expect(try Data(contentsOf: file) == previous, "failed channel export damaged original")
                }
            })
        ]
        for (name, body) in cases {
            do { try body(); print("PASS " + name) }
            catch { failures += 1; print("FAIL " + name + ": " + String(describing: error)) }
        }
        print("\(cases.count - failures)/\(cases.count) document boundary groups passed; real local files, no media playback")
        if failures > 0 { exit(1) }
    }
}
