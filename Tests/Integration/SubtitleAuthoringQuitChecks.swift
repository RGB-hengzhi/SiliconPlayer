import Foundation
import PlayerCore

/// Prepared typed checks for actual proposed permit/State methods. No native
/// NSAlert/NSSavePanel/AppDelegate lifecycle is mocked into a runtime pass.
@main struct SubtitleAuthoringQuitChecks {
    @MainActor static func main() throws {
        func require(_ value: Bool, _ detail: String) throws {
            if !value { throw NSError(domain: "SubtitleAuthoringQuitChecks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: detail]) }
        }
        let a = UUID(), b = UUID(), c = UUID()
        var permit = SubtitleAuthoringQuitPermit()
        permit.approve(editor: a, revision: 7)
        try require(!permit.permits([a: 7, b: 3]), "Every retained editor must be reviewed")
        permit.approve(editor: b, revision: 3)
        try require(permit.permits([a: 7, b: 3]), "Exact authorized set/revisions")
        try require(!permit.permits([a: 7, b: 4]), "Later draft mutation revokes permission")
        try require(!permit.permits([a: 7, b: 3, c: 0]), "New editor is not implicitly discarded")
        try require(!permit.permits([a: 7]), "Lost editor changes the retained set")
        print("PASS subtitle-quit-permit-exact-set-and-revision")

        let original = "WEBVTT\n\n00:01.000 --> 00:02.000\n原句\n"
        let document = try PreservingSubtitleDocument.parse(original, format: .vtt)
        let state = SubtitleAuthoringState(document: document,
            sourceURL: URL(fileURLWithPath: "/private/tmp/not-created.vtt"), observedPlayerTime: nil)
        state.draftText = "未保存"
        try require(state.hasPendingChanges, "Uncommitted text is dirty")
        let revision = state.terminationRevision
        state.setAppTerminationLocked(true)
        state.deleteCue(); state.shift(); state.applyDraft()
        try require((try state.document.text()) == original && state.hasPendingChanges,
            "Authoring actions do not mutate locked document")
        state.draftText = "程序性晚到修改"
        try require(state.terminationRevision != revision,
            "Even a direct late draft assignment invalidates permission")
        state.setAppTerminationLocked(false); state.applyDraft()
        try require(state.document.cues[0].rawBody == "程序性晚到修改" && state.hasPendingChanges,
            "Cancel restores editing without losing typed content")
        print("PASS subtitle-quit-state-lock-cancel-keeps-draft")

        var discardPermit = SubtitleAuthoringQuitPermit()
        guard let current = state.terminationRevision else { throw NSError(domain: "Revision", code: 1) }
        discardPermit.approve(editor: a, revision: current)
        try require(discardPermit.permits([a: current]) && state.hasPendingChanges,
            "Discard authorization does not erase the document")
        discardPermit = SubtitleAuthoringQuitPermit() // A resource barrier canceled App exit.
        try require(!discardPermit.permits([a: current]) && state.hasPendingChanges,
            "Canceled exit revokes discard, preserving the contents for a later prompt")
        print("PASS subtitle-quit-discard-revoked-after-cleanup-cancel")

        let clean = SubtitleAuthoringState(document: document,
            sourceURL: URL(fileURLWithPath: "/private/tmp/not-created-clean.vtt"), observedPlayerTime: nil)
        try require(!clean.hasPendingChanges, "Existing clean editor")
        clean.setAppTerminationLocked(true)
        guard let cleanRevision = clean.terminationRevision else { throw NSError(domain: "Revision", code: 2) }
        var cleanPermit = SubtitleAuthoringQuitPermit()
        cleanPermit.approve(editor: c, revision: cleanRevision)
        try require(cleanPermit.permits([c: cleanRevision]), "Clean editor has an explicit exact permit")
        clean.draftText = "清理期间晚到的未保存内容"
        guard let changedRevision = clean.terminationRevision else { throw NSError(domain: "Revision", code: 3) }
        try require(!cleanPermit.permits([c: changedRevision]) && clean.hasPendingChanges,
            "Direct late edit fails the final revision gate rather than silently discarding")
        clean.setAppTerminationLocked(false)
        try require(clean.draftText == "清理期间晚到的未保存内容", "Canceled cleanup keeps new input")
        print("PASS subtitle-quit-clean-editor-final-revision")
    }
}
