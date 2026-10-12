import AppKit
import Foundation
import PlayerCore

extension PlayerModel: PlaybackProgramHost {
    func openPlaybackProgram() {
        guard playbackProgramSnapshot() != nil else { toast("请先加载可确认时长的媒体"); return }
        PlaybackProgramWindow.show(controller: playbackProgram)
    }
    var restoredPlaybackProgram: PlaybackProgram? { mediaPreferences.restoredPlaybackProgram }
    var persistedPlaybackProgram: PlaybackProgram? { mediaPreferences.savedCurrent?.playbackProgram }
    func savePlaybackProgram(_ value: PlaybackProgram?, token: UUID) -> Bool {
        guard !profileStoresBlocked else { return false }
        return mediaPreferences.savePlaybackProgram(value, token: token)
    }
    func preparePlaybackProgramCore() -> Bool {
        guard playbackProgramSnapshot() != nil, !loopFile, string("loop-file") == "no",
              nativeAudioQueue.retireForPlaybackProgram(),
              string("loop-playlist") == "no",
              let rows = jsonProperty("playlist") as? [Any], rows.count == 1 else {
            toast("播放程序需要退出当前文件循环并确认连续音频尾部清理"); return false
        }
        return playbackProgramSnapshot() != nil
    }
    func writePlaybackProgramInterval(_ interval: PlaybackInterval?) -> Bool {
        guard let before = playbackProgramSnapshot(), before.remaining != nil else { return false }
        let a = interval.map { PlaybackProgram.seconds($0.startMicroseconds) } ?? "no"
        let b = interval.map { PlaybackProgram.seconds($0.endMicroseconds) } ?? "no"
        let count = interval?.totalPlays.map { String($0 - 1) } ?? "inf"
        // count is written last: all three options reset remaining-ab-loops.
        // Checked setters plus actual configured/remaining readbacks are needed;
        // a parent command-list status would not prove every child succeeded.
        guard setChecked("ab-loop-a", a) >= 0, setChecked("ab-loop-b", b) >= 0,
              setChecked("ab-loop-count", count) >= 0,
              let after = playbackProgramSnapshot(), after.itemID == before.itemID,
              after.loadToken == before.loadToken, after.entryID == before.entryID,
              after.remaining == (interval?.nativeLoopSeeks ?? -1), string("ab-loop-count") == count,
              interval.map({ value in
                  Double(string("ab-loop-a")).flatMap(PlaybackProgram.microseconds) == value.startMicroseconds
                    && Double(string("ab-loop-b")).flatMap(PlaybackProgram.microseconds) == value.endMicroseconds
              }) ?? (string("ab-loop-a") == "no" && string("ab-loop-b") == "no") else {
            // Best effort configuration cleanup, not arbitrary Core state rollback.
            _ = setChecked("ab-loop-a", "no"); _ = setChecked("ab-loop-b", "no")
            _ = setChecked("ab-loop-count", "inf")
            error = "A–B 配置未被实际播放器确认"; return false
        }
        abStart = interval.map { Double($0.startMicroseconds) / 1_000_000 }
        abEnd = interval.map { Double($0.endMicroseconds) / 1_000_000 }
        return true
    }
    func seekPlaybackProgram(_ target: Int64) -> Bool {
        guard target >= 0, let snapshot = playbackProgramSnapshot(), snapshot.seekable,
              target < snapshot.duration, !playbackProgramOwnSeek else { return false }
        playbackProgramOwnSeek = true; defer { playbackProgramOwnSeek = false }
        SubtitleSpeechController.shared.stop()
        return executeCommand(["seek", PlaybackProgram.seconds(target), "absolute+exact"]) >= 0
    }
    func holdPlaybackProgramBoundary() -> Bool {
        guard playbackProgramSnapshot() != nil, setChecked("pause", "yes") >= 0, flag("pause") else { return false }
        paused = true; return true
    }
    func restorePlaybackProgramPause(_ value: Bool) -> Bool {
        guard playbackProgramSnapshot() != nil,
              setChecked("pause", value ? "yes" : "no") >= 0, flag("pause") == value else { return false }
        paused = value; return true
    }
    func closeRecognitionForPlaybackProgram() async -> Bool {
        guard liveASR.canStop || LiveASRController.hasActiveJobs else { return true }
        let result = await liveASR.stop()
        // Keep existing partial/final distinction. stop is a real cancellation
        // and retains determined cues; an interval/outro is not media EOF.
        return result.confirmed && result.resourcesReleased && !LiveASRController.hasActiveJobs && !liveASR.canStop
    }
    func performPlaybackProgramAction(_ action: PlaybackProgramAction, ticket: PlaybackProgramTicket) -> Bool {
        guard let current = playbackProgramSnapshot(), current.itemID == ticket.itemID,
              current.loadToken == ticket.loadToken, current.entryID == ticket.entryID else { return false }
        switch action {
        case .nextMedia:
            var logical = playlist
            let hasSuccessor = logical.next(wrap: loopPlaylist) != nil
            next()
            return !hasSuccessor || (mediaPreferenceToken != ticket.loadToken && (isLoading || loaded))
        case .stop: stopPlayback(); return !loaded && !isLoading
        case .pause, .appSleep:
            guard setChecked("pause", "yes") >= 0, flag("pause") else { return false }
            paused = true
            if action == .appSleep, let activity = sleepActivity {
                ProcessInfo.processInfo.endActivity(activity); sleepActivity = nil
            }
            toast(action == .appSleep ? "已暂停并释放本应用的播放防睡眠活动" : "播放程序已暂停")
            return true
        case .quit:
            guard setChecked("pause", "yes") >= 0, flag("pause"),
                  let delegate = NSApp.delegate as? PlayerAppDelegate else { return false }
            paused = true
            // Uses the actual user Quit entry and dirty-editor/resource barriers.
            delegate.requestUserTermination(source: "playback-program")
            return true // A submitted App request, not proof that Quit completed.
        case .nextInterval, .continuePlayback: return false
        }
    }
}
