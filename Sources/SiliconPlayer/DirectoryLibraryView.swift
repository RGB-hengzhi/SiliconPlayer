import AppKit
import SwiftUI
import PlayerCore

@MainActor
private final class DirectoryLibraryForm: ObservableObject {
    @Published var selected: UUID?
    @Published var search = ""
}

@MainActor
struct DirectoryLibraryView: View {
    @ObservedObject var controller: DirectoryLibraryController
    let player: PlayerModel
    let choose: () -> Void
    @StateObject private var form = DirectoryLibraryForm()
    private var selected: DirectoryLibraryFolder? {
        controller.folders.first(where: { $0.id == form.selected }) ?? controller.folders.first
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("目录扫描与监控").font(.title2.bold())
                Spacer()
                Button("选择目录…", action: choose).disabled(!controller.canAcceptRequests)
            }
            Text("本次会话明确选择的本机目录；不会自动加入或播放，重启后不自动监控。")
                .font(.caption).foregroundStyle(.secondary)
            if controller.folders.isEmpty {
                Text("选择目录后在后台扫描，随后监听原生文件事件。最多四个目录。")
            } else {
                Picker("目录", selection: Binding(get: { selected?.id }, set: { form.selected = $0 })) {
                    ForEach(controller.folders) { folder in Text(folder.url.path).tag(Optional(folder.id)) }
                }.accessibilityIdentifier("directory-library-root")
                if let folder = selected { folderBody(folder) }
            }
            if let error = controller.error { Text(error).foregroundStyle(.orange) }
            Spacer(minLength: 0)
        }.padding(20).frame(minWidth: 780, minHeight: 560)
    }
    private func folderBody(_ folder: DirectoryLibraryFolder) -> some View {
        let files = folder.files.filter { form.search.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(form.search) }
        let mutable = controller.canAcceptRequests && !folder.closing
        return VStack(alignment: .leading, spacing: 10) {
            Text(folder.status).accessibilityIdentifier("directory-library-status")
            Text("扫描条目 \(folder.scanned) · 增 \(folder.delta.added) / 删 \(folder.delta.removed) / 改 \(folder.delta.modified)")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Toggle("含子目录", isOn: Binding(get: { folder.recursive }, set: { controller.setRecursive(folder.id, $0) }))
                    .disabled(!mutable)
                Button("手动刷新") { controller.refresh(folder.id) }.disabled(!mutable)
                Button("取消扫描") { controller.cancelScan(folder.id) }.disabled(!folder.scanning || !mutable)
                if folder.paused {
                    Button("恢复监听") { controller.resume(folder.id) }.disabled(!mutable)
                } else {
                    Button("暂停监听") { Task { await controller.pause(folder.id) } }.disabled(!mutable)
                }
                Button("移除监控") { Task { await controller.remove(folder.id) } }
                    .disabled(!controller.canAcceptRequests)
            }
            TextField("按相对路径筛选", text: $form.search).accessibilityIdentifier("directory-library-search")
            HStack {
                Text("\(files.count) 个筛选结果 / \(folder.files.count) 个媒体")
                Spacer()
                Button("加入筛选前 200 项") { player.appendDirectoryLibraryFiles(Array(files.prefix(200)).map(\.url)) }
                    .disabled(!folder.available || folder.closing || !controller.canAcceptRequests || files.isEmpty)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(files) { file in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(file.relativePath).lineLimit(2)
                                Text(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("加入") { player.appendDirectoryLibraryFiles([file.url]) }
                            Button("播放") { player.open([file.url]) }
                        }.disabled(!folder.available || folder.closing || !controller.canAcceptRequests)
                        Divider()
                    }
                }
            }.frame(minHeight: 250)
            Text("不跟随符号链接、不扫描隐藏项／应用包或其他挂载卷。完整扫描受 100000 项、20000 媒体、32 层、30 秒限制；达到上限保留旧清单。变化按路径、文件身份、大小及修改时间核对。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class DirectoryLibraryWindow: NSWindowController, NSWindowDelegate {
    private static var current: DirectoryLibraryWindow?
    private let controller = DirectoryLibraryController()
    private var panel: NSOpenPanel?
    private var closeTask: Task<Void, Never>?
    private var closeApproved = false
    private var closing = false

    static func ownsPlaybackInput(_ event: NSEvent) -> Bool {
        event.window != nil && event.window === current?.window
    }
    static func cancelPanelsForTermination() {
        current?.closing = true
        current?.panel?.cancel(nil); current?.panel = nil
    }
    static func resumeAfterCancelledTermination() { current?.closing = false }
    static func show(player: PlayerModel) {
        guard DirectoryLibraryController.allowsNewWindow else { player.toast("目录任务正在退出收尾。"); return }
        if let current {
            current.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let owner = DirectoryLibraryWindow(player: player); current = owner
        owner.showWindow(nil); owner.window?.makeKeyAndOrderFront(nil)
    }
    private init(player: PlayerModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "目录扫描与监控"; window.isReleasedWhenClosed = false; window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: DirectoryLibraryView(controller: controller,
            player: player, choose: { [weak self] in self?.chooseDirectory() }))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func chooseDirectory() {
        guard !closing, panel == nil, controller.canAcceptRequests, let window else { return }
        let panel = NSOpenPanel(); self.panel = panel
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "扫描并监控"; panel.message = "选择本次会话明确监控的目录；不会自动播放。"
        panel.beginSheetModal(for: window) { [weak self, weak panel] reply in
            Task { @MainActor in
                guard let self, let panel, self.panel === panel else { return }
                self.panel = nil
                guard reply == .OK, !self.closing, self.controller.canAcceptRequests, let url = panel.url else { return }
                self.controller.add(url)
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeApproved { return true }
        guard closeTask == nil else { return false }
        closing = true; panel?.cancel(nil); panel = nil
        closeTask = Task { @MainActor in
            let released = await controller.closeWindowOwner()
            closeTask = nil
            if released {
                closeApproved = true; sender.performClose(nil)
            } else {
                closing = false
                // Keep this same owner/window for Retry; never create a second
                // hidden resource owner after an unconfirmed close.
                controller.resumeAfterWindowCloseFailure()
                sender.makeKeyAndOrderFront(nil)
            }
        }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        if closeApproved, Self.current === self { Self.current = nil }
    }
}
