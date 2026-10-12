import Foundation
#if !PLAYER_CORE_STANDALONE
import XCTest
@testable import PlayerCore
#endif

final class ExpandedCoreTests: XCTestCase {
    func testSettingsMigrationAndInvalidValues() throws {
        let defaults = PlaybackSettings()
        XCTAssertEqual(defaults, defaults.sanitized())
        var invalid = defaults
        invalid.brightness = .nan; invalid.contrast = 150; invalid.zoom = -99
        invalid.equalizer = [99, -99, .infinity]; invalid.rotation = 45
        invalid.subtitleFont = "\u{0}\n"; invalid.subtitleColor = "#ff00a9"
        invalid.cacheMB = Int.max; invalid.preferredAudioLanguages = "ZH,zh， en-US ,bad;code,eng"
        let cleaned = invalid.sanitized()
        XCTAssertEqual(cleaned.brightness, 0); XCTAssertEqual(cleaned.contrast, 100)
        XCTAssertEqual(cleaned.zoom, -2); XCTAssertEqual(cleaned.rotation, 0)
        XCTAssertEqual(cleaned.equalizer, [12, -12, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(cleaned.subtitleFont, "Heiti SC"); XCTAssertEqual(cleaned.subtitleColor, "#FF00A9")
        XCTAssertEqual(cleaned.preferredAudioLanguages, "zh,en-us,eng")
        XCTAssertEqual(cleaned.cacheMB, 2048)
        let old = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{\"brightness\":40,\"equalizer\":[1,2],\"cacheMB\":\"bad\"}".utf8))
        XCTAssertEqual(old.brightness, 40); XCTAssertEqual(old.cacheMB, 128); XCTAssertEqual(old.equalizer.count, 10)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(cleaned)), cleaned)
        let legacy = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{\"processing\":{\"projection\":\"bad\",\"audioSampleRate\":1,\"cropWidth\":-2}}".utf8))
        XCTAssertEqual(legacy.processing.projection, "off"); XCTAssertEqual(legacy.processing.audioSampleRate, 0)
        XCTAssertEqual(legacy.processing.cropWidth, 0.1)
    }

    func testLibraryPersistenceAndInvalidBookmarks() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let location = dir.appendingPathComponent("library.json")
        let media = dir.appendingPathComponent("中文 电影.mp4")
        let store = LibraryStore(fileURL: location)
        XCTAssertNotNil(store.addBookmark(url: media, position: 14.25, title: "高光"))
        XCTAssertNil(store.addBookmark(url: media, position: .nan, title: "无效"))
        XCTAssertTrue(store.toggleFavorite(url: media))
        XCTAssertNotNil(store.savePlaylist(name: "课程", urls: [media]))
        store.flush()
        let restored = LibraryStore(fileURL: location)
        XCTAssertEqual(restored.bookmarks.first?.position, 14.25)
        XCTAssertEqual(restored.favorites.first?.url, media)
        XCTAssertEqual(restored.savedPlaylists.first?.name, "课程")
        XCTAssertFalse(restored.toggleFavorite(url: media))
        restored.removeBookmark(id: restored.bookmarks[0].id)
        restored.flush()
        XCTAssertTrue(LibraryStore(fileURL: location).bookmarks.isEmpty)
    }

    func testPlaylistDocumentRelativePathsAndHLS() throws {
        let base = URL(fileURLWithPath: "/影片/lists/我的列表.m3u8")
        let list = try PlaylistDocument.parse("\u{FEFF}#EXTM3U\r\n#EXTINF:-1,中文标题\r\n../中文 影片.mp4\r\nhttps://example.com/video.mp4\n", baseURL: base)
        XCTAssertEqual(list.count, 2); XCTAssertEqual(list[0].path, "/影片/中文 影片.mp4")
        let pls = try PlaylistDocument.parse("[playlist]\nFile2=second.mp4\nFile1=first.mp4\n", baseURL: base, format: .pls)
        XCTAssertEqual(pls.map(\.lastPathComponent), ["first.mp4", "second.mp4"])
        let special = URL(fileURLWithPath: "/影片/#中文 空格.mp4")
        XCTAssertEqual(try PlaylistDocument.parse(PlaylistDocument.m3u8(urls: [special, list[1]]), baseURL: base), [special, list[1]])
        XCTAssertTrue(throwsError { _ = try PlaylistDocument.parse("#EXTM3U\n#EXT-X-VERSION:3\na.ts", baseURL: base) })
    }

    func testSubtitleRoundTripAndAtomicTiming() throws {
        let source = "1\r\n00:00:01,250 --> 00:00:03,750\r\n你好，世界\r\n第二行\r\n\r\n2\r\n00:01:00,000 --> 00:01:01,000\r\n再见"
        var document = try SubtitleDocument.parse(source)
        XCTAssertEqual(document.cues[0].text, "你好，世界\n第二行")
        XCTAssertEqual(try SubtitleDocument.parse(document.srtText()).cues[1].end, 61)
        let before = document.cues
        XCTAssertTrue(throwsError { try document.shift(offset: -2) })
        XCTAssertEqual(document.cues, before)
        try document.shift(offset: 0.5); try document.scaleTime(factor: 2)
        XCTAssertEqual(document.cues[0].start, 3.5)
        for bad in ["00:00:01..250", "00:00:01,", "00:60:00.000", "-1:00:00.000", "99:99"] {
            XCTAssertTrue(throwsError { _ = try SubtitleDocument.parseTimestamp(bad) }, bad)
        }
        let tiny = SubtitleDocument(cues: [.init(start: 1, end: 1.00001, text: "无法保存的零毫秒时长")])
        XCTAssertTrue(throwsError { _ = try tiny.srtText() })
    }

    func testVTTASSAndOverlap() throws {
        let vtt = try SubtitleDocument.parse("WEBVTT\n\nNOTE comment\nignored\n\ncue-a\n00:01.000 --> 00:03.000 align:center\n<v Jane><b>Hello</b> &amp; 世界\n", format: .vtt)
        XCTAssertEqual(vtt.cues[0].text, "Hello & 世界"); XCTAssertTrue(vtt.losesFormatting)
        let ass = try SubtitleDocument.parse("[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:03.20,Default,,0,0,0,,{\\b1}你好,世界\\N下一行\n", format: .ass)
        XCTAssertEqual(ass.cues[0].text, "你好,世界\n下一行"); XCTAssertEqual(ass.cues[0].end, 3.2)
        let overlap = SubtitleDocument(cues: [.init(start: 0, end: 10, text: "A"), .init(start: 2, end: 3, text: "B"), .init(start: 9, end: 12, text: "C")])
        XCTAssertEqual(overlap.overlappingCueIndices, [0, 1, 2])
    }

    func testReorderPreservesPlayingItem() {
        var playlist = Playlist()
        playlist.add(["片 10.mp4", "片 2.mp4", "片 1.mp4"].map { URL(fileURLWithPath: "/影片/" + $0) })
        let id = playlist.items[1].id
        _ = playlist.select(id: id)
        playlist.move(id: id, to: 0)
        XCTAssertEqual(playlist.currentItem?.id, id); XCTAssertEqual(playlist.currentIndex, 0)
        playlist.sortByTitle()
        XCTAssertEqual(playlist.items.map(\.title), ["片 1.mp4", "片 2.mp4", "片 10.mp4"])
        XCTAssertEqual(playlist.currentItem?.id, id)
        playlist.shuffle()
        XCTAssertEqual(playlist.currentItem?.id, id); XCTAssertEqual(Set(playlist.items.map(\.id)).count, 3)
    }

    func testChannelMetadataAndPercentEncodedPaths() throws {
        let base = URL(string: "https://example.com/lists/channels.m3u8")!
        let document = try ChannelDocument.parse("#EXTM3U\n#EXTINF:-1 group-title=\"中文分组\" tvg-logo=\"../logo.png\",中文频道\n../中文%20影片.mp4\n", baseURL: base)
        XCTAssertEqual(document.channels[0].name, "中文频道")
        XCTAssertEqual(document.channels[0].group, "中文分组")
        XCTAssertEqual(document.channels[0].url.path, "/中文 影片.mp4")
        XCTAssertEqual(document.channels[0].logoURL?.absoluteString, "https://example.com/logo.png")
        let roundTrip = try ChannelDocument.parse(document.m3u8Text(), baseURL: base)
        XCTAssertEqual(roundTrip.channels[0].url, document.channels[0].url)
        XCTAssertEqual(roundTrip.channels[0].group, document.channels[0].group)
        XCTAssertTrue(throwsError { _ = try ChannelDocument.parse("#EXTM3U\nhttps://user:password@example.com/movie.mp4", baseURL: base) })
        XCTAssertTrue(throwsError { _ = try ChannelDocument.parse("#EXTM3U\n#EXT-X-VERSION:3\na.ts", baseURL: base) })
    }

    private func temporaryDirectory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("SiliconPlayerExpanded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    private func throwsError(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }
}
