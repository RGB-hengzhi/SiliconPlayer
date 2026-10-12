import AppKit
import Combine

@MainActor final class ExplicitScriptController: ObservableObject {
    struct Runtime: Equatable {
        var clientID: Int64?
        var text: String
        var waitingSince: Double?
    }
    private enum Command { case load(UUID), message(UUID) }
    @Published private(set) var records: [ExplicitScriptRecord] = []
    @Published private(set) var runtime: [UUID: Runtime] = [:]
    @Published private(set) var status = "导入后不会自动执行；启用后仍需点击本次载入。"
    @Published private(set) var error: String?
    @Published private(set) var commandCount = 0
    private let directory: URL
    private let canPersist: () -> Bool
    private let canExecute: () -> Bool
    private let submit: ([String], UInt64) -> Int32
    private var store: ExplicitScriptStore?
    private var pending: [UInt64: Command] = [:]
    private var nextReplyID: UInt64 = 0x4558_0000_0000_0000
    private var engineClosing = false
    private var watchdog: Timer?

    init(directory: URL, canPersist: @escaping () -> Bool, canExecute: @escaping () -> Bool, submit: @escaping ([String], UInt64) -> Int32) {
        self.directory = directory; self.canPersist = canPersist; self.canExecute = canExecute; self.submit = submit
    }
    private func writableStore() throws -> ExplicitScriptStore {
        guard canPersist() else { throw ExplicitScriptError.blocked }
        if let store { return store }
        let value = try ExplicitScriptStore(directory: directory)
        store = value
        return value
    }
    private func updateRows() { records = store?.document.records ?? [] }
    private func perform(_ body: () throws -> Void) {
        error = nil
        do { try body() } catch {
            updateRows()
            self.error = (error as? ExplicitScriptError)?.errorDescription ?? "扩展操作失败；原始文件未自动重置。"
        }
    }

