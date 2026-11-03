import Foundation
import Combine

/// Preferences belong to this device. In particular, syncing a reply must never enable playback.
@MainActor
public final class VoicePreferences: ObservableObject {
    public static let shared = VoicePreferences()

    private let defaults: UserDefaults
    public static let supportedLanguageIdentifiers = ["", "en-US", "zh-CN"]
    public static let speechRateRange = 0.3...0.65

    @Published public var automaticallySpeakReplies: Bool {
        didSet { defaults.set(automaticallySpeakReplies, forKey: "voice.autoSpeak.v1") }
    }
    @Published public var languageIdentifier: String {
        didSet {
            let validated = Self.validatedLanguage(languageIdentifier)
            if languageIdentifier != validated {
                languageIdentifier = validated
                return
            }
            defaults.set(languageIdentifier, forKey: "voice.language.v1")
        }
    }
    @Published public var speechRate: Double {
        didSet {
            let validated = Self.validatedRate(speechRate)
            if speechRate != validated {
                speechRate = validated
                return
            }
            defaults.set(speechRate, forKey: "voice.rate.v1")
        }
    }

    public var resolvedLanguageIdentifier: String {
        (languageIdentifier.isEmpty ? Locale.current.identifier : languageIdentifier)
            .replacingOccurrences(of: "_", with: "-")
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticallySpeakReplies = (defaults.object(forKey: "voice.autoSpeak.v1") as? NSNumber)?.boolValue ?? false
        languageIdentifier = Self.validatedLanguage(defaults.string(forKey: "voice.language.v1") ?? "")
        speechRate = Self.validatedRate((defaults.object(forKey: "voice.rate.v1") as? NSNumber)?.doubleValue ?? 0.5)
    }

    private static func validatedLanguage(_ value: String) -> String {
        supportedLanguageIdentifiers.contains(value) ? value : ""
    }

    private static func validatedRate(_ value: Double) -> Double {
        value.isFinite ? min(speechRateRange.upperBound, max(speechRateRange.lowerBound, value)) : 0.5
    }
}
