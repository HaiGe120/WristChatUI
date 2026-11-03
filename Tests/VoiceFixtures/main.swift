import Foundation

@main
struct VoiceFixtures {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        let sample = """
        # Answer
        **Hello**, [world](https://example.test/path)! [[1]](https://example.test/source)
        ```swift
        print("secret code")
        ```
        - Read the [source](https://example.test).
        ![chart](https://example.test/chart.png)
        """
        let spoken = VoiceTextFormatting.spokenText(sample)
        expect(spoken.contains("Hello, world!"), "Link labels and natural punctuation remain readable")
        expect(!spoken.contains("https://") && !spoken.contains("[[1]]"), "Speech excludes raw URLs and citation markers")
        expect(!spoken.contains("secret code") && spoken.contains("Code is available"), "Fenced code is acknowledged without reading syntax")
        expect(!spoken.contains("chart") && !spoken.contains("**"), "Speech removes images and Markdown markers")
        expect(VoiceTextFormatting.spokenText("普通话回答。\n- 第二点。") == "普通话回答。\n第二点。", "Speech preserves non-Latin text")
        expect(!VoiceTextFormatting.spokenText("~~~\nunfinished code").contains("unfinished code"), "Unclosed code fences stay out of speech")
        expect(VoiceTextFormatting.spokenText("[source](https://example.test/a_(b))") == "source", "Balanced URL parentheses do not leak into speech")
        let long = VoiceTextFormatting.spokenText(String(repeating: "A useful sentence. ", count: 1_000))
        expect(long.count < VoiceTextFormatting.maximumSpokenCharacters + 100 && long.contains("rest of the reply"), "Long answers have a bounded spoken presentation and audible notice")
        let original = "Preserve my instructions."
        let applied = VoiceTextFormatting.applying(toSystemPrompt: original)
        expect(applied.hasPrefix(original), "Voice request guidance preserves the stored instructions")
        expect(VoiceTextFormatting.applying(toSystemPrompt: applied) == applied, "Voice guidance is idempotent")

        let suite = "VoiceFixtures-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = VoicePreferences(defaults: defaults)
        expect(!preferences.automaticallySpeakReplies && preferences.languageIdentifier.isEmpty && preferences.speechRate == 0.5, "New devices start silent with system language and normal speed")
        preferences.automaticallySpeakReplies = true
        preferences.languageIdentifier = "zh-CN"
        preferences.speechRate = 0.6
        let restored = VoicePreferences(defaults: defaults)
        expect(restored.automaticallySpeakReplies && restored.resolvedLanguageIdentifier == "zh-CN" && restored.speechRate == 0.6, "Device preferences survive relaunch")
        preferences.languageIdentifier = "invalid"
        preferences.speechRate = .nan
        expect(preferences.languageIdentifier.isEmpty && preferences.speechRate == 0.5, "Invalid updates use supported defaults")
        preferences.speechRate = 99
        expect(preferences.speechRate == VoicePreferences.speechRateRange.upperBound, "Speech rate is constrained to a usable range")
        defaults.set("unknown", forKey: "voice.language.v1")
        defaults.set(-10, forKey: "voice.rate.v1")
        let invalid = VoicePreferences(defaults: defaults)
        expect(invalid.languageIdentifier.isEmpty && invalid.speechRate == VoicePreferences.speechRateRange.lowerBound, "Persisted invalid settings are repaired on load")
        print("Voice fixtures: \(checks) checks passed")
    }
}
