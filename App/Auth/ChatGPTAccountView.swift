import SwiftUI

struct ChatGPTAccountView: View {
    var body: some View {
        List {
            Section {
                Label(ChatGPTSignInReadiness.status, systemImage: "person.crop.circle.badge.clock")
                    .font(.headline)
                Text("Continue using your saved custom connections while direct ChatGPT sign-in is prepared.")
                    .foregroundStyle(.secondary)
            }
            Section("Before sign-in becomes available") {
                ForEach(ChatGPTSignInReadiness.requirements, id: \.self) { requirement in
                    Text(requirement)
                }
            }
            Section {
                Link("OpenAI sign-in documentation", destination: ChatGPTSignInReadiness.documentationURL)
            } footer: {
                Text("ChatGPT credentials will be kept separately from custom connection keys. Account setup and renewal will start on iPhone.")
            }
        }
        .navigationTitle("ChatGPT Account")
    }
}
