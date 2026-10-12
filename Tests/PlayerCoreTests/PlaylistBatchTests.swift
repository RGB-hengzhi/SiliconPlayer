import Foundation
#if !PLAYER_CORE_STANDALONE
import XCTest
@testable import PlayerCore
#endif

final class PlaylistBatchTests: XCTestCase {
    private func queue(_ count: Int = 7) -> Playlist {
        var playlist = Playlist()
        playlist.add((0..<count).map { URL(fileURLWithPath: "/影片/测试 \($0).mp4") })
        return playlist
    }

    func testBatchRemoveKeepsCurrentIdentityAndDoesNotUseShiftedIndices() {
        var playlist = queue()
        let old = playlist.items
        _ = playlist.select(id: old[4].id)
        XCTAssertEqual(playlist.remove(ids: [old[0].id, old[2].id, old[6].id, UUID()]), 3)
        XCTAssertEqual(playlist.items.map(\.id), [old[1].id, old[3].id, old[4].id, old[5].id])
        XCTAssertEqual(playlist.currentItem?.id, old[4].id)
        XCTAssertEqual(playlist.currentIndex, 2)
        XCTAssertEqual(playlist.remove(ids: [UUID()]), 0)
        XCTAssertEqual(playlist.currentItem?.id, old[4].id)
    }

    func testBatchRemovalSuccessorsPredecessorsAndEmptyQueueExhaustively() {
        let original = queue(8)
        let ids = original.items.map(\.id)
        for selected in ids.indices {
            for mask in 0..<256 {
                var playlist = original
                _ = playlist.select(id: ids[selected])
                let removing = Set(ids.indices.filter { mask & (1 << $0) != 0 }.map { ids[$0] })
                let remaining = ids.filter { !removing.contains($0) }
                let expected = !removing.contains(ids[selected]) ? ids[selected]
                    : ids.dropFirst(selected + 1).first { !removing.contains($0) }
                        ?? ids.prefix(selected).last { !removing.contains($0) }
                XCTAssertEqual(playlist.remove(ids: removing), removing.count)
                XCTAssertEqual(playlist.items.map(\.id), remaining)
                XCTAssertEqual(playlist.currentItem?.id, expected)
                if remaining.isEmpty { XCTAssertNil(playlist.currentIndex) }
            }
        }
    }

    func testNoncontiguousMoveRetainsRelativeOrderAndCurrentIdentity() {
        var playlist = queue()
        let ids = playlist.items.map(\.id)
        _ = playlist.select(id: ids[3])
        XCTAssertTrue(playlist.move(ids: [ids[1], ids[3]], to: .before(ids[6])))
        XCTAssertEqual(playlist.items.map(\.id), [ids[0], ids[2], ids[4], ids[5], ids[1], ids[3], ids[6]])
        XCTAssertEqual(playlist.currentItem?.id, ids[3])
        XCTAssertEqual(playlist.currentIndex, 5)
        XCTAssertTrue(playlist.move(ids: [ids[1], ids[3]], to: .beginning))
        XCTAssertEqual(playlist.items.map(\.id), [ids[1], ids[3], ids[0], ids[2], ids[4], ids[5], ids[6]])
        XCTAssertTrue(playlist.move(ids: [ids[1], ids[3]], to: .end))
        XCTAssertEqual(playlist.items.map(\.id), [ids[0], ids[2], ids[4], ids[5], ids[6], ids[1], ids[3]])
        XCTAssertEqual(playlist.currentItem?.id, ids[3])
    }

    func testOriginalInsertionBoundaryCorrectsAllRemovedPrecedingRows() {
        var playlist = queue()
        let ids = playlist.items.map(\.id)
        _ = playlist.select(id: ids[4])
        XCTAssertTrue(playlist.move(ids: [ids[1], ids[3], ids[5]], toInsertionIndex: 4))
        XCTAssertEqual(playlist.items.map(\.id), [ids[0], ids[2], ids[1], ids[3], ids[5], ids[4], ids[6]])
        XCTAssertEqual(playlist.currentItem?.id, ids[4])
        var downward = queue(6)
        let down = downward.items.map(\.id)
        XCTAssertTrue(downward.move(ids: [down[0], down[1]], toInsertionIndex: 4))
        XCTAssertEqual(downward.items.map(\.id), [down[2], down[3], down[0], down[1], down[4], down[5]])
    }

    func testFilteredDropAndRemovalUseIDsAndKeepHiddenRows() throws {
        var playlist = queue()
        let ids = playlist.items.map(\.id)
        let visible = [ids[1], ids[4]]
        let end = try XCTUnwrap(PlaylistMoveTarget.visibleInsertion(ids: visible, row: 2))
        XCTAssertEqual(end, .after(ids[4]))
        XCTAssertTrue(playlist.move(ids: [ids[1]], to: end))
        XCTAssertEqual(playlist.items.map(\.id), [ids[0], ids[2], ids[3], ids[4], ids[1], ids[5], ids[6]])
        XCTAssertEqual(PlaylistMoveTarget.visibleInsertion(ids: visible, row: 1), .before(ids[4]))
        _ = playlist.select(id: ids[3])
        XCTAssertEqual(playlist.remove(ids: Set(visible)), 2)
        XCTAssertEqual(playlist.items.map(\.id), [ids[0], ids[2], ids[3], ids[5], ids[6]])
        XCTAssertEqual(playlist.currentItem?.id, ids[3])
    }

