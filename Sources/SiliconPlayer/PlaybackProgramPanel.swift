import AppKit
import SwiftUI
import PlayerCore

/// Explicitly confirmed fields are persisted immediately. Text still being
/// entered is a form value, never a silently applied playback configuration.
@MainActor final class PlaybackProgramPanelState: ObservableObject {
    let controller: PlaybackProgramController
    private var editingTicket: PlaybackProgramTicket?
    @Published private(set) var draft: PlaybackProgram
    @Published var title = ""
    @Published var start = "0"
    @Published var end = "10"
    @Published var count = "1"
    @Published var intro = ""
    @Published var outro = ""
    @Published var error: String?
    init(controller: PlaybackProgramController) {
        self.controller = controller; editingTicket = controller.editingTicket
        draft = controller.savedProgram ?? PlaybackProgram()
        loadFields()
    }
    func loadFields() {
        if let interval = draft.selectedInterval {
            title = interval.title; start = PlaybackProgram.seconds(interval.startMicroseconds)
            end = PlaybackProgram.seconds(interval.endMicroseconds); count = interval.totalPlays.map(String.init) ?? "inf"
        } else { title = ""; start = "0"; end = "10"; count = "1" }
        intro = draft.introEndMicroseconds.map(PlaybackProgram.seconds) ?? ""
        outro = draft.outroStartMicroseconds.map(PlaybackProgram.seconds) ?? ""
    }
    @discardableResult func confirm() -> Bool {
        var next = draft
        if let id = next.selectedIntervalID, let index = next.intervals.firstIndex(where: { $0.id == id }) {
            guard let a = PlaybackProgram.parseSeconds(start), let b = PlaybackProgram.parseSeconds(end),
                  count == "inf" || Int(count).map({ (1...1_000_000).contains($0) }) == true else {
                error = "请输入 A/B 秒数（最多六位小数），次数为 1…1000000 或 inf"; return false
            }
            next.intervals[index] = .init(id: id, title: title, startMicroseconds: a,
                                         endMicroseconds: b, totalPlays: count == "inf" ? nil : Int(count))
        }
        if !intro.isEmpty, PlaybackProgram.parseSeconds(intro) == nil { error = "片头秒数无效"; return false }
        if !outro.isEmpty, PlaybackProgram.parseSeconds(outro) == nil { error = "片尾秒数无效"; return false }
        next.introEndMicroseconds = intro.isEmpty ? nil : PlaybackProgram.parseSeconds(intro)
        next.outroStartMicroseconds = outro.isEmpty ? nil : PlaybackProgram.parseSeconds(outro)
        return publish(next)
    }
    private func publish(_ value: PlaybackProgram) -> Bool {
        guard let original = editingTicket, let current = controller.editingTicket,
              original.itemID == current.itemID, original.loadToken == current.loadToken,
              original.entryID == current.entryID, original.programRevision == current.programRevision else {
            error = "当前媒体已变更，请重新打开播放程序窗口"; return false
        }
        if value == draft, controller.program == draft { return true }
        var next = value; next.revision = UUID()
        guard controller.save(next) else { error = controller.error ?? "配置未保存"; return false }
        draft = next; editingTicket = controller.editingTicket; error = nil; loadFields(); return true
    }
    func change(_ body: (inout PlaybackProgram) -> Void) {
        guard confirm() else { return }
        var next = draft; body(&next); _ = publish(next)
    }
    func choose(_ id: UUID) {
        guard confirm() else { return }
        var next = draft; next.selectedIntervalID = id; _ = publish(next)
    }
    func add() {
        guard confirm(), draft.intervals.count < PlaybackProgram.maximumIntervals else { return }
        var next = draft
        let interval = PlaybackInterval(title: "区间 \(next.intervals.count + 1)", startMicroseconds: 0, endMicroseconds: 10_000_000)
        next.intervals.append(interval); next.selectedIntervalID = interval.id
        _ = publish(next)
    }
    func remove() {
        guard let id = draft.selectedIntervalID else { return }
        var next = draft; next.intervals.removeAll { $0.id == id }
        next.selectedIntervalID = next.intervals.first?.id
        if next.selectedIntervalID == nil { next.automaticallyStartSelected = false }
        _ = publish(next)
    }
    func move(_ delta: Int) {
        guard confirm(), let id = draft.selectedIntervalID,
              let index = draft.intervals.firstIndex(where: { $0.id == id }),
              draft.intervals.indices.contains(index + delta) else { return }
        var next = draft; next.intervals.swapAt(index, index + delta); _ = publish(next)
    }
    func startSelected() {
        guard confirm(), let id = draft.selectedIntervalID else { return }
        if !controller.activate(id) { error = controller.error }
    }
}

