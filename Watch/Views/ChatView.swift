//  ChatView.swift
//  Watch chat view with a Messages-style reply box at the bottom of
//  the scroll content.

import SwiftUI
import SwiftData
import os.log

private let chatLog = Logger(subsystem: "com.wristassistant.app.watchkitapp", category: "ChatView")

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var endpoints: EndpointStore
    @Bindable var conversation: Conversation
    let focusComposerOnAppear: Bool

    @ObservedObject private var session: ChatSession
    @ObservedObject private var speech = SpeechPlaybackController.shared
    @ObservedObject private var voicePreferences = VoicePreferences.shared
    @State private var isVisible = false
    @State private var isSceneActive = false
    @State private var lastVoiceError: String?
    private var engine: ChatEngine { session.engine }
    @ObservedObject private var searchSources = SearchSourceStore.shared
    @State private var searchEnabled = false
    @State private var draft: String = ""
    @State private var presentingEndpointPicker = false
    @State private var focusComposerTrigger = 0

    init(conversation: Conversation, focusComposerOnAppear: Bool = false) {
        self.conversation = conversation
        self.session = ChatSessionCoordinator.shared.session(for: conversation.id)
        self.focusComposerOnAppear = focusComposerOnAppear
    }

    private var endpoint: EndpointConfig? {
        endpoints.endpoints.first(where: { $0.id == conversation.endpointID })
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        messages
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentingEndpointPicker = true
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
                .disabled(endpoints.endpoints.count < 2)
            }
        }
        .sheet(isPresented: $presentingEndpointPicker) {
            NavigationStack {
                EndpointPickerSheet(conversation: conversation)
            }
        }
        .onAppear {
            isVisible = true
            isSceneActive = scenePhase == .active
            searchEnabled = endpoint?.searchMode == .auto
            ChatSessionCoordinator.shared.reconcile(conversation, context: modelContext)
        }
        .onChange(of: conversation.endpointID) { _, _ in
            stop()
            searchEnabled = endpoint?.searchMode == .auto
        }
        .onChange(of: scenePhase) { _, phase in
            isSceneActive = phase == .active
            if phase == .active { engine.reconcileAfterForeground() }
            else {
                speech.stop(ownerID: conversation.id)
                try? modelContext.save()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SearchSourceStore.didChange)) { _ in stop() }
        .onChange(of: conversation.model) { _, _ in stop() }
        .onDisappear {
            isVisible = false
            stop()
        }
    }

    /// The composer is the final scroll item, matching Apple Watch
    /// Messages: it is available at the end of the thread without
    /// covering older context while the user scrolls back.
    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(conversation.sortedMessages) { message in
                        WatchMessageRow(
                            message: message,
                            streamingOverride: streamingOverride(for: message)
                        )
                        .id(message.id)
                        if let metadata = message.responseMetadata,
                           [.failed, .partial, .cancelled].contains(metadata.phase) {
                            Button("Retry") { start(retry: message) }
                                .font(.caption)
                                .disabled(engine.isStreaming)
                            if metadata.searchOutcome != .off {
                                Button("Retry without search") { start(retry: message, searchOverride: false) }
                                    .font(.caption)
                                    .disabled(engine.isStreaming)
                            }
                            if ["timeout", "offline", "connectionLost", "incomplete"].contains(metadata.errorCode ?? "") {
                                NavigationLink("Connection help") { WatchConnectionHelpView() }
                                    .font(.caption2)
                            }
                        }
                    }

                    Toggle("Search · \(searchSources.selectedSource?.name ?? "Native")", isOn: $searchEnabled)
                        .font(.caption2)
                        .disabled(engine.isStreaming)
                    if engine.isStreaming {
                        Text(engine.metadata?.statusText ?? "Connecting…")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if speech.isSpeaking, speech.ownerID == conversation.id {
                        Button("Stop speaking", systemImage: "speaker.slash") {
                            speech.stop(ownerID: conversation.id)
                        }.font(.caption2)
                    } else if let reply = conversation.sortedMessages.last(where: {
                        $0.role == .assistant && !$0.content.isEmpty && ($0.responseMetadata?.phase == .completed || $0.responseMetadata == nil)
                    }) {
                        Button("Read reply", systemImage: "speaker.wave.2") {
                            lastVoiceError = nil
                            speech.speak(reply.content, ownerID: conversation.id) { lastVoiceError = speech.lastError }
                        }
                        .font(.caption2)
                        .disabled(engine.isStreaming)
                    }
                    if let error = lastVoiceError {
                        Text(error).font(.caption2).foregroundStyle(.secondary)
                    }
                    ComposerView(
                        text: $draft,
                        isStreaming: engine.isStreaming,
                        canSend: canSend,
                        focusTrigger: focusComposerTrigger,
                        onSend: { send() },
                        onStop: { stop() },
                        onSubmitText: { send($0, fromDictation: true) },
                        onBeginInput: {
                            lastVoiceError = nil
                            speech.stop()
                        }
                    )
                    .id(composerID)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
            .onAppear {
                scrollToBottom(proxy, focus: focusComposerOnAppear)
            }
            .onChange(of: conversation.messages.count) { _, _ in
                scrollToBottom(proxy, focus: false)
            }
            .onChange(of: engine.isStreaming) { _, isStreaming in
                if isStreaming {
                    scrollToBottom(proxy, focus: false)
                }
            }
        }
    }

    private var composerID: String { "watch-chat-composer" }

    private func scrollToBottom(_ proxy: ScrollViewProxy, focus: Bool) {
        Task {
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(composerID, anchor: .bottom)
                }
                if focus {
                    focusComposerTrigger += 1
                }
            }
        }
    }

    /// The live streaming buffer applies only to the most recent
    /// assistant message while the engine is producing deltas.
    private func streamingOverride(for message: Message) -> String? {
        guard engine.isStreaming, message.role == .assistant else { return nil }
        guard let attemptID = engine.metadata?.attemptID,
              message.responseMetadata?.attemptID == attemptID else { return nil }
        return session.streamingContent
    }

    private func send(_ submittedText: String? = nil, fromDictation: Bool = false) {
        if let submittedText { draft = submittedText }
        guard isVisible, isSceneActive else { return }
        guard !engine.isStreaming else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if start(text: text, voiceTurn: fromDictation) { draft = "" }
    }

    private func stop() {
        speech.stop(ownerID: conversation.id)
        session.cancel()
    }

    @discardableResult
    private func start(text: String? = nil, retry: Message? = nil, voiceTurn: Bool = false, searchOverride: Bool? = nil) -> Bool {
        guard let endpoint else { return false }
        lastVoiceError = nil
        speech.stop()
        return session.send(conversation: conversation, context: modelContext, endpoint: endpoint,
                            apiKey: endpoints.apiKey(for: endpoint.id), text: text, retry: retry,
                            searchEnabled: searchOverride ?? searchEnabled,
                            additionalSystemPrompt: voiceTurn ? VoiceTextFormatting.applying(toSystemPrompt: "") : nil) { reply, metadata in
            guard isVisible, isSceneActive, voicePreferences.automaticallySpeakReplies,
                  metadata.phase == .completed else { return }
            speech.speak(reply, ownerID: conversation.id) { lastVoiceError = speech.lastError }
        }
    }

}

