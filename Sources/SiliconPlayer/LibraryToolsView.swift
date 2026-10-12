import AppKit
import SwiftUI
import PlayerCore
import UniformTypeIdentifiers

private final class LibraryViewState: ObservableObject {
    enum EditingTarget {
        case bookmark(UUID)
        case playlist(UUID)
    }
    @Published var tab = 0
    @Published var editingTarget: EditingTarget?
    @Published var name = ""
    @Published var time = ""
    @Published var editingError: String?

    var isEditingBookmark: Bool {
        if case .bookmark? = editingTarget { return true }
        return false
    }

    func edit(_ bookmark: PlaybackBookmark) {
        name = bookmark.title
        time = String(bookmark.position)
        editingError = nil
        editingTarget = .bookmark(bookmark.id)
    }

    func rename(_ playlist: SavedPlaylist) {
        name = playlist.name
        editingError = nil
        editingTarget = .playlist(playlist.id)
    }

    func closeEditor() { editingTarget = nil; editingError = nil }
}

struct LibraryToolsView: View {
    @ObservedObject var player: PlayerModel
    @StateObject private var state = LibraryViewState()

    var body: some View {
        let _ = player.libraryRevision
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("书签、收藏与最近播放", systemImage: "books.vertical").font(.title2.bold())
                Spacer()
                Button("完成") { player.showLibrary = false }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Button { player.addBookmark() } label: { Label("当前位置书签", systemImage: "bookmark.badge.plus") }.disabled(!player.loaded)
                Button { player.toggleFavorite() } label: { Label("收藏当前媒体", systemImage: "star") }.disabled(player.playlist.currentItem == nil)
                Spacer()
                Button("目录扫描与监控…") { DirectoryLibraryWindow.show(player: player) }
                Button("字幕编辑器…") { player.openSubtitleEditor() }
            }
            Picker("分类", selection: $state.tab) {
                Text("书签 (\(player.library.bookmarks.count))").tag(0)
                Text("收藏 (\(player.library.favorites.count))").tag(1)
                Text("播放列表 (\(player.library.savedPlaylists.count))").tag(2)
                Text("最近播放").tag(3)
            }.pickerStyle(.segmented)
            Group {
                if state.tab == 0 { bookmarks }
                else if state.tab == 1 { favorites }
                else if state.tab == 2 { savedPlaylists }
                else { recent }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = player.library.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
            Divider()
            HStack {
                Button("导入播放列表…") { player.importPlaylist() }
                Button("导出 M3U8…") { player.exportPlaylist() }.disabled(player.playlist.items.isEmpty)
                Button("导出 PLS…") { player.exportPlaylist(format: .pls) }.disabled(player.playlist.items.isEmpty)
                Spacer()
                Button("保存当前列表…") { player.saveNamedPlaylist() }.disabled(player.playlist.items.isEmpty)
            }
            Text("书签、收藏与列表保存在本机；网络媒体会在播放时连接。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(minWidth: 650, minHeight: 480)
            .sheet(isPresented: Binding(get: { state.editingTarget != nil }, set: { if !$0 { state.closeEditor() } })) {
                libraryEditor
            }
    }

    private var libraryEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(state.isEditingBookmark ? "编辑书签" : "重命名播放列表").font(.title2.bold())
            VStack(alignment: .leading, spacing: 6) {
                Text("名称")
                TextField("请输入名称", text: $state.name)
            }
            if state.isEditingBookmark {
                VStack(alignment: .leading, spacing: 6) {
                    Text("播放时间")
                    TextField("秒数或 时:分:秒.毫秒", text: $state.time)
                    Text("支持非负秒数（如 14.25）或 01:02:03.250。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = state.editingError { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("取消") { state.closeEditor() }.keyboardShortcut(.cancelAction)
                Button("保存") { saveLibraryEdits() }.keyboardShortcut(.defaultAction)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 440)
    }

    private func saveLibraryEdits() {
        let saved: Bool
        switch state.editingTarget {
        case .bookmark(let id):
            let text = state.time.trimmingCharacters(in: .whitespacesAndNewlines)
            let position = text.contains(":") ? try? SubtitleDocument.parseTimestamp(text)
                : Double(text.replacingOccurrences(of: ",", with: "."))
            guard let position, position.isFinite, position >= 0 else {
                state.editingError = "请输入有效的非负秒数，或 时:分:秒.毫秒。"
                return
            }
            saved = player.updateBookmark(id, title: state.name, position: position)
        case .playlist(let id):
            saved = player.renameSavedPlaylist(id, name: state.name)
        case .none:
            return
        }
        if saved { state.closeEditor() }
        else { state.editingError = player.library.lastError ?? "修改未能保存，请重试。" }
    }

    private var recent: some View {
        Group {
            if player.recentMedia.isEmpty {
                empty("还没有播放记录", symbol: "clock", hint: "打开媒体后，会在这里保存最近的播放位置。")
            } else {
                List(player.recentMedia) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(MediaItem(url: entry.url).title).lineLimit(1)
                            Text(entry.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(TimeText.format(entry.position)) / \(TimeText.format(entry.duration))").font(.caption.monospaced())
                        Button("继续播放") { player.open([entry.url]) }
                    }
                }
            }
        }
    }

    private var bookmarks: some View {
        Group {
            if player.library.bookmarks.isEmpty { empty("还没有书签", symbol: "bookmark", hint: "播放时添加当前位置，随时返回精彩片段。") }
            else {
                List {
                    ForEach(player.library.bookmarks.reversed()) { bookmark in
                        HStack {
                            Image(systemName: "bookmark.fill").foregroundStyle(.mint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(bookmark.title).lineLimit(1)
                                Text(MediaItem(url: bookmark.url).title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(TimeText.format(bookmark.position)).monospacedDigit().foregroundStyle(.secondary)
                            Button("编辑…") { state.edit(bookmark) }
                            Button("播放") { player.openBookmark(bookmark) }
                        }.padding(.vertical, 3).contextMenu {
                            Button("从书签播放") { player.openBookmark(bookmark) }
                            Button("编辑名称与时间…") { state.edit(bookmark) }
                            if bookmark.url.isFileURL { Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([bookmark.url]) } }
                            Button("删除书签", role: .destructive) { player.removeBookmark(bookmark.id) }
                        }
                    }
                }
            }
        }
    }

    private var favorites: some View {
        Group {
            if player.library.favorites.isEmpty { empty("收藏喜爱的媒体", symbol: "star", hint: "当前媒体可加入收藏，下次快速打开。") }
            else {
                List {
                    ForEach(player.library.favorites) { item in
                        HStack {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).lineLimit(1)
                                Text(item.url.isFileURL ? item.url.deletingLastPathComponent().path : item.url.absoluteString)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("播放") { player.open([item.url]) }
                        }.padding(.vertical, 3).contextMenu {
                            Button("播放") { player.open([item.url]) }
                            Button("加入当前列表") { player.open([item.url], append: true) }
                            if item.url.isFileURL { Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } }
                            Button("移除收藏", role: .destructive) {
                                player.library.toggleFavorite(url: item.url)
                                player.libraryRevision += 1
                            }
                        }
                    }
                }
            }
        }
    }

