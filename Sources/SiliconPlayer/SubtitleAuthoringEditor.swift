import AppKit
import SwiftUI
import PlayerCore
import UniformTypeIdentifiers

/// Separate from translation/ASR's plain-text SubtitleDocument. Saving a copy
/// does not select, remove, reload, or delay either player subtitle track.
/// A permit covers the exact retained editor set and its current edit revision.
/// Discard does not erase in-memory contents; a canceled App exit revokes it.
struct SubtitleAuthoringQuitPermit {
    private(set) var reviewed: [UUID: UInt64] = [:]
    mutating func approve(editor: UUID, revision: UInt64) { reviewed[editor] = revision }
    func permits(_ current: [UUID: UInt64]) -> Bool { reviewed == current }
}


@MainActor
final class SubtitleAuthoringWindow: NSWindowController, NSWindowDelegate {
    private static var editors: [SubtitleAuthoringWindow] = []
    private var state: SubtitleAuthoringState?

    private final class QuitReview {
        let editors: [SubtitleAuthoringWindow]
        let approved: () -> Void
        var permit = SubtitleAuthoringQuitPermit()
        var isApproved = false
        init(editors: [SubtitleAuthoringWindow], approved: @escaping () -> Void) {
            self.editors = editors; self.approved = approved
        }
    }
    private static var quitReview: QuitReview?
    private static var emptyEditorQuitPermit = false
    private let terminationID = UUID()

    static var appTerminationReviewIsActive: Bool {
        guard let review = quitReview else { return false }
        return !review.isApproved
    }

    static func cancelAppTerminationReview() {
        let prior = quitReview; quitReview = nil; emptyEditorQuitPermit = false
        for editor in prior?.editors ?? [] { editor.state?.setAppTerminationLocked(false) }
    }

    /// False means the App must terminateCancel before beginning resource cleanup.
    /// Approval calls the existing native user-termination timer entry, once all
    /// async save/alert callbacks have completed and their exact editor set agrees.
    static func allowAppTermination(onApproval: @escaping () -> Void) -> Bool {
        if let review = quitReview {
            guard review.isApproved else { return false }
            guard let revisions = currentRevisions(), review.permit.permits(revisions) else {
                cancelAppTerminationReview(); NSSound.beep(); return false
            }
            return true
        }
        if editors.isEmpty {
            emptyEditorQuitPermit = true
            return true
        }
        emptyEditorQuitPermit = false
        let review = QuitReview(editors: editors, approved: onApproval)
        quitReview = review
        for editor in review.editors { editor.state?.setAppTerminationLocked(true) }
        DispatchQueue.main.async { reviewNext(review) }
        return false
    }

    /// Called immediately before irreversible finalization/actual reply(true).
    /// A clean editor is still locked/reviewed, and direct late mutations or
    /// set changes must cancel the exit rather than losing new unsaved input.
    static func confirmAppTerminationPermit() -> Bool {
        if emptyEditorQuitPermit { return editors.isEmpty && quitReview == nil }
        guard let review = quitReview, review.isApproved,
              review.editors.allSatisfy({ $0.state?.appTerminationLocked == true }),
              let revisions = currentRevisions() else { return false }
        return review.permit.permits(revisions)
    }

    private static func currentRevisions() -> [UUID: UInt64]? {
        var result: [UUID: UInt64] = [:]
        for editor in editors {
            guard let revision = editor.state?.terminationRevision else { return nil }
            result[editor.terminationID] = revision
        }
        return result
    }

