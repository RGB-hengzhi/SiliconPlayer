import AppKit
import SwiftUI
import PlayerCore
import Translation
import NaturalLanguage
import AVFoundation
import UniformTypeIdentifiers

struct SubtitleTranslationView: View {
    @ObservedObject var player: PlayerModel
    var body: some View {
        Group {
            if #available(macOS 15.0, *) {
                NativeSubtitleTranslationView(player: player)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "character.bubble").font(.system(size: 42)).foregroundStyle(.secondary)
                    Text("本地字幕翻译需要 macOS 15 或更新版本").font(.title3.weight(.semibold))
                    Text("升级系统后可使用 Apple 本地翻译模型。当前仍可加载与编辑字幕。").foregroundStyle(.secondary)
                    Button("完成") { player.showTranslation = false }.keyboardShortcut(.defaultAction)
                }.padding(32).frame(width: 600, height: 280)
            }
        }
    }
}

private enum SubtitleTranslationError: LocalizedError {
    case missingDocument, unidentifiedLanguage, sameLanguage, unsupportedPair
    case invalidResponse, incompleteResponse, noResult
    var errorDescription: String? {
        switch self {
        case .missingDocument: return "请先选择一份文本字幕。"
        case .unidentifiedLanguage: return "无法自动识别字幕语言，请手动选择源语言。"
        case .sameLanguage: return "源语言与目标语言相同，请选择另一种目标语言。"
        case .unsupportedPair: return "系统翻译模型暂不支持这组语言，请选择其他语言。"
        case .invalidResponse: return "系统翻译返回的字幕标识或正文无效，已停止处理。"
        case .incompleteResponse: return "系统没有返回全部字幕的翻译。请重新尝试；未完成的结果不会导出。"
        case .noResult: return "请先完成字幕翻译，再保存结果。"
        }
    }
}

@available(macOS 15.0, *)
@MainActor
private final class SubtitleTranslationState: ObservableObject {
    @Published var document: SubtitleDocument?
    @Published var sourceURL: URL?
    @Published var sourceCode = "auto"
    @Published var targetCode = "zh-Hans"
    @Published var resolvedSourceCode = ""
    @Published var translations: [UUID: String] = [:]
    @Published var configuration: TranslationSession.Configuration?
    @Published var busy = false
    @Published var finished = false
    @Published var status = "选择字幕文件，然后开始翻译。"
    @Published var error: String?
    @Published var bilingual = true
    @Published var readTranslated = false
    @Published var savedURL: URL?
    private var runID = UUID()

