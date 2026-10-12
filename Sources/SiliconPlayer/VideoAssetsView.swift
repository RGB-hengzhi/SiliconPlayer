import SwiftUI
import AppKit
import PlayerCore

/// Same native sheet/focus policy as existing preference surfaces. The host
/// supplies Done and owns the controller through actual async cleanup.
struct VideoAssetsView: View {
    @ObservedObject var controller: VideoAssetsController
    let done: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("GLSL 与 LUT 资源").font(.title2)
            Text("CPU LUT 在现有用户滤镜之后执行；GLSL 在 GPU 管线执行。分别按各自列表顺序应用。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("导入 GLSL / CUBE…",action:importFile)
                    .disabled(controller.hasActiveJobs)
                    .accessibilityIdentifier("video-assets-import")
                Spacer()
                Text(status).font(.caption)
            }
            HStack {
                Button("导出完整资源包…",action:exportArchive)
                Button("导入资源包并替换列表…",action:importArchive)
            }.disabled(controller.hasActiveJobs)
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    section(.cube,title:"CPU 3D LUT（标准化输入 CUBE）")
                    section(.glsl,title:"GPU GLSL（显式导入的代码）")
                }
            }
            Text("导入时默认关闭。GLSL 是可执行的 GPU 代码；结构验证不保证 GPU 安全、画质或 HDR 正确性。")
                .font(.caption).foregroundStyle(.secondary)
            Text("资源包包含列表和完整文件，可单独迁移。完整设置备份也包含这些资源；导入旧版不含资源的备份时，会保留当前资源列表。")
                .font(.caption).foregroundStyle(.secondary)
            if let message=controller.message {Text(message).font(.caption).foregroundStyle(.orange)}
            HStack {
                Button("取消未完成更改") {controller.cancelRequest()}
                    .disabled(!controller.hasActiveJobs)
                Spacer()
                Button("完成",action:done).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width:680,height:520)
    }
    private var status: String {
        switch controller.activity {
        case .ready:return "资源已读取"
        case .checking:return "正在验证…"
        case .active:return "当前资源已通过应用验证"
        case .suspended:return "当前媒体已暂停应用资源"
        case .closing:return "正在取消并关闭资源任务…"
        }
    }
    @ViewBuilder private func section(_ kind: VideoAssetKind,title:String) -> some View {
        let entries=controller.document.entries.filter{$0.kind==kind}
        VStack(alignment:.leading,spacing:10) {
            Text(title).font(.headline)
            if entries.isEmpty {Text("尚未导入资源").foregroundStyle(.secondary)}
            ForEach(Array(entries.enumerated()),id:\.element.id) {index,entry in
                HStack {
                    Toggle(entry.name,isOn:Binding(get:{entry.enabled},set:{controller.enabled(entry.id,$0)}))
                        .accessibilityIdentifier("video-assets-enabled-"+entry.id.uuidString)
                    Spacer()
                    Button("上移 \(entry.name)") {controller.move(entry.id,before:entries[index-1].id)}
                        .disabled(index==0)
                    Button("下移 \(entry.name)") {
                        let target=index+2<entries.count ? entries[index+2].id : nil
                        controller.move(entry.id,before:target)
                    }.disabled(index==entries.count-1)
                    Button("移除 \(entry.name)") {controller.remove(entry.id)}
                }.disabled(controller.hasActiveJobs)
                Text("\(entry.byteCount) 字节 · SHA \(entry.sha256.prefix(12))…")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }.padding(14).background(.quaternary,in:RoundedRectangle(cornerRadius:10))
    }
    private func importFile() {
        let panel=NSOpenPanel()
        panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        panel.title="选择要复制到资源库的 GLSL 或 CUBE 文件"
        guard panel.runModal() == .OK,let url=panel.url else {return}
        controller.importFile(url)
    }
    private func exportArchive() {
        let panel=NSSavePanel();panel.nameFieldStringValue="SiliconPlayer-video-resources.json"
        panel.title="导出包含完整 GLSL / LUT 的资源包"
        panel.begin {response in guard response == .OK,let url=panel.url else {return};controller.exportArchive(url)}
    }
    private func importArchive() {
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        panel.title="选择资源包，验证后替换当前资源列表"
        panel.begin {response in guard response == .OK,let url=panel.url else {return};controller.importArchive(url)}
    }
}

/// Host presents this NSHostingView in a parent.beginSheet(NSPanel) and owns
/// controller until shutdown. A new independent window would also require
/// explicit playback-key focus exclusion; do not silently use that route.
@MainActor final class VideoAssetsPanelPresenter: NSObject,NSWindowDelegate {
    private var panel:NSPanel?
    func show(controller:VideoAssetsController,parent:NSWindow) {
        if let panel {panel.makeKeyAndOrderFront(nil);return}
        guard parent.attachedSheet==nil else {return}
        let new=NSPanel(contentRect:NSRect(x:0,y:0,width:680,height:520),
                        styleMask:[.titled,.closable],backing:.buffered,defer:false)
        new.title="GLSL 与 LUT 资源";new.isReleasedWhenClosed=false;new.delegate=self
        new.contentView=NSHostingView(rootView:VideoAssetsView(controller:controller) { [weak self,weak parent] in
            guard let panel=self?.panel,let parent else {return}
            parent.endSheet(panel)
        })
        panel=new
        parent.beginSheet(new) { [weak self,weak controller] _ in
            controller?.cancelRequest()
            self?.panel?.orderOut(nil);self?.panel=nil
        }
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool {
        if let parent=sender.sheetParent {parent.endSheet(sender);return false}
        return true
    }
}
