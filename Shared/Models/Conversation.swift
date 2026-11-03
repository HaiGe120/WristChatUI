import Foundation
import SwiftData

@Model
public final class Conversation {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var endpointID: UUID
    public var endpointName: String
    public var model: String
    public var systemPrompt: String

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    public var messages: [Message] = []

    public init(
        id: UUID = UUID(),
        title: String = "New chat",
        endpointID: UUID,
        endpointName: String,
        model: String,
        systemPrompt: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        messages: [Message] = []
    ) {
        self.id = id
        self.title = title
        self.endpointID = endpointID
        self.endpointName = endpointName
        self.model = model
        self.systemPrompt = systemPrompt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    public var sortedMessages: [Message] {
        ConversationOrdering.sorted(messages)
    }

    public var lastMessagePreview: String {
        let last = sortedMessages.last(where: { $0.role == .assistant || $0.role == .user })
        return last?.content.prefix(120).description ?? ""
    }
}
