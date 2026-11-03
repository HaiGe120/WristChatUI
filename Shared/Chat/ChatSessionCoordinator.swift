import Foundation
import Combine
import SwiftData

/// A process owns requests; phone and CarPlay attach to the same session.
/// The Watch has its own coordinator and continues using its own networking.
@MainActor
public final class ChatSessionCoordinator {
    public static let shared = ChatSessionCoordinator()
    public static let willRemoveConversation = Notification.Name("ChatSessionWillRemoveConversation")

    private var sessions: [UUID: ChatSession] = [:]
    private let makeEngine: @MainActor () -> ChatEngine
    private var observers: Set<AnyCancellable> = []

    public init(makeEngine: @escaping @MainActor () -> ChatEngine = { ChatEngine() }, observeChanges: Bool = true) {
        self.makeEngine = makeEngine
        if observeChanges {
            NotificationCenter.default.publisher(for: EndpointStore.willChange)
                .sink { [weak self] notification in
                    guard let self else { return }
                    let endpointID = notification.object as? UUID
                    for session in self.sessions.values where endpointID == nil || session.endpointID == endpointID {
                        session.cancel()
                    }
                }.store(in: &observers)
            NotificationCenter.default.publisher(for: SearchSourceStore.didChange)
                .sink { [weak self] _ in self?.cancelAll() }.store(in: &observers)
        }
    }

    public func session(for conversationID: UUID) -> ChatSession {
        if let existing = sessions[conversationID] { return existing }
        let session = ChatSession(engine: makeEngine())
        sessions[conversationID] = session
        return session
    }

    public func reconcile(_ conversation: Conversation, context: ModelContext) {
        // Merely opening the phone UI must not turn an active CarPlay reply into an interruption.
        guard sessions[conversation.id]?.isStreaming != true else { return }
        ConversationRequest.reconcileInterrupted(conversation, context: context)
    }

    public func remove(conversationID: UUID) {
        NotificationCenter.default.post(name: Self.willRemoveConversation, object: conversationID)
        sessions.removeValue(forKey: conversationID)?.cancel()
    }

    public func cancelAll() {
        for session in sessions.values { session.cancel() }
    }
}

@MainActor
public final class ChatSession: ObservableObject {
    public let engine: ChatEngine
    // Keep unsent input and the search choice with the conversation, even if
    // a fold, resize, or sidebar selection recreates its presentation.
    @Published public var draft = ""
    @Published public var searchEnabled: Bool?
    @Published public private(set) var streamingContent = ""
    public private(set) var endpointID: UUID?
    private var engineObservation: AnyCancellable?

    public var isStreaming: Bool { engine.isStreaming }
    public var metadata: ResponseMetadata? { engine.metadata }

    public init(engine: ChatEngine) {
        self.engine = engine
        engineObservation = engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Returns false without touching history when another surface already owns this conversation.
    @discardableResult
    public func send(conversation: Conversation, context: ModelContext, endpoint: EndpointConfig,
                     apiKey: String?, text: String? = nil, retry: Message? = nil,
                     searchEnabled: Bool, additionalSystemPrompt: String? = nil,
                     onResult: @escaping (String, ResponseMetadata) -> Void = { _, _ in }) -> Bool {
        guard !isStreaming, context.deletedModelsArray.contains(where: { $0.persistentModelID == conversation.persistentModelID }) == false,
              retry != nil || text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
        if let retry {
            guard conversation.messages.contains(where: { $0.id == retry.id && $0.role == .assistant }),
                  let userID = retry.responseMetadata?.userMessageID,
                  conversation.messages.contains(where: { $0.id == userID && $0.role == .user }) else { return false }
        }
        endpointID = endpoint.id
        streamingContent = ""
        ConversationRequest.start(engine: engine, conversation: conversation, context: context,
                                  endpoint: endpoint, apiKey: apiKey, userText: text, retry: retry,
                                  searchEnabled: searchEnabled, additionalSystemPrompt: additionalSystemPrompt,
                                  onDelta: { [weak self] delta in self?.streamingContent += delta },
                                  onComplete: {}, onResult: { [weak self] text, metadata in
                                      self?.streamingContent = ""
                                      onResult(text, metadata)
                                  }, onAnswerReset: { [weak self] in self?.streamingContent = "" })
        return true
    }

    public func cancel() { engine.cancel() }
}
