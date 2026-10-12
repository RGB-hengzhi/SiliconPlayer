import CoreFoundation
import Foundation

/// The signed application declares the components it packages. This is read
/// once; preferences, environment variables and downloads cannot enable them.
struct AppCapabilities: Sendable {
    enum Profile: String, Sendable { case core, full, unavailable }

    let profile: Profile
    let hasMediaTools: Bool
    let hasWebMediaExtractor: Bool
    let hasOfflineSpeechRecognition: Bool
    let hasLiveSpeechRecognition: Bool

    static let current = load(from: Bundle.main)

    private static func load(from bundle: Bundle) -> AppCapabilities {
        // Existing full development builds predate the declaration. Their
        // existing tool resolvers still validate actual bundled components.
        guard let declaration = bundle.object(forInfoDictionaryKey: "SiliconPlayerCapabilities") else {
            return full
        }
        guard let value = declaration as? [String: Any],
              let schema = value["schema"] as? NSNumber,
              CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.stringValue == "1",
              let name = value["profile"] as? String,
              let profile = Profile(rawValue: name), profile != .unavailable,
              let features = value["features"] as? [String: Any],
              let media = boolean(features["mediaTools"]),
              let web = boolean(features["webMediaExtractor"]),
              let offline = boolean(features["offlineSpeechRecognition"]),
              let live = boolean(features["liveSpeechRecognition"]),
              media,
              ((profile == .full && web && offline && live) ||
               (profile == .core && !web && !offline && !live)) else {
            return unavailable
        }
        return AppCapabilities(profile: profile, hasMediaTools: media,
            hasWebMediaExtractor: web, hasOfflineSpeechRecognition: offline,
            hasLiveSpeechRecognition: live)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static let full = AppCapabilities(profile: .full, hasMediaTools: true,
        hasWebMediaExtractor: true, hasOfflineSpeechRecognition: true, hasLiveSpeechRecognition: true)
    private static let unavailable = AppCapabilities(profile: .unavailable, hasMediaTools: false,
        hasWebMediaExtractor: false, hasOfflineSpeechRecognition: false, hasLiveSpeechRecognition: false)
}
