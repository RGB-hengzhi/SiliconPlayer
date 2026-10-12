import AppKit
import SwiftUI
import PlayerCore

@MainActor
private final class FTPBrowserForm: ObservableObject {
    @Published var search = ""
}

@MainActor
struct FTPBrowserView: View {
    @ObservedObject var controller: FTPBrowserController
    let player: PlayerModel
    @StateObject private var form = FTPBrowserForm()
    private var results: [FTPDirectoryResource] {
        controller.resources.filter { form.search.isEmpty || $0.name.localizedCaseInsensitiveContains(form.search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FTP / FTPS 文件").font(.title2.bold())
            Text("手动连接与当前目录枚举；没有自动登录、目录写入或后台重连。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("ftp://server/folder/ 或 ftps://server/folder/", text: $controller.addressText)
                    .accessibilityIdentifier("ftp-address")
                Button("连接目录") { controller.connect() }.disabled(!controller.canRequest)
                Button("重新连接 / 刷新") { controller.reconnect() }.disabled(!controller.canRequest)
                Button("断开") { Task { await controller.disconnect() } }.disabled(!controller.canRequest)
            }.textFieldStyle(.roundedBorder).disabled(!controller.canRequest)
            HStack {
                TextField("账号（空为匿名）", text: $controller.username).accessibilityIdentifier("ftp-username")
                SecureField("密码（仅内存；可明确保存）", text: $controller.password).accessibilityIdentifier("ftp-password")
                Toggle("要求 TLS", isOn: $controller.requireTLS)
            }.textFieldStyle(.roundedBorder).disabled(!controller.canRequest)
            HStack {
                Button("选择该连接 CA PEM…") { controller.chooseCertificateAuthority() }.disabled(!controller.requireTLS)
                Button("恢复系统信任") { controller.restoreSystemTrust() }.disabled(controller.certificateAuthority == nil)
                if let ca = controller.certificateAuthority {
                    Text("\(ca.name) · SHA256 \(ca.sha256.prefix(16)) · \(ca.scope.description)").font(.caption).lineLimit(2)
                } else { Text("系统默认信任").font(.caption).foregroundStyle(.secondary) }
            }.disabled(!controller.canRequest)
            Text("CA 仅用于本窗口明确选择的协议/主机/端口/TLS 连接，不写系统信任或配置备份；证书链与主机名校验始终开启。更换主机需重新选择。")
                .font(.caption).foregroundStyle(.secondary)
            if !controller.requireTLS {
                Text("普通 FTP 的账号、密码与文件在网络上传输时不加密。ftps:// 始终要求 TLS。")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("保存密码到钥匙串") { controller.keychainAction("save") }.disabled(controller.username.isEmpty)
                Button("读取已保存密码") { controller.keychainAction("read") }.disabled(controller.username.isEmpty)
                Button("删除已保存密码") { controller.keychainAction("delete") }.disabled(controller.username.isEmpty)
                Button("清空内存凭据") { controller.username = ""; controller.password = "" }
            }.disabled(!controller.canRequest)
            Divider()
            HStack {
                Button("上一级") { if let parent = controller.directory?.parent { controller.connect(parent) } }
                    .disabled(!controller.canRequest || controller.directory?.parent == nil)
                Text(controller.directory?.url.path ?? "尚未连接").lineLimit(1)
                Spacer()
                TextField("搜索当前目录", text: $form.search).frame(width: 210)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(results) { resource in
                        HStack {
                            Image(systemName: resource.isDirectory ? "folder" : "play.rectangle")
                            VStack(alignment: .leading) {
                                Text(resource.name).lineLimit(2)
                                if let bytes = resource.bytes { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if resource.isDirectory {
                                Button("打开目录") {
                                    if let next = try? FTPDirectoryAddress(resource.url.absoluteString, requireTLS: controller.directory?.requireTLS ?? true) { controller.connect(next) }
                                }
                            } else if controller.readyCopies[resource.url] != nil {
                                Button("播放本机副本") { controller.playCopy(resource, player: player) }
                                Button("副本加入队列") { controller.playCopy(resource, player: player, append: true) }
                            } else {
                                Button("下载后播放") { controller.download(resource, player: player) }
                                Button("下载后加入队列") { controller.download(resource, player: player, append: true) }
                            }
                        }.disabled(!controller.canRequest)
                        Divider()
                    }
                }
            }.frame(minHeight: 270)
            HStack {
                if controller.busy { ProgressView().controlSize(.small) }
                Text(controller.status).font(.callout).accessibilityIdentifier("ftp-status")
                Spacer()
                if controller.busy || !controller.canRequest { Button("取消 / 重试清理") { Task { _ = await controller.shutdown(); controller.resumeAfterWindowCloseFailure() } } }
                else { Button("取消") { controller.cancel() }.disabled(true) }
            }
            if let total = controller.expectedBytes, total > 0 {
                ProgressView(value: min(1, Double(controller.receivedBytes) / Double(total)))
            }
            if let error = controller.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            Text("只下载完整文件到专用本机缓存；不把凭据 URL 放入队列。MLSD UTF-8 上限 8 MiB / 20000 项；单文件 20 GiB，每窗最多 32 个缓存记录。钥匙串不进入配置备份。")
                .font(.caption).foregroundStyle(.secondary)
            Text("SFTP 尚未接入。SMB/NAS 仍需在 Finder 挂载后通过普通媒体入口打开；此窗口不执行挂载。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 900, minHeight: 640)
    }
}

@MainActor
final class FTPBrowserWindow: NSWindowController, NSWindowDelegate {
    private static var current: FTPBrowserWindow?
    private let controller = FTPBrowserController()
    private var closeTask: Task<Void, Never>?
    private var approvedClose = false
    private var terminating = false
    static func ownsPlaybackInput(_ event: NSEvent) -> Bool { event.window != nil && event.window === current?.window }
    static func beginUserTermination() { current?.terminating = true }
    static func resumeAfterCancelledTermination() { current?.terminating = false }
    static func show(player: PlayerModel) {
        guard FTPBrowserController.canCreate else { player.toast("网络任务正在退出收尾。"); return }
        if let current { current.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let owner = FTPBrowserWindow(player: player); current = owner
        owner.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private init(player: PlayerModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 670),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "FTP / FTPS 文件 — SiliconPlayer"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        window.contentView = NSHostingView(rootView: FTPBrowserView(controller: controller, player: player)); window.center()
    }
    required init?(coder: NSCoder) { nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if approvedClose { return true }
        guard !terminating, closeTask == nil else { return false }
        closeTask = Task { @MainActor [self] in
            let released = await controller.releaseWindow()
            closeTask = nil
            if released { approvedClose = true; sender.close() }
            else { controller.resumeAfterWindowCloseFailure() }
        }
        return false
    }
    func windowWillClose(_ notification: Notification) { if Self.current === self { Self.current = nil } }
}
