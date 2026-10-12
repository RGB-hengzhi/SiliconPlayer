import AppKit
import SwiftUI

@MainActor
private struct OrdinaryMediaOpenView: View {
    @ObservedObject var controller: OrdinaryMediaOpenController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("打开目录／列表").font(.title2.bold())
            Text(controller.status).accessibilityIdentifier("ordinary-open-status")
            Text("已核对 \(controller.visited) 个目录条目")
                .accessibilityIdentifier("ordinary-open-visited")
            if controller.busy { ProgressView().controlSize(.small) }
            if let error = controller.error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button("取消打开") { controller.cancel() }.disabled(!controller.canCancel)
                    .accessibilityIdentifier("ordinary-open-cancel")
                Button("明确重试") { controller.retry() }.disabled(!controller.canRetry)
                    .accessibilityIdentifier("ordinary-open-retry")
            }
            Text("完整展开成功才替换或加入队列；扫描期间原队列继续保留。最多 128 个输入、100000 个目录条目、20000 个媒体／字幕、32 层、30 秒。普通打开不建立目录监控。取消需要等待当前原生读取返回；失联卷无法承诺硬超时。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(20).frame(minWidth: 580, minHeight: 240)
    }
}

@MainActor
final class OrdinaryMediaOpenWindow: NSWindowController {
    private static var current: OrdinaryMediaOpenWindow?
    static func ownsPlaybackInput(_ event: NSEvent) -> Bool {
        event.window != nil && event.window === current?.window
    }
    static func show(controller: OrdinaryMediaOpenController) {
        if let current { current.window?.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "打开目录／列表"; window.isReleasedWhenClosed = false; window.isRestorable = false
        let owner = OrdinaryMediaOpenWindow(window: window)
        window.contentViewController = NSHostingController(rootView: OrdinaryMediaOpenView(controller: controller))
        current = owner; window.center(); owner.showWindow(nil)
    }
    // Closing this status window does not erase native ownership or turn a still
    // running job into a closed resource. Cancel remains explicit and available
    // by reopening Tools → Directory/list opening progress.
}