    func testRejectedMovesAndSelfDropAreAtomic() {
        var playlist = queue()
        let ids = playlist.items.map(\.id)
        _ = playlist.select(id: ids[3])
        XCTAssertFalse(playlist.move(ids: [], to: .end))
        XCTAssertFalse(playlist.move(ids: [ids[1], UUID()], to: .end))
        XCTAssertFalse(playlist.move(ids: [ids[1]], to: .before(UUID())))
        XCTAssertFalse(playlist.move(ids: [ids[1]], toInsertionIndex: -1))
        XCTAssertFalse(playlist.move(ids: [ids[1]], toInsertionIndex: Int.max))
        XCTAssertTrue(playlist.move(ids: [ids[1], ids[2]], to: .before(ids[2])))
        XCTAssertEqual(playlist.items.map(\.id), ids)
        XCTAssertEqual(playlist.currentItem?.id, ids[3])
        XCTAssertNil(PlaylistMoveTarget.visibleInsertion(ids: [], row: 0))
        XCTAssertNil(PlaylistMoveTarget.visibleInsertion(ids: ids, row: -1))
        XCTAssertNil(PlaylistMoveTarget.visibleInsertion(ids: ids, row: ids.count + 1))
        XCTAssertNil(PlaylistMoveTarget.visibleInsertion(ids: [ids[0], ids[0]], row: 1))
    }

    func testSelectedAnchorAndTailDropConsolidateNoncontiguousSelection() {
        var playlist = queue()
        let ids = playlist.items.map(\.id)
        _ = playlist.select(id: ids[6])
        XCTAssertTrue(playlist.move(ids: [ids[1], ids[6]], to: .after(ids[6])))
        XCTAssertEqual(playlist.items.map(\.id), [ids[0], ids[2], ids[3], ids[4], ids[5], ids[1], ids[6]])
        XCTAssertEqual(playlist.currentItem?.id, ids[6])
        var anchored = queue()
        let anchorIDs = anchored.items.map(\.id)
        XCTAssertTrue(anchored.move(ids: [anchorIDs[1], anchorIDs[3]], to: .before(anchorIDs[3])))
        XCTAssertEqual(anchored.items.map(\.id), [anchorIDs[0], anchorIDs[2], anchorIDs[1], anchorIDs[3], anchorIDs[4], anchorIDs[5], anchorIDs[6]])
        let previous = anchored.items.map(\.id)
        XCTAssertTrue(anchored.move(ids: Set(previous), to: .end))
        XCTAssertEqual(anchored.items.map(\.id), previous)
    }

    func testDragPayloadRoundTripAndStrictSessionValidation() throws {
        let playlist = queue()
        let ids = playlist.items.map(\.id)
        let session = UUID()
        let selected = [ids[1], ids[4]]
        let data = try PlaylistDragPayload(sessionID: session, itemIDs: selected).encoded()
        XCTAssertEqual(try PlaylistDragPayload.validatedIDs(data, sessionID: session, availableIDs: Set(ids)), Set(selected))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("测试"))
        expectInvalid { _ = try PlaylistDragPayload.validatedIDs(data, sessionID: UUID(), availableIDs: Set(ids)) }
        expectInvalid { _ = try PlaylistDragPayload.validatedIDs(data, sessionID: session, availableIDs: Set([ids[1]])) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 99
        let wrongVersion = try JSONSerialization.data(withJSONObject: object)
        expectInvalid { _ = try PlaylistDragPayload.validatedIDs(wrongVersion, sessionID: session, availableIDs: Set(ids)) }
        object["version"] = 1
        object["itemIDs"] = [ids[1].uuidString, ids[1].uuidString]
        let duplicates = try JSONSerialization.data(withJSONObject: object)
        expectInvalid { _ = try PlaylistDragPayload.validatedIDs(duplicates, sessionID: session, availableIDs: Set(ids)) }
    }

    func testMalformedEmptyOversizedAndExcessivePayloadsAreRejected() throws {
        let session = UUID()
        for text in ["", "null", "[]", "{}", "{\"version\":1,\"sessionID\":\"bad\",\"itemIDs\":[]}"] {
            expectInvalid { _ = try PlaylistDragPayload.validatedIDs(Data(text.utf8), sessionID: session, availableIDs: []) }
        }
        expectInvalid { _ = try PlaylistDragPayload(sessionID: session, itemIDs: []).encoded() }
        let id = UUID()
        expectInvalid { _ = try PlaylistDragPayload(sessionID: session, itemIDs: [id, id]).encoded() }
        expectInvalid { _ = try PlaylistDragPayload.validatedIDs(Data(repeating: 0, count: PlaylistDragPayload.maximumBytes + 1), sessionID: session, availableIDs: []) }
        expectInvalid { _ = try PlaylistDragPayload(sessionID: session, itemIDs: (0...PlaylistDragPayload.maximumItems).map { _ in UUID() }).encoded() }
        let maxIDs = (0..<PlaylistDragPayload.maximumItems).map { _ in UUID() }
        let data = try PlaylistDragPayload(sessionID: session, itemIDs: maxIDs).encoded()
        XCTAssertEqual(try PlaylistDragPayload.validatedIDs(data, sessionID: session, availableIDs: Set(maxIDs)).count, maxIDs.count)
    }

    private func expectInvalid(_ operation: () throws -> Void, file: StaticString = #file, line: UInt = #line) {
        do { try operation(); XCTAssertTrue(false, "Expected drag validation to reject the data", file: file, line: line) }
        catch { XCTAssertNotNil(error as? PlaylistDragPayload.ValidationError, file: file, line: line) }
    }
}
