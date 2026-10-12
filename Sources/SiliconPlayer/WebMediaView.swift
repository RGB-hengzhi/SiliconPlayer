import SwiftUI
import PlayerCore

@MainActor
private final class WebMediaUIState: ObservableObject {
    @Published var address = ""
    @Published var submittedPageURL: URL?
    @Published var resolvedPageURL: URL?
    @Published var formatID = "auto"
    @Published var subtitleLanguage = ""
    @Published var includeAutomaticSubtitles = false
    @Published var feedback: String?
    @Published var localError: String?
}

@MainActor
struct WebMediaView: View {
    @ObservedObject var player: PlayerModel
    @StateObject private var resolver = WebMediaResolver()
    @StateObject private var state = WebMediaUIState()

    // A result belongs to the exact submitted page, never to text edited later.
    private var currentDocument: WebMediaDocument? {
        guard let resolvedPage = state.resolvedPageURL,
              let document = resolver.document,
              let editedURL = try? WebMediaDocument.validatedPageURL(state.address),
              editedURL == resolvedPage,
              document.pageURL == resolvedPage else { return nil }
        return document
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("打开网页视频", systemImage: "globe").font(.title2.bold())
                Spacer()
                Button("完成", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .help("关闭网页视频窗口并取消尚未完成的解析。")
            }

            Text("输入视频页面地址，解析后选择清晰度和字幕。")
                .font(.callout).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField("https://…", text: $state.address)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("视频页面地址")
                    .help("输入完整的 HTTP 或 HTTPS 视频页面地址。编辑地址后需要重新解析。")
                    .onSubmit { resolve() }
                Button("解析", action: resolve)
                    .disabled(resolver.busy || state.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("读取这个页面的标题、清晰度和可用字幕。")
            }

            if let document = currentDocument {
                mediaOptions(document)
            } else {
                ContentUnavailableView(
                    resolver.busy ? "正在解析页面" : "尚未选择网页视频",
                    systemImage: "play.rectangle",
                    description: Text(resolver.busy ? "完成后会显示视频标题和可选清晰度。" : "输入地址并点击“解析”。更改地址后，之前的选择会作废。")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            }

            Divider()
            HStack(spacing: 10) {
                if resolver.busy {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("正在解析网页视频")
                }
                Text(state.feedback ?? resolver.status)
                    .font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                if resolver.busy {
                    Button("取消解析", action: cancelResolution)
                        .help("停止本次解析，保留输入的页面地址。")
                }
            }
            if let error = state.localError ?? resolver.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(5)
                    .help(error)
                    .accessibilityLabel("网页视频提示：\(error)")
            }

            HStack {
                Text("原网页地址和清晰度选择会保留在播放列表。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("加入列表") { openMedia(append: true) }
                    .disabled(currentDocument == nil || resolver.busy)
                    .help("把这个网页视频及当前选择加入播放列表。")
                Button("播放") { openMedia(append: false) }
                    .disabled(currentDocument == nil || resolver.busy)
                    .help("按所选清晰度打开这个网页视频。")
            }
            Text("支持范围为可公开访问、没有 DRM 的单个视频页面；网站和网络限制可能导致解析失败。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(minWidth: 680, minHeight: 470)
        .onAppear {
            if state.address.isEmpty, player.currentIsWebMedia, let page = player.currentURL {
                state.address = page.absoluteString
            }
        }
        .onChange(of: state.address) { _, _ in invalidateResult() }
        .onReceive(resolver.$document) { document in
            guard let document, let requestedPage = state.submittedPageURL,
                  document.pageURL == requestedPage,
                  (try? WebMediaDocument.validatedPageURL(state.address)) == requestedPage else { return }
            state.resolvedPageURL = requestedPage
            state.formatID = "auto"
            state.subtitleLanguage = ""
            state.includeAutomaticSubtitles = false
            state.feedback = nil
            state.localError = nil
            if player.currentIsWebMedia, player.currentURL == document.pageURL,
               let preference = player.playlist.currentItem?.webMedia {
                if let restored = try? document.validatedSelection(preference) {
                    state.formatID = restored.formatID
                    state.subtitleLanguage = restored.subtitleLanguage ?? ""
                    state.includeAutomaticSubtitles = restored.includeAutomaticSubtitles
                } else {
                    state.feedback = "之前的清晰度或字幕已不可用，已改为自动选择和无字幕。"
                }
            }
        }
        .onDisappear {
            state.submittedPageURL = nil
            state.resolvedPageURL = nil
            resolver.cancel()
        }
    }

    private func mediaOptions(_ document: WebMediaDocument) -> some View {
        GroupBox("网页视频") {
            VStack(alignment: .leading, spacing: 14) {
                Text(document.title).font(.headline).textSelection(.enabled)
                    .lineLimit(3).truncationMode(.tail)
                HStack(spacing: 8) {
                    Label(durationText(document), systemImage: document.isLive ? "dot.radiowaves.left.and.right" : "clock")
                    Spacer()
                }.font(.callout).foregroundStyle(.secondary)

                Picker("清晰度", selection: $state.formatID) {
                    Text("自动选择").tag("auto")
                    ForEach(document.formats.filter { $0.formatID != "auto" }, id: \.formatID) { format in
                        Text(format.displayName).tag(format.formatID)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("网页视频清晰度")
                .help("可选择自动清晰度，或页面实际提供的一种格式。")

                Picker("网页字幕", selection: subtitleBinding(in: document)) {
                    Text("无字幕").tag("")
                    ForEach(document.availableSubtitleLanguages, id: \.self) { language in
                        Text(subtitleName(language, in: document)).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("网页字幕语言")
                .help("选择页面提供的字幕语言。自动生成字幕会单独标明，可能包含识别误差。")
                if !state.subtitleLanguage.isEmpty,
                   document.automaticSubtitleLanguages.contains(state.subtitleLanguage),
                   !document.manualSubtitleLanguages.contains(state.subtitleLanguage) {
                    Text("此语言的字幕由网站自动生成，内容可能有误。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !state.subtitleLanguage.isEmpty,
                          document.automaticSubtitleLanguages.contains(state.subtitleLanguage) {
                    Toggle("允许使用网站自动生成字幕", isOn: $state.includeAutomaticSubtitles)
                        .help("这个语言有网站字幕和自动生成字幕，优先使用网站字幕。自动字幕可能包含识别误差。")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(resolver.busy)
    }

    private func resolve() {
        guard !resolver.busy else { return }
        state.localError = nil
        state.feedback = nil
        state.resolvedPageURL = nil
        state.submittedPageURL = nil
        state.formatID = "auto"
        state.subtitleLanguage = ""
        state.includeAutomaticSubtitles = false
        do {
            state.submittedPageURL = try WebMediaDocument.validatedPageURL(state.address)
            resolver.resolve(address: state.address)
        } catch {
            resolver.cancel()
            state.localError = error.localizedDescription
        }
    }

    private func invalidateResult() {
        let hadResultOrJob = state.submittedPageURL != nil || currentDocument != nil || resolver.busy
        state.submittedPageURL = nil
        state.resolvedPageURL = nil
        state.formatID = "auto"
        state.subtitleLanguage = ""
        state.includeAutomaticSubtitles = false
        state.localError = nil
        if hadResultOrJob {
            resolver.cancel()
            state.feedback = "地址已更改，请重新解析。"
        } else {
            state.feedback = nil
        }
    }

    private func cancelResolution() {
        state.submittedPageURL = nil
        state.resolvedPageURL = nil
        state.localError = nil
        resolver.cancel()
        state.feedback = "已取消解析。"
    }

    private func openMedia(append: Bool) {
        guard !resolver.busy, let document = currentDocument else { return }
        do {
            let selection = try document.selection(
                formatID: state.formatID,
                subtitleLanguage: state.subtitleLanguage.isEmpty ? nil : state.subtitleLanguage,
                includeAutomaticSubtitles: state.includeAutomaticSubtitles
            )
            // Persist the original page identity and preference. No signed stream URL enters the queue.
            guard player.openWebMedia(pageURL: document.pageURL, selection: selection, append: append) else {
                state.localError = player.error ?? "未能打开网页视频，请检查页面地址和解析工具。"
                return
            }
            state.localError = nil
            if append { state.feedback = "已加入播放列表。" }
            else { dismiss() }
        } catch {
            state.localError = error.localizedDescription
        }
    }

    private func dismiss() {
        state.submittedPageURL = nil
        state.resolvedPageURL = nil
        resolver.cancel()
        player.showWebMedia = false
    }

    private func subtitleName(_ language: String, in document: WebMediaDocument) -> String {
        let name = Locale(identifier: "zh_CN").localizedString(forIdentifier: language) ?? language
        let automatic = document.automaticSubtitleLanguages.contains(language)
            && !document.manualSubtitleLanguages.contains(language)
        return automatic ? "\(name)（自动生成）" : name
    }

    private func subtitleBinding(in document: WebMediaDocument) -> Binding<String> {
        Binding(get: { state.subtitleLanguage }, set: { language in
            state.subtitleLanguage = language
            state.includeAutomaticSubtitles = !language.isEmpty
                && document.automaticSubtitleLanguages.contains(language)
                && !document.manualSubtitleLanguages.contains(language)
        })
    }

    private func durationText(_ document: WebMediaDocument) -> String {
        if document.isLive { return "直播" }
        guard let duration = document.duration, duration.isFinite, duration >= 0 else { return "时长未知" }
        let seconds = Int(min(duration, Double(Int.max / 2)))
        if seconds >= 3600 { return "\(seconds / 3600):" + String(format: "%02d:%02d", seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
