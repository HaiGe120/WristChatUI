import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var endpoints: EndpointStore
    @Bindable var conversation: Conversation
    @ObservedObject private var session: ChatSession
    @ObservedObject private var voice = VoiceConversationController.shared
    @ObservedObject private var voicePreferences = VoicePreferences.shared
    @State private var isVisible = false

    init(conversation: Conversation) {
        self.conversation = conversation
        self.session = ChatSessionCoordinator.shared.session(for: conversation.id)
    }

    private var engine: ChatEngine { session.engine }
    @ObservedObject private var searchSources = SearchSourceStore.shared
    private var searchEnabled: Bool {
        get { session.searchEnabled ?? (endpoint?.searchMode == .auto) }
        nonmutating set { session.searchEnabled = newValue }
    }
    private var draft: String {
        get { session.draft }
        nonmutating set { session.draft = newValue }
    }
    @State private var presentingEndpointSheet = false
    @FocusState private var inputFocused: Bool

    private var endpoint: EndpointConfig? {
        endpoints.endpoints.first(where: { $0.id == conversation.endpointID })
    }

    var body: some View {
        VStack(spacing: 0) {
            messagesScroll
            Divider()
            composer
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(horizontalSizeClass == .compact ? .hidden : .automatic, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentingEndpointSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Switch model")
                .accessibilityValue(conversation.model)
                .disabled(endpoints.endpoints.isEmpty)
            }
        }
        .sheet(isPresented: $presentingEndpointSheet) {
            NavigationStack {
                ChatEndpointSheet(conversation: conversation)
            }
        }
        .onAppear {
            isVisible = true
            if session.searchEnabled == nil { searchEnabled = endpoint?.searchMode == .auto }
            ChatSessionCoordinator.shared.reconcile(conversation, context: modelContext)
        }
        .onChange(of: conversation.endpointID) { _, _ in
            stopConversation()
            searchEnabled = endpoint?.searchMode == .auto
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { engine.reconcileAfterForeground() }
            else { try? modelContext.save() }
        }
        .onChange(of: conversation.model) { _, _ in stopConversation() }
        .onDisappear {
            isVisible = false
            if voice.conversationID == conversation.id { voice.stop(surface: .phone) }
        }
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
                            HStack(spacing: 20) {
                                Button("Retry") { retry(message) }
                                    .accessibilityHint("Replaces this reply using the original question")
                                if metadata.searchOutcome != .off {
                                    Button("Retry without search") { retry(message, searchOverride: false) }
                                        .accessibilityHint("Uses the original question once, with web search off")
                                }
                            }
                            .font(.caption)
                            .disabled(engine.isStreaming)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: 800)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
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
        return session.streamingContent
    }

    private var composer: some View {
        VStack(spacing: 8) {
            voiceControls
            Toggle(isOn: Binding(get: { searchEnabled }, set: { searchEnabled = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Web search")
                    Text(searchSources.selectedSource?.name ?? "Native")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.switch)
            .disabled(engine.isStreaming)
            if engine.isStreaming {
                HStack {
                    Text(engine.metadata?.statusText ?? "Connecting…")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop", role: .destructive) { stopConversation() }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $session.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .focused($inputFocused)
                Button {
                    inputFocused = false
                    if voice.conversationID == conversation.id, voice.state == .listening {
                        voice.finishListening()
                    } else if let endpoint {
                        voice.begin(conversation: conversation, context: modelContext, endpoint: endpoint,
                                    searchEnabled: searchEnabled, surface: .phone)
                    }
                } label: {
                    Image(systemName: voice.conversationID == conversation.id && voice.state == .listening ? "checkmark.circle.fill" : "mic.circle")
                        .font(.title)
                }
                .accessibilityLabel(voice.conversationID == conversation.id && voice.state == .listening ? "Send voice message" : "Record voice message")
                .frame(minWidth: 44, minHeight: 44)
                .disabled(engine.isStreaming || endpoint == nil || voice.isCarPlayConnected)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .accessibilityLabel("Send message")
                .frame(minWidth: 44, minHeight: 44)
                .disabled(!canSend || engine.isStreaming || (voice.conversationID == conversation.id && voice.state == .listening))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var voiceControls: some View {
        HStack {
            if voice.isCarPlayConnected {
                Label("Voice is connected to CarPlay", systemImage: "car")
                    .font(.caption).foregroundStyle(.secondary)
            } else if voice.conversationID == conversation.id, voice.state == .listening {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Listening… Tap the checkmark to send.").font(.caption)
                    if !voice.transcript.isEmpty { Text(voice.transcript).font(.caption).lineLimit(3) }
                }
                Spacer()
                Button("Cancel") { voice.stop(surface: .phone) }.font(.caption)
            } else if voice.conversationID == conversation.id, voice.state == .speaking {
                Label("Speaking…", systemImage: "speaker.wave.2").font(.caption)
                Spacer()
                Button("Stop speaking") { voice.stop(surface: .phone) }.font(.caption)
            } else if voice.conversationID == conversation.id, voice.state == .thinking, !engine.isStreaming {
                Text("Finishing voice input…").font(.caption)
                Spacer()
                Button("Cancel") { voice.stop(surface: .phone) }.font(.caption)
            } else {
                if voice.conversationID == conversation.id, let message = voice.statusMessage {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                        NavigationLink("Voice settings") { PhoneVoiceSettingsView() }.font(.caption)
                    }
                }
                Spacer()
                Button { voice.replay(conversation: conversation, surface: .phone) } label: {
                    Label("Read reply", systemImage: "speaker.wave.2")
                }
                .font(.caption)
                .disabled(engine.isStreaming || !hasCompletedReply)
            }
        }
    }

    private var hasCompletedReply: Bool {
        conversation.sortedMessages.contains {
            $0.role == .assistant && !$0.content.isEmpty && ($0.responseMetadata?.phase == .completed || $0.responseMetadata == nil)
        }
    }

    private func stopConversation() {
        if voice.conversationID == conversation.id { voice.stop() }
        session.cancel()
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard !engine.isStreaming, canSend, let endpoint else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if start(endpoint: endpoint, text: text) {
            draft = ""
            inputFocused = false
        }
    }

    private func retry(_ message: Message, searchOverride: Bool? = nil) {
        guard !engine.isStreaming, let endpoint else { return }
        start(endpoint: endpoint, retry: message, searchOverride: searchOverride)
    }

    @discardableResult
    private func start(endpoint: EndpointConfig, text: String? = nil, retry: Message? = nil, searchOverride: Bool? = nil) -> Bool {
        if voice.conversationID == conversation.id, voice.activeSurface == .phone {
            voice.stop(surface: .phone)
        }
        return session.send(conversation: conversation, context: modelContext, endpoint: endpoint,
                            apiKey: endpoints.apiKey(for: endpoint.id), text: text, retry: retry,
                            searchEnabled: searchOverride ?? searchEnabled) { reply, metadata in
            guard isVisible, scenePhase == .active, voicePreferences.automaticallySpeakReplies,
                  metadata.phase == .completed, !voice.isCarPlayConnected else { return }
            voice.speakReply(reply, conversationID: conversation.id, surface: .phone)
        }
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
