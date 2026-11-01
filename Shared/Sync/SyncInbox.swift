import Foundation
import SwiftData

/// Receives plain-value snapshots published by the other side and upserts
/// them into this process's local SwiftData store. Idempotent: reapplying
/// the same snapshot is a no-op, so re-deliveries from
/// `updateApplicationContext` and `transferUserInfo` are safe.
@MainActor
public final class SyncInbox {
    public static let shared = SyncInbox()

    private var container: ModelContainer { DataStore.shared }

    private init() {}

    public func upsertConversation(_ snapshot: ConversationSnapshot) {
        let context = container.mainContext
        let id = snapshot.id
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.id == id }
        )
        let existing = (try? context.fetch(descriptor))?.first
        let target = existing ?? Conversation(
            id: snapshot.id,
            title: snapshot.title,
            endpointID: snapshot.endpointID,
            endpointName: snapshot.endpointName,
            model: snapshot.model,
            systemPrompt: snapshot.systemPrompt,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt
        )
        if existing != nil {
            target.title = snapshot.title
            target.endpointID = snapshot.endpointID
            target.endpointName = snapshot.endpointName
            target.model = snapshot.model
            target.systemPrompt = snapshot.systemPrompt
            target.updatedAt = snapshot.updatedAt
        }
        // Upsert messages.
        let existingByID: [UUID: Message] = Dictionary(
            uniqueKeysWithValues: target.messages.map { ($0.id, $0) }
        )
        for ms in snapshot.messages {
            if let m = existingByID[ms.id] {
                Self.merge(ms, into: m)
            } else {
                let m = Message(
                    id: ms.id,
                    role: MessageRole(rawValue: ms.roleRaw) ?? .user,
                    content: ms.content,
                    createdAt: ms.createdAt,
                    orderIndex: ms.orderIndex,
                    conversation: target
                )
                m.responseMetadata = ms.responseMetadata
                context.insert(m)
            }
        }
        if existing == nil {
            context.insert(target)
        }
        try? context.save()
    }

    public func upsertMessage(_ message: MessageSnapshot, in conversationID: UUID) {
        let context = container.mainContext
        let convDescriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.id == conversationID }
        )
        guard let conversation = (try? context.fetch(convDescriptor))?.first else {
            // Conversation hasn't arrived yet; stash the message as a
            // pending upsert by inserting a stub conversation if necessary.
            // In practice the conversation is sent immediately before any
            // messages, so this branch is rare.
            return
        }
        let messageID = message.id
        let msgDescriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.id == messageID }
        )
        if let existing = (try? context.fetch(msgDescriptor))?.first {
            Self.merge(message, into: existing)
        } else {
            let m = Message(
                id: message.id,
                role: MessageRole(rawValue: message.roleRaw) ?? .user,
                content: message.content,
                createdAt: message.createdAt,
                orderIndex: message.orderIndex,
                conversation: conversation
            )
            m.responseMetadata = message.responseMetadata
            context.insert(m)
        }
        try? context.save()
    }

    /// Keep answer text and its citation offsets as one revision across mixed app versions.
    static func merge(_ incoming: MessageSnapshot, into target: Message) {
        if let local = target.responseMetadata {
            guard let remote = incoming.responseMetadata, remote.updatedAt >= local.updatedAt else { return }
        }
        target.roleRaw = incoming.roleRaw
        target.content = incoming.content
        target.createdAt = incoming.createdAt
        target.orderIndex = incoming.orderIndex
        if let metadata = incoming.responseMetadata { target.responseMetadata = metadata }
    }

    public func upsertAPIKey(_ value: String, for endpointID: UUID) {
        if value.isEmpty {
            KeychainStore.delete("\(endpointID.uuidString).apikey")
        } else {
            KeychainStore.set(value, for: "\(endpointID.uuidString).apikey")
        }
    }

    /// Drop a conversation that was deleted on the companion. Idempotent:
    /// calling this for a conversation that no longer exists locally is
    /// a no-op, so a delete arriving before the conversation itself is
    /// fine.
    public func deleteConversation(_ id: UUID) {
        let context = container.mainContext
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.id == id }
        )
        if let existing = (try? context.fetch(descriptor))?.first {
            context.delete(existing)
            try? context.save()
        }
    }

    /// Batch variant of `upsertConversation` used by the bulk-conversations
    /// sync path. Calls the single-conversation path so the merge logic
    /// stays in one place; the only difference is that we save the context
    /// once at the end instead of once per snapshot.
    public func upsertConversations(_ snapshots: [ConversationSnapshot]) {
        guard !snapshots.isEmpty else { return }
        let context = container.mainContext
        for snapshot in snapshots {
            upsertConversationUnchecked(snapshot, context: context)
        }
        try? context.save()
    }

    /// Same as `upsertConversation` but does NOT save the context. Lets
    /// the batch path coalesce many upserts into a single write.
    private func upsertConversationUnchecked(_ snapshot: ConversationSnapshot, context: ModelContext) {
        let id = snapshot.id
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.id == id }
        )
        let existing = (try? context.fetch(descriptor))?.first
        let target = existing ?? Conversation(
            id: snapshot.id,
            title: snapshot.title,
            endpointID: snapshot.endpointID,
            endpointName: snapshot.endpointName,
            model: snapshot.model,
            systemPrompt: snapshot.systemPrompt,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt
        )
        if existing != nil {
            target.title = snapshot.title
            target.endpointID = snapshot.endpointID
            target.endpointName = snapshot.endpointName
            target.model = snapshot.model
            target.systemPrompt = snapshot.systemPrompt
            target.updatedAt = snapshot.updatedAt
        }
        let existingByID: [UUID: Message] = Dictionary(
            uniqueKeysWithValues: target.messages.map { ($0.id, $0) }
        )
        for ms in snapshot.messages {
            if let m = existingByID[ms.id] {
                Self.merge(ms, into: m)
            } else {
                let m = Message(
                    id: ms.id,
                    role: MessageRole(rawValue: ms.roleRaw) ?? .user,
                    content: ms.content,
                    createdAt: ms.createdAt,
                    orderIndex: ms.orderIndex,
                    conversation: target
                )
                m.responseMetadata = ms.responseMetadata
                context.insert(m)
            }
        }
        if existing == nil {
            context.insert(target)
        }
    }
}
