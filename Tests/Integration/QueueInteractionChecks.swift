// Tail appended to the actual queue AppKit types and model methods by run_queue_checks.py.
// No copied implementation, production app launch, visible window, or device access.
import AppKit
import SwiftUI
import PlayerCore

// Instrument the queue method's intent boundary; this does not emulate or
// certify the native controller, libmpv pause state, or audio continuity.
@MainActor private final class QueueIntentBoundary {
    var currentIntent = true
}

@MainActor private final class PlayerModel {
    var playlist = Playlist()
    var continuousAudioEnabled = false
    let nativeAudioQueue = QueueIntentBoundary()
    var saves = 0
    var loads = 0
    var stops = 0
    var writes = 0
    var loadedIDs: [UUID] = []
    var requestedStartIntents: [Bool?] = []
    var notices: [String] = []
    func saveHistory() { saves += 1 }
    func playSelected(startPlaying: Bool? = nil) {
        loads += 1; requestedStartIntents.append(startPlaying)
        if let id = playlist.currentItem?.id { loadedIDs.append(id) }
    }
    func stopPlayback() { stops += 1 }
    func persistQueue() { writes += 1 }
    func toast(_ message: String) { notices.append(message) }
}

@MainActor private final class QueueSelectionBox { var ids: Set<UUID> = [] }

