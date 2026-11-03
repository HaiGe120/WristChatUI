import SwiftUI

struct VoiceSettingsView: View {
    @ObservedObject private var preferences = VoicePreferences.shared

    var body: some View {
        Form {
            Section {
                Toggle("Speak replies automatically", isOn: $preferences.automaticallySpeakReplies)
            } footer: {
                Text("Applies to replies you request on this device. Synced conversations stay silent.")
            }
            Section("Speech") {
                Picker("Language", selection: $preferences.languageIdentifier) {
                    Text("Device language").tag("")
                    Text("English").tag("en-US")
                    Text("简体中文").tag("zh-CN")
                }
                VStack(alignment: .leading) {
                    Text("Speaking speed")
                    Slider(value: $preferences.speechRate, in: VoicePreferences.speechRateRange)
                        .accessibilityLabel("Speaking speed")
                        .accessibilityValue(speedDescription)
                    HStack {
                        Text("Slower")
                        Spacer()
                        Text("Faster")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Section("Voice privacy") {
                #if os(watchOS)
                Text("Apple Watch uses Apple's system dictation. Choose the dictation language in the input screen. This speech language setting controls spoken replies.")
                #else
                Text("Speech recognition may use Apple's servers, depending on the language and device. Your configured AI connection receives the transcribed text to answer.")
                #endif
                Text("The app saves the text conversation. Raw microphone audio is not saved or included in backups. Voice availability depends on your device and installed languages.")
            }
        }
        .navigationTitle("Voice")
    }

    private var speedDescription: String {
        if preferences.speechRate < 0.45 { return "Slower" }
        if preferences.speechRate > 0.55 { return "Faster" }
        return "Normal"
    }
}