    private var savedPlaylists: some View {
        Group {
            if player.library.savedPlaylists.isEmpty { empty("保存常用播放列表", symbol: "text.badge.plus", hint: "为当前列表命名，集中保存课程、音乐和影片。") }
            else {
                List {
                    ForEach(player.library.savedPlaylists.reversed()) { playlist in
                        HStack {
                            Image(systemName: "list.bullet.rectangle").foregroundStyle(.mint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.name)
                                Text("\(playlist.urls.count) 个媒体").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("重命名…") { state.rename(playlist) }
                            Button("打开") { player.open(playlist.urls) }
                        }.padding(.vertical, 3).contextMenu {
                            Button("打开列表") { player.open(playlist.urls) }
                            Button("加入当前列表") { player.open(playlist.urls, append: true) }
                            Button("重命名…") { state.rename(playlist) }
                            Button("删除保存的列表", role: .destructive) { player.removeSavedPlaylist(playlist.id) }
                        }
                    }
                }
            }
        }
    }

    private func empty(_ title: String, symbol: String, hint: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(hint).font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class SubtitleEditorWindow: NSWindowController, NSWindowDelegate {
    private static var editors: [SubtitleEditorWindow] = []
    private var editingState: SubtitleEditingState?

    static func show(url: URL, onSaved: @escaping (URL) -> Void) {
        do {
            let state = SubtitleEditingState(document: try SubtitleDocument.read(from: url), sourceURL: url, onSaved: onSaved)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "字幕编辑器 · \(url.lastPathComponent)"
            window.minSize = NSSize(width: 860, height: 580)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SubtitleEditorView(state: state))
            let controller = SubtitleEditorWindow(window: window)
            controller.editingState = state
            window.delegate = controller
            editors.append(controller)
            window.center()
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法打开字幕编辑器"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    func windowWillClose(_ notification: Notification) { Self.editors.removeAll { $0 === self } }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let state = editingState, state.hasPendingChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "字幕修改尚未导出"
        alert.informativeText = "导出 SRT 以保存当前修改。"
        alert.addButton(withTitle: "导出并关闭")
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "放弃修改")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return state.exportSRT()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
}

@MainActor
private final class SubtitleEditingState: ObservableObject {
    @Published var document: SubtitleDocument
    @Published var selection: UUID?
    @Published var search = ""
    @Published var draftStart = ""
    @Published var draftEnd = ""
    @Published var draftText = ""
    @Published var offsetText = "0"
    @Published var factorText = "1"
    @Published var error: String?
    @Published var status = ""
    @Published private(set) var hasChanges = false
    private let sourceURL: URL
    private let onSaved: (URL) -> Void

    init(document: SubtitleDocument, sourceURL: URL, onSaved: @escaping (URL) -> Void) {
        self.document = document
        self.sourceURL = sourceURL
        self.onSaved = onSaved
        if let first = document.cues.first { select(first.id) }
    }

    var selectedIndex: Int? { document.cues.firstIndex { $0.id == selection } }
    var hasPendingChanges: Bool {
        guard let index = selectedIndex else { return hasChanges }
        let cue = document.cues[index]
        return hasChanges || draftText != cue.text || (try? SubtitleDocument.parseTimestamp(draftStart)) != cue.start
            || (try? SubtitleDocument.parseTimestamp(draftEnd)) != cue.end
    }
    var filteredCues: [SubtitleCue] {
        search.isEmpty ? document.cues : document.cues.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    func select(_ id: UUID?) {
        do {
            if selection != nil { try commitDraft() }
            selection = id
            refreshDraft()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func applyDraft() { perform { try commitDraft(); status = "已应用当前字幕的修改。" } }

    func shift() {
        perform {
            try commitDraft()
            guard let seconds = Double(offsetText.replacingOccurrences(of: ",", with: ".")) else { throw SubtitleDocumentError.invalidAdjustment }
            try document.shift(offset: seconds)
            if seconds != 0 { hasChanges = true }
            refreshDraft()
            status = "已将全部字幕偏移 \(seconds) 秒。"
        }
    }

    func scale() {
        perform {
            try commitDraft()
            guard let factor = Double(factorText.replacingOccurrences(of: ",", with: ".")) else { throw SubtitleDocumentError.invalidAdjustment }
            try document.scaleTime(factor: factor)
            if factor != 1 { hasChanges = true }
            refreshDraft()
            status = "已将全部字幕时间乘以 \(factor)。"
        }
    }

    func addCue() {
        perform {
            try commitDraft()
            let start = selectedIndex.map { document.cues[$0].end } ?? document.cues.last?.end ?? 0
            let cue = SubtitleCue(start: start, end: start + 2, text: "新字幕")
            let index = selectedIndex.map { $0 + 1 } ?? document.cues.count
            document.cues.insert(cue, at: index)
            hasChanges = true
            selection = cue.id
            refreshDraft()
            status = "已添加字幕，请编辑时间和正文。"
        }
    }

    func deleteCue() {
        guard let index = selectedIndex else { return }
        document.cues.remove(at: index)
        hasChanges = true
        selection = document.cues.isEmpty ? nil : document.cues[min(index, document.cues.count - 1)].id
        refreshDraft()
        error = nil
        status = "已删除字幕。"
    }

    @discardableResult
    func exportSRT() -> Bool {
        do {
            try commitDraft()
            try document.validate()
            let panel = NSSavePanel()
            panel.title = "导出 UTF-8 SRT 字幕"
            panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
            panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-edited.srt"
            panel.directoryURL = sourceURL.deletingLastPathComponent()
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            try document.writeSRT(to: url)
            hasChanges = false
            status = "已导出：\(url.lastPathComponent)"
            onSaved(url)
            error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    private func commitDraft() throws {
        guard let index = selectedIndex else { return }
        var changed = document
        changed.cues[index].start = try SubtitleDocument.parseTimestamp(draftStart)
        changed.cues[index].end = try SubtitleDocument.parseTimestamp(draftEnd)
        changed.cues[index].text = draftText
        try changed.validate()
        if changed.cues != document.cues { hasChanges = true }
        document = changed
    }

    private func refreshDraft() {
        guard let index = selectedIndex else { draftStart = ""; draftEnd = ""; draftText = ""; return }
        let cue = document.cues[index]
        draftStart = SubtitleDocument.timestamp(cue.start)
        draftEnd = SubtitleDocument.timestamp(cue.end)
        draftText = cue.text
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

private struct SubtitleEditorView: View {
    @ObservedObject var state: SubtitleEditingState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("文本字幕编辑器", systemImage: "captions.bubble").font(.title2.bold())
                Text("\(state.document.cues.count) 条").foregroundStyle(.secondary)
                Spacer()
                Button("导出 SRT 并载入播放器…") { state.exportSRT() }.buttonStyle(.borderedProminent)
            }
            Text("编辑正文、单条起止时间或批量校准时间；修改会自动保留在编辑器中，导出后生成新的 UTF-8 SRT 文件。")
                .font(.caption).foregroundStyle(.secondary)
            if state.document.losesFormatting {
                Label("\(state.document.sourceFormat.rawValue.uppercased()) 以纯文本编辑；导出 SRT 会去掉原有样式、定位、特效、绘图及元数据。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HSplitView {
                VStack(spacing: 10) {
                    TextField("搜索字幕正文", text: $state.search).textFieldStyle(.roundedBorder)
                    List(selection: Binding(get: { state.selection }, set: { state.select($0) })) {
                        ForEach(state.filteredCues) { cue in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(SubtitleDocument.timestamp(cue.start)) → \(SubtitleDocument.timestamp(cue.end))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(cue.text.replacingOccurrences(of: "\n", with: " / ")).lineLimit(2)
                            }.tag(cue.id).padding(.vertical, 3)
                        }
                    }
                    HStack {
                        Button { state.addCue() } label: { Label("添加", systemImage: "plus") }
                        Button { state.deleteCue() } label: { Label("删除", systemImage: "minus") }.disabled(state.selection == nil)
                        Spacer()
                    }
                }.frame(minWidth: 310, idealWidth: 420)
                VStack(alignment: .leading, spacing: 12) {
                    if state.selection != nil {
                        Text("第 \((state.selectedIndex ?? 0) + 1) 条字幕").font(.headline)
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("开始时间").font(.caption).foregroundStyle(.secondary)
                                TextField("00:00:00.000", text: $state.draftStart).font(.body.monospacedDigit())
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text("结束时间").font(.caption).foregroundStyle(.secondary)
                                TextField("00:00:00.000", text: $state.draftEnd).font(.body.monospacedDigit())
                            }
                        }.textFieldStyle(.roundedBorder)
                        TextEditor(text: $state.draftText).font(.body)
                            .frame(minHeight: 160).overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.25)))
                        HStack {
                            Text("支持多行文本，时间精确到毫秒。").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("应用当前条") { state.applyDraft() }
                        }
                    } else {
                        ContentUnavailableView("选择字幕进行编辑", systemImage: "text.bubble", description: Text("从左侧选择一条字幕，或添加新字幕。"))
                    }
                }.padding(.leading, 14).frame(minWidth: 380)
            }
            Divider()
            HStack {
                Text("全部偏移（秒）").font(.caption)
                TextField("如 -0.5", text: $state.offsetText).frame(width: 85)
                Button("应用偏移") { state.shift() }
                Spacer()
                Text("时间比例").font(.caption)
                TextField("1.0", text: $state.factorText).frame(width: 80)
                Button("应用比例") { state.scale() }
            }.textFieldStyle(.roundedBorder)
            Text("比例 = 原字幕帧率 ÷ 视频帧率。例如 25 fps 字幕配 23.976 fps 视频：1.04271。负偏移导致时间越界时会提示并保留原值。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = state.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            else if !state.status.isEmpty { Text(state.status).font(.callout).foregroundStyle(.secondary) }
            if !state.document.overlappingCueIndices.isEmpty {
                Text("有 \(state.document.overlappingCueIndices.count) 条字幕时间重叠；可继续编辑和导出。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }.padding(20).frame(minWidth: 840, minHeight: 540)
    }
}