    func refresh() {
        perform {
            let current = try writableStore()
            // No load command is submitted here. Holding this process's lock
            // precedes retirement of tombstones from an older App lifecycle.
            try current.purgeDeleted(retaining: Set(runtime.keys))
            updateRows()
        }
    }
    func importFile(_ url: URL) {
        perform {
            let current = try writableStore()
            _ = try current.importFile(url)
            updateRows(); status = "已保存托管副本；默认禁用，尚未执行。"
        }
    }
    func setEnabled(_ id: UUID, _ enabled: Bool) {
        perform {
            try writableStore().setEnabled(id, enabled); updateRows()
            if runtime[id] != nil, !enabled {
                status = "已禁用后续载入。本次脚本仍可能执行，退出此播放器后才结束。"
            } else { status = enabled ? "允许手动载入；启用操作本身不会执行脚本。" : "已禁用。" }
        }
    }
    func delete(_ id: UUID) {
        perform {
            let current = try writableStore()
            try current.markDeleted(id)
            try current.purgeDeleted(retaining: Set(runtime.keys))
            updateRows()
            status = runtime[id] == nil ? "已移除记录及托管副本。" : "已安排删除；本次可能仍执行的副本保留到下一次启动。"
        }
    }
    var alive: Bool { !engineClosing && canExecute() }
    func canLoad(_ item: ExplicitScriptRecord) -> Bool {
        alive && canPersist() && item.enabled && !item.pendingDeletion && runtime[item.id] == nil && pending.count < 64
    }
    private func reserve(_ command: Command) throws -> UInt64 {
        guard alive else { throw ExplicitScriptError.unavailable }
        guard pending.count < 64, nextReplyID < 0x4558_FFFF_FFFF_FFFF else { throw ExplicitScriptError.busy }
        nextReplyID += 1; pending[nextReplyID] = command; commandCount = pending.count
        if watchdog == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.observeWaits() }
            }
            watchdog = timer; RunLoop.main.add(timer, forMode: .common)
        }
        return nextReplyID
    }
    func load(_ id: UUID) {
        perform {
            guard runtime[id] == nil else { throw ExplicitScriptError.busy }
            let url = try writableStore().loadURL(id)
            let reply = try reserve(.load(id))
            // Retain before calling the real async adapter. A submission or
            // result failure never proves arbitrary script cleanup occurred.
            runtime[id] = Runtime(clientID: nil, text: "已提交；尚未获得真实载入回复。", waitingSince: ProcessInfo.processInfo.systemUptime)
            let code = submit(["load-script", url.path], reply)
            if code < 0 {
                pending.removeValue(forKey: reply); commandCount = pending.count
                runtime[id]?.text = "提交失败（mpv \(code)）；副本保留，重新启动后可再尝试。"
                runtime[id]?.waitingSince = nil
                error = "load-script 提交返回 \(code)，未宣称已执行。"
            } else { status = "等待真实 load-script 回复；载入完成前不能重复提交。" }
        }
    }
    func sendMessage(_ id: UUID, name: String, argument: String) {
        perform {
            guard canPersist() else { throw ExplicitScriptError.blocked }
            guard let target = runtime[id]?.clientID, target > 0 else { throw ExplicitScriptError.unavailable }
            guard !name.isEmpty, name.utf8.count <= 128, argument.utf8.count <= 4_096,
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !argument.utf8.contains(0), !pending.values.contains(where: {
                      if case .message(let owner) = $0 { return owner == id }; return false
                  }) else { throw ExplicitScriptError.busy }
            let reply = try reserve(.message(id))
            let code = submit(["script-message-to", "@\(target)", name, argument], reply)
            if code < 0 {
                pending.removeValue(forKey: reply); commandCount = pending.count
                error = "script-message-to 提交返回 \(code)，未宣称投递或处理成功。"
            } else { status = "已提交定向消息；等待真实 mpv 回复。" }
        }
    }
    func ownsReply(_ id: UInt64) -> Bool { pending[id] != nil }
    func commandReply(id: UInt64, status code: Int32, clientID: Int64?) {
        guard let command = pending.removeValue(forKey: id) else { return }
        commandCount = pending.count
        switch command {
        case .load(let owner):
            guard runtime[owner] != nil else { return }
            runtime[owner]?.waitingSince = nil
            if code >= 0, let clientID, clientID > 0 {
                runtime[owner]?.clientID = clientID
                runtime[owner]?.text = engineClosing ? "已请求内核退出；副本继续保留。" : "真实 client_id \(clientID) 已创建；初始化及脚本逻辑尚未确认。"
                status = "load-script 回复成功；不代表脚本无错或初始化已完成。"
            } else {
                runtime[owner]?.text = "载入回复失败或格式未确认（mpv \(code)）；副本保留到退出。"
                error = "未收到成功的真实 INT64 client_id，不能宣称脚本已载入。"
            }
        case .message:
            if code >= 0 { status = "mpv 确认已投递定向消息；不代表脚本已处理或卸载。" }
            else { error = "定向消息回复失败（mpv \(code)）。" }
        }
    }
    private func observeWaits() {
        let now = ProcessInfo.processInfo.systemUptime
        for (id, value) in runtime where value.waitingSince.map({ now - $0 >= 10 }) == true {
            runtime[id]?.text = "10 秒仍未收到真实回复；未取消或卸载，继续保留并等待迟到回复。"
            runtime[id]?.waitingSince = nil
        }
        if pending.isEmpty { watchdog?.invalidate(); watchdog = nil }
    }
    func shutdownRequested() {
        engineClosing = true; watchdog?.invalidate(); watchdog = nil
        for id in Array(runtime.keys) { runtime[id]?.text = "内核已发出 shutdown 请求；不等同于所有脚本线程已关闭。" }
        status = "已阻止新的扩展命令。托管副本和配置锁保留至本播放器进程退出。"
        // Do not clear pending, release the store lock, delete a submitted
        // script, or invent client/thread termination from MPV_EVENT_SHUTDOWN.
    }
}
