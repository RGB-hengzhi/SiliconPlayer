import AppKit
import SwiftUI
import PlayerCore

private final class NetworkMediaUIState: ObservableObject {
    @Published var tab = 0
    @Published var channelSearch = ""
    @Published var channelGroup: String?
    @Published var fileSearch = ""
    @Published var showEPG = false
}

struct NetworkMediaView: View {
    @ObservedObject var player: PlayerModel
    @StateObject private var network = NetworkMediaService()
    @StateObject private var state = NetworkMediaUIState()
    @StateObject private var epg = EPGService()

    private var filteredChannels: [MediaChannel] {
        network.channels.filter {
            (state.channelGroup == nil || $0.group == state.channelGroup)
            && (state.channelSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(state.channelSearch)
                || $0.group.localizedCaseInsensitiveContains(state.channelSearch))
        }
    }

    private var filteredResources: [WebDAVResource] {
        network.resources.filter { state.fileSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(state.fileSearch) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("频道与网络媒体", systemImage: "network").font(.title2.bold())
                Spacer()
                Button("完成") { network.dismiss(); player.showNetwork = false }.keyboardShortcut(.cancelAction)
            }
            Picker("网络来源", selection: $state.tab) {
                Text("HTTP(S) 频道列表").tag(0)
                Text("WebDAV 文件").tag(1)
            }.pickerStyle(.segmented).disabled(network.isBusy)
            HStack(spacing: 10) {
                if state.tab == 0 {
                    TextField("https://example.com/channels.m3u8", text: $network.playlistAddress).textFieldStyle(.roundedBorder)
                    Button("读取频道") { network.loadChannels() }.disabled(network.isBusy)
                } else {
                    TextField("https://example.com/webdav/", text: $network.webDAVAddress).textFieldStyle(.roundedBorder)
                    Button("连接目录") { network.browse() }.disabled(network.isBusy)
                }
            }.disabled(network.isBusy)
            HStack {
                Text("HTTP Basic 认证").font(.caption).foregroundStyle(.secondary)
                TextField("账号（可选）", text: $network.username).frame(width: 170)
                SecureField("密码（仅本次）", text: $network.password).frame(width: 190)
                Spacer()
                Button("清空凭据") { network.username = ""; network.password = "" }.disabled(network.isBusy)
            }.textFieldStyle(.roundedBorder).disabled(network.isBusy)
            Group {
                if state.tab == 0 { channelsPanel }
                else { webDAVPanel }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                if network.isBusy { ProgressView().controlSize(.small) }
                Text(network.status).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if network.isBusy { Button("取消") { network.cancel() } }
            }
            if network.isBusy, let progress = network.downloadProgress {
                ProgressView(value: progress).progressViewStyle(.linear)
            }
            if let error = network.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("FTP / FTPS 文件…") { FTPBrowserWindow.show(player: player) }
                Button("打开 Finder 已挂载目录…") { player.openPanel() }
                Spacer()
                Text("目录/频道超时 25 秒 · 下载可取消").font(.caption).foregroundStyle(.secondary)
            }
            Text("账号密码仅用于本次请求，关闭即清除。支持 HTTP Basic；受保护文件先完整下载到本机再播放。SMB/NAS 可先在 Finder 挂载后打开。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(minWidth: 830, minHeight: 620)
            .onChange(of: network.channels) { _, _ in
                if let group = state.channelGroup, !network.channelGroups.contains(group) { state.channelGroup = nil }
                updateEPGChannels()
            }
            .sheet(isPresented: $state.showEPG) {
                EPGView(service: epg, playChannel: { player.open([$0]) }, onDone: { state.showEPG = false })
            }
            .onDisappear { epg.dismiss(); network.dismiss() }
    }

