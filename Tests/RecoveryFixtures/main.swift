import Foundation
import SwiftData

@main
struct RecoveryFixtures {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        let budget = RequestBudget(firstResult: 0.04, inactivity: 0.04, overall: 0.15, pollInterval: 0.005)
        let endpoint = EndpointConfig(name: "Fixture", providerType: .openAICompatible, baseURLString: "https://example.test/v1", model: "fixture")
        var continuations: [AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation] = []
        let engine = ChatEngine { _, _, _ in
            AsyncThrowingStream { continuations.append($0) }
        }
        var results: [(String, ResponseMetadata)] = []
        var deltas = ""
        func send(_ requestBudget: RequestBudget = budget) {
            engine.send(endpoint: endpoint, apiKey: nil, messages: [.init(role: .user, content: "question")], userMessageID: UUID(), budget: requestBudget,
                        onDelta: { deltas += $0 }, onComplete: { results.append(($0, $1)) })
        }
        send()
        try await waitUntil { !engine.isStreaming }
        expect(results.count == 1 && results[0].1.errorCode == "timeout", "No-header timeout must finish exactly once")
        send()
        try await waitUntil { continuations.count == 2 }
        continuations[0].yield(.text("late old delta"))
        continuations[0].yield(.completed)
        continuations[1].yield(.text("next reply"))
        continuations[1].yield(.completed)
        try await waitUntil { !engine.isStreaming }
        expect(results.count == 2 && results[1].0 == "next reply", "Next prompt must succeed on the same engine")
        expect(!deltas.contains("late"), "Old attempt must never append text")
        expect(results[1].1.phase == .completed, "Terminal success must be completed")

        send()
        try await waitUntil { continuations.count == 3 }
        continuations[2].yield(.text("partial"))
        try await waitUntil { !engine.isStreaming }
        expect(results[2].0 == "partial" && results[2].1.phase == .partial, "Stalled text must survive as partial")
        expect(results[2].1.errorCode == "timeout", "Partial timeout retains typed error")

        send()
        try await waitUntil { continuations.count == 4 }
        engine.cancel()
        expect(!engine.isStreaming && results[3].1.phase == .cancelled, "Stop must synchronously unlock composer")
        send()
        try await waitUntil { continuations.count == 5 }
        continuations[3].yield(.text("obsolete")); continuations[3].yield(.completed)
        continuations[4].yield(.text("fresh")); continuations[4].yield(.completed)
        try await waitUntil { !engine.isStreaming }
        expect(results[4].0 == "fresh" && results.count == 5, "Stop then Send must isolate callbacks and finish once")

        send()
        try await waitUntil { continuations.count == 6 }
        continuations[5].finish()
        try await waitUntil { !engine.isStreaming }
        expect(results[5].1.errorCode == "incomplete", "EOF without success terminal cannot complete")

