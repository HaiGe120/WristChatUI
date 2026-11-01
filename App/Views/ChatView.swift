import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var endpoints: EndpointStore
    @Bindable var conversation: Conversation
    @StateObject private var engine = ChatEngine()
    @ObservedObject private var searchSources = SearchSourceStore.shared
    @State private var searchEnabled = false
    @State private var draft: String = ""
    @State private var lastError: String?
    /// Live buffer of the assistant's in-progress reply. Written to the
    /// Message row on completion. This guarantees the view re-renders
    /// even if SwiftData's per-property observation lags the stream.
    @State private var streamingContent: String = ""
    @State private var presentingEndpointSheet = false
    @FocusState private var inputFocused: Bool

    private var endpoint: EndpointConfig? {
        endpoints.endpoints.first(where: { $0.id == conversation.endpointID })
    }

    /// The currently-streaming assistant message, if any. We find it by
    /// looking for the last assistant message that has no content yet.
    private var streamingAssistantMessage: Message? {
        conversation.sortedMessages.last(where: { $0.role == .assistant })
    }

    var body: some View {
        VStack(spacing: 0) {
            messagesScroll
            Divider()
            composer
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentingEndpointSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up.chevron.down")
                        Text(conversation.model)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                }
                .disabled(endpoints.endpoints.isEmpty)
            }
        }
        .sheet(isPresented: $presentingEndpointSheet) {
            NavigationStack {
                ChatEndpointSheet(conversation: conversation)
            }
        }
        .onAppear {
            searchEnabled = endpoint?.searchMode == .auto
            if !engine.isStreaming { ConversationRequest.reconcileInterrupted(conversation, context: modelContext) }
        }
        .onChange(of: conversation.endpointID) { _, _ in
            engine.cancel()
            searchEnabled = endpoint?.searchMode == .auto
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { engine.reconcileAfterForeground() }
            else { try? modelContext.save() }
        }
        .onReceive(NotificationCenter.default.publisher(for: SearchSourceStore.didChange)) { _ in engine.cancel() }
        .onDisappear { engine.cancel() }
    }

    private var messagesScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(conversation.sortedMessages) { message in
                        MessageBubble(
                            message: message,
                            streamingOverride: streamingOverride(for: message)
                        )
                        .id(message.id)
                        if let metadata = message.responseMetadata,
                           [.failed, .partial, .cancelled].contains(metadata.phase) {
                            Button("Retry") { retry(message) }
                                .font(.caption)
                                .disabled(engine.isStreaming)
                                .accessibilityHint("Replaces this reply using the original question")
                        }
                    }
                }
                .padding()
            }
            .onChange(of: conversation.messages.count) { _, _ in
                if let last = conversation.sortedMessages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    /// The live streaming buffer applies only to the most recent
    /// assistant message while the engine is producing deltas. After
    /// the stream finishes the buffer is reset to `""` in
    /// `send`'s `onComplete` handler, so this method naturally
    /// returns `nil` and the bubble falls back to the persisted
    /// `message.content`.
    private func streamingOverride(for message: Message) -> String? {
        guard engine.isStreaming, message.role == .assistant else { return nil }
        guard let attemptID = engine.metadata?.attemptID,
              message.responseMetadata?.attemptID == attemptID else { return nil }
        return streamingContent
    }

    private var composer: some View {
        VStack(spacing: 4) {
            HStack {
                Toggle("Web search · \(searchSources.selectedSource?.name ?? "Native")", isOn: $searchEnabled)
                    .toggleStyle(.switch)
                    .font(.caption)
                    .disabled(engine.isStreaming)
                Spacer()
                if engine.isStreaming {
                    Text(engine.metadata?.statusText ?? "Connecting…")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Stop", role: .destructive) { engine.cancel() }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .focused($inputFocused)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .accessibilityLabel("Send message")
                .disabled(!canSend || engine.isStreaming)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard !engine.isStreaming, canSend, let endpoint else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        inputFocused = false
        start(endpoint: endpoint, text: text)
    }

    private func retry(_ message: Message) {
        guard !engine.isStreaming, let endpoint else { return }
        start(endpoint: endpoint, retry: message)
    }

    private func start(endpoint: EndpointConfig, text: String? = nil, retry: Message? = nil) {
        streamingContent = ""
        ConversationRequest.start(engine: engine, conversation: conversation, context: modelContext,
                                  endpoint: endpoint, apiKey: endpoints.apiKey(for: endpoint.id),
                                  userText: text, retry: retry, searchEnabled: searchEnabled,
                                  onDelta: { streamingContent += $0 },
                                  onComplete: { streamingContent = "" })
    }

}


/// Sheet for switching the active conversation to a different endpoint or to
/// a different model on the same endpoint. Mirrors the watch's picker and
/// extends it with a per-endpoint model picker (loaded from the server when
/// the sheet appears, or accepting a free-text value if the server probe
/// returns nothing).
///
/// The model picker is *always* visible — we keep a per-endpoint cache of
/// the last server-confirmed list in `UserDefaults` so the user can switch
/// between models on an endpoint they've used before without re-probing.
/// "Custom…" stays in the list so typing an ad-hoc model name (e.g. a
/// brand-new MiniMax release not yet on the server) is one tap away.
private struct ChatEndpointSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var endpoints: EndpointStore
    @Bindable var conversation: Conversation

    /// Server-confirmed models for the active endpoint. Persisted per
    /// endpoint in `UserDefaults` so a re-open of the sheet doesn't
    /// re-probe for the same endpoint unless the user asks for it.
    @State private var loadedModels: [String] = []
    @State private var isLoadingModels = false
    @State private var loadError: String?
    /// Whether the user has tapped "Custom…" in the picker. While set,
    /// the model field becomes a free-text `TextField` so they can type
    /// any model name. Cleared as soon as they pick something from the
    /// list again.
    @State private var isUsingCustomModel: Bool = false

    private static let modelCacheKey = "endpoint.models.cache.v1"
    private static let customModelSentinel = "__custom__"

    private var activeEndpoint: EndpointConfig? {
        endpoints.endpoints.first(where: { $0.id == conversation.endpointID })
            ?? endpoints.endpoints.first
    }

    var body: some View {
        Form {
            Section("Endpoint") {
                ForEach(endpoints.endpoints) { endpoint in
                    Button {
                        applyEndpoint(endpoint)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(endpoint.name).foregroundStyle(.primary)
                                Text(endpoint.providerType.shortName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(endpoint.model)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if endpoint.id == conversation.endpointID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
            if let endpoint = activeEndpoint {
                Section {
                    if isLoadingModels {
                        HStack { ProgressView(); Text("Loading models…").foregroundStyle(.secondary) }
                    } else if isUsingCustomModel {
                        TextField("Model name", text: Binding(
                            get: { conversation.model },
                            set: { newValue in
                                conversation.model = newValue
                                conversation.updatedAt = .now
                            }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        Button {
                            isUsingCustomModel = false
                            loadModels(for: endpoint, force: true)
                        } label: {
                            Label("Pick from server list", systemImage: "list.bullet")
                        }
                        .font(.caption)
                    } else {
                        Picker("Model", selection: Binding(
                            get: { conversation.model },
                            set: { newValue in
                                if newValue == Self.customModelSentinel {
                                    isUsingCustomModel = true
                                } else {
                                    conversation.model = newValue
                                    conversation.updatedAt = .now
                                    try? modelContext.save()
                                }
                            }
                        )) {
                            if !loadedModels.contains(conversation.model) && !conversation.model.isEmpty {
                                Text(conversation.model).tag(conversation.model)
                            }
                            ForEach(loadedModels, id: \.self) { name in
                                Text(name).tag(name)
                            }
                            Text("Custom…").tag(Self.customModelSentinel)
                        }
                        Button {
                            loadModels(for: endpoint, force: true)
                        } label: {
                            Label("Reload models from server", systemImage: "arrow.clockwise")
                        }
                        .font(.caption)
                    }
                    if let loadError {
                        Text(loadError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Model for \(endpoint.name)")
                } footer: {
                    Text("Used for the next message. Existing messages keep the model that was active when they were written.")
                }
            }
        }
        .navigationTitle("Switch model")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            // Prime the picker from the per-endpoint cache so it's
            // instantly usable. A background re-probe refreshes the
            // list when the server is reachable.
            if let endpoint = activeEndpoint {
                loadedModels = Self.cachedModels(for: endpoint.id)
                loadModels(for: endpoint, force: false)
            }
        }
    }

    private func applyEndpoint(_ endpoint: EndpointConfig) {
        conversation.endpointID = endpoint.id
        conversation.endpointName = endpoint.name
        conversation.model = endpoint.model
        conversation.systemPrompt = endpoint.systemPrompt
        conversation.updatedAt = .now
        isUsingCustomModel = false
        try? modelContext.save()
        // Refresh the model list for the new endpoint so the picker
        // reflects the new server. Use the per-endpoint cache to skip
        // the network round-trip if we've seen this endpoint before.
        loadedModels = Self.cachedModels(for: endpoint.id)
        loadError = nil
        loadModels(for: endpoint, force: false)
    }

    private func loadModels(for endpoint: EndpointConfig, force: Bool) {
        // Skip the probe entirely if we have a fresh-enough cached
        // list and the user didn't explicitly ask to reload. The
        // server-confirmed list rarely changes within a session, so
        // hitting the network on every sheet open is wasteful and can
        // feel laggy on a flaky watch.
        let cached = Self.cachedModels(for: endpoint.id)
        if !force, !cached.isEmpty {
            loadedModels = cached
            return
        }
        isLoadingModels = true
        loadError = nil
        let provider = ProviderRegistry.provider(for: endpoint)
        let key = endpoints.apiKey(for: endpoint.id)
        Task {
            do {
                let models = try await provider.listModels(endpoint: endpoint, apiKey: key)
                await MainActor.run {
                    loadedModels = models
                    Self.persistModels(models, for: endpoint.id)
                    isLoadingModels = false
                }
            } catch {
                await MainActor.run {
                    // Don't wipe the picker if we already had cached
                    // models — show the error inline so the user can
                    // still pick from the stale list.
                    if loadedModels.isEmpty {
                        loadedModels = []
                    }
                    isLoadingModels = false
                    loadError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
        }
    }

    // MARK: - Per-endpoint model cache

    private static func cachedModels(for endpointID: UUID) -> [String] {
        let key = cacheKey(for: endpointID)
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func persistModels(_ models: [String], for endpointID: UUID) {
        let key = cacheKey(for: endpointID)
        if models.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func cacheKey(for endpointID: UUID) -> String {
        "\(modelCacheKey).\(endpointID.uuidString)"
    }
}