    private var channelsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("分组", selection: $state.channelGroup) {
                    Text("全部分组").tag(Optional<String>.none)
                    ForEach(network.channelGroups, id: \.self) { group in Text(group.isEmpty ? "未分组" : group).tag(Optional(group)) }
                }.frame(width: 210)
                TextField("搜索频道或分组", text: $state.channelSearch).textFieldStyle(.roundedBorder)
                Text("\(filteredChannels.count) / \(network.channels.count)").font(.caption).foregroundStyle(.secondary)
            }
            if network.channels.isEmpty {
                ContentUnavailableView("导入频道列表", systemImage: "list.bullet.rectangle", description: Text("读取远程 M3U / M3U8 / PLS，或打开已保存的本地列表。"))
            } else {
                List(filteredChannels) { channel in
                    HStack(spacing: 12) {
                        Image(systemName: "play.tv").foregroundStyle(.mint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(channel.name).lineLimit(1)
                            Text(channel.group.isEmpty ? "未分组" : channel.group).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if channel.logoURL != nil { Image(systemName: "photo").foregroundStyle(.tertiary).help("图标 URL 已保存；不会自动请求图片。") }
                        Button("播放") { player.open([channel.url]) }.disabled(network.isBusy)
                    }.padding(.vertical, 3).contextMenu {
                        Button("播放") { player.open([channel.url]) }
                        Button("加入当前列表") { player.open([channel.url], append: true) }
                        Button("复制频道地址") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(channel.url.absoluteString, forType: .string) }
                    }
                }
            }
            HStack {
                Button("读取本地列表…") { network.importLocalChannels() }.disabled(network.isBusy)
                Spacer()
                Button("节目单…") {
                    updateEPGChannels()
                    epg.setSourceTransport(ProductionEPGSourceTransport(username: network.username, password: network.password))
                    state.showEPG = true
                }.disabled(network.channels.isEmpty || network.isBusy)
                    .help("主动读取 XMLTV、匹配节目与可选台标。不会自动请求节目单。")
                Button("导出当前筛选…") { network.exportChannels(filteredChannels) }.disabled(filteredChannels.isEmpty || network.isBusy)
                Button("保存全部频道…") { network.exportChannels() }.disabled(network.channels.isEmpty || network.isBusy)
            }
            Text("频道会直接交给播放器。凭据用于读取列表；含认证的视频文件请从 WebDAV 下载后播放。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var webDAVPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { if let parent = network.parentDirectoryURL { network.browse(parent) } } label: { Label("上一级", systemImage: "arrow.up") }
                    .disabled(network.parentDirectoryURL == nil || network.isBusy)
                Text(network.currentDirectoryURL?.path ?? "尚未连接").font(.caption).lineLimit(1).textSelection(.enabled)
                Spacer()
                TextField("搜索当前目录", text: $state.fileSearch).textFieldStyle(.roundedBorder).frame(width: 210)
            }
            if network.currentDirectoryURL == nil {
                ContentUnavailableView("浏览 WebDAV 文件", systemImage: "externaldrive.connected.to.line.below", description: Text("输入服务器的文件夹地址，点击连接目录。"))
            } else if filteredResources.isEmpty {
                ContentUnavailableView("目录为空或没有匹配文件", systemImage: "folder", description: Text("返回上一级，或更改搜索内容。"))
            } else {
                List(filteredResources) { resource in
                    HStack(spacing: 12) {
                        Image(systemName: resource.isCollection ? "folder.fill" : "play.rectangle").foregroundStyle(resource.isCollection ? .yellow : .mint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(resource.name).lineLimit(1)
                            HStack(spacing: 8) {
                                if let size = resource.size, !resource.isCollection { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                                if let date = resource.modifiedAt { Text(date, style: .date) }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if resource.isCollection {
                            Button("打开文件夹") { network.browse(resource.url) }.disabled(network.isBusy)
                        } else if network.usesCredentials {
                            Button("先下载再播放") { network.download(resource) { player.open([$0]) } }.disabled(network.isBusy)
                        } else {
                            Button("直接播放") { player.open([resource.url]) }.disabled(network.isBusy)
                            Button("下载后播放") { network.download(resource) { player.open([$0]) } }.disabled(network.isBusy)
                        }
                    }.padding(.vertical, 3)
                }
            }
            HStack {
                Text("下载缓存：Application Support / SiliconPlayer / RemoteCache").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("打开缓存目录") {
                    try? FileManager.default.createDirectory(at: NetworkMediaService.cacheDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(NetworkMediaService.cacheDirectory)
                }
            }
        }
    }
    private func updateEPGChannels() {
        epg.setChannels(network.channels.map { EPGChannelReference(mediaURL: $0.url, tvgID: $0.tvgID, displayName: $0.name, logoURL: $0.logoURL) })
    }
}
