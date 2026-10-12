import AppKit
import SwiftUI
#if canImport(PlayerCore)
import PlayerCore
#endif
import UniformTypeIdentifiers

@MainActor
private final class EPGUIState: ObservableObject {
    @Published var search = ""
    @Published var selectedKey: String?
    @Published var day = Date()
    @Published var mappingSearch = ""
    @Published var mappingDraft = ""
}

/// The injected playChannel receives the original media URL, never a XMLTV or logo URL.
@MainActor
struct EPGView: View {
    @ObservedObject var service: EPGService
    let playChannel: (URL) -> Void
    let onDone: () -> Void
    @StateObject private var state = EPGUIState()

    private var visibleChannels: [EPGChannelReference] {
        service.channels.filter { state.search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(state.search)
            || ($0.tvgID?.localizedCaseInsensitiveContains(state.search) == true) }
    }
    private var selected: EPGChannelReference? {
        service.channels.first { $0.stableKey == state.selectedKey }
    }
    private var mappingIDs: [String] {
        var ids = (service.document?.channelIDs ?? []).filter { state.mappingSearch.isEmpty || $0.localizedCaseInsensitiveContains(state.mappingSearch) }.sorted()
        ids = Array(ids.prefix(200))
        if !state.mappingDraft.isEmpty, !ids.contains(state.mappingDraft) { ids.insert(state.mappingDraft, at: 0) }
        return ids
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("频道节目单", systemImage: "calendar.badge.clock").font(.title2.bold())
                Spacer()
                Button("完成") { service.dismiss(); onDone() }.keyboardShortcut(.cancelAction)
                    .help("关闭节目单并取消未完成的读取与台标请求。")
            }
            HStack {
                TextField("XMLTV 的 HTTP 或 HTTPS 地址", text: Binding(get: { service.address }, set: {
                    service.address = $0; service.addressEdited()
                }))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("节目单来源地址")
                    .help("输入来源后点击读取。更改地址不会替换当前已成功读取的节目单。")
                Button("读取节目单") { service.loadRemote() }.disabled(service.isBusy)
                Button("本地文件…") { chooseFile() }.disabled(service.isBusy)
                    .help("选择本机 XMLTV 文件，读取上限 8 MiB。")
            }
            if let source = service.committedSource {
                HStack(alignment: .firstTextBaseline) {
                    Text("当前节目单：").foregroundStyle(.secondary)
                    Text(sourceDescription(source)).lineLimit(2)
                        .textSelection(.enabled)
                    Spacer()
                    if service.isBusy { Text("读取期间继续显示原节目单").foregroundStyle(.secondary) }
                }.font(.caption)
            }
            HStack {
                TextField("搜索频道名称或 tvg-id", text: $state.search).textFieldStyle(.roundedBorder)
                Text("\(visibleChannels.count) / \(service.channels.count)").font(.caption).foregroundStyle(.secondary)
                Toggle("加载台标", isOn: Binding(get: { service.logoEnabled }, set: { service.setLogoEnabled($0) }))
                    .toggleStyle(.switch).help("主动开启后单独请求可见频道的图片，不发送节目单账号密码。")
                Button("刷新台标") { service.refreshVisibleLogos() }.disabled(!service.logoEnabled)
            }
            HSplitView {
                channelList.frame(minWidth: 330, idealWidth: 370)
                detail.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                if service.isBusy || service.logoPending > 0 { ProgressView().controlSize(.small) }
                Text(service.status).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if service.isBusy || service.logoPending > 0 { Button("取消") { service.cancel() } }
            }
            if let error = service.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            if let notice = service.logoNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if service.logoEnabled, !service.logoRequestsAuthorized {
                Text("已恢复台标偏好；读取节目单或点击刷新台标后才联网。").font(.caption).foregroundStyle(.secondary)
            }
            Text("时间按本机时区显示；缺结束时间会明确标注。频道按 tvg-id 精确匹配，也可手动指定。台标失败不会阻止播放。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(minWidth: 880, minHeight: 640)
            .onChange(of: state.selectedKey) { _, _ in
                state.mappingDraft = selected.flatMap { service.mapping.explicitOverrides[$0.stableKey] } ?? ""
                state.mappingSearch = ""
            }
            .onChange(of: service.channels) { _, values in
                if !values.contains(where: { $0.stableKey == state.selectedKey }) { state.selectedKey = visibleChannels.first?.stableKey }
            }
            .onAppear { if selected == nil { state.selectedKey = visibleChannels.first?.stableKey } }
            .onDisappear { service.dismiss() }
    }

