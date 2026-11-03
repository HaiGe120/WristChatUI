import SwiftUI
import SwiftData
import os.log

private let convsLog = Logger(subsystem: "com.wristassistant.app.watchkitapp", category: "ConversationsView")

struct ConversationsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var endpoints: EndpointStore
    @EnvironmentObject private var sync: SyncCoordinator
    @Query(sort: [SortDescriptor(\Conversation.updatedAt, order: .reverse)]) private var conversations: [Conversation]

    @State private var presentingSettings = false
    @State private var isResyncing = false
    @State private var isBackingUp = false
    @State private var isRestoring = false
    @State private var backupStatus: String?
    @State private var path: [ChatRoute] = []

    struct ChatRoute: Hashable {
        let conversationID: UUID
        let focusComposer: Bool
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !conversations.isEmpty {
                    Section("Recent") {
                        ForEach(conversations.prefix(20)) { conversation in
                            NavigationLink(value: ChatRoute(conversationID: conversation.id, focusComposer: false)) {
                                WatchConversationRow(conversation: conversation)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
                Section {
                    NavigationLink { VoiceSettingsView() } label: {
                        Label("Voice", systemImage: "speaker.wave.2")
                    }
                    Button {
                        startNewChat(withPrompt: nil)
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                    .disabled(endpoints.activeEndpoint == nil)

                    Button {
                        presentingSettings = true
                    } label: {
                        Label("Endpoints", systemImage: "antenna.radiowaves.left.and.right")
                    }

                    Button {
                        backUpConversations()
                    } label: {
                        Label(isBackingUp ? "Backing up..." : "Back Up to iCloud", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(conversations.isEmpty || isBackingUp)

                    Button {
                        restoreConversations()
                    } label: {
                        Label(isRestoring ? "Restoring..." : "Restore from iCloud", systemImage: "icloud.and.arrow.down")
                    }
                    .disabled(isRestoring)
                }
                if let backupStatus {
                    Section {
                        Text(backupStatus)
                            .font(.caption2)
                            .foregroundStyle(isFailureStatus(backupStatus) ? .red : .secondary)
                    }
                }
                if conversations.isEmpty && !endpoints.endpoints.isEmpty {
                    Section {
                        Text("Tap New chat to begin.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if endpoints.endpoints.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No endpoints").font(.headline)
                            Text("Add an endpoint in the Endpoints screen to start chatting.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            #if os(watchOS)
            .listStyle(.carousel)
            #else
            .listStyle(.insetGrouped)
            #endif
            .refreshable { await resyncWithPhone() }
            .navigationTitle("Chats")
            .navigationDestination(for: ChatRoute.self) { route in
                if let conversation = conversations.first(where: { $0.id == route.conversationID }) {
                    ChatView(
                        conversation: conversation,
                        focusComposerOnAppear: route.focusComposer
                    )
                } else {
                    ProgressView()
                }
            }
            .sheet(isPresented: $presentingSettings) {
                NavigationStack {
                    WatchEndpointsView()
                }
            }
            .onOpenURL { url in
                handleDeepLink(url)
            }
            .onAppear {
                consumePendingShortcutIfAny()
                if ProcessInfo.processInfo.arguments.contains("--auto-new-chat") {
                    startNewChat(withPrompt: nil)
                }
            }
        }
    }

    /// Re-pull endpoints and chat history from the paired phone.
    /// watchOS supports pull-to-refresh via the digital crown; this gives
    /// the user a manual recovery path when the initial sync missed (e.g.
    /// the watch was out of range when the app launched).
    private func resyncWithPhone() async {
        guard !isResyncing else { return }
        isResyncing = true
        defer { isResyncing = false }
        SyncCoordinator.shared.requestEndpoints()
        SyncCoordinator.shared.requestConversations()
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    /// Routes `wristassistant://new-chat` (and friends) to the appropriate
    /// in-app action. The widget and the App Shortcut on the watch home
    /// screen both open the app via this URL. Both paths now go
    /// straight into a chat with the active endpoint — no picker.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "wristassistant" else { return }
        if url.host == "new-chat" {
            startNewChat(withPrompt: nil)
        }
    }

    /// Reads the one-shot prompt the `StartNewChatIntent` may have stored
    /// via UserDefaults and forwards it to the new-chat flow before
    /// clearing it.
    private func consumePendingShortcutIfAny() {
        let key = "pendingNewChatPrompt"
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return
        }
        guard let req = try? JSONDecoder().decode(NewChatRequest.self, from: data) else {
            return
        }
        UserDefaults.standard.removeObject(forKey: key)
        startNewChat(withPrompt: req.prompt)
    }

    /// Create a fresh conversation using the *active* endpoint (no
    /// picker), seed it with `prompt` if the user passed text in via
    /// the Siri intent, save, and push straight into the chat. If
    /// there is no active endpoint the button is disabled so this
    /// path only runs when the user has set one up on the phone or
    /// the bootstrap has finished.
    private func startNewChat(withPrompt prompt: String?) {
        convsLog.info("startNewChat(prompt=)")
        guard let endpoint = endpoints.activeEndpoint else {
            convsLog.error("startNewChat: no active endpoint")
            return
        }
        let trimmed = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "New chat" : String(trimmed.prefix(40))
        let conv = Conversation(
            title: title,
            endpointID: endpoint.id,
            endpointName: endpoint.name,
            model: endpoint.model,
            systemPrompt: endpoint.systemPrompt
        )
        modelContext.insert(conv)
        if !trimmed.isEmpty {
            let firstMessage = Message(
                role: .user,
                content: trimmed,
                orderIndex: 0,
                conversation: conv
            )
            modelContext.insert(firstMessage)
        }
        try? modelContext.save()
        // Mirror to the phone so the conversations list stays in sync.
        SyncCoordinator.shared.publishConversation(ConversationSnapshot(conv))
        convsLog.info("startNewChat: route append")
        path.append(ChatRoute(conversationID: conv.id, focusComposer: true))
    }

    private func backUpConversations() {
        guard !isBackingUp else { return }
        isBackingUp = true
        backupStatus = nil

        Task { @MainActor in
            defer { isBackingUp = false }
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    SyncCoordinator.shared.requestConversationBackup { reply in
                        switch reply {
                        case .success(let count, let fileName):
                            backupStatus = "Saved \(count) chat\(count == 1 ? "" : "s") to \(fileName ?? "iCloud")."
                            continuation.resume()
                        case .failure(let message):
                            backupStatus = "Backup failed: \(message)"
                            continuation.resume()
                        }
                    }
                }
            } catch {
                backupStatus = "Backup failed: \(error.localizedDescription)"
            }
        }
    }

    private func restoreConversations() {
        guard !isRestoring else { return }
        isRestoring = true
        backupStatus = nil

        Task { @MainActor in
            defer { isRestoring = false }
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    SyncCoordinator.shared.requestConversationRestore { reply in
                        switch reply {
                        case .success(let count, let fileName):
                            backupStatus = "Restored \(count) chat\(count == 1 ? "" : "s") from \(fileName ?? "iCloud")."
                            SyncCoordinator.shared.requestConversations()
                            continuation.resume()
                        case .failure(let message):
                            backupStatus = "Restore failed: \(message)"
                            continuation.resume()
                        }
                    }
                }
            } catch {
                backupStatus = "Restore failed: \(error.localizedDescription)"
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.map { conversations[$0].id }
        for id in ids { ChatSessionCoordinator.shared.remove(conversationID: id) }
        for index in offsets {
            modelContext.delete(conversations[index])
        }
        try? modelContext.save()
        for id in ids {
            SyncCoordinator.shared.publishDeleteConversation(id)
        }
    }

    private func isFailureStatus(_ status: String) -> Bool {
        status.hasPrefix("Backup failed") || status.hasPrefix("Restore failed")
    }
}

private struct WatchConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conversation.title)
                .font(.headline)
                .lineLimit(1)
            Text(conversation.lastMessagePreview)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
