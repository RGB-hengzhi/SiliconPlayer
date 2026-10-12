import SwiftUI

@MainActor
struct UserProfileBackupView: View {
    @ObservedObject var controller: UserProfileBackupController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("设置备份", systemImage: "externaldrive").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("备份包含全局播放设置、快捷键、用户视频滤镜、媒体设置，已解析网页的清晰度和字幕选择，以及完整 GLSL/LUT 资源与顺序。")
                .font(.callout)
            HStack {
                Button("导出备份", action: controller.chooseExport)
                Button("选择备份…", action: controller.chooseImport)
                if controller.busy { ProgressView().controlSize(.small) }
            }.disabled(controller.busy || controller.blocksPersistence)
            if let backup = controller.pendingImport {
                GroupBox("待导入：\(controller.pendingName)") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("备份版本 \(backup.version) · 应用 \(backup.appVersion)")
                        Text("创建于 \(backup.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        Text("快捷键 \(backup.shortcuts.count) 项 · 视频滤镜 \(backup.filters.filters.count) 项")
                        Text("媒体设置 \(backup.media.entries.count) 项")
                        Text(backup.web == nil ? "未包含网页选择，现有网页选择会保留" : "包含网页选择，导入时替换现有网页选择")
                        Text(backup.videoAssets.map {"包含 \($0.document.entries.count) 项视频资源和完整文件，导入前验证当前媒体"} ?? "旧备份未包含视频资源，现有资源会保留")
                        Text("导入会替换所列设置。读取和验证备份不会修改当前配置。")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("取消", action: controller.cancelPendingImport)
                            Spacer()
                            Button("导入这些设置") { Task { _ = await controller.commitImport() } }
                                .disabled(controller.busy || controller.blocksPersistence)
                        }
                    }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !controller.status.isEmpty { Text(controller.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if let error = controller.errorText {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if controller.blocksPersistence {
                Text("导入恢复尚未完成，请重新启动后再导入或保存设置。").font(.callout).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }.padding(22).frame(minWidth: 620, minHeight: 360)
            .onDisappear { controller.cancelPendingImport() }
    }
}
