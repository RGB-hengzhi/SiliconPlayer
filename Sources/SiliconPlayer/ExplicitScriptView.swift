import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor private final class ExplicitScriptForm: ObservableObject {
    @Published var trusted = false
    @Published var selectedID: UUID?
    @Published var messageName = ""
    @Published var messageArgument = ""
    @Published var importPanel: NSOpenPanel?
}

@MainActor struct ExplicitScriptView: View {
    @ObservedObject var controller: ExplicitScriptController
    let close: () -> Void
    @StateObject private var form = ExplicitScriptForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lua / JavaScript 扩展").font(.title2.bold())
                Spacer()
                Button("完成", action: close).keyboardShortcut(.defaultAction)
            }
            Text("脚本与播放器拥有相同的文件、网络和进程权限。这里只管理本地副本，并不提供沙箱。无限循环等脚本错误可能阻止播放器退出。")
                .font(.callout).foregroundStyle(.secondary)
            Text("导入和启用都不会自动执行；本次载入需要明确点击。已载入的脚本没有通用卸载接口，禁用或删除在下一次启动生效，本次仍可能执行。")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("我信任所选择的脚本，并了解本次载入的权限与退出风险", isOn: $form.trusted)
                .accessibilityIdentifier("explicit-scripts-trust")
            HStack {
                Button("导入本地 .lua / .js…", action: chooseImport)
                    .accessibilityIdentifier("explicit-scripts-import")
                Button("刷新记录") { controller.refresh() }
                Spacer()
                Text("最多 64 个单文件，每个 1 MiB").font(.caption).foregroundStyle(.secondary)
            }
            List(selection: $form.selectedID) {
                ForEach(controller.records) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(item.title).lineLimit(1)
                            Text(item.language.rawValue.uppercased()).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Toggle("启用", isOn: Binding(get: { item.enabled }, set: { controller.setEnabled(item.id, $0) }))
                                .disabled(item.pendingDeletion)
                            Button("本次载入") { controller.load(item.id) }
                                .disabled(!form.trusted || !controller.canLoad(item))
                            Button(controller.runtime[item.id] == nil ? "删除" : "下次启动删除") { controller.delete(item.id) }
                                .disabled(item.pendingDeletion)
                        }
                        Text(item.pendingDeletion ? "删除待生效，托管副本保留" : controller.runtime[item.id]?.text ?? "未提交执行")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("SHA256 " + item.sha256).font(.system(.caption2, design: .monospaced)).lineLimit(1)
                    }
                    .tag(item.id)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("向所选脚本发送自定义消息").font(.headline)
                HStack {
                    TextField("脚本声明的消息名", text: $form.messageName)
                    TextField("一个参数（可留空）", text: $form.messageArgument)
                    Button("发送") {
                        if let selectedID = form.selectedID { controller.sendMessage(selectedID, name: form.messageName, argument: form.messageArgument) }
                    }
                    .disabled(!form.trusted || !controller.alive || form.selectedID.flatMap { controller.runtime[$0]?.clientID } == nil)
                }
                Text("这里只确认 mpv 定向投递；没有通用的关闭消息，不能把发送成功当作处理或卸载成功。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(controller.status).font(.callout)
            if let error = controller.error { Text(error).foregroundStyle(.red).font(.callout) }
            Text("设置备份不包含执行代码；脚本必须在目标配置中再次明确导入。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 800, height: 620)
        .onAppear { controller.refresh() }
        .onDisappear { form.importPanel?.cancel(nil); form.importPanel = nil }
    }
    private func chooseImport() {
        guard form.importPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.allowedContentTypes = [UTType(filenameExtension: "lua") ?? .data, UTType(filenameExtension: "js") ?? .data]
        form.importPanel = panel
        let response: (NSApplication.ModalResponse) -> Void = { result in
            guard form.importPanel === panel else { return }
            form.importPanel = nil
            if result == .OK, let url = panel.url { controller.importFile(url) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: response) }
        else { panel.begin(completionHandler: response) }
    }
}
