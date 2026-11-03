import Foundation
import SwiftData

@MainActor
public enum ConversationRequest {
    /// A retry replaces its partial reply and reuses the original user turn.
    public static func start(engine: ChatEngine, conversation: Conversation, context: ModelContext,
                             endpoint: EndpointConfig, apiKey: String?, userText: String? = nil,
                             retry: Message? = nil, searchEnabled: Bool,
                             additionalSystemPrompt: String? = nil,
                             onDelta: @escaping (String) -> Void, onComplete: @escaping () -> Void,
                             onResult: @escaping (String, ResponseMetadata) -> Void = { _, _ in },
                             onAnswerReset: @escaping () -> Void = {}) {
        guard !engine.isStreaming else { return }
        let user: Message
        let assistant: Message
        var history: [ChatMessage]
        if let retry, let userID = retry.responseMetadata?.userMessageID,
           let original = conversation.sortedMessages.first(where: { $0.id == userID && $0.role == .user }) {
            user = original
            assistant = retry
            history = outgoingHistory(conversation.sortedMessages, through: userID)
        } else if let userText, !userText.isEmpty {
            history = outgoingHistory(conversation.sortedMessages)
            let order = (conversation.messages.map(\.orderIndex).max() ?? -1) + 1
            user = Message(role: .user, content: userText, orderIndex: order, conversation: conversation)
            assistant = Message(role: .assistant, content: "", orderIndex: order + 1, conversation: conversation)
            context.insert(user)
            context.insert(assistant)
            history.append(ChatMessage(role: .user, content: userText))
            if conversation.title == "New chat" || conversation.title.isEmpty {
                conversation.title = String(userText.prefix(40))
            }
        } else { return }
        assistant.content = ""
        assistant.responseMetadata = nil
        conversation.updatedAt = .now
        var resolved = endpoint
        if !conversation.model.isEmpty { resolved.model = conversation.model }
        resolved.systemPrompt = conversation.systemPrompt
        if let additionalSystemPrompt, !additionalSystemPrompt.isEmpty {
            resolved.systemPrompt += "\n" + additionalSystemPrompt
        }
        #if os(watchOS)
        resolved.systemPrompt = WatchResponseFormatting.applying(toSystemPrompt: resolved.systemPrompt)
        #endif
        resolved.searchMode = searchEnabled ? .auto : .off
        let source = searchEnabled ? SearchSourceStore.shared.selectedSource : nil
        let credential = source.flatMap { SearchSourceStore.shared.credential(for: $0.id) }
        var lastCheckpoint = Date()
        engine.send(endpoint: resolved, apiKey: apiKey, messages: history, userMessageID: user.id,
                    searchSource: source, searchCredential: credential, onDelta: { delta in
                        assistant.content += delta
                        onDelta(delta)
                        if Date().timeIntervalSince(lastCheckpoint) >= 1 {
                            try? context.save()
                            lastCheckpoint = Date()
                        }
                    },
                    onMetadata: { metadata in assistant.responseMetadata = metadata },
                    onAnswerReset: {
                        assistant.content = ""
                        onAnswerReset()
                        try? context.save()
                    },
                    onComplete: { text, metadata in
                        assistant.content = text
                        assistant.responseMetadata = metadata
                        conversation.updatedAt = .now
                        try? context.save()
                        SyncCoordinator.shared.publishConversation(ConversationSnapshot(conversation))
                        onResult(text, metadata)
                        onComplete()
                    })
        try? context.save()
    }

    /// Recover persisted in-flight rows after process termination; no request is replayed automatically.
    public static func reconcileInterrupted(_ conversation: Conversation, context: ModelContext) {
        var changed = false
        for message in conversation.messages {
            guard var metadata = message.responseMetadata, metadata.phase.isActive else { continue }
            metadata.phase = message.content.isEmpty ? .failed : .partial
            metadata.errorCode = "interrupted"
            metadata.errorMessage = "Request interrupted"
            metadata.updatedAt = .now
            message.responseMetadata = metadata
            changed = true
        }
        if changed { try? context.save() }
    }

    /// Interrupted replies are retained on screen but omitted from subsequent model context.
    /// Legacy transport-error prose and empty assistant placeholders are never replayed.
    public static func outgoingHistory(_ messages: [Message], through userID: UUID? = nil) -> [ChatMessage] {
        var result: [ChatMessage] = []
        for message in messages {
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.role == .user, !content.isEmpty {
                result.append(ChatMessage(role: .user, content: message.content))
            } else if message.role == .assistant, !content.isEmpty,
                      !content.hasPrefix("⚠️"),
                      message.responseMetadata.map({ $0.phase == .completed }) ?? true {
                result.append(ChatMessage(role: .assistant, content: message.content))
            }
            if message.id == userID { break }
        }
        return result
    }
}