    private var channelList: some View {
        Group {
            if service.channels.isEmpty {
                ContentUnavailableView("尚无频道", systemImage: "play.tv", description: Text("先在频道列表中导入 M3U，再查看对应节目。"))
            } else if visibleChannels.isEmpty {
                ContentUnavailableView("没有匹配频道", systemImage: "magnifyingglass", description: Text("更改名称或 tvg-id 搜索。"))
            } else {
                List(selection: $state.selectedKey) {
                    ForEach(visibleChannels, id: \.stableKey) { channel in
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            channelRow(channel, at: context.date)
                        }.tag(channel.stableKey)
                            .task(id: service.logoRequestEpoch) { await service.requestLogo(channel) }
                    }
                }
            }
        }
    }
    private func channelRow(_ channel: EPGChannelReference, at date: Date) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let image = service.logoImage(channel) { Image(nsImage: image).resizable().scaledToFit() }
                else { Image(systemName: "play.tv").font(.title2).foregroundStyle(.secondary) }
            }.frame(width: 44, height: 44).accessibilityLabel("\(channel.displayName)台标")
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.displayName).font(.headline).lineLimit(1)
                if let value = service.nowAndNext(channel, at: date) {
                    if !value.current.isEmpty {
                        Text("正在播：" + titles(value.current.prefix(3).map(\.programme), totalCount: value.current.count)).lineLimit(2)
                    } else if !value.latestWithUnknownEnd.isEmpty {
                        Text("结束未知：" + titles(value.latestWithUnknownEnd)).lineLimit(2)
                    } else { Text("当前时段无节目").foregroundStyle(.secondary) }
                    if !value.next.isEmpty {
                        Text("下一节目：" + titles(value.next)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                } else { Text(mappingMessage(channel)).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 4)
            Button("播放") { playChannel(channel.mediaURL) }.help("播放频道 \(channel.displayName)。")
        }.padding(.vertical, 4)
    }
    private func mappingMessage(_ channel: EPGChannelReference) -> String {
        guard service.document != nil else { return "尚未读取节目单" }
        switch service.mappingResult(channel) {
        case .matched: return "已匹配节目单"
        case .unavailable(let id): return "节目单没有频道 ID：\(id)"
        case .unmapped: return "未匹配，可手动指定频道 ID"
        }
    }
    private func titles(_ values: [EPGProgramme], totalCount: Int? = nil) -> String {
        let result = values.prefix(3).map(\.title).joined(separator: " / ")
        let count = totalCount ?? values.count
        return count > 3 ? result + "（另有 \(count - 3) 条）" : result
    }
    private func sourceDescription(_ source: URL) -> String {
        if source.isFileURL { return source.path }
        guard var value = URLComponents(url: source, resolvingAgainstBaseURL: false) else { return "HTTP 来源" }
        value.query = nil; value.fragment = nil
        return value.string ?? source.host ?? "HTTP 来源"
    }
    private var detail: some View {
        Group {
            if let channel = selected {
                VStack(alignment: .leading, spacing: 12) {
                    Text(channel.displayName).font(.title3.bold())
                    Text(mappingMessage(channel)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    mappingEditor(channel)
                    Divider()
                    DatePicker("节目日期", selection: $state.day, displayedComponents: .date)
                        .help("按本机时区查看当天节目，包括跨午夜节目。")
                    schedule(channel)
                }.padding(.leading, 12)
            } else {
                ContentUnavailableView("选择频道查看节目", systemImage: "list.bullet.rectangle", description: Text("选择左侧频道查看当天节目或手动匹配。"))
            }
        }
    }
    private func mappingEditor(_ channel: EPGChannelReference) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField("筛选节目单频道 ID", text: $state.mappingSearch).textFieldStyle(.roundedBorder)
                .accessibilityLabel("手动匹配的频道 ID 筛选")
            HStack {
                Picker("匹配", selection: $state.mappingDraft) {
                    Text("使用原 tvg-id").tag("")
                    ForEach(mappingIDs, id: \.self) { id in Text(id).tag(id) }
                }.disabled(service.document == nil)
                Button("应用") { service.setMapping(channel, channelID: state.mappingDraft.isEmpty ? nil : state.mappingDraft) }
                    .disabled(service.document == nil)
            }
            if (service.document?.channelIDs.count ?? 0) > 200 {
                Text("列表最多显示 200 个匹配 ID；输入关键词缩小范围。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func schedule(_ channel: EPGChannelReference) -> some View {
        let entries = service.daySchedule(channel, on: state.day)
        return Group {
            if entries.isEmpty {
                ContentUnavailableView("当天没有节目", systemImage: "calendar", description: Text("检查节目单来源、频道匹配或日期。"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(entries.prefix(500), id: \.programme.sequence) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.programme.title).font(.headline)
                                HStack(spacing: 4) {
                                    Text(entry.programme.start, format: .dateTime.month().day().hour().minute())
                                    Text("—")
                                    if let end = entry.end {
                                        Text(end, format: .dateTime.month().day().hour().minute())
                                        if entry.endWasInferred { Text("（按下一节目推断）") }
                                    } else { Text("结束未知") }
                                }.font(.caption).foregroundStyle(.secondary)
                                if !entry.programme.description.isEmpty { Text(entry.programme.description).font(.callout).textSelection(.enabled) }
                            }
                            Divider()
                        }
                        if entries.count > 500 { Text("当天共有 \(entries.count) 条节目；当前显示前 500 条。").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "读取 XMLTV 节目单"
        panel.allowedContentTypes = [.xml, .data]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        service.loadLocal(url)
    }
}
