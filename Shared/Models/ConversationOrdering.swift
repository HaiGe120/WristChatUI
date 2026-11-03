import Foundation

/// A phone and Watch can independently allocate the same order indices before sync.
/// Keep each answer with its question, and resolve only conflicting turn slots by
/// timestamp and UUID. Stored indices remain unchanged for older peers and backups.
public enum ConversationOrdering {
    private struct Turn {
        let anchor: Message
        var replies: [Message] = []
    }

    public static func sorted(_ messages: [Message]) -> [Message] {
        let baseline = messages.sorted(by: precedes)
        var turns: [Turn] = []
        var userTurnByID: [UUID: Int] = [:]
        var userTurnsByIndex: [Int: [Int]] = [:]
        for message in baseline where message.role == .user {
            let index = turns.count
            turns.append(Turn(anchor: message))
            userTurnByID[message.id] = index
            userTurnsByIndex[message.orderIndex, default: []].append(index)
        }

        // Metadata is authoritative even when a synced reply's index or timestamp
        // collides with another turn. Orphan references remain visible as standalone rows.
        var unlinked: [(offset: Int, message: Message)] = []
        for (offset, message) in baseline.enumerated() where message.role != .user {
            if message.role == .assistant,
               let userID = message.responseMetadata?.userMessageID,
               let turnIndex = userTurnByID[userID] {
                turns[turnIndex].replies.append(message)
            } else {
                unlinked.append((offset, message))
            }
        }

        for (offset, message) in unlinked {
            if message.role == .assistant, message.responseMetadata == nil {
                let predecessor = message.orderIndex.subtractingReportingOverflow(1)
                var candidates = predecessor.overflow ? [] : (userTurnsByIndex[predecessor.partialValue] ?? [])
                candidates = candidates.filter { turns[$0].replies.isEmpty }
                // Older data can use gaps or identical indices. Preserve an adjacent
                // legacy question/answer pair when no explicit association is available.
                if candidates.isEmpty, offset > 0 {
                    let previous = baseline[offset - 1]
                    if previous.role == .user, let index = userTurnByID[previous.id], turns[index].replies.isEmpty {
                        candidates = [index]
                    }
                }
                // A unique preceding slot wins regardless of clock skew. If several
                // devices used that slot, nearest creation time is a deterministic
                // legacy fallback; only metadata can prove the original association.
                if let turnIndex = candidates.min(by: { left, right in
                    let leftDistance = abs(message.createdAt.timeIntervalSince(turns[left].anchor.createdAt))
                    let rightDistance = abs(message.createdAt.timeIntervalSince(turns[right].anchor.createdAt))
                    if leftDistance != rightDistance { return leftDistance < rightDistance }
                    return precedes(turns[left].anchor, turns[right].anchor)
                }) {
                    turns[turnIndex].replies.append(message)
                    continue
                }
            }
            turns.append(Turn(anchor: message))
        }

        return turns.sorted { precedes($0.anchor, $1.anchor) }.flatMap { turn in
            [turn.anchor] + turn.replies.sorted(by: precedes)
        }
    }

    private static func precedes(_ left: Message, _ right: Message) -> Bool {
        if left.orderIndex != right.orderIndex { return left.orderIndex < right.orderIndex }
        if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
        if left.role != right.role { return roleRank(left.role) < roleRank(right.role) }
        return left.id.uuidString < right.id.uuidString
    }

    private static func roleRank(_ role: MessageRole) -> Int {
        switch role {
        case .system: return 0
        case .user: return 1
        case .assistant: return 2
        }
    }
}