        send(RequestBudget(firstResult: 0.03, inactivity: 0.04, overall: 0.07, pollInterval: 0.005))
        try await waitUntil { continuations.count == 7 }
        for _ in 0..<10 {
            continuations[6].yield(.searchActivity(.searching))
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        expect(!engine.isStreaming && results[6].1.errorCode == "timeout", "Search activity cannot extend the overall deadline")
        expect(results[6].1.searchOutcome == .failed, "Failed search is never a success claim")

        let defaults = UserDefaults(suiteName: "WristAssistantFixtures-\(UUID())")!
        let capability = NativeSearchCapabilities(defaults: defaults)
        expect(capability.state(for: endpoint) == .unknown, "Capability begins unknown")
        capability.record(.unsupported, for: endpoint)
        var changed = endpoint; changed.model = "other"
        expect(capability.state(for: changed) == .unknown, "Model changes invalidate capability")
        changed = endpoint; changed.baseURLString = "https://example.test/prefix/v1"
        expect(capability.state(for: changed) == .unknown, "Destination changes invalidate capability")
        capability.clear(for: endpoint)
        expect(capability.state(for: endpoint) == .unknown, "Recheck clears rejection")

        let schema = Schema([Conversation.self, Message.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = container.mainContext
        let conversation = Conversation(endpointID: endpoint.id, endpointName: endpoint.name, model: endpoint.model)
        context.insert(conversation)
        let user = Message(role: .user, content: "original", orderIndex: 0, conversation: conversation)
        let reply = Message(role: .assistant, content: "partial text", orderIndex: 1, conversation: conversation)
        context.insert(user); context.insert(reply)
        reply.responseMetadata = ResponseMetadata(attemptID: UUID(), userMessageID: user.id, phase: .partial,
            searchOutcome: .succeeded, citations: [.init(url: "https://example.test/source", title: "Verified source")], errorCode: "connectionLost", errorMessage: "Connection lost")
        try context.save()
        expect(ConversationRequest.outgoingHistory(conversation.sortedMessages).map(\.content) == ["original"], "Partial assistant replies excluded from history")
        let placeholder = Message(role: .assistant, content: "", orderIndex: 2)
        let oldError = Message(role: .assistant, content: "⚠️ disconnected", orderIndex: 3)
        expect(ConversationRequest.outgoingHistory([user, placeholder, oldError]).map(\.content) == ["original"], "No placeholders or old transport error prose in model history")
        let snapshot = ConversationSnapshot(conversation)
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ConversationSnapshot.self, from: encoded)
        expect(decoded.messages[1].responseMetadata?.citations.count == 1, "Sync/backup round trip retains citations")
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object["messages"] = (object["messages"] as! [[String: Any]]).map { entry in
            var legacy = entry; legacy.removeValue(forKey: "responseMetadata"); return legacy
        }
        let legacy = try JSONDecoder().decode(ConversationSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        expect(legacy.messages.allSatisfy { $0.responseMetadata == nil }, "Version-1 snapshots decode without metadata")

        let wireEncoder = JSONEncoder(); wireEncoder.dateEncodingStrategy = .iso8601
        let wireDecoder = JSONDecoder(); wireDecoder.dateDecodingStrategy = .iso8601
        let originalMetadata = reply.responseMetadata!
        let wireMetadata = try wireDecoder.decode(ResponseMetadata.self, from: wireEncoder.encode(originalMetadata))
        expect(abs(wireMetadata.updatedAt.timeIntervalSince(originalMetadata.updatedAt)) < 0.00001, "Companion encoding preserves subsecond metadata ordering")
        var oldMessage = legacy.messages[1]
        oldMessage.content = "obsolete content"
        SyncInbox.merge(oldMessage, into: reply)
        expect(reply.content == "partial text" && reply.responseMetadata?.citations.count == 1, "Legacy companion cannot split answer text from citations")
        var stale = MessageSnapshot(reply)
        stale.content = "stale cited content"
        stale.responseMetadata?.updatedAt = .distantPast
        SyncInbox.merge(stale, into: reply)
        expect(reply.content == "partial text", "Older metadata revision cannot overwrite newer answer")
        let source = SourceCitation(url: "https://example.test/source", title: "Source", startIndex: 0, endIndex: 2)
        let cited = CitedAnswer.markdown("😀 answer", citations: [source])
        expect(cited.hasPrefix("😀 [[1]]"), "Citation positions handle UTF-16 emoji safely")
        let verified = CitedAnswer.markdown("[real](https://example.test/source) [invented](https://unknown.test)", citations: [.init(url: source.url, title: source.title)], restrictLinksToSources: true)
        expect(verified.contains("[real](https://example.test/source)") && !verified.contains("https://unknown.test"), "Displayed search links must match returned source URLs")
        let orphan = Message(role: .assistant, content: "saved partial", orderIndex: 4, conversation: conversation)
        context.insert(orphan)
        orphan.responseMetadata = ResponseMetadata(attemptID: UUID(), userMessageID: user.id, phase: .receiving)
        ConversationRequest.reconcileInterrupted(conversation, context: context)
        expect(orphan.responseMetadata?.phase == .partial, "A persisted interrupted attempt offers recovery after restart")
        context.delete(orphan)
        try context.save()

        var requests: [[ChatMessage]] = []
        let retryEngine = ChatEngine { _, _, messages in
            requests.append(messages)
            return AsyncThrowingStream { continuation in
                continuation.yield(.text("replacement")); continuation.yield(.completed); continuation.finish()
            }
        }
        ConversationRequest.start(engine: retryEngine, conversation: conversation, context: context, endpoint: endpoint, apiKey: nil, retry: reply,
                                  searchEnabled: false, onDelta: { _ in }, onComplete: {})
        try await waitUntil { !retryEngine.isStreaming }
        expect(conversation.messages.filter { $0.role == .user }.count == 1, "Retry creates no duplicate user turn")
        expect(reply.content == "replacement" && reply.responseMetadata?.phase == .completed, "Retry replaces partial reply")
        expect(requests[0].map(\.content) == ["original"], "Retry sends the original turn without its assistant placeholder")
        print("Recovery fixtures: \(checks) checks passed")
    }

    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        precondition(condition(), "Fixture did not settle within bounded deadline")
    }
}
