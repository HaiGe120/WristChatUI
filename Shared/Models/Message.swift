import Foundation
import SwiftData

@Model
public final class Message {
    @Attribute(.unique) public var id: UUID
    public var roleRaw: String
    public var content: String
    public var createdAt: Date
    public var orderIndex: Int
    public var responseMetadataData: Data? = nil

    public var conversation: Conversation?

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        createdAt: Date = .now,
        orderIndex: Int = 0,
        conversation: Conversation? = nil
    ) {
        self.id = id
        self.roleRaw = role.rawValue
        self.content = content
        self.createdAt = createdAt
        self.orderIndex = orderIndex
        self.conversation = conversation
    }

    public var responseMetadata: ResponseMetadata? {
        get { responseMetadataData.flatMap { try? JSONDecoder().decode(ResponseMetadata.self, from: $0) } }
        set { responseMetadataData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    public var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }
}