private struct WatchMessageRow: View {
    let message: Message
    let streamingOverride: String?

    private var isUser: Bool { message.role == .user }

    private var displayContent: String {
        if let streamingOverride, !streamingOverride.isEmpty {
            return streamingOverride
        }
        return message.content
    }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 24) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                if !displayContent.isEmpty || message.responseMetadata?.phase.isActive != false {
                    MarkdownText(raw: CitedAnswer.markdown(displayContent, citations: message.responseMetadata?.citations ?? [], restrictLinksToSources: message.responseMetadata?.searchSource != nil))
                        .font(.body)
                        .lineSpacing(2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(isUser ? Color.accentColor : Color.gray.opacity(0.25))
                        .foregroundStyle(isUser ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
                }
                if let metadata = message.responseMetadata {
                    ResponseDetailsView(metadata: metadata, content: displayContent)
                }
            }
            if !isUser { Spacer(minLength: 24) }
        }
    }
}

private struct EndpointPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var endpoints: EndpointStore
    @Bindable var conversation: Conversation

    var body: some View {
        List(endpoints.endpoints) { endpoint in
            Button {
                conversation.endpointID = endpoint.id
                conversation.endpointName = endpoint.name
                conversation.model = endpoint.model
                conversation.systemPrompt = endpoint.systemPrompt
                conversation.updatedAt = .now
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(endpoint.name)
                        Text(endpoint.model)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if endpoint.id == conversation.endpointID {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        .navigationTitle("Switch Endpoint")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}
