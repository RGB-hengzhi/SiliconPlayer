import Foundation
import PlayerCore

/// Prepared direct State tests, compiled with the actual proposed editor file;
/// no mock PlayerModel/render/track acceptance and no save-panel automation.
@main struct SubtitleAuthoringStateChecks {
    @MainActor static func main() throws {
        let source = "WEBVTT\n\n00:01.000 --> 00:02.000\n甲\n\n00:03.000 --> 00:04.000\n乙\n"
        let document = try PreservingSubtitleDocument.parse(source, format: .vtt)
        var clock: Int64 = 2_000_000
        var bindingStillCurrent = true
        var requestedSeek: Int64?
        let state = SubtitleAuthoringState(document: document, sourceURL: URL(fileURLWithPath: "/private/tmp/not-created.vtt"), observedPlayerTime: {
            guard bindingStillCurrent else { throw SubtitlePreservationError.invalid("测试接口已退役") }
            return clock
        }, seekPlayer: { value in
            guard bindingStillCurrent else { throw SubtitlePreservationError.invalid("测试定位接口已退役") }
            requestedSeek = value
        })
        func require(_ value: Bool, _ detail: String) throws {
            if !value { throw NSError(domain: "SubtitleStateChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: detail]) }
        }
        try require(!state.hasPendingChanges && !state.allowRounding, "Exact default and clean read")
        state.captureAnchor(first: true)
        state.select(document.cues[1].id); clock = 6_000_000; state.captureAnchor(first: false)
        try require(state.sourceA == "00:00:01.000" && state.videoA == "00:00:02.000000"
            && state.sourceB == "00:00:03.000" && state.videoB == "00:00:06.000000", "Four independent anchor values")
        let before = try state.document.text(); state.videoB = "00:00:01.000000"; state.calibrate()
        try require(state.error != nil && (try state.document.text()) == before, "Reversed anchors keep document unchanged")
        state.videoB = "00:00:06.000000"; state.calibrate()
        try require(state.document.cues[0].startMicroseconds == 2_000_000 && state.hasPendingChanges, "Real State invokes integer calibration and dirty flag")
        state.moveSelection(-1); state.locateCue()
        try require(state.selection == document.cues[0].id && requestedSeek == 2_000_000, "Explicit previous-cue selection and bound seek request")
        state.moveSelection(1)
        print("PASS subtitle-authoring-state-four-anchor-and-dirty")

        let selected = state.selection; state.draftStart = "错误"; state.select(document.cues[0].id)
        try require(state.selection == selected && state.error != nil, "Invalid draft prevents selection/implicit data loss")
        state.draftStart = state.document.displayTime(state.document.cues[1].startMicroseconds)
        state.applyDraft(); let anchorBefore = state.videoB
        bindingStillCurrent = false; clock = 9_000_000; state.captureAnchor(first: false)
        try require(state.videoB == anchorBefore && state.error != nil, "Retired capture callback cannot assign stale anchor")
        let oldSeek = requestedSeek; state.locateCue()
        try require(requestedSeek == oldSeek && state.error != nil, "Retired locator cannot submit a new request")
        print("PASS subtitle-authoring-state-invalid-draft-and-retired-capture")

        let ass = try PreservingSubtitleDocument.parse("[Events]\nFormat: Start,End,Text\nDialogue: 0:00:01.00,0:00:02.00,{\\b1}甲", format: .ass)
        let exact = SubtitleAuthoringState(document: ass, sourceURL: URL(fileURLWithPath: "/private/tmp/not-created.ass"), observedPlayerTime: nil)
        exact.sourceA = "00:00:00.000000"; exact.videoA = "00:00:00.000001"
        exact.sourceB = "00:00:10.000000"; exact.videoB = "00:00:10.000001"
        exact.calibrate(); try require(exact.error != nil && !exact.hasChanges, "Sub-centisecond affine result refused by default")
        exact.allowRounding = true; exact.calibrate()
        try require(exact.error == nil && (try exact.document.text()) == (try ass.text()), "Explicit rounding accepted without marking unchanged bytes dirty")
        print("PASS subtitle-authoring-state-explicit-native-rounding")
    }
}
