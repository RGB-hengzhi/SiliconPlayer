import SwiftUI

private final class ShortcutSettingsState: ObservableObject {
    @Published var drafts: [String: String] = [:]
    @Published var search = ""
    @Published var message = ""
    @Published var failed = false
}

struct ShortcutSettingsView: View {
    @ObservedObject var player: PlayerModel
    @ObservedObject private var input = InputController.shared
    @StateObject private var state = ShortcutSettingsState()

    private var filtered: [ShortcutBinding] {
        let query = state.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return input.bindings.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.key.localizedCaseInsensitiveContains(query) }
    }
    private var colorScheme: ColorScheme? {
        player.settings.theme == "dark" ? .dark : player.settings.theme == "light" ? .light : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("自定义快捷键").font(.title2.weight(.semibold))
                    Text("每一项按 Return 或点击保存后生效").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("搜索操作或按键", text: $state.search).frame(width: 180)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("输入键名，使用 + 连接修饰键，例如 space、shift+left、option+b、ctrl+shift+right。")
                    Text("修饰键：cmd、ctrl、option、shift。常用键：left / right / up / down、pageup / pagedown、return、escape、f1–f12，也支持字母、数字及 [ ] , .。")
                    Text("留空并保存可取消绑定。已被系统或菜单使用的组合会保留；快捷键不会在文本输入框或对话框内触发。")
                }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            HStack {
                Text("操作").frame(width: 202, alignment: .leading)
                Text("按键组合").frame(maxWidth: .infinity, alignment: .leading)
                Text(" ").frame(width: 62)
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if filtered.isEmpty { ContentUnavailableView.search(text: state.search).frame(minHeight: 200) }
                    ForEach(filtered) { binding in shortcutRow(binding) }
                }.padding(.vertical, 2)
            }
            if !state.message.isEmpty {
                Label(state.message, systemImage: state.failed ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.caption).foregroundStyle(state.failed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("恢复默认快捷键") {
                    input.restoreDefaults()
                    synchronizeDrafts()
                    state.failed = input.error != nil
                    state.message = input.error ?? "已恢复默认快捷键。"
                }
                Spacer()
                Button("完成") { player.showShortcuts = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 680, height: 650)
        .preferredColorScheme(colorScheme)
        .onAppear(perform: synchronizeDrafts)
    }

    private func shortcutRow(_ binding: ShortcutBinding) -> some View {
        HStack(spacing: 12) {
            Text(binding.title).font(.system(size: 12)).frame(width: 190, alignment: .leading)
            TextField("未绑定", text: draft(for: binding)).font(.system(size: 12, design: .monospaced))
                .onSubmit { save(binding) }
                .accessibilityLabel("\(binding.title)的快捷键")
            Button("保存") { save(binding) }.frame(width: 50)
        }.padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
    private func draft(for binding: ShortcutBinding) -> Binding<String> {
        Binding(get: { state.drafts[binding.action] ?? binding.key }, set: { state.drafts[binding.action] = $0 })
    }
    private func save(_ binding: ShortcutBinding) {
        if input.update(action: binding.action, key: state.drafts[binding.action] ?? binding.key) {
            let key = input.bindings.first(where: { $0.action == binding.action })?.key ?? ""
            state.drafts[binding.action] = key
            state.failed = false
            state.message = key.isEmpty ? "已取消“\(binding.title)”的按键绑定。" : "已保存“\(binding.title)”：\(key)"
        } else {
            state.failed = true
            state.message = input.error ?? "无法保存快捷键。"
        }
    }
    private func synchronizeDrafts() {
        state.drafts = Dictionary(uniqueKeysWithValues: input.bindings.map { ($0.action, $0.key) })
    }
}