    private static func reviewNext(_ review: QuitReview) {
        guard quitReview === review, !review.isApproved else { return }
        guard Set(editors.map(\.terminationID)) == Set(review.editors.map(\.terminationID)) else {
            cancelAppTerminationReview(); return
        }
        for editor in review.editors {
            guard let state = editor.state, let revision = state.terminationRevision else {
                cancelAppTerminationReview(); return
            }
            if review.permit.reviewed[editor.terminationID] == revision { continue }
            if !state.hasPendingChanges {
                review.permit.approve(editor: editor.terminationID, revision: revision); continue
            }
            guard let window = editor.window, window.attachedSheet == nil else {
                cancelAppTerminationReview(); return
            }
            let alert = NSAlert(); alert.messageText = "字幕修改尚未保存"
            alert.informativeText = "\(window.title)\n保存同格式副本后退出，或保留窗口继续编辑。原始字幕不会被覆盖。"
            alert.addButton(withTitle: "保存副本并退出")
            alert.addButton(withTitle: "取消退出")
            alert.addButton(withTitle: "放弃本次修改并退出")
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated {
                    guard quitReview === review, state.appTerminationLocked,
                          state.terminationRevision == revision else {
                        if quitReview === review { cancelAppTerminationReview() }
                        return
                    }
                    switch response {
                    case .alertFirstButtonReturn:
                        // beginSheetModal invokes its completion while AppKit may
                        // still detach the alert. Defer before attaching save panel.
                        DispatchQueue.main.async {
                            guard quitReview === review, state.appTerminationLocked,
                                  window.attachedSheet == nil else {
                                if quitReview === review { cancelAppTerminationReview() }; return
                            }
                            state.exportCopyForAppTermination(window: window) { saved in
                                guard quitReview === review else { return }
                                guard saved, let savedRevision = state.terminationRevision else {
                                    cancelAppTerminationReview(); return
                                }
                                review.permit.approve(editor: editor.terminationID, revision: savedRevision)
                                DispatchQueue.main.async { reviewNext(review) }
                            }
                        }
                    case .alertThirdButtonReturn:
                        review.permit.approve(editor: editor.terminationID, revision: revision)
                        DispatchQueue.main.async { reviewNext(review) }
                    default: cancelAppTerminationReview()
                    }
                }
            }
            return
        }
        guard let revisions = currentRevisions(), review.permit.permits(revisions) else {
            cancelAppTerminationReview(); return
        }
        review.isApproved = true
        DispatchQueue.main.async {
            guard quitReview === review, review.isApproved,
                  let revisions = currentRevisions(), review.permit.permits(revisions) else {
                if quitReview === review { cancelAppTerminationReview() }; return
            }
            review.approved()
        }
    }

    static func show(url: URL, observedPlayerTime: (() throws -> Int64)? = nil, seekPlayer: ((Int64) throws -> Void)? = nil) {
        guard quitReview == nil, !emptyEditorQuitPermit else { NSSound.beep(); return }
        do {
            let state = SubtitleAuthoringState(document: try PreservingSubtitleDocument.read(from: url), sourceURL: url, observedPlayerTime: observedPlayerTime, seekPlayer: seekPlayer)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "字幕编辑器 · \(url.lastPathComponent)"
            window.minSize = NSSize(width: 950, height: 740)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SubtitleAuthoringView(state: state))
            let controller = SubtitleAuthoringWindow(window: window)
            controller.state = state; window.delegate = controller; editors.append(controller)
            window.center(); controller.showWindow(nil); window.makeKeyAndOrderFront(nil)
        } catch {
            let alert = NSAlert(); alert.messageText = "无法打开字幕编辑器"
            alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
    func windowWillClose(_ notification: Notification) {
        Self.editors.removeAll { $0 === self }
        if Self.quitReview != nil { Self.cancelAppTerminationReview() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if state?.appTerminationLocked == true { return false }
        guard let state, state.hasPendingChanges else { return true }
        let alert = NSAlert(); alert.messageText = "字幕修改尚未保存"
        alert.informativeText = "保存同格式副本以保留当前修改。原始文件保持不变。"
        alert.addButton(withTitle: "保存副本并关闭"); alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃修改")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return state.exportCopy()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
}

@MainActor
final class SubtitleAuthoringState: ObservableObject {
    @Published private(set) var document: PreservingSubtitleDocument { didSet { noteAuthoringEdit() } }
    @Published var selection: UUID?
    @Published var search = ""
    @Published var draftStart = "" { didSet { if oldValue != draftStart { noteAuthoringEdit() } } }
    @Published var draftEnd = "" { didSet { if oldValue != draftEnd { noteAuthoringEdit() } } }
    @Published var draftText = "" { didSet { if oldValue != draftText { noteAuthoringEdit() } } }
    @Published var offsetText = "0"
    @Published var factorText = "1"
    @Published var sourceA = ""
    @Published var videoA = ""
    @Published var sourceB = ""
    @Published var videoB = ""
    @Published var subtitleFPS = "25"
    @Published var videoFPS = "23.976"
    @Published var allowRounding = false
    @Published var error: String?
    @Published var status = ""
    @Published private(set) var hasChanges = false
    private let sourceURL: URL

    @Published private(set) var appTerminationLocked = false
    private var authoringRevision: UInt64 = 0
    private var authoringRevisionOverflow = false
    var terminationRevision: UInt64? { authoringRevisionOverflow ? nil : authoringRevision }
    func setAppTerminationLocked(_ locked: Bool) { appTerminationLocked = locked }
    private func noteAuthoringEdit() {
        let next = authoringRevision.addingReportingOverflow(1)
        if next.overflow { authoringRevisionOverflow = true }
        else { authoringRevision = next.partialValue }
    }

    /// The App quit review keeps authoring controls locked. Saving still commits
    /// the real draft, validates the complete format, and writes the same-format
    /// copy through the existing alias-safe writer. Save cancel/failure keeps it
    /// dirty and cancels the App request; no original is overwritten.
    func exportCopyForAppTermination(window: NSWindow, completion: @escaping (Bool) -> Void) {
        guard appTerminationLocked else { completion(false); return }
        do { try commitDraft(); try document.validate() }
        catch { self.error = error.localizedDescription; completion(false); return }
        guard let expectedRevision = terminationRevision else {
            error = "字幕编辑代次达到上限，请先保存副本。"; completion(false); return
        }
        let ext = document.format.rawValue; let panel = NSSavePanel()
        panel.title = "保存 UTF-8 \(ext.uppercased()) 副本后退出"
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-edited." + ext
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, self.appTerminationLocked,
                      self.terminationRevision == expectedRevision,
                      response == .OK, let url = panel.url else { completion(false); return }
                do {
                    try self.document.writeCopy(to: url, sourceURL: self.sourceURL)
                    self.hasChanges = false; self.error = nil
                    self.status = "已保存副本：\(url.lastPathComponent)。原始字幕保持不变。"
                    completion(true)
                } catch { self.error = error.localizedDescription; completion(false) }
            }
        }
    }
    private let observedPlayerTime: (() throws -> Int64)?
    private let seekPlayer: ((Int64) throws -> Void)?

    init(document: PreservingSubtitleDocument, sourceURL: URL, observedPlayerTime: (() throws -> Int64)?, seekPlayer: ((Int64) throws -> Void)? = nil) {
        self.document = document; self.sourceURL = sourceURL; self.observedPlayerTime = observedPlayerTime; self.seekPlayer = seekPlayer
        selection = document.cues.first?.id; refreshDraft()
    }
    var selectedIndex: Int? { document.cues.firstIndex { $0.id == selection } }
    var hasPendingChanges: Bool {
        guard let index = selectedIndex else { return hasChanges }
        let cue = document.cues[index]
        return hasChanges || draftText != cue.rawBody || (try? document.parseEditableTime(draftStart)) != cue.startMicroseconds
            || (try? document.parseEditableTime(draftEnd)) != cue.endMicroseconds
    }
    var filteredCues: [PreservingSubtitleCue] {
        search.isEmpty ? document.cues : document.cues.filter { $0.rawBody.localizedCaseInsensitiveContains(search) }
    }
    var canCapturePlayerTime: Bool { observedPlayerTime != nil && selectedIndex != nil }
    var canSeekCue: Bool { seekPlayer != nil && selectedIndex != nil }
    var precision: SubtitleQuantization { allowRounding ? .nearestNativeTick : .exact }

    func select(_ id: UUID?) {
        perform { if selection != nil { try commitDraft() }; selection = id; refreshDraft() }
    }
    func applyDraft() { perform { try commitDraft(); status = "已应用当前字幕的修改。" } }
    func shift() {
        perform {
            try commitDraft(); let before = try document.text()
            try document.shift(decimalSeconds: offsetText.replacingOccurrences(of: ",", with: "."))
            let after = try document.text(); if before != after { hasChanges = true }; refreshDraft(); status = "已按原格式刻度应用偏移。"
        }
    }
    func scale() {
        perform {
            try commitDraft(); let before = try document.text()
            try document.scale(decimalFactor: factorText.replacingOccurrences(of: ",", with: "."), quantization: precision)
            let after = try document.text(); if before != after { hasChanges = true }; refreshDraft(); status = "已应用时间比例。"
        }
    }
    func convertFrameRate() {
        perform {
            try commitDraft()
            let map = try SubtitleTwoPointMap.frameRateConversion(subtitleFPS: subtitleFPS, videoFPS: videoFPS)
            let before = try document.text(); try document.calibrate(map, quantization: precision)
            let after = try document.text(); if before != after { hasChanges = true }; refreshDraft()
            status = "已按字幕帧率 ÷ 视频帧率的精确比例转换。"
        }
    }
    func moveSelection(_ direction: Int) {
        guard let index = selectedIndex else { return }
        let target = index + direction
        guard document.cues.indices.contains(target) else { return }
        select(document.cues[target].id)
    }
    func locateCue() {
        perform {
            try commitDraft()
            guard let index = selectedIndex, let seekPlayer else { throw SubtitlePreservationError.invalid("没有绑定的播放器") }
            try seekPlayer(document.cues[index].startMicroseconds)
            status = "已请求定位到所选字幕；未改变主、副字幕选择。"
        }
    }
    func captureAnchor(first: Bool) {
        perform {
            try commitDraft()
            guard let index = selectedIndex, let observedPlayerTime else { throw SubtitlePreservationError.invalid("没有绑定的播放器时间") }
            let source = document.displayTime(document.cues[index].startMicroseconds)
            let video = try Self.exactDisplay(observedPlayerTime())
            if first { sourceA = source; videoA = video } else { sourceB = source; videoB = video }
            status = "已取所选字幕起点与当前播放器时间；仅记录锚点，不改变播放或字幕选择。"
        }
    }
    func calibrate() {
        perform {
            try commitDraft()
            let map = try SubtitleTwoPointMap(sourceA: SubtitleExactClock.parse(sourceA.replacingOccurrences(of: ",", with: ".")),
                videoA: SubtitleExactClock.parse(videoA.replacingOccurrences(of: ",", with: ".")),
                sourceB: SubtitleExactClock.parse(sourceB.replacingOccurrences(of: ",", with: ".")),
                videoB: SubtitleExactClock.parse(videoB.replacingOccurrences(of: ",", with: ".")))
            let before = try document.text(); try document.calibrate(map, quantization: precision)
            let after = try document.text(); if before != after { hasChanges = true }; refreshDraft()
            status = allowRounding ? "已两点校准，并明确舍入到原格式刻度。" : "已精确两点校准。"
        }
    }
    func addCue() {
        perform { try commitDraft(); selection = try document.insert(after: selection); hasChanges = true; refreshDraft(); status = "已添加字幕。" }
    }
    func deleteCue() {
        guard !appTerminationLocked else { return }
        guard let index = selectedIndex, let id = selection else { return }
        document.remove(id: id); hasChanges = true
        selection = document.cues.isEmpty ? nil : document.cues[min(index, document.cues.count - 1)].id
        refreshDraft(); error = nil; status = "已删除字幕。"
    }
    @discardableResult func exportCopy() -> Bool {
        guard !appTerminationLocked else { return false }
        do {
            try commitDraft(); try document.validate()
            let ext = document.format.rawValue; let panel = NSSavePanel()
            panel.title = "保存 UTF-8 \(ext.uppercased()) 副本"
            panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
            panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-edited." + ext
            panel.directoryURL = sourceURL.deletingLastPathComponent()
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            try document.writeCopy(to: url, sourceURL: sourceURL)
            hasChanges = false; error = nil; status = "已保存副本：\(url.lastPathComponent)。可从字幕菜单明确载入。"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    private func commitDraft() throws {
        guard let index = selectedIndex else { return }
        let cue = document.cues[index]; var changed = document
        try changed.update(id: cue.id, start: document.parseEditableTime(draftStart), end: document.parseEditableTime(draftEnd), rawBody: draftText)
        if changed.cues != document.cues { hasChanges = true }; document = changed
    }
    private func refreshDraft() {
        guard let index = selectedIndex else { draftStart = ""; draftEnd = ""; draftText = ""; return }
        let cue = document.cues[index]; draftStart = document.displayTime(cue.startMicroseconds)
        draftEnd = document.displayTime(cue.endMicroseconds); draftText = cue.rawBody
    }
    private func perform(_ action: () throws -> Void) {
        guard !appTerminationLocked else { return }
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
    private static func exactDisplay(_ value: Int64) throws -> String {
        guard value >= 0, value <= SubtitleExactClock.maximumMicroseconds else { throw SubtitlePreservationError.bounds }
        let seconds = value / 1_000_000
        return String(format: "%02lld:%02lld:%02lld.%06lld", seconds / 3600, seconds / 60 % 60, seconds % 60, value % 1_000_000)
    }
}

@MainActor
private struct SubtitleAuthoringView: View {
    @ObservedObject var state: SubtitleAuthoringState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("字幕编辑器 · \(state.document.format.rawValue.uppercased())", systemImage: "captions.bubble").font(.title2.bold())
                Text("\(state.document.cues.count) 条").foregroundStyle(.secondary); Spacer()
                Button("保存同格式副本…") { state.exportCopy() }.buttonStyle(.borderedProminent).accessibilityLabel("保存同格式字幕副本")
            }
            Text("原样保留未修改的样式、定位、标签与元数据。编辑原始正文后保存 UTF-8 同格式副本；保存不会改变主、副字幕选择。")
                .font(.caption).foregroundStyle(.secondary)
            HSplitView {
                VStack(spacing: 10) {
                    TextField("搜索原始字幕正文", text: $state.search).textFieldStyle(.roundedBorder).accessibilityLabel("搜索字幕正文")
                    List(selection: Binding(get: { state.selection }, set: { state.select($0) })) {
                        ForEach(state.filteredCues) { cue in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(state.document.displayTime(cue.startMicroseconds)) → \(state.document.displayTime(cue.endMicroseconds))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(cue.rawBody.replacingOccurrences(of: "\n", with: " / ")).lineLimit(2)
                            }.tag(cue.id).padding(.vertical, 3)
                        }
                    }
                    HStack { Button("添加字幕") { state.addCue() }; Button("删除所选字幕") { state.deleteCue() }.disabled(state.selection == nil); Spacer() }
                    HStack {
                        Button("上一条") { state.moveSelection(-1) }.accessibilityLabel("选择上一条字幕")
                        Button("下一条") { state.moveSelection(1) }.accessibilityLabel("选择下一条字幕")
                        Button("定位所选字幕") { state.locateCue() }.disabled(!state.canSeekCue).accessibilityLabel("定位播放器到所选字幕")
                    }
                }.frame(minWidth: 300, idealWidth: 400)
                VStack(alignment: .leading, spacing: 10) {
                    if state.selection != nil {
                        Text("第 \((state.selectedIndex ?? 0) + 1) 条字幕").font(.headline)
                        HStack {
                            VStack(alignment: .leading) { Text("开始时间"); TextField("开始时间", text: $state.draftStart).accessibilityLabel("所选字幕开始时间") }
                            VStack(alignment: .leading) { Text("结束时间"); TextField("结束时间", text: $state.draftEnd).accessibilityLabel("所选字幕结束时间") }
                        }.textFieldStyle(.roundedBorder).font(.body.monospacedDigit())
                        TextEditor(text: $state.draftText).font(.body.monospaced()).frame(minHeight: 130).accessibilityLabel("字幕原始正文和标签")
                        HStack { Text("时间刻度：\(state.document.nativePrecisionDescription)。").font(.caption); Spacer(); Button("应用当前条") { state.applyDraft() } }
                        if state.document.format == .ass || state.document.format == .ssa {
                            Text("保留 {\\…} overrides 与绘图；换行使用 \\N。两点校准仅变更事件起止时间，相对动画/卡拉 OK 标签数值保持原样。").font(.caption).foregroundStyle(.secondary)
                        }
                    } else { ContentUnavailableView("选择字幕进行编辑", systemImage: "text.bubble") }
                }.padding(.leading, 12).frame(minWidth: 440)
            }
            Divider()
            Text("两点同步：先填字幕与视频的对应 A 点，再填较晚的 B 点。视频锚点可输入到微秒；输出遵守原格式刻度。").font(.caption).foregroundStyle(.secondary)
            HStack {
                VStack(alignment: .leading) { Text("字幕 A"); TextField("00:00:00.000", text: $state.sourceA).accessibilityLabel("两点同步字幕 A") }
                VStack(alignment: .leading) { Text("视频 A"); TextField("00:00:00.000000", text: $state.videoA).accessibilityLabel("两点同步视频 A") }
                Button("取当前时间为 A") { state.captureAnchor(first: true) }.disabled(!state.canCapturePlayerTime)
                VStack(alignment: .leading) { Text("字幕 B"); TextField("00:00:00.000", text: $state.sourceB).accessibilityLabel("两点同步字幕 B") }
                VStack(alignment: .leading) { Text("视频 B"); TextField("00:00:00.000000", text: $state.videoB).accessibilityLabel("两点同步视频 B") }
                Button("取当前时间为 B") { state.captureAnchor(first: false) }.disabled(!state.canCapturePlayerTime)
            }.textFieldStyle(.roundedBorder).font(.body.monospacedDigit())
            HStack {
                Toggle("允许舍入到原格式刻度", isOn: $state.allowRounding).accessibilityLabel("允许字幕时间舍入")
                Button("应用两点同步") { state.calibrate() }.accessibilityLabel("应用两点字幕同步")
                Spacer(); Text("整体偏移（秒）").font(.caption); TextField("-0.5", text: $state.offsetText).frame(width: 72)
                Button("偏移") { state.shift() }; Text("比例").font(.caption); TextField("1.0", text: $state.factorText).frame(width: 70); Button("比例") { state.scale() }
            }.textFieldStyle(.roundedBorder)
            HStack {
                Text("字幕帧率").font(.caption); TextField("25", text: $state.subtitleFPS).frame(width: 90).accessibilityLabel("原字幕帧率")
                Text("视频帧率").font(.caption); TextField("23.976", text: $state.videoFPS).frame(width: 90).accessibilityLabel("目标视频帧率")
                Button("帧率转换") { state.convertFrameRate() }
                Text("十进制帧率按输入值精确计算；非刻度结果默认拒绝。相对 ASS 特效参数保持原值。").font(.caption).foregroundStyle(.secondary)
            }.textFieldStyle(.roundedBorder)
            if let error = state.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            else if !state.status.isEmpty { Text(state.status).foregroundStyle(.secondary) }
            if state.hasPendingChanges { Text("有未保存修改").font(.caption).foregroundStyle(.orange) }
        }.padding(18).frame(minWidth: 920, minHeight: 700)
            .disabled(state.appTerminationLocked)
    }
}
