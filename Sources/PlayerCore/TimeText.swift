import Foundation

public enum TimeText {
    public static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(min(seconds, Double(Int.max / 2)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 {
            return "\(hours):" + String(format: "%02d:%02d", minutes, remainder)
        }
        return "\(minutes):" + String(format: "%02d", remainder)
    }
}