@MainActor private final class QueueTestDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(pasteboard: NSPasteboard, source: Any?) { draggingPasteboard = pasteboard; draggingSource = source }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@main @MainActor private struct QueueInteractionChecks {
    static func main() throws {
        _ = NSApplication.shared
        let model = PlayerModel()
        model.playlist.add((0..<7).map { URL(fileURLWithPath: "/影片/真实 队列 \($0).mp4") })
        let ids = model.playlist.items.map(\.id)
        _ = model.playlist.select(id: ids[3])
        model.removePlaylistItems([ids[0], ids[2]])
        precondition(model.playlist.currentItem?.id == ids[3] && model.loads == 0 && model.stops == 0 && model.saves == 0 && model.writes == 1)
        print("PASS model batch remove surviving current does not save/reload/stop")
        let selectedBeforeMove = model.playlist.currentItem?.id
        precondition(model.movePlaylistItems([ids[1], ids[5]], to: .after(ids[6])))
        precondition(model.playlist.currentItem?.id == selectedBeforeMove && model.loads == 0 && model.stops == 0)
        let beforeInvalid = model.playlist.items.map(\.id)
        precondition(!model.movePlaylistItems([ids[1], UUID()], to: .end))
        precondition(model.playlist.items.map(\.id) == beforeInvalid && model.writes == 2)
        print("PASS model drag preserves current and rejects unknown IDs without persistence")
        model.removePlaylistItems([ids[3], ids[4]])
        precondition(model.loads == 1 && model.saves == 1 && model.stops == 0 && model.loadedIDs == [ids[6]])
        precondition(model.requestedStartIntents == [nil], "Ordinary removal preserves the default load intent")
        for startPlaying in [false, true] {
            let intentModel = PlayerModel()
            intentModel.playlist.add((0..<3).map { URL(fileURLWithPath: "/队列/意图 \($0).wav") })
            let intentIDs = intentModel.playlist.items.map(\.id)
            _ = intentModel.playlist.select(id: intentIDs[0])
            intentModel.continuousAudioEnabled = true
            intentModel.nativeAudioQueue.currentIntent = startPlaying
            intentModel.removePlaylistItems([intentIDs[0]])
            precondition(intentModel.loads == 1 && intentModel.saves == 1 && intentModel.stops == 0)
            precondition(intentModel.loadedIDs == [intentIDs[1]] && intentModel.requestedStartIntents == [startPlaying],
                         "Opt-in removal forwards both paused and playing intent to the one successor load")
        }
        print("PASS model removes current and neighbors with one successor load")
        model.removePlaylistItems(Set(model.playlist.items.map(\.id)))
        precondition(model.loads == 1 && model.stops == 1 && model.saves == 2 && model.playlist.currentIndex == nil)
        let writes = model.writes
        model.removePlaylistItems([UUID()])
        precondition(model.writes == writes && model.loads == 1 && model.stops == 1)
        print("PASS model clear stops once and stale removal does nothing")

        var queue = Playlist()
        queue.add((0..<7).map { URL(fileURLWithPath: "/队列/中文 \($0).mp4") })
        let all = queue.items
        let selection = QueueSelectionBox()
        let binding = Binding(get: { selection.ids }, set: { selection.ids = $0 })
        let session = UUID()
        var removed: Set<UUID> = []
        var played: UUID?
        var error: String?
        var parent = QueueTableView(rows: all.enumerated().map { QueueRow(index: $0.offset, item: $0.element) },
                                   allItems: all, currentID: all[3].id, selection: binding, dragSession: session,
                                   play: { played = $0 }, remove: { removed = $0 },
                                   move: { queue.move(ids: $0, to: $1) }, failed: { error = $0 })
        let coordinator = parent.makeCoordinator()
        let scroll = QueueTableView.makeScrollView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 260, height: 500)
        scroll.layoutSubtreeIfNeeded()
        parent.updateTable(coordinator)
        let table = coordinator.table!
        precondition(table.identifier?.rawValue == "playlist-queue" && table.allowsMultipleSelection && table.numberOfRows == 7)
        precondition(table.tableColumns.count == 1 && table.rowHeight == 64 && table.delegate === coordinator)
        precondition(table.frame.width > 200, "Native table must fill the 260pt panel")
        table.selectRowIndexes(IndexSet([1, 4]), byExtendingSelection: false)
        precondition(selection.ids == Set([all[1].id, all[4].id]))
        print("PASS native production table setup, sizing and noncontiguous selection IDs")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        precondition(coordinator.tableView(table, writeRowsWith: table.selectedRowIndexes, to: pasteboard))
        let data = pasteboard.data(forType: QueueTableView.Coordinator.pasteboardType)!
        let payloadIDs = try PlaylistDragPayload.validatedIDs(data, sessionID: session, availableIDs: Set(all.map(\.id)))
        precondition(payloadIDs == selection.ids)
        precondition(pasteboard.data(forType: .fileURL) == nil && pasteboard.data(forType: .URL) == nil)
        let dragging = QueueTestDraggingInfo(pasteboard: pasteboard, source: table)
        precondition(coordinator.tableView(table, validateDrop: dragging, proposedRow: 6, proposedDropOperation: .on) == .move)
        precondition(coordinator.tableView(table, acceptDrop: dragging, row: 6, dropOperation: .above))
        precondition(queue.items.map(\.id) == [all[0].id, all[2].id, all[3].id, all[5].id, all[1].id, all[4].id, all[6].id])
        parent = QueueTableView(rows: queue.items.enumerated().map { QueueRow(index: $0.offset, item: $0.element) },
                                allItems: queue.items, currentID: all[3].id, selection: binding, dragSession: session,
                                play: { played = $0 }, remove: { removed = $0 },
                                move: { queue.move(ids: $0, to: $1) }, failed: { error = $0 })
        selection.ids = [all[1].id, all[6].id]
        parent.updateTable(coordinator)
        precondition(coordinator.tableView(table, writeRowsWith: table.selectedRowIndexes, to: pasteboard))
        precondition(coordinator.tableView(table, acceptDrop: dragging, row: 7, dropOperation: .above))
        precondition(queue.items.map(\.id) == [all[0].id, all[2].id, all[3].id, all[5].id, all[4].id, all[1].id, all[6].id])
        print("PASS native multi-row pasteboard and drop insertion route actual core move")