@MainActor struct PlaybackProgramPanel: View {
    @StateObject private var state: PlaybackProgramPanelState
    @ObservedObject private var controller: PlaybackProgramController
    init(controller: PlaybackProgramController) {
        _state = StateObject(wrappedValue: PlaybackProgramPanelState(controller: controller))
        self.controller = controller
    }
    private func name(_ action: PlaybackProgramAction) -> String {
        switch action {
        case .nextInterval: return "下一区间（最后转媒体结束动作）"
        case .continuePlayback: return "继续当前媒体"
        case .nextMedia: return "下一个媒体"
        case .pause: return "暂停"
        case .stop: return "停止"
        case .quit: return "退出应用（可取消）"
        case .appSleep: return "暂停并释放应用防睡眠"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("此媒体的播放程序").font(.headline)
            Text("按回车或“确认文本”保存字段；输入中的文本尚未应用。区间结束位置按播放器轮询确认。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("启用此媒体播放程序", isOn: Binding(get: { state.draft.enabled }, set: { value in state.change { $0.enabled = value } }))
            HStack {
                ScrollView { VStack(alignment: .leading) {
                    ForEach(state.draft.intervals) { interval in
                        Button((interval.id == state.draft.selectedIntervalID ? "✓ " : "") + interval.title) { state.choose(interval.id) }
                            .accessibilityLabel("选择区间 \(interval.title)")
                    }
                } }.frame(width: 200, height: 220, alignment: .leading)
                VStack(alignment: .leading) {
                    TextField("区间名称", text: $state.title).onSubmit { _ = state.confirm() }
                    HStack {
                        TextField("A 秒", text: $state.start).onSubmit { _ = state.confirm() }
                        TextField("B 秒", text: $state.end).onSubmit { _ = state.confirm() }
                        TextField("总播放次数或 inf", text: $state.count).onSubmit { _ = state.confirm() }
                    }
                    HStack {
                        Button("新增区间", action: state.add); Button("删除区间", action: state.remove)
                        Button("上移") { state.move(-1) }; Button("下移") { state.move(1) }
                    }
                    Toggle("下次从头加载时自动开始所选区间", isOn: Binding(get: { state.draft.automaticallyStartSelected }, set: { value in state.change { $0.automaticallyStartSelected = value } }))
                    Button("开始所选区间", action: state.startSelected)
                        .disabled(state.draft.selectedIntervalID == nil || !state.draft.enabled)
                }
            }
            Picker("区间次数结束后", selection: Binding(get: { state.draft.afterInterval }, set: { value in state.change { $0.afterInterval = value } })) {
                ForEach(PlaybackProgramAction.allCases, id: \.self) { Text(name($0)).tag($0) }
            }
            Picker("媒体结束／片尾开始后", selection: Binding(get: { state.draft.afterMedia }, set: { value in state.change { $0.afterMedia = value } })) {
                ForEach(PlaybackProgramAction.allCases.filter { ![.nextInterval, .continuePlayback].contains($0) }, id: \.self) { Text(name($0)).tag($0) }
            }
            HStack {
                TextField("片头结束秒（留空关闭）", text: $state.intro).onSubmit { _ = state.confirm() }
                TextField("片尾开始秒（留空关闭）", text: $state.outro).onSubmit { _ = state.confirm() }
                Button("确认文本") { _ = state.confirm() }
            }
            Text("历史续播／书签优先于自动起点。手动定位后，本次片头片尾自动跳过停用；停止和换片撤销旧动作。暂停并释放防睡眠不会调用系统睡眠。")
                .font(.caption).foregroundStyle(.secondary)
            Text(controller.status)
            if let error = state.error ?? controller.error { Text(error).foregroundStyle(.red) }
        }.padding(16).frame(minWidth: 720, minHeight: 430)
    }
}

@MainActor final class PlaybackProgramWindow: NSWindowController {
    private static var retained: PlaybackProgramWindow?
    static func show(controller: PlaybackProgramController) {
        retained?.window?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "此媒体的播放程序"
        window.contentView = NSHostingView(rootView: PlaybackProgramPanel(controller: controller))
        let owner = PlaybackProgramWindow(window: window); retained = owner
        window.center(); owner.showWindow(nil); window.makeKeyAndOrderFront(nil)
    }
}
