import SwiftUI
import PlayerCore

struct MediaInspectorView: View {
    @ObservedObject var player: PlayerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("媒体信息与播放统计").font(.title2.bold()); Spacer(); Button("完成") { player.showInspector = false }.keyboardShortcut(.defaultAction) }
            Text(player.currentURL?.absoluteString ?? "未打开媒体").font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    ForEach(player.statistics.keys.sorted(), id: \.self) { key in
                        GridRow { Text(key).foregroundStyle(.secondary); Text(player.statistics[key] ?? "").textSelection(.enabled).monospacedDigit() }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Divider().padding(.vertical, 12)
                ForEach(Array(player.tracks.enumerated()), id: \.offset) { _, track in HStack { Text(track.type).frame(width: 55, alignment: .leading); Text(track.label).textSelection(.enabled); Spacer() }.font(.caption).padding(.vertical, 3) }
            }
            Text("HDR 输入解析与正确 HDR 显示输出需要分别验证。").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 600, height: 570)
    }
}
