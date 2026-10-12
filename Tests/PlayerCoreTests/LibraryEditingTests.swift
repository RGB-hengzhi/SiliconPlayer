import Foundation
#if !PLAYER_CORE_STANDALONE
import XCTest
@testable import PlayerCore
#endif

final class LibraryEditingTests: XCTestCase {
    func testBookmarkEditingPersistsWithoutChangingIdentity() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.json")
        let store = LibraryStore(fileURL: file)
        let original = try XCTUnwrap(store.addBookmark(url: directory.appendingPathComponent("中文 影片.mp4"), position: 1, title: "原名称"))
        XCTAssertTrue(store.updateBookmark(id: original.id, title: "  新的精彩片段  ", position: 3723.125))
        let restored = try XCTUnwrap(LibraryStore(fileURL: file).bookmarks.first)
        XCTAssertEqual(restored.title, "新的精彩片段")
        XCTAssertEqual(restored.position, 3723.125)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.url, original.url)
        XCTAssertEqual(restored.createdAt, original.createdAt)
        XCTAssertNil(store.lastError)
    }

    func testInvalidBookmarkEditsLeaveMemoryAndDiskUnchanged() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.json")
        let store = LibraryStore(fileURL: file)
        let original = try XCTUnwrap(store.addBookmark(url: directory.appendingPathComponent("media.mp4"), position: 12.25, title: "原书签"))
        let savedData = try Data(contentsOf: file)
        for time in [Double.nan, .infinity, -.infinity, -0.01] {
            XCTAssertFalse(store.updateBookmark(id: original.id, title: "有效名称", position: time))
            XCTAssertNotNil(store.lastError)
        }
        for name in ["", "  \n  ", "名称\n第二行", "名称\t制表", "名称\u{0}"] {
            XCTAssertFalse(store.updateBookmark(id: original.id, title: name, position: 50))
            XCTAssertNotNil(store.lastError)
        }
        XCTAssertFalse(store.updateBookmark(id: UUID(), title: "不存在", position: 50))
        XCTAssertEqual(store.bookmarks, [original])
        XCTAssertEqual(try Data(contentsOf: file), savedData)
    }

    func testSavedPlaylistRenamingPreservesMediaAndRejectsInvalidNames() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.json")
        let store = LibraryStore(fileURL: file)
        let urls = [directory.appendingPathComponent("第一课.mp4"), URL(string: "https://example.org/lesson2.mp4")!]
        let original = try XCTUnwrap(store.savePlaylist(name: "原列表", urls: urls))
        XCTAssertTrue(store.renameSavedPlaylist(id: original.id, name: "  中文课程  "))
        let renamed = try XCTUnwrap(LibraryStore(fileURL: file).savedPlaylists.first)
        XCTAssertEqual(renamed.name, "中文课程")
        XCTAssertEqual(renamed.id, original.id)
        XCTAssertEqual(renamed.urls, original.urls)
        XCTAssertEqual(renamed.createdAt, original.createdAt)
        let savedData = try Data(contentsOf: file)
        for name in ["", " \n ", "课程\n第二行", "课程\u{0}"] {
            XCTAssertFalse(store.renameSavedPlaylist(id: original.id, name: name))
            XCTAssertNotNil(store.lastError)
        }
        XCTAssertFalse(store.renameSavedPlaylist(id: UUID(), name: "不存在"))
        XCTAssertEqual(store.savedPlaylists, [renamed])
        XCTAssertEqual(try Data(contentsOf: file), savedData)
    }

    func testEditingWriteFailureRollsBackAndCanRecover() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.json")
        let store = LibraryStore(fileURL: file)
        let media = directory.appendingPathComponent("media.mp4")
        let bookmark = try XCTUnwrap(store.addBookmark(url: media, position: 12.25, title: "原书签"))
        let playlist = try XCTUnwrap(store.savePlaylist(name: "原列表", urls: [media]))
        // A directory at the document path forces an actual atomic-write failure
        // without relying on permissions that differ when tests run as root.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertFalse(store.updateBookmark(id: bookmark.id, title: "未保存", position: 88))
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.bookmarks, [bookmark])
        XCTAssertFalse(store.renameSavedPlaylist(id: playlist.id, name: "未保存列表"))
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.savedPlaylists, [playlist])
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(store.updateBookmark(id: bookmark.id, title: "恢复后书签", position: 88))
        XCTAssertTrue(store.renameSavedPlaylist(id: playlist.id, name: "恢复后列表"))
        XCTAssertNil(store.lastError)
        let restored = LibraryStore(fileURL: file)
        XCTAssertEqual(restored.bookmarks.first?.title, "恢复后书签")
        XCTAssertEqual(restored.bookmarks.first?.position, 88)
        XCTAssertEqual(restored.savedPlaylists.first?.name, "恢复后列表")
    }

    func testPLSExportRoundTripsChineseURLsAndMetadata() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("列表.pls")
        let urls = [directory.appendingPathComponent("#中文 空格=影片.mp4"), URL(string: "https://example.org/中文%20影片.mp4?token=a=b&part=2")!]
        let text = try PlaylistDocument.pls(urls: urls)
        XCTAssertTrue(text.hasPrefix("[playlist]\nNumberOfEntries=2\n"))
        XCTAssertTrue(text.contains("Title1=#中文 空格=影片.mp4\n"))
        XCTAssertTrue(text.contains("Length1=-1\n"))
        XCTAssertTrue(text.contains("Length2=-1\n"))
        XCTAssertTrue(text.hasSuffix("Version=2\n"))
        XCTAssertEqual(try PlaylistDocument.parse(text, baseURL: file, format: .pls), urls)
        try PlaylistDocument.writePLS(urls: urls, to: file)
        XCTAssertEqual(try PlaylistDocument.read(from: file), urls)
        XCTAssertEqual(try PlaylistDocument.parse(PlaylistDocument.pls(urls: []), baseURL: file, format: .pls), [])
        XCTAssertEqual(try PlaylistDocument.parse(PlaylistDocument.m3u8(urls: urls), baseURL: file), urls)
    }

    func testUnsafePLSExportDoesNotReplaceExistingFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("列表.pls")
        let previous = "保留已有导出"
        try previous.write(to: file, atomically: true, encoding: .utf8)
        let unsafe = [directory.appendingPathComponent("影片\nFile2=other.mp4")]
        XCTAssertTrue(throwsError { try PlaylistDocument.writePLS(urls: unsafe, to: file) })
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), previous)
        XCTAssertTrue(throwsError { _ = try PlaylistDocument.m3u8(urls: unsafe) })
    }

    private func temporaryDirectory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("SiliconPlayerLibraryEditing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    private func throwsError(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }
}
