import Foundation
#if !PLAYER_CORE_STANDALONE
import XCTest
@testable import PlayerCore
#endif

final class PlayerCoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiliconPlayerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testMediaItemPreservesChineseAndSpacesThroughCoding() throws {
        let url = temporaryDirectory.appendingPathComponent("中文 电影.mkv")
        let item = MediaItem(url: url)
        XCTAssertEqual(item.title, "中文 电影.mkv")
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item)), item)
        let stream = URL(string: "https://example.com/live?id=1")!
        XCTAssertEqual(MediaItem(url: stream).title, stream.absoluteString)
    }

    func testPlaylistNormalizesAndDeduplicatesWithoutChangingSelection() {
        let first = temporaryDirectory.appendingPathComponent("中文 电影.mkv")
        let equivalent = temporaryDirectory.appendingPathComponent("nested/../中文 电影.mkv")
        let second = temporaryDirectory.appendingPathComponent("second.mp4")
        var playlist = Playlist()
        playlist.add([first, equivalent, first, second])
        XCTAssertEqual(playlist.items.count, 2)
        XCTAssertEqual(playlist.currentItem?.url, first.standardizedFileURL)
        let selectedID = playlist.items[1].id
        playlist.select(id: selectedID)
        playlist.add([first, second, temporaryDirectory.appendingPathComponent("third.mov")])
        XCTAssertEqual(playlist.items.count, 3)
        XCTAssertEqual(playlist.currentItem?.id, selectedID)
    }

    func testPlaylistRemovesCurrentSuccessorThenPredecessorThenClears() {
        var playlist = threeItemPlaylist()
        let original = playlist.items
        playlist.select(id: original[1].id)
        playlist.remove(id: original[1].id)
        XCTAssertEqual(playlist.currentItem?.id, original[2].id)
        XCTAssertEqual(playlist.currentIndex, 1)
        playlist.remove(id: original[2].id)
        XCTAssertEqual(playlist.currentItem?.id, original[0].id)
        XCTAssertEqual(playlist.currentIndex, 0)
        playlist.remove(id: original[0].id)
        XCTAssertTrue(playlist.items.isEmpty)
        XCTAssertNil(playlist.currentItem)
        XCTAssertNil(playlist.currentIndex)
    }

    func testRemovingBeforeSelectionKeepsSameItemSelected() {
        var playlist = threeItemPlaylist()
        let original = playlist.items
        playlist.select(id: original[2].id)
        playlist.remove(id: original[0].id)
        XCTAssertEqual(playlist.currentItem?.id, original[2].id)
        XCTAssertEqual(playlist.currentIndex, 1)
        playlist.remove(id: UUID())
        XCTAssertEqual(playlist.items.count, 2)
        XCTAssertNil(playlist.select(id: UUID()))
        XCTAssertEqual(playlist.currentItem?.id, original[2].id)
    }

    func testPlaylistBoundariesAndWrapping() {
        var playlist = threeItemPlaylist()
        let original = playlist.items
        XCTAssertNil(playlist.previous(wrap: false))
        XCTAssertEqual(playlist.currentItem?.id, original[0].id)
        XCTAssertEqual(playlist.previous(wrap: true)?.id, original[2].id)
        XCTAssertNil(playlist.next(wrap: false))
        XCTAssertEqual(playlist.currentItem?.id, original[2].id)
        XCTAssertEqual(playlist.next(wrap: true)?.id, original[0].id)
        XCTAssertEqual(playlist.next(wrap: false)?.id, original[1].id)
        XCTAssertEqual(playlist.previous(wrap: false)?.id, original[0].id)
        var empty = Playlist()
        XCTAssertNil(empty.next())
        XCTAssertNil(empty.previous())
    }

    func testSingleItemPlaylistDoesNotAdvanceWithoutWrap() {
        var playlist = Playlist()
        playlist.add([temporaryDirectory.appendingPathComponent("one.mp4")])
        let current = playlist.currentItem
        XCTAssertNil(playlist.next(wrap: false))
        XCTAssertNil(playlist.previous(wrap: false))
        XCTAssertEqual(playlist.next(wrap: true), current)
        XCTAssertEqual(playlist.previous(wrap: true), current)
    }

    func testDirectoryExpansionSortsRecursivelyAndSkipsHiddenFilesAndSymlinks() throws {
        let first = try createFile("视频 01.MKV")
        let second = try createFile("视频 02.mp4")
        let tenth = try createFile("视频 10.mov")
        let nested = try createFile("子目录/中文 歌曲.flac")
        _ = try createFile(".hidden.mp4")
        _ = try createFile(".secret/movie.mkv")
        _ = try createFile("notes.txt")
        _ = try createFile("字幕.srt")
        let linkedDirectory = temporaryDirectory.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: temporaryDirectory)
        let linkedFile = temporaryDirectory.appendingPathComponent("file-link.mkv")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: first)
        let expanded = MediaFormats.expand([temporaryDirectory])
        XCTAssertEqual(Set(expanded), Set([first, second, tenth, nested]))
        XCTAssertLessThan(expanded.firstIndex(of: second)!, expanded.firstIndex(of: tenth)!)
        XCTAssertEqual(expanded.count, 4)
        XCTAssertTrue(MediaFormats.expand([linkedDirectory]).isEmpty)
        XCTAssertTrue(MediaFormats.expand([temporaryDirectory.appendingPathComponent(".secret")]).isEmpty)
    }

    func testExplicitFilesAndStreamsAreKeptAndSubtitlesExcluded() throws {
        let file = try createFile("自定义 格式.unusual")
        let stream = URL(string: "https://example.com/watch?video=1")!
        let subtitle = try createFile("中文字幕.SRT")
        XCTAssertTrue(MediaFormats.isSubtitle(subtitle))
        XCTAssertEqual(MediaFormats.expand([file, stream, subtitle, file]), [file, stream])
    }

    func testHistoryRoundTripNormalizesChinesePathsAndStoresCompletedEntries() throws {
        let historyURL = temporaryDirectory.appendingPathComponent("应用设置/history.json")
        let mediaURL = temporaryDirectory.appendingPathComponent("中文 电影.mkv")
        let equivalent = temporaryDirectory.appendingPathComponent("nested/../中文 电影.mkv")
        let completedURL = temporaryDirectory.appendingPathComponent("finished.mp4")
        let history = HistoryStore(fileURL: historyURL)
        history.record(url: mediaURL, position: 120.5, duration: 600)
        history.record(url: completedURL, position: 598, duration: 600)
        history.flush()
        XCTAssertNil(history.lastError)
        let loaded = HistoryStore(fileURL: historyURL)
        XCTAssertEqual(loaded.resumePosition(for: equivalent), 120.5)
        XCTAssertNil(loaded.resumePosition(for: completedURL))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: historyURL)) as? [String: Any])
        let entries = try XCTUnwrap(json["entries"] as? [String: Any])
        XCTAssertNotNil(entries[completedURL.absoluteString], "Completed history remains recorded even when it cannot resume.")
    }

    func testHistoryResumeEligibilityAndInvalidUpdates() {
        let history = HistoryStore(fileURL: temporaryDirectory.appendingPathComponent("history.json"))
        let url = temporaryDirectory.appendingPathComponent("movie.mkv")
        history.record(url: url, position: 5, duration: 600)
        XCTAssertNil(history.resumePosition(for: url))
        history.record(url: url, position: 5.1, duration: 600)
        XCTAssertEqual(history.resumePosition(for: url), 5.1)
        history.record(url: url, position: 190, duration: 200)
        XCTAssertNil(history.resumePosition(for: url))
        history.record(url: url, position: 950, duration: 1000)
        XCTAssertNil(history.resumePosition(for: url))
        history.record(url: url, position: 940, duration: 1000)
        XCTAssertEqual(history.resumePosition(for: url), 940)
        history.record(url: url, position: .nan, duration: 1000)
        history.record(url: url, position: 300, duration: .infinity)
        history.record(url: url, position: -1, duration: 1000)
        history.record(url: url, position: 1, duration: 0)
        XCTAssertEqual(history.resumePosition(for: url), 940)
    }

    func testHistoryReportsReadAndWriteFailures() throws {
        let corrupt = try createFile("corrupt.json")
        try Data("invalid json".utf8).write(to: corrupt)
        XCTAssertNotNil(HistoryStore(fileURL: corrupt).lastError)
        let fileInsteadOfDirectory = try createFile("blocked")
        let history = HistoryStore(fileURL: fileInsteadOfDirectory.appendingPathComponent("history.json"))
        let media = temporaryDirectory.appendingPathComponent("movie.mkv")
        history.record(url: media, position: 100, duration: 600)
        history.flush()
        XCTAssertNotNil(history.lastError)
        XCTAssertEqual(history.resumePosition(for: media), 100, "A failed write must retain the in-memory history.")
        try FileManager.default.removeItem(at: fileInsteadOfDirectory)
        history.flush()
        XCTAssertNil(history.lastError)
        XCTAssertEqual(HistoryStore(fileURL: fileInsteadOfDirectory.appendingPathComponent("history.json")).resumePosition(for: media), 100)
    }

    func testTimeTextHandlesInvalidValuesAndHours() {
        XCTAssertEqual(TimeText.format(.nan), "0:00")
        XCTAssertEqual(TimeText.format(.infinity), "0:00")
        XCTAssertEqual(TimeText.format(-60), "0:00")
        XCTAssertEqual(TimeText.format(0), "0:00")
        XCTAssertEqual(TimeText.format(59.99), "0:59")
        XCTAssertEqual(TimeText.format(60), "1:00")
        XCTAssertEqual(TimeText.format(3_661), "1:01:01")
        XCTAssertEqual(TimeText.format(360_000), "100:00:00")
        XCTAssertFalse(TimeText.format(Double.greatestFiniteMagnitude).isEmpty)
    }

    private func threeItemPlaylist() -> Playlist {
        var playlist = Playlist()
        playlist.add(["one.mp4", "two.mp4", "three.mp4"].map { temporaryDirectory.appendingPathComponent($0) })
        return playlist
    }

    @discardableResult
    private func createFile(_ relativePath: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        return url
    }
}