    static let languages: [(String, String)] = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁体中文"), ("en", "英语"), ("ja", "日语"), ("ko", "韩语"),
        ("fr", "法语"), ("de", "德语"), ("es", "西班牙语"), ("it", "意大利语"), ("pt", "葡萄牙语"),
        ("ru", "俄语"), ("ar", "阿拉伯语"), ("hi", "印地语"), ("th", "泰语"), ("vi", "越南语"),
        ("id", "印度尼西亚语"), ("tr", "土耳其语"), ("uk", "乌克兰语"), ("nl", "荷兰语"), ("pl", "波兰语")
    ]
    var complete: Bool { finished && !busy && document != nil && translations.count == document?.cues.count }
    var total: Int { document?.cues.count ?? 0 }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "选择要翻译的字幕"
        panel.allowedContentTypes = ["srt", "vtt", "ass", "ssa"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let document = try SubtitleDocument.read(from: url)
            cancel(showStatus: false)
            self.document = document
            sourceURL = url
            translations = [:]
            savedURL = nil
            resolvedSourceCode = ""
            error = nil
            status = "已读取 \(document.cues.count) 条字幕。"
        } catch { self.error = error.localizedDescription }
    }

    func selectionChanged() {
        guard !busy else { return }
        translations = [:]
        finished = false
        savedURL = nil
        resolvedSourceCode = ""
        error = nil
        status = document == nil ? "选择字幕文件，然后开始翻译。" : "语言设置已更改，点击开始翻译。"
    }

    func begin() {
        guard !busy else { return }
        error = nil
        do {
            guard let document, !document.cues.isEmpty else { throw SubtitleTranslationError.missingDocument }
            guard document.cues.contains(where: { !Self.plainText($0.text).isEmpty }) else { throw TranslationError.nothingToTranslate }
            let source: String
            if sourceCode == "auto" {
                let sample = document.cues.prefix(80).map { Self.plainText($0.text) }.joined(separator: "\n")
                guard let detected = NLLanguageRecognizer.dominantLanguage(for: String(sample.prefix(12_000))) else {
                    throw SubtitleTranslationError.unidentifiedLanguage
                }
                source = detected.rawValue
            } else { source = sourceCode }
            let from = Locale.Language(identifier: source)
            let to = Locale.Language(identifier: targetCode)
            guard from.languageCode != to.languageCode else { throw SubtitleTranslationError.sameLanguage }
            runID = UUID()
            translations = [:]
            finished = false
            savedURL = nil
            resolvedSourceCode = source
            busy = true
            status = "正在检查语言模型…"
            configuration = .init(source: from, target: to)
        } catch { self.error = error.localizedDescription }
    }

    func cancel(showStatus: Bool = true) {
        let wasBusy = busy
        runID = UUID()
        // Changing the configuration cancels the view-owned translation task.
        // No session escapes the lifetime of that task (required by Apple's API).
        configuration = nil
        busy = false
        finished = false
        if wasBusy && showStatus { status = "已取消翻译。未完成的结果不会导出。" }
    }

    func translate(using session: TranslationSession) async {
        guard busy, let document else { return }
        let run = runID
        defer {
            if runID == run { busy = false; configuration = nil }
        }
        do {
            try ensureCurrent(run)
            guard let source = session.sourceLanguage, let target = session.targetLanguage else { throw SubtitleTranslationError.unidentifiedLanguage }
            let availability = await LanguageAvailability().status(from: source, to: target)
            try ensureCurrent(run)
            guard availability != .unsupported else { throw SubtitleTranslationError.unsupportedPair }
            status = availability == .installed ? "正在准备本地翻译…" : "等待系统准备语言模型，请在系统提示中决定是否下载。"
            // This API displays the system's download consent UI when needed.
            try await session.prepareTranslation()
            try ensureCurrent(run)
            let pending = document.cues.filter { !Self.plainText($0.text).isEmpty }
            for cue in document.cues where Self.plainText(cue.text).isEmpty { translations[cue.id] = "" }
            for offset in stride(from: 0, to: pending.count, by: 64) {
                try ensureCurrent(run)
                let batch = Array(pending[offset..<min(offset + 64, pending.count)])
                let expected = Set(batch.map(\.id))
                var received = Set<UUID>()
                let requests = batch.map { TranslationSession.Request(sourceText: Self.plainText($0.text), clientIdentifier: $0.id.uuidString) }
                for try await response in session.translate(batch: requests) {
                    try ensureCurrent(run)
                    guard let identifier = response.clientIdentifier, let id = UUID(uuidString: identifier),
                          expected.contains(id), received.insert(id).inserted else { throw SubtitleTranslationError.invalidResponse }
                    let translated = Self.cueText(response.targetText)
                    guard !translated.isEmpty else { throw SubtitleTranslationError.invalidResponse }
                    translations[id] = translated
                    status = "已翻译 \(translations.count) / \(document.cues.count) 条字幕"
                }
                guard received == expected else { throw SubtitleTranslationError.incompleteResponse }
            }
            try ensureCurrent(run)
            guard translations.count == document.cues.count else { throw SubtitleTranslationError.incompleteResponse }
            finished = true
            status = "翻译完成：\(document.cues.count) 条，时间轴与原字幕一致。"
        } catch is CancellationError {
            if runID == run { status = "已取消翻译。" }
        } catch {
            if runID == run { self.error = error.localizedDescription; status = "翻译未完成。" }
        }
    }

    func result(bilingual: Bool) throws -> SubtitleDocument {
        guard complete, let document else { throw SubtitleTranslationError.noResult }
        let cues = try document.cues.map { cue -> SubtitleCue in
            guard let raw = translations[cue.id] else { throw SubtitleTranslationError.incompleteResponse }
            let translated = Self.cueText(raw)
            let original = Self.plainText(cue.text)
            let text = bilingual && !original.isEmpty && !translated.isEmpty ? original + "\n" + translated : translated
            return SubtitleCue(start: cue.start, end: cue.end, text: text, id: cue.id)
        }
        return SubtitleDocument(cues: cues, sourceFormat: .srt)
    }

    func save(loadAfterSaving: Bool, onSaved: (URL) -> Void) {
        do {
            let translated = try result(bilingual: bilingual)
            let panel = NSSavePanel()
            panel.title = bilingual ? "保存双语字幕" : "保存译文字幕"
            panel.allowedContentTypes = [UTType(filenameExtension: "srt")!]
            let name = sourceURL?.deletingPathExtension().lastPathComponent ?? "字幕"
            panel.nameFieldStringValue = "\(name).\(bilingual ? "双语" : targetCode).srt"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try translated.writeSRT(to: url)
            savedURL = url
            error = nil
            status = "已保存 UTF-8 SRT：\(url.lastPathComponent)"
            if loadAfterSaving { onSaved(url) }
        } catch { self.error = error.localizedDescription }
    }

    private func ensureCurrent(_ run: UUID) throws {
        try Task.checkCancellation()
        guard run == runID, busy else { throw CancellationError() }
    }
    static func plainText(_ text: String) -> String {
        cueText(text.replacingOccurrences(of: "</?(?:i|b|u|font)(?:\\s[^>]*)?>", with: "", options: [.regularExpression, .caseInsensitive]))
    }
    private static func cueText(_ text: String) -> String {
        text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@available(macOS 15.0, *)
private struct NativeSubtitleTranslationView: View {
    @ObservedObject var player: PlayerModel
    @ObservedObject private var speech = SubtitleSpeechController.shared
    @StateObject private var state = SubtitleTranslationState()
    private var colorScheme: ColorScheme? {
        player.settings.theme == "dark" ? .dark : player.settings.theme == "light" ? .light : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本地字幕翻译").font(.title2.weight(.semibold))
                    Text("Apple 本地模型 · 保留字幕时间轴").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("选择字幕…") { speech.stop(); state.chooseFile() }.disabled(state.busy)
                Button("完成") { speech.stop(); state.cancel(); player.showTranslation = false }.keyboardShortcut(.defaultAction)
            }
            Text(state.sourceURL?.lastPathComponent ?? "支持 SRT、VTT、ASS、SSA 文本字幕")
                .font(.headline).lineLimit(1).textSelection(.enabled)
            HStack {
                Picker("源语言", selection: $state.sourceCode) {
                    Text("自动识别").tag("auto")
                    ForEach(SubtitleTranslationState.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Picker("目标语言", selection: $state.targetCode) {
                    ForEach(SubtitleTranslationState.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
            }.disabled(state.busy)
            Text("字幕文本在本机翻译。首次使用某种语言时，系统可能提示下载语言模型，由你决定是否下载。单份字幕应使用同一种源语言；自动识别不确定时请手动选择。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if state.document?.losesFormatting == true {
                Label("将以纯文字 SRT 导出，ASS / VTT 的样式和位置不会保留。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(state.complete ? "重新翻译" : "开始翻译") { speech.stop(); state.begin() }
                    .buttonStyle(.borderedProminent).disabled(state.document == nil || state.busy)
                if state.busy { Button("取消") { state.cancel() } }
                if !state.resolvedSourceCode.isEmpty {
                    Text("源语言：\(Locale.current.localizedString(forIdentifier: state.resolvedSourceCode) ?? state.resolvedSourceCode)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if state.busy { ProgressView(value: Double(state.translations.count), total: Double(max(1, state.total))).frame(width: 130) }
            }
            Text(state.status).font(.caption).foregroundStyle(.secondary)
            if let error = state.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let document = state.document {
                        ForEach(Array(document.cues.enumerated()), id: \.element.id) { index, cue in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(index + 1) · \(SubtitleDocument.timestamp(cue.start)) → \(SubtitleDocument.timestamp(cue.end))")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(cue.text).font(.system(size: 12)).textSelection(.enabled)
                                if let translated = state.translations[cue.id], !translated.isEmpty {
                                    Text(translated).font(.system(size: 12, weight: .medium)).foregroundStyle(.tint).textSelection(.enabled)
                                }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        }
                    } else { ContentUnavailableView("尚未选择字幕", systemImage: "captions.bubble", description: Text("选择字幕文件即可查看原文与译文。")).frame(minHeight: 160) }
                }
            }
            Divider()
            HStack {
                Picker("朗读文本", selection: $state.readTranslated) {
                    Text("原文").tag(false)
                    Text("译文").tag(true).disabled(!state.complete)
                }.frame(width: 170).disabled(speech.isReading)
                Button(speech.isReading ? "停止朗读" : "开始朗读") {
                    if speech.isReading { speech.stop() } else { startReading() }
                }.disabled(!speech.isReading && (state.document == nil || !player.loaded || player.paused || (state.readTranslated && !state.complete)))
                Text("随当前播放位置朗读；暂停或跳转后停止。").font(.caption).foregroundStyle(.secondary)
            }
            if let error = speech.error { Text(error).font(.caption).foregroundStyle(.red) }
            Divider()
            HStack {
                Toggle("双语 SRT（原文 + 译文）", isOn: $state.bilingual).toggleStyle(.checkbox)
                Spacer()
                Button("保存 SRT…") { state.save(loadAfterSaving: false, onSaved: { _ in }) }.disabled(!state.complete)
                Button("保存并载入播放器…") { state.save(loadAfterSaving: true, onSaved: player.addSubtitle) }
                    .disabled(!state.complete || !player.loaded)
            }
        }.padding(20).frame(width: 840, height: 680)
        .preferredColorScheme(colorScheme)
        .translationTask(state.configuration) { session in await state.translate(using: session) }
        .onChange(of: state.sourceCode) { _, _ in speech.stop(); state.selectionChanged() }
        .onChange(of: state.targetCode) { _, _ in speech.stop(); state.selectionChanged() }
        .onDisappear { speech.stop(); state.cancel(showStatus: false) }
    }

    private func startReading() {
        do {
            guard let document = state.document else { throw SubtitleTranslationError.missingDocument }
            if state.readTranslated {
                speech.start(document: try state.result(bilingual: false), player: player, language: state.targetCode)
            } else {
                let source: String
                if state.sourceCode == "auto" {
                    let sample = document.cues.prefix(80).map { SubtitleTranslationState.plainText($0.text) }.joined(separator: "\n")
                    guard let detected = NLLanguageRecognizer.dominantLanguage(for: String(sample.prefix(12_000))) else {
                        throw SubtitleTranslationError.unidentifiedLanguage
                    }
                    source = detected.rawValue
                } else { source = state.sourceCode }
                let cues = document.cues.map { SubtitleCue(start: $0.start, end: $0.end, text: SubtitleTranslationState.plainText($0.text), id: $0.id) }
                speech.start(document: SubtitleDocument(cues: cues), player: player, language: source)
            }
        } catch { state.error = error.localizedDescription }
    }
}

/// User-started subtitle narration. Never requests microphone access.
@MainActor
final class SubtitleSpeechController: ObservableObject {
    static let shared = SubtitleSpeechController()
    @Published private(set) var isReading = false
    @Published private(set) var error: String?
    private let synthesizer = AVSpeechSynthesizer()
    private weak var player: PlayerModel?
    private var timer: Timer?
    private var cues: [SubtitleCue] = []
    private var prefixEnds: [Double] = []
    private var voice: AVSpeechSynthesisVoice?
    private var lastCueID: UUID?
    private var previousPosition: Double?
    private var previousTick: TimeInterval?

    private init() {}

    func start(document: SubtitleDocument, player: PlayerModel, language: String) {
        stop()
        error = nil
        guard player.loaded, !player.paused else { error = "请先播放媒体，再开始字幕朗读。"; return }
        guard let voice = AVSpeechSynthesisVoice(language: language) else {
            error = "系统没有可用的 \(language) 朗读声音，请在系统设置的辅助功能中安装对应声音。"; return
        }
        do { try document.validate() } catch { self.error = error.localizedDescription; return }
        cues = document.cues.sorted { $0.start < $1.start }
        var maximumEnd = 0.0
        prefixEnds = cues.map { maximumEnd = max(maximumEnd, $0.end); return maximumEnd }
        self.voice = voice
        self.player = player
        isReading = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        synthesizer.stopSpeaking(at: .immediate)
        isReading = false
        lastCueID = nil
        previousPosition = nil
        previousTick = nil
        player = nil
        voice = nil
        cues = []
        prefixEnds = []
        error = nil
    }

    private func tick() {
        guard isReading, let player, player.loaded, !player.paused else { stop(); return }
        let position = player.position
        let now = ProcessInfo.processInfo.systemUptime
        guard position.isFinite else { stop(); return }
        if let previousPosition, let previousTick {
            let expectedAdvance = max(0, now - previousTick) * player.speed
            if abs((position - previousPosition) - expectedAdvance) > max(0.4, expectedAdvance * 2) {
                stop(); return
            }
        }
        previousPosition = position
        previousTick = now
        guard let cue = activeCue(at: position) else {
            if lastCueID != nil { synthesizer.stopSpeaking(at: .immediate); lastCueID = nil }
            return
        }
        guard lastCueID != cue.id else { return }
        synthesizer.stopSpeaking(at: .immediate)
        lastCueID = cue.id
        guard !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let utterance = AVSpeechUtterance(string: cue.text)
        utterance.voice = voice
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(player.speed)))
        synthesizer.speak(utterance)
    }

    private func activeCue(at position: Double) -> SubtitleCue? {
        var lower = 0, upper = cues.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if cues[middle].start <= position { lower = middle + 1 } else { upper = middle }
        }
        var index = lower - 1
        while index >= 0 {
            guard prefixEnds[index] > position else { return nil }
            if cues[index].end > position { return cues[index] }
            index -= 1
        }
        return nil
    }
}
