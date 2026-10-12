import Foundation

@main struct ScreenshotPreferencesChecks {
    static func main() throws {
        let old = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{\"screenshotFormat\":\"jpg\"}".utf8))
        precondition(old.screenshot == ScreenshotPreferences() && old.screenshotFormat == "jpg")
        print("PASS screenshot old settings migrate")
        for path in ["~/Pictures", "relative/shot", "/tmp/a\0b", "/tmp/a\nb", "/" + String(repeating: "a", count: 4100)] {
            var preferences = ScreenshotPreferences(); preferences.directory = path
            precondition(preferences.sanitized().directory.isEmpty)
        }
        var valid = ScreenshotPreferences(); valid.directory = "/Volumes/测试磁盘/图片 新建"
        precondition(valid.sanitized().directory == valid.directory)
        print("PASS screenshot invalid paths and Chinese spaces")
        valid.mode = .window; valid.quality = 120
        precondition(valid.sanitized().quality == 100)
        valid.quality = -10; precondition(valid.sanitized().quality == 1)
        let settings = try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(PlaybackSettings()))
        precondition(settings.screenshot == ScreenshotPreferences())
        let roundTrip = try JSONDecoder().decode(ScreenshotPreferences.self, from: JSONEncoder().encode(valid))
        precondition(roundTrip == valid)
        print("PASS screenshot range and JSON persistence")
        let name = ScreenshotPreferences.filename(title: "中文/:\\\n" + String(repeating: "x", count: 400), format: "../bad")
        precondition(!name.contains("/") && !name.contains("\\") && !name.contains(":"))
        precondition(name.hasSuffix(".png") && name.count < 130)
        precondition(ScreenshotPreferences.filename(title: "", format: "webp").hasPrefix("SiliconPlayer_"))
        print("PASS screenshot filenames bounded and safe")
        let malformed = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{\"screenshot\":{\"mode\":\"bad\",\"directory\":\"/tmp\",\"quality\":90}}".utf8))
        precondition(malformed.screenshot == ScreenshotPreferences())
        print("PASS screenshot malformed imported mode recovers")
        print("5 screenshot preference groups passed")
    }
}
