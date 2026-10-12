import SwiftUI
import PlayerCore

@MainActor private final class UserVideoFilterSelection: ObservableObject {
    @Published var selectedID: UUID?
}
@MainActor private final class UserVideoFilterDraft: ObservableObject {
    @Published var entry: UserVideoFilter
    init(_ entry: UserVideoFilter) { self.entry = entry }
}

@MainActor
struct UserVideoFiltersView: View {
    @ObservedObject var controller: UserVideoFiltersController
    @StateObject private var selection = UserVideoFilterSelection()
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 14, content: content).padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
    var body: some View {
        card("可编辑视频滤镜链") {
            VStack(alignment: .leading, spacing: 12) {
                Text("按从上到下的顺序处理，追加在基础视频处理之后。未打开视频时仅保存配置；视频播放时先检查滤镜链是否可用。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Menu {
                        ForEach(UserVideoFilterKind.allCases) { kind in
                            Button(kind.title) { selection.selectedID = controller.add(kind) }
                        }
                    } label: { Label("添加滤镜", systemImage: "plus") }
                        .disabled(!controller.isReady || controller.isApplying || controller.chain.filters.count >= UserVideoFilterChain.maximumCount)
                    Spacer()
                    Text("\(controller.chain.filters.count) / \(UserVideoFilterChain.maximumCount)").monospacedDigit().foregroundStyle(.secondary)
                    Button("清空链") { selection.selectedID = nil; controller.removeAll() }
                        .disabled(controller.chain.filters.isEmpty || controller.isApplying || !controller.isReady)
                }
                if controller.chain.filters.isEmpty {
                    Text("添加一个滤镜，然后调整参数、启用状态和顺序。").foregroundStyle(.secondary)
                }
                ForEach(Array(controller.chain.filters.enumerated()), id: \.element.id) { index, filter in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { filter.enabled }, set: { controller.setEnabled(id: filter.id, enabled: $0) }))
                            .labelsHidden().help("启用或暂时禁用")
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                        Button { selection.selectedID = filter.id } label: {
                            HStack { Text(filter.kind.title); Spacer(); Image(systemName: "slider.horizontal.3") }
                        }.buttonStyle(.borderless)
                        Button { controller.move(id: filter.id, to: index - 1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0).help("上移")
                        Button { controller.move(id: filter.id, to: index + 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == controller.chain.filters.count - 1).help("下移")
                        Button(role: .destructive) {
                            if selection.selectedID == filter.id { selection.selectedID = nil }
                            controller.remove(id: filter.id)
                        } label: { Image(systemName: "trash") }.help("删除")
                    }.disabled(controller.isApplying || !controller.isReady)
                }
                if let selected = controller.chain.filters.first(where: { $0.id == selection.selectedID }) {
                    Divider()
                    UserVideoFilterParameterEditor(filter: selected, controller: controller).id(selected.id)
                }
                if controller.isApplying {
                    HStack { ProgressView().controlSize(.small); Text("正在检查并应用滤镜…").font(.caption) }
                }
                if controller.runtimeSuspended {
                    HStack {
                        Text("本媒体暂时使用基础视频处理，保存的滤镜链已保留。").font(.caption)
                        Spacer()
                        Button("重试当前链") { controller.retryCurrentChain() }.disabled(controller.isApplying || !controller.isReady)
                    }
                }
                if let error = controller.errorText {
                    HStack(alignment: .top) {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        Spacer(); Button("关闭提示") { controller.clearError() }.buttonStyle(.borderless)
                    }
                }
                Text(AppCapabilities.current.profile == .full
                    ? "这是 CPU 视频处理链；效果、顺序和负载取决于素材。文件型 LUT 和 GLSL 可在“视频 → GLSL 与 LUT 资源”中导入并验证。"
                    : "滤镜会增加画面处理负载，效果取决于素材和顺序。此版本暂不提供文件型 LUT 与 GLSL 导入。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor private struct UserVideoFilterParameterEditor: View {
    let filter: UserVideoFilter
    @ObservedObject var controller: UserVideoFiltersController
    @StateObject private var draft: UserVideoFilterDraft
    init(filter: UserVideoFilter, controller: UserVideoFiltersController) {
        self.filter = filter; self.controller = controller
        _draft = StateObject(wrappedValue: UserVideoFilterDraft(filter))
    }
    private func value(_ parameter: UserVideoFilterParameter) -> Binding<Double> {
        Binding(get: { draft.entry.values[parameter.id] ?? parameter.defaultValue },
                set: { draft.entry.values[parameter.id] = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(filter.kind.title).font(.headline)
            if filter.kind.parameters.isEmpty { Text("此滤镜无需参数，可通过开关暂时禁用。").font(.caption).foregroundStyle(.secondary) }
            ForEach(filter.kind.parameters) { parameter in
                if parameter.choices.isEmpty {
                    HStack {
                        Text(parameter.title).frame(width: 135, alignment: .leading)
                        Slider(value: value(parameter), in: parameter.range, step: parameter.step)
                        Text(String(format: "%.2f", draft.entry.values[parameter.id] ?? parameter.defaultValue))
                            .monospacedDigit().frame(width: 50, alignment: .trailing)
                    }
                } else {
                    Picker(parameter.title, selection: value(parameter)) {
                        ForEach(parameter.choices, id: \.value) { choice in Text(choice.title).tag(choice.value) }
                    }
                }
            }
            if !filter.kind.parameters.isEmpty {
                HStack {
                    Button("应用参数") { controller.replace(draft.entry) }.disabled(draft.entry == filter)
                    Button("撤销编辑") { draft.entry = filter }.disabled(draft.entry == filter)
                    Button("默认参数") {
                        draft.entry.values = UserVideoFilter(kind: filter.kind).values
                    }
                }
            }
        }.disabled(controller.isApplying || !controller.isReady)
            .onChange(of: filter) { _, value in draft.entry = value }
    }
}