        // A filtered view must anchor its bottom after the last visible item, not the queue end.
        queue = Playlist(); queue.add(all.map(\.url))
        let filteredAll = queue.items
        parent = QueueTableView(rows: [QueueRow(index: 1, item: filteredAll[1]), QueueRow(index: 4, item: filteredAll[4])],
                                allItems: filteredAll, currentID: filteredAll[3].id, selection: binding, dragSession: session,
                                play: { played = $0 }, remove: { removed = $0 },
                                move: { queue.move(ids: $0, to: $1) }, failed: { error = $0 })
        selection.ids = [filteredAll[1].id, filteredAll[3].id]
        parent.updateTable(coordinator)
        precondition(table.selectedRowIndexes == IndexSet(integer: 0))
        precondition(coordinator.tableView(table, writeRowsWith: table.selectedRowIndexes, to: pasteboard))
        precondition(coordinator.tableView(table, acceptDrop: dragging, row: 2, dropOperation: .above))
        precondition(queue.items.map(\.id) == [filteredAll[0].id, filteredAll[2].id, filteredAll[3].id, filteredAll[4].id, filteredAll[1].id, filteredAll[5].id, filteredAll[6].id])
        print("PASS native filtered bottom drop preserves hidden tail and IDs")
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        table.keyDown(with: delete)
        precondition(removed == Set([filteredAll[1].id]) && selection.ids.isEmpty)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        table.keyDown(with: enter)
        precondition(played == filteredAll[4].id)
        print("PASS native Delete removes visible selection and Return plays stable ID")
        let unchanged = queue.items.map(\.id)
        let otherSource = QueueTestDraggingInfo(pasteboard: pasteboard, source: NSTableView())
        precondition(coordinator.tableView(table, validateDrop: otherSource, proposedRow: 1, proposedDropOperation: .above).isEmpty)
        pasteboard.clearContents(); pasteboard.setData(Data("bad".utf8), forType: QueueTableView.Coordinator.pasteboardType)
        precondition(coordinator.tableView(table, validateDrop: dragging, proposedRow: 1, proposedDropOperation: .above).isEmpty)
        precondition(!coordinator.tableView(table, acceptDrop: dragging, row: 1, dropOperation: .above) && error != nil)
        pasteboard.setData(try PlaylistDragPayload(sessionID: session, itemIDs: [UUID()]).encoded(), forType: QueueTableView.Coordinator.pasteboardType)
        precondition(coordinator.tableView(table, validateDrop: dragging, proposedRow: 1, proposedDropOperation: .above).isEmpty)
        pasteboard.setData(try PlaylistDragPayload(sessionID: UUID(), itemIDs: [filteredAll[1].id]).encoded(), forType: QueueTableView.Coordinator.pasteboardType)
        precondition(coordinator.tableView(table, validateDrop: dragging, proposedRow: 1, proposedDropOperation: .above).isEmpty)
        precondition(coordinator.tableView(table, validateDrop: dragging, proposedRow: -1, proposedDropOperation: .above).isEmpty)
        precondition(coordinator.tableView(table, validateDrop: dragging, proposedRow: 3, proposedDropOperation: .above).isEmpty)
        precondition(queue.items.map(\.id) == unchanged)
        print("PASS native malformed/cross-source/stale/session/illegal-row drops rejected atomically")
        table.selectAll(nil)
        precondition(selection.ids == Set([filteredAll[1].id, filteredAll[4].id]))
        let menu = NSMenu()
        coordinator.menuWillOpen(menu)
        precondition(menu.items.contains { $0.title == "移出选中的 2 项" })
        precondition(!menu.items.contains { $0.title == "播放" })
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        coordinator.menuWillOpen(menu)
        precondition(menu.items.contains { $0.title == "播放" } && menu.items.contains { $0.title == "在 Finder 中显示" })
        let cell = coordinator.tableView(table, viewFor: table.tableColumns[0], row: 1)!
        let labels = cell.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        precondition(labels.contains(filteredAll[4].title) && labels.contains("05"))
        print("PASS native filtered select-all, batch/single menus and original queue row identity")
        print("10 queue model and native callback groups passed")
    }
}
