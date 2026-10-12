import Foundation

// precondition remains active under the smoke runner's -O build.
// The former cached harness used assert, which -O removes.
@main struct Harness {
 @MainActor static func wait(_ tools: MediaTools) async throws {
  let deadline=Date().addingTimeInterval(60)
  while tools.busy && Date()<deadline { try await Task.sleep(nanoseconds: 50_000_000) }
  guard !tools.busy else { tools.cancel(); throw NSError(domain:"test",code:1,userInfo:[NSLocalizedDescriptionKey:"Job timeout"]) }
  if let error=tools.error { throw NSError(domain:"test",code:2,userInfo:[NSLocalizedDescriptionKey:error]) }
 }
 @MainActor static func main() async throws {
  let t=MediaTools.shared
  let folder=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
  let source=folder.appendingPathComponent("generated-video.mp4")
  for name in ["api-clip.mp4", "api-copy.mkv", "api-audio.wav", "api-stopped-recording.mkv", "api-subtitles.srt"] {
   let output=folder.appendingPathComponent(name)
   if FileManager.default.fileExists(atPath:output.path) {try FileManager.default.removeItem(at:output)}
  }
  let clip=folder.appendingPathComponent("api-clip.mp4")
  t.exportClip(source:source,start:1,end:3,output:clip,transcode:true)
  try await wait(t); precondition(FileManager.default.fileExists(atPath:clip.path)); print("API exact clip passed")
  let copied=folder.appendingPathComponent("api-copy.mkv")
  t.exportClip(source:source,start:0,end:2,output:copied,transcode:false)
  try await wait(t); precondition(FileManager.default.fileExists(atPath:copied.path)); print("API copy clip passed")
  let audio=folder.appendingPathComponent("api-audio.wav")
  t.extractAudio(source:source,output:audio); try await wait(t); print("API audio extraction passed")
  let recording=folder.appendingPathComponent("api-stopped-recording.mkv")
  t.recordStream(source:source,output:recording)
  try await Task.sleep(nanoseconds:1_200_000_000);t.stop();try await wait(t)
  precondition(FileManager.default.fileExists(atPath:recording.path)); print("API graceful recording stop passed")
  let cancelled=folder.appendingPathComponent("api-cancelled.mkv")
  let original=Data("preserve existing output".utf8);try original.write(to:cancelled)
  t.recordStream(source:source,output:cancelled)
  try await Task.sleep(nanoseconds:250_000_000);t.cancel();try await wait(t)
  let after=try Data(contentsOf:cancelled);precondition(after==original);precondition(t.status=="已取消");print("API cancel preserves existing output passed")
  var callback:URL?
  t.onSubtitlesReady={callback=$0}
  let srt=folder.appendingPathComponent("api-subtitles.srt")
  t.generateSubtitles(source:folder.appendingPathComponent("chinese-speech.wav"),output:srt,language:"zh")
  try await wait(t)
  let contents=try String(contentsOf:srt);precondition(contents.contains("-->"));precondition(callback==srt);print("API Chinese subtitles and callback passed")
  let clipBefore=try Data(contentsOf:clip)
  t.exportClip(source:source,start:2,end:1,output:clip,transcode:true)
  let deadline=Date().addingTimeInterval(5)
  while t.busy && Date()<deadline {try await Task.sleep(nanoseconds:20_000_000)}
  precondition(!t.busy && t.error != nil)
  let clipAfter=try Data(contentsOf:clip);precondition(clipAfter==clipBefore)
  print("API invalid range rejected passed")
  let remains=try FileManager.default.contentsOfDirectory(atPath:folder.path).filter{$0.hasPrefix(".siliconplayer-")}
  precondition(remains.isEmpty);print("API temporary output cleanup passed")
  print("ALL 8 API CHECKS PASSED")
 }
}
