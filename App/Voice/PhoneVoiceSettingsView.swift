import SwiftUI
import UIKit

struct PhoneVoiceSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var voice = VoiceConversationController.shared
    @StateObject private var input = VoiceInputController()
    @State private var permissionsGranted = false
    @State private var requestingAccess = false
    @State private var requestedAccess = false

    var body: some View {
        VoiceSettingsView()
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(permissionsGranted ? "Microphone and speech access enabled" : "Enable voice for iPhone",
                          systemImage: permissionsGranted ? "checkmark.circle" : "mic")
                        .font(.subheadline)
                    if !permissionsGranted {
                        Button(requestingAccess ? "Requesting access…" : "Enable voice access") {
                            requestingAccess = true
                            Task {
                                permissionsGranted = await input.requestPermissions()
                                requestedAccess = true
                                requestingAccess = false
                            }
                        }
                        .disabled(requestingAccess || voice.isCarPlayConnected)
                        if requestedAccess {
                            Button("Open system settings") {
                                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                    Text("Complete connection and voice setup before using spoken questions and replies on iPhone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.bar)
            }
            .task { await refreshPermissions() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refreshPermissions() } }
            }
    }

    private func refreshPermissions() async {
        let granted = await Task.detached(priority: .userInitiated) { VoiceInputController.permissionsGranted }.value
        guard !Task.isCancelled else { return }
        permissionsGranted = granted
    }
}
