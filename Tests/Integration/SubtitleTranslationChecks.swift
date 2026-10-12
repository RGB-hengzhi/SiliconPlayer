import AppKit
import Combine
import Foundation
import Darwin

@MainActor final class PlayerModel: ObservableObject {
    @Published var settings = PlaybackSettings()
    @Published var showTranslation = true
    @Published var loaded = true
    @Published var paused = true
    @Published var position = 0.0
    @Published var speed = 1.0
    func addSubtitle(_ url: URL) {}
}

private func translationRequire(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw NSError(domain: "SubtitleTranslationChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main struct SubtitleTranslationChecks {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        guard #available(macOS 15.0, *) else {
            print("SKIP translation state execution: macOS 15+ required; macOS 14 build still typechecks")
            return
        }
        let state = SubtitleTranslationState()
        state.begin()
        try translationRequire(state.error != nil && !state.busy, "Missing document accepted")
        let first = SubtitleCue(start: 1.125, end: 3.5, text: "<i>Hello</i>")
        let second = SubtitleCue(start: 4, end: 6.75, text: "Welcome home.")
        state.document = SubtitleDocument(cues: [first, second], sourceFormat: .ass)
        state.sourceCode = "en"; state.targetCode = "en"; state.begin()
        try translationRequire(state.error?.contains("相同") == true && !state.busy, "Same language accepted")
        state.sourceCode = "zh-Hans"; state.targetCode = "zh-Hant"; state.begin()
        try translationRequire(state.error?.contains("相同") == true && !state.busy, "Same base-language pair accepted")
        state.sourceCode = "en"; state.targetCode = "zh-Hans"; state.begin()
        try translationRequire(state.busy && state.configuration?.source?.languageCode?.identifier == "en", "Explicit language configuration invalid")
        state.cancel()
        state.document = SubtitleDocument(cues: [.init(start: 0, end: 2, text: "This English sentence explains watching a film with translated subtitles.")])
        state.sourceCode = "auto"; state.begin()
        try translationRequire(state.busy && state.resolvedSourceCode == "en", "Automatic source detection failed")
        print("PASS missing/same-language rejection, explicit configuration and local source detection")
        state.cancel()
        try translationRequire(!state.busy && state.configuration == nil && !state.finished, "Cancellation retained active/complete state")
        state.cancel(showStatus: false)
        try translationRequire(state.configuration == nil && !state.complete, "Repeated cancel changed state")
        state.document = SubtitleDocument(cues: [.init(start: 0, end: 1, text: "   ")]); state.begin()
        try translationRequire(!state.busy && state.error != nil, "Empty subtitle text accepted")
        print("PASS configuration cancellation, repeat cancellation and empty text rejection; no session started")
        state.document = SubtitleDocument(cues: [first, second], sourceFormat: .ass)
        state.translations = [second.id: "欢迎回家。", first.id: "你好\n\n世界"]
        state.finished = true
        let translated = try state.result(bilingual: false)
        try translationRequire(translated.cues.map(\.id) == [first.id, second.id], "Keyed translations reordered cues")
        try translationRequire(translated.cues[0].start == first.start && translated.cues[1].end == second.end, "Translation changed timing")
        let bilingual = try state.result(bilingual: true)
        try translationRequire(bilingual.cues[0].text == "Hello\n你好\n世界", "Bilingual text/blank line normalization failed")
        let roundTrip = try SubtitleDocument.parse(bilingual.srtText())
        try translationRequire(roundTrip.cues.map(\.text) == bilingual.cues.map(\.text) && roundTrip.cues.map(\.start) == bilingual.cues.map(\.start), "UTF-8 SRT roundtrip failed")
        print("PASS keyed-result ordering, timeline preservation and bilingual SRT roundtrip")
        state.finished = false
        var rejected = false
        do { _ = try state.result(bilingual: true) } catch { rejected = true }
        try translationRequire(rejected, "Unfinished result exported")
        state.finished = true; state.translations = [first.id: "你好"]
        try translationRequire(!state.complete, "Partial results reported complete")
        state.translations = [UUID(): "错误标识", UUID(): "另一个错误"]
        rejected = false
        do { _ = try state.result(bilingual: false) } catch { rejected = true }
        try translationRequire(rejected, "Wrong cue IDs exported")
        state.selectionChanged()
        try translationRequire(!state.complete && state.translations.isEmpty && !state.finished, "Changed language retained old results")
        print("PASS unfinished/partial/wrong-ID result protection and language-change reset")
        try SubtitleSpeechController.shared.checkSilentCueAndLifecycle()
        print("6 translation/TTS logic groups passed; no TranslationSession, language download or audible speech invoked")
    }
}

// The script appends this file to production source. Private helpers manipulate
// cue/clock state only and never call speak() or install a speech voice.
private extension SubtitleSpeechController {
    func checkSilentCueAndLifecycle() throws {
        let long = SubtitleCue(start: 1, end: 10, text: "Long")
        let short = SubtitleCue(start: 2, end: 3, text: "Short")
        let late = SubtitleCue(start: 20, end: 21, text: "Late")
        cues = [long, short, late]; prefixEnds = [10, 10, 21]
        try translationRequire(activeCue(at: 0) == nil && activeCue(at: 10) == nil && activeCue(at: 21) == nil, "Cue gaps/end boundaries incorrect")
        try translationRequire(activeCue(at: 1)?.id == long.id && activeCue(at: 2.5)?.id == short.id && activeCue(at: 3)?.id == long.id && activeCue(at: 20)?.id == late.id, "Cue starts/overlaps incorrect")
        stop(); try translationRequire(activeCue(at: 2) == nil, "Stop retained cue data")
        print("PASS speech cue start/end boundaries, gaps, overlaps and cue cleanup")
        let fixture = PlayerModel()
        start(document: SubtitleDocument(cues: [long]), player: fixture, language: "en")
        try translationRequire(!isReading && error != nil, "Paused player allowed narration")
        stop()
        isReading = true; player = fixture; tick()
        try translationRequire(!isReading, "Pause did not stop narration state")
        fixture.paused = false; fixture.loaded = false; isReading = true; player = fixture; tick()
        try translationRequire(!isReading, "Unloaded player did not stop narration state")
        fixture.loaded = true; fixture.position = 10
        isReading = true; player = fixture; previousPosition = 0; previousTick = ProcessInfo.processInfo.systemUptime
        tick(); try translationRequire(!isReading && previousPosition == nil && player == nil, "Clock discontinuity retained narration state")
        stop()
        print("PASS user-start playing requirement and silent pause/unload/seek-state cleanup")
    }
}
