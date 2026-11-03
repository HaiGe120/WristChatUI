import SwiftUI
import SwiftData

struct ConversationsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var endpoints: EndpointStore
    @EnvironmentObject private var sync: SyncCoordinator
    @Query(sort: [SortDescriptor(\Conversation.updatedAt, order: .reverse)]) private var conversations: [Conversation]
    @State private var selectedConversationID: UUID?
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var isResyncing = false

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            Group {
                if conversations.isEmpty {
                    ContentUnavailableView {
                        Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Start a new chat or open one on your Apple Watch.")
                    } actions: {
                        Button("New chat", systemImage: "square.and.pencil", action: startNewChat)
                            .buttonStyle(.borderedProminent)
                            .disabled(endpoints.endpoints.isEmpty)
                    }
                } else {
                    List(selection: $selectedConversationID) {
                        if isResyncing {
                            HStack {
                                ProgressView()
                                Text("Syncing with Apple Watch…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(conversations) { conversation in
                            NavigationLink(value: conversation.id) {
                                ConversationRow(conversation: conversation)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                    .refreshable { await resyncWithWatch() }
                }
            }
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startNewChat()
                    } label: {
                        Label("New", systemImage: "square.and.pencil")
                    }
                    .disabled(endpoints.endpoints.isEmpty)
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 340)
        } detail: {
            if let conversation = conversations.first(where: { $0.id == selectedConversationID }) {
                ChatView(conversation: conversation)
                    .id(conversation.id)
            } else {
                ContentUnavailableView {
                    Label("Your next conversation", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Choose a chat from the sidebar or start a new one.")
                } actions: {
                    Button("New chat", systemImage: "square.and.pencil", action: startNewChat)
                        .buttonStyle(.borderedProminent)
                        .disabled(endpoints.endpoints.isEmpty)
                }
                .navigationTitle("WristChatUI")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onAppear {
            #if DEBUG
            if let screen = ScreenshotPreview.screen {
                if screen == "chat" { openConversation(ScreenshotPreview.conversationID) }
                return
            }
            seedTestThreeDotChatIfRequested()
            #endif
            consumePendingShortcutIfAny()
        }
    }

    private func delete(at offsets: IndexSet) {
        // Capture the ids before deleting so we can mirror the delete
        // to the paired watch. Without this, the conversation
        // disappears from the iPhone but stays on the watch, and the
        // next sync run will resurrect it on the iPhone because the
        // watch still has the full snapshot.
        let ids = offsets.map { conversations[$0].id }
        if let selectedConversationID, ids.contains(selectedConversationID) {
            self.selectedConversationID = nil
            preferredCompactColumn = .sidebar
        }
        for id in ids { ChatSessionCoordinator.shared.remove(conversationID: id) }
        for index in offsets {
            modelContext.delete(conversations[index])
        }
        try? modelContext.save()
        for id in ids {
            SyncCoordinator.shared.publishDeleteConversation(id)
        }
    }

    /// Re-pull endpoints and chat history from the paired watch. The
    /// pull-to-refresh affordance on the list triggers this; it's also
    /// useful when the user has just paired a new watch.
    private func resyncWithWatch() async {
        guard !isResyncing else { return }
        isResyncing = true
        defer { isResyncing = false }
        SyncCoordinator.shared.requestEndpoints()
        SyncCoordinator.shared.requestConversations()
        // Give the round-trip a moment so the spinner doesn't flicker.
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    /// Routes `wristassistant://new-chat` to the in-app new-chat flow.
    /// The widget and any future App Shortcut use the same URL.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "wristassistant" else { return }
        if url.host == "new-chat" {
            consumePendingShortcutIfAny()
        }
    }

    /// Reads the one-shot prompt `StartNewChatIntent` writes to `UserDefaults`
    /// and seeds a new conversation with it as the first user message, then
    /// navigates straight into the chat.
    private func consumePendingShortcutIfAny() {
        let key = "pendingNewChatPrompt"
        guard let data = UserDefaults.standard.data(forKey: key),
              let req = try? JSONDecoder().decode(NewChatRequest.self, from: data) else {
            return
        }
        UserDefaults.standard.removeObject(forKey: key)
        let prompt = req.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        createConversationFromShortcut(prompt: prompt)
    }

    /// Creates a new conversation with the active endpoint and pushes
    /// straight into the chat. The conversation title is auto-derived
    /// from the first user message, so there's no need for a title sheet.
    private func startNewChat() {
        guard let endpoint = endpoints.activeEndpoint ?? endpoints.endpoints.first else { return }
        let conversation = Conversation(
            title: "New chat",
            endpointID: endpoint.id,
            endpointName: endpoint.name,
            model: endpoint.model,
            systemPrompt: endpoint.systemPrompt
        )
        modelContext.insert(conversation)
        try? modelContext.save()
        SyncCoordinator.shared.publishConversation(ConversationSnapshot(conversation))
        openConversation(conversation.id)
    }

    private func createConversationFromShortcut(prompt: String) {
        guard let endpoint = endpoints.activeEndpoint ?? endpoints.endpoints.first else { return }
        let title = prompt.isEmpty ? "New chat" : String(prompt.prefix(40))
        let conversation = Conversation(
            title: title,
            endpointID: endpoint.id,
            endpointName: endpoint.name,
            model: endpoint.model,
            systemPrompt: endpoint.systemPrompt
        )
        modelContext.insert(conversation)
        if !prompt.isEmpty {
            let firstMessage = Message(
                role: .user,
                content: prompt,
                orderIndex: 0,
                conversation: conversation
            )
            modelContext.insert(firstMessage)
        }
        try? modelContext.save()
        SyncCoordinator.shared.publishConversation(ConversationSnapshot(conversation))
        openConversation(conversation.id)
    }

    private func openConversation(_ id: UUID) {
        selectedConversationID = id
        preferredCompactColumn = .detail
    }
    #if DEBUG
    /// One-shot test hook. When the app is launched with
    /// `WA_TEST_SEED_3DOT_CHAT=1` and no chats exist, create a fake
    /// conversation with one user message and an empty assistant
    /// message, then push straight into it. The empty assistant
    /// bubble renders the 3-dot "…" placeholder, which is exactly
    /// what the streaming chat shows while waiting for the first
    /// delta from the API. This avoids needing a working API key
    /// (or a UI-tap dance) to verify the placeholder style.
    private func seedTestThreeDotChatIfRequested() {
        guard ProcessInfo.processInfo.environment["WA_TEST_SEED_3DOT_CHAT"] == "1" else { return }
        guard conversations.isEmpty else { return }
        guard let endpoint = endpoints.activeEndpoint ?? endpoints.endpoints.first else { return }
        let conv = Conversation(
            title: "3-dot placeholder test",
            endpointID: endpoint.id,
            endpointName: endpoint.name,
            model: endpoint.model,
            systemPrompt: endpoint.systemPrompt
        )
        modelContext.insert(conv)
        modelContext.insert(Message(role: .user, content: "Hello", orderIndex: 0, conversation: conv))
        modelContext.insert(Message(role: .assistant, content: "", orderIndex: 1, conversation: conv))
        try? modelContext.save()
        openConversation(conv.id)
    }
    #endif

}

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(conversation.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(conversation.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(conversation.lastMessagePreview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 6) {
                Image(systemName: conversation.model.contains("claude") ? "sparkles" : "cpu")
                    .font(.caption2)
                Text(conversation.endpointName)
                    .font(.caption2)
                Text("·").font(.caption2)
                Text(conversation.model)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
