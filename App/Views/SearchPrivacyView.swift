import SwiftUI

struct SearchPrivacyView: View {
    var body: some View {
        List {
            Section("Chat connections") {
                Text("Your selected chat connection receives your question, the conversation context needed to answer, and its configured authentication. API keys entered in the key field are stored in Keychain and mirrored to your paired Watch for requests from the Watch app.")
            }
            Section("Web search") {
                Text("Search is off by default. Native search runs at your selected chat provider when its endpoint, model and account support it. Choosing a separate search source sends your question to that service, then sends retrieved references to your chat model. Those services apply their own privacy policies and usage limits.")
                Text("Custom search credentials stay in a separate Keychain service and are provisioned separately to your paired Watch. They are excluded from connection profiles, conversation backups and logs.")
                Text("Search status distinguishes ordinary answers, retrieved reference material, successful search and failures. Sources show links returned by the provider or search source. Opening a link contacts that website. A failed search offers Retry; turn search off explicitly to answer without it.")
            }
            Section("Chat history") {
                Text("Chats, compact source details and request outcomes sync with your paired device and are included in your optional conversation backups. Full retrieved search documents are not synced or included in those backups. Retry replaces the interrupted reply and reuses the original question.")
            }
        }
        .navigationTitle("Privacy & search")
    }
}
