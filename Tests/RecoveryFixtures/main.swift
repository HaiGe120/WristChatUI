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

        var managedEngineCount = 0
        var managedContinuations: [AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation] = []
        var managedEndpoints: [EndpointConfig] = []
        var managedResults: [(String, ResponseMetadata)] = []
        let coordinator = ChatSessionCoordinator(makeEngine: {
            managedEngineCount += 1
            return ChatEngine { resolved, _, _ in
                managedEndpoints.append(resolved)
                return AsyncThrowingStream { managedContinuations.append($0) }
            }
        }, observeChanges: false)
        let managedConversation = Conversation(endpointID: endpoint.id, endpointName: endpoint.name,
                                               model: endpoint.model, systemPrompt: "Preserve these instructions.")
        context.insert(managedConversation)
        try context.save()
        let phoneSession = coordinator.session(for: managedConversation.id)
        let carSession = coordinator.session(for: managedConversation.id)
        expect(phoneSession === carSession && managedEngineCount == 1,
               "Phone and CarPlay references to one conversation must share the same session and engine")

        let accepted = phoneSession.send(conversation: managedConversation, context: context, endpoint: endpoint,
                                         apiKey: nil, text: "First voice question", searchEnabled: false,
                                         additionalSystemPrompt: "Answer briefly for speech.",
                                         onResult: { managedResults.append(($0, $1)) })
        let duplicate = carSession.send(conversation: managedConversation, context: context, endpoint: endpoint,
                                        apiKey: nil, text: "Duplicate surface send", searchEnabled: false)
        expect(accepted && !duplicate, "A second surface must not start another attempt while a conversation is active")
        expect(managedConversation.messages.filter { $0.role == .user }.count == 1 &&
               managedConversation.messages.filter { $0.role == .assistant }.count == 1,
               "A rejected duplicate send must not insert question or answer rows")
        try await waitUntil { managedContinuations.count == 1 }
        expect(managedEndpoints[0].systemPrompt.contains("Preserve these instructions.") &&
               managedEndpoints[0].systemPrompt.contains("Answer briefly for speech.") &&
               managedConversation.systemPrompt == "Preserve these instructions.",
               "Per-turn voice guidance must preserve saved instructions without mutating the conversation")
        let managedReply = managedConversation.sortedMessages.last!
        let activeAttemptID = managedReply.responseMetadata?.attemptID
        coordinator.reconcile(managedConversation, context: context)
        expect(managedReply.responseMetadata?.attemptID == activeAttemptID &&
               managedReply.responseMetadata?.phase.isActive == true && managedReply.responseMetadata?.errorCode == nil,
               "Opening another surface must not reconcile a live request into an interrupted answer")

        managedContinuations[0].yield(.text("unfinished answer"))
        try await waitUntil { phoneSession.streamingContent == "unfinished answer" }
        carSession.cancel()
        expect(!phoneSession.isStreaming && managedResults.count == 1 &&
               managedResults[0].1.phase == .cancelled && managedReply.content == "unfinished answer" &&
               phoneSession.streamingContent.isEmpty,
               "Stop from either surface must finish once, preserve partial text and clear the live buffer")
        let retryAccepted = phoneSession.send(conversation: managedConversation, context: context, endpoint: endpoint,
                                              apiKey: nil, retry: managedReply, searchEnabled: false,
                                              onResult: { managedResults.append(($0, $1)) })
        expect(retryAccepted && managedConversation.messages.filter { $0.role == .user }.count == 1,
               "A cancelled managed turn must accept Retry without duplicating its original question")
        try await waitUntil { managedContinuations.count == 2 }
        managedContinuations[0].yield(.text("stale cancelled text"))
        managedContinuations[0].yield(.completed)
        managedContinuations[1].yield(.text("recovered answer"))
        managedContinuations[1].yield(.completed)
        try await waitUntil { !carSession.isStreaming }
        expect(managedResults.count == 2 && managedResults[1].0 == "recovered answer" &&
               managedReply.content == "recovered answer" && managedReply.responseMetadata?.phase == .completed,
               "A managed retry must replace the answer and fence callbacks from the cancelled attempt")

        let nextAccepted = carSession.send(conversation: managedConversation, context: context, endpoint: endpoint,
                                           apiKey: nil, text: "Next question", searchEnabled: false,
                                           onResult: { managedResults.append(($0, $1)) })
        expect(nextAccepted && managedConversation.messages.filter { $0.role == .user }.count == 2,
               "The other surface must be able to send a new turn after the shared attempt completes")
        try await waitUntil { managedContinuations.count == 3 }
        coordinator.remove(conversationID: managedConversation.id)
        expect(!phoneSession.isStreaming && managedResults.count == 3 && managedResults[2].1.phase == .cancelled,
               "Removing a conversation must cancel its live managed request")
        let replacementSession = coordinator.session(for: managedConversation.id)
        expect(replacementSession !== phoneSession && managedEngineCount == 2,
               "A removed session must be evicted rather than reused by a later surface")
        managedContinuations[2].yield(.text("late deleted-conversation answer"))
        managedContinuations[2].yield(.completed)
        await Task.yield()
        expect(managedResults.count == 3 && !replacementSession.isStreaming,
               "Late output from a removed session must not finish again or activate its replacement")

        let managedOrphan = Message(role: .assistant, content: "saved orphan", orderIndex: 4,
                                    conversation: managedConversation)
        context.insert(managedOrphan)
        managedOrphan.responseMetadata = ResponseMetadata(attemptID: UUID(), userMessageID: UUID(), phase: .receiving)
        coordinator.reconcile(managedConversation, context: context)
        expect(managedOrphan.responseMetadata?.phase == .partial && managedOrphan.responseMetadata?.errorCode == "interrupted",
               "A coordinator with no live request must still recover persisted in-flight rows")
        let foreignRetry = replacementSession.send(conversation: managedConversation, context: context, endpoint: endpoint,
                                                   apiKey: nil, retry: reply, searchEnabled: false)
        expect(!foreignRetry && !replacementSession.isStreaming,
               "A retry belonging to another conversation must not claim request ownership")
        let watchedCoordinator = ChatSessionCoordinator(makeEngine: {
            ChatEngine { _, _, _ in AsyncThrowingStream { _ in } }
        })
        let watchedSession = watchedCoordinator.session(for: managedConversation.id)
        watchedSession.send(conversation: managedConversation, context: context, endpoint: endpoint,
                            apiKey: nil, text: "Watch connection changes", searchEnabled: false)
        NotificationCenter.default.post(name: EndpointStore.willChange, object: UUID())
        expect(watchedSession.isStreaming, "Editing another endpoint must not cancel this conversation")
        NotificationCenter.default.post(name: EndpointStore.willChange, object: endpoint.id)
        expect(!watchedSession.isStreaming, "Editing the active connection must cancel its owned request")
        watchedSession.send(conversation: managedConversation, context: context, endpoint: endpoint,
                            apiKey: nil, text: "Watch source changes", searchEnabled: false)
        NotificationCenter.default.post(name: SearchSourceStore.didChange, object: nil)
        expect(!watchedSession.isStreaming, "Search-source changes must cancel requests outside visible chat screens")

        func fixtureMessage(_ role: MessageRole, _ text: String, index: Int, time: TimeInterval,
                            id: UUID = UUID()) -> Message {
            Message(id: id, role: role, content: text, createdAt: Date(timeIntervalSince1970: time), orderIndex: index)
        }
        func link(_ answer: Message, to question: Message, phase: AttemptPhase = .completed) {
            answer.responseMetadata = ResponseMetadata(attemptID: UUID(), userMessageID: question.id, phase: phase)
        }
        func orderingConversation(_ rows: [Message]) -> Conversation {
            Conversation(endpointID: endpoint.id, endpointName: endpoint.name, model: endpoint.model, messages: rows)
        }

        // Reproduce two independently allocated phone/Watch turns: both questions have
        // index 8 and both answers have index 9, but their creation times differ.
        let earlierQuestion = fixtureMessage(.user, "Give me more", index: 8, time: 100)
        let laterQuestion = fixtureMessage(.user, "give me more", index: 8, time: 160)
        let earlierFailure = fixtureMessage(.assistant, "", index: 9, time: 100.1)
        let laterPartial = fixtureMessage(.assistant, "Partial answer", index: 9, time: 160.1)
        link(earlierFailure, to: earlierQuestion, phase: .failed)
        link(laterPartial, to: laterQuestion, phase: .partial)
        let collision = orderingConversation([laterQuestion, earlierQuestion, laterPartial, earlierFailure])
        let expectedCollisionIDs = [earlierQuestion.id, earlierFailure.id, laterQuestion.id, laterPartial.id]
        expect(collision.sortedMessages.map(\.id) == expectedCollisionIDs,
               "Concurrent phone/Watch turns must sort chronologically and keep each failed/partial answer beside its own question")
        collision.messages.reverse()
        expect(collision.sortedMessages.map(\.id) == expectedCollisionIDs,
               "Merged relationship arrival order must not affect the repaired conversation order")
        expect(earlierQuestion.orderIndex == 8 && laterQuestion.orderIndex == 8 &&
               earlierFailure.orderIndex == 9 && laterPartial.orderIndex == 9,
               "Ordering repair must not renumber stored indices or destabilize queued peer snapshots")
        expect(ConversationSnapshot(collision).messages.map(\.id) == expectedCollisionIDs,
               "Backups and outgoing sync snapshots must use the same repaired order as the chat UI")
        expect(ConversationRequest.outgoingHistory(collision.sortedMessages).map(\.content) == ["Give me more", "give me more"],
               "Repaired history must retain chronological questions while excluding their failed/partial answers")
        link(earlierFailure, to: earlierQuestion)
        earlierFailure.content = "Earlier complete answer"
        link(laterPartial, to: laterQuestion)
        expect(ConversationRequest.outgoingHistory(collision.sortedMessages).map(\.content) ==
               ["Give me more", "Earlier complete answer", "give me more", "Partial answer"],
               "Completed concurrent answers must stay paired correctly in the next provider request")

        let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let highID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let tiedLow = fixtureMessage(.user, "Low UUID", index: 4, time: 200, id: lowID)
        let tiedHigh = fixtureMessage(.user, "High UUID", index: 4, time: 200, id: highID)
        let tiedLowAnswer = fixtureMessage(.assistant, "Low answer", index: 5, time: 201)
        let tiedHighAnswer = fixtureMessage(.assistant, "High answer", index: 5, time: 201)
        link(tiedLowAnswer, to: tiedLow)
        link(tiedHighAnswer, to: tiedHigh)
        let tied = orderingConversation([tiedHighAnswer, tiedHigh, tiedLowAnswer, tiedLow])
        expect(tied.sortedMessages.map(\.id) == [tiedLow.id, tiedLowAnswer.id, tiedHigh.id, tiedHighAnswer.id],
               "Concurrent turns with identical timestamps must use stable user UUID ordering")

        let skewFirst = fixtureMessage(.user, "First indexed turn", index: 0, time: 400)
        let skewFirstAnswer = fixtureMessage(.assistant, "First indexed answer", index: 1, time: 401)
        let skewSecond = fixtureMessage(.user, "Second indexed turn", index: 2, time: 300)
        let skewSecondAnswer = fixtureMessage(.assistant, "Second indexed answer", index: 3, time: 301)
        link(skewFirstAnswer, to: skewFirst)
        link(skewSecondAnswer, to: skewSecond)
        let skewed = orderingConversation([skewSecondAnswer, skewFirstAnswer, skewSecond, skewFirst])
        expect(skewed.sortedMessages.map(\.id) == [skewFirst.id, skewFirstAnswer.id, skewSecond.id, skewSecondAnswer.id],
               "Clock skew must not reorder existing sequential turns whose indices are unambiguous")

        let legacyFirst = fixtureMessage(.user, "Legacy first", index: 0, time: 600)
        let legacyFirstAnswer = fixtureMessage(.assistant, "Legacy first answer", index: 1, time: 601)
        let legacySecond = fixtureMessage(.user, "Legacy second", index: 2, time: 500)
        let legacySecondAnswer = fixtureMessage(.assistant, "Legacy second answer", index: 3, time: 501)
        let legacyOrdering = orderingConversation([legacySecondAnswer, legacyFirstAnswer, legacySecond, legacyFirst])
        expect(legacyOrdering.sortedMessages.map(\.id) == [legacyFirst.id, legacyFirstAnswer.id, legacySecond.id, legacySecondAnswer.id],
               "Legacy replies without response metadata must retain their adjacent indexed questions across clock skew")
        let legacyEarlier = fixtureMessage(.user, "Legacy earlier collision", index: 6, time: 700)
        let legacyEarlierAnswer = fixtureMessage(.assistant, "Legacy earlier answer", index: 7, time: 700.1)
        let legacyLater = fixtureMessage(.user, "Legacy later collision", index: 6, time: 800)
        let legacyLaterAnswer = fixtureMessage(.assistant, "Legacy later answer", index: 7, time: 800.1)
        let legacyCollision = orderingConversation([legacyLaterAnswer, legacyEarlierAnswer, legacyLater, legacyEarlier])
        expect(legacyCollision.sortedMessages.map(\.id) ==
               [legacyEarlier.id, legacyEarlierAnswer.id, legacyLater.id, legacyLaterAnswer.id],
               "Legacy collisions must use deterministic nearest-time fallback instead of grouping both questions before both replies")

        let legacySameIndexUser = fixtureMessage(.user, "Same index question", index: 0, time: 900)
        let legacySameIndexAnswer = fixtureMessage(.assistant, "Same index answer", index: 0, time: 900.1)
        let legacyGapUser = fixtureMessage(.user, "Gap question", index: 5, time: 901)
        let legacyGapAnswer = fixtureMessage(.assistant, "Gap answer", index: 9, time: 901.1)
        let legacyGaps = orderingConversation([legacyGapAnswer, legacySameIndexAnswer, legacyGapUser, legacySameIndexUser])
        expect(legacyGaps.sortedMessages.map(\.id) ==
               [legacySameIndexUser.id, legacySameIndexAnswer.id, legacyGapUser.id, legacyGapAnswer.id],
               "Legacy same-index and gapped-index question/answer adjacency must remain intact")
        let orphanedAnswer = fixtureMessage(.assistant, "Orphaned but visible", index: 10, time: 902)
        orphanedAnswer.responseMetadata = ResponseMetadata(attemptID: UUID(), userMessageID: UUID(), phase: .completed)
        let systemRow = fixtureMessage(.system, "Retained system row", index: -1, time: 899)
        legacyGaps.messages.append(contentsOf: [orphanedAnswer, systemRow])
        expect(legacyGaps.sortedMessages.count == 6 && legacyGaps.sortedMessages.first?.id == systemRow.id &&
               legacyGaps.sortedMessages.last?.id == orphanedAnswer.id,
               "Repair must not lose system rows, legacy rows or replies whose referenced question is missing")
        expect(results[0].1.errorMessage?.contains("No response arrived") == true,
               "First-result timeouts must explain that no response arrived")
        expect(results[2].1.errorMessage?.contains("stopped making progress") == true &&
               results[2].1.statusText?.hasPrefix("Partial reply") == true,
               "Stalled replies must say the displayed answer is partial")

        func settled(_ events: [ProviderStreamEvent], failure: APIError? = nil) async throws -> ResponseMetadata {
            let fixture = ChatEngine { _, _, _ in
                AsyncThrowingStream { continuation in
                    for event in events { continuation.yield(event) }
                    continuation.finish(throwing: failure)
                }
            }
            var result: ResponseMetadata?
            fixture.send(endpoint: endpoint, apiKey: nil, messages: [.init(role: .user, content: "Fixture")],
                         userMessageID: UUID(), onDelta: { _ in }, onComplete: { _, metadata in result = metadata })
            try await waitUntil { !fixture.isStreaming }
            return result!
        }
        let emptyAnswer = try await settled([.text(" \n "), .completed])
        expect(emptyAnswer.phase == .failed && emptyAnswer.errorCode == "emptyResponse",
               "A whitespace-only terminal response must not be reported as a complete answer")
        for (failure, expectedCode) in [(APIError.searchLimitReached, "searchLimit"),
                                        (.continuationLimitReached, "continuationLimit"),
                                        (.outputLimitReached, "outputLimit"),
                                        (.contextLimitReached, "contextLimit")] {
            let typed = try await settled([.text("Useful partial information")], failure: failure)
            expect(typed.phase == .partial && typed.errorCode == expectedCode &&
                   typed.statusText?.hasPrefix("Partial reply") == true,
                   "Provider limits must preserve partial information and a specific actionable failure: \(expectedCode)")
        }
        let returnedSource = SourceCitation(url: "https://example.test/verified", title: "Verified")
        let limitedSuccess = try await settled([.searchActivity(.searching), .citation(returnedSource),
                                               .searchActivity(.limitReached), .text("An answer using the existing results."), .completed])
        expect(limitedSuccess.phase == .completed && limitedSuccess.searchLimitReached &&
               limitedSuccess.citations.count == 1 && limitedSuccess.searchOutcome == .succeeded,
               "A server search-limit control result must allow the model's real final answer and retain references")
        let limitedRoundTrip = try JSONDecoder().decode(ResponseMetadata.self, from: JSONEncoder().encode(limitedSuccess))
        expect(limitedRoundTrip.searchLimitReached, "Companion and backup metadata must retain the search-limit note")
        var legacyLimitObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(limitedSuccess)) as! [String: Any]
        legacyLimitObject.removeValue(forKey: "searchLimitReached")
        let legacyLimit = try JSONDecoder().decode(ResponseMetadata.self, from: JSONSerialization.data(withJSONObject: legacyLimitObject))
        expect(!legacyLimit.searchLimitReached, "Older companion metadata must decode without the new optional limit flag")

        var repeatedSourceContinuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation?
        let repeatedSourceEngine = ChatEngine { _, _, _ in
            AsyncThrowingStream { repeatedSourceContinuation = $0 }
        }
        repeatedSourceEngine.send(endpoint: endpoint, apiKey: nil, messages: [.init(role: .user, content: "Question")],
                                  userMessageID: UUID(),
                                  budget: RequestBudget(firstResult: 0.1, inactivity: 0.04, overall: 0.5, pollInterval: 0.002),
                                  onDelta: { _ in }, onComplete: { _, _ in })
        try await waitUntil { repeatedSourceContinuation != nil }
        for _ in 0..<12 {
            repeatedSourceContinuation?.yield(.citation(returnedSource))
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        expect(!repeatedSourceEngine.isStreaming && repeatedSourceEngine.metadata?.errorCode == "timeout" &&
               repeatedSourceEngine.metadata?.citations.count == 1,
               "Repeating the same source must not count as useful progress or keep a stalled request alive")

        var retrySearchModes: [SearchMode] = []
        var searchDefault = endpoint
        searchDefault.searchMode = .auto
        let withoutSearch = ChatSession(engine: ChatEngine { resolved, _, _ in
            retrySearchModes.append(resolved.searchMode)
            return AsyncThrowingStream { continuation in
                continuation.yield(.text("A complete answer without another search."))
                continuation.yield(.completed)
                continuation.finish()
            }
        })
        let usersBeforeRetry = managedConversation.messages.filter { $0.role == .user }.count
        expect(withoutSearch.send(conversation: managedConversation, context: context, endpoint: searchDefault,
                                  apiKey: nil, retry: managedReply, searchEnabled: false),
               "An explicit retry without search must accept the original question")
        try await waitUntil { !withoutSearch.isStreaming }
        expect(retrySearchModes == [.off] && searchDefault.searchMode == .auto &&
               managedConversation.messages.filter { $0.role == .user }.count == usersBeforeRetry &&
               managedReply.responseMetadata?.searchOutcome == .off,
               "Retry without search must disable search for one attempt, reuse its question and preserve the saved default")
        var processingContinuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation?
        var processingText = ""
        let processingEngine = ChatEngine { _, _, _ in
            AsyncThrowingStream { processingContinuation = $0 }
        }
        processingEngine.send(endpoint: endpoint, apiKey: nil, messages: [.init(role: .user, content: "Question")],
                              userMessageID: UUID(),
                              budget: RequestBudget(firstResult: 0.03, inactivity: 0.05, overall: 0.4, pollInterval: 0.002),
                              onDelta: { processingText += $0 }, onComplete: { _, _ in })
        try await waitUntil { processingContinuation != nil }
        for _ in 0..<5 {
            processingContinuation?.yield(.processing)
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        expect(processingEngine.isStreaming && processingText.isEmpty,
               "Real processing activity must keep the initial response alive without displaying reasoning")
        processingContinuation?.yield(.text("Only the final answer"))
        processingContinuation?.yield(.completed)
        try await waitUntil { !processingEngine.isStreaming }
        expect(processingEngine.metadata?.phase == .completed && processingText == "Only the final answer",
               "Processing activity must not contaminate the completed answer")

        var boundedProcessingContinuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation?
        let boundedProcessingEngine = ChatEngine { _, _, _ in
            AsyncThrowingStream { boundedProcessingContinuation = $0 }
        }
        boundedProcessingEngine.send(endpoint: endpoint, apiKey: nil, messages: [.init(role: .user, content: "Question")],
                                     userMessageID: UUID(),
                                     budget: RequestBudget(firstResult: 0.1, inactivity: 0.1, overall: 0.05, pollInterval: 0.002),
                                     onDelta: { _ in }, onComplete: { _, _ in })
        try await waitUntil { boundedProcessingContinuation != nil }
        for _ in 0..<8 {
            boundedProcessingContinuation?.yield(.processing)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        expect(!boundedProcessingEngine.isStreaming && boundedProcessingEngine.metadata?.errorCode == "timeout" &&
               boundedProcessingEngine.metadata?.errorMessage?.contains("took too long") == true,
               "Continuous processing must never extend the request's overall deadline")
        var synthesisContinuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation?
        let synthesisSession = ChatSession(engine: ChatEngine { _, _, _ in
            AsyncThrowingStream { synthesisContinuation = $0 }
        })
        let synthesisConversation = Conversation(endpointID: endpoint.id, endpointName: endpoint.name, model: endpoint.model)
        context.insert(synthesisConversation)
        synthesisSession.send(conversation: synthesisConversation, context: context, endpoint: endpoint,
                              apiKey: nil, text: "Give me more", searchEnabled: false)
        try await waitUntil { synthesisContinuation != nil }
        synthesisContinuation?.yield(.text("I'll dig deeper with more targeted searches."))
        synthesisContinuation?.yield(.citation(SourceCitation(url: "https://example.test/unused", title: "Not selected", startIndex: 0, endIndex: 4)))
        try await waitUntil { synthesisSession.streamingContent.contains("dig deeper") }
        let synthesisReply = synthesisConversation.sortedMessages.last!
        let synthesisAttempt = synthesisReply.responseMetadata!.attemptID
        let synthesisUser = synthesisReply.responseMetadata!.userMessageID
        let selectedEvidence = SourceCitation(url: "https://example.test/evidence", title: "Selected evidence", excerpt: "Actual returned page text", startIndex: 0, endIndex: 3)
        synthesisContinuation?.yield(.answerStarted(sources: [selectedEvidence]))
        try await waitUntil { synthesisSession.metadata?.usesSourceSynthesis == true }
        expect(synthesisSession.streamingContent.isEmpty && synthesisReply.content.isEmpty,
               "Starting answer synthesis must clear acquisition narration from both live and stored answer text")
        expect(synthesisReply.responseMetadata?.attemptID == synthesisAttempt &&
               synthesisReply.responseMetadata?.userMessageID == synthesisUser &&
               synthesisConversation.messages.filter { $0.role == .user }.count == 1,
               "Synthesis must retain the same attempt and original question without inserting another user turn")
        expect(synthesisReply.responseMetadata?.citations.map(\.url) == [selectedEvidence.url] &&
               synthesisReply.responseMetadata?.citations.first?.startIndex == nil &&
               synthesisReply.responseMetadata?.citations.first?.endIndex == nil,
               "Synthesis must replace unused sources and discard offsets into old acquisition prose")
        let unreturnedSource = SourceCitation(url: "https://example.test/not-returned", title: "Not returned")
        synthesisContinuation?.yield(.citation(unreturnedSource))
        synthesisContinuation?.yield(.text("A finished answer from the selected sources."))
        synthesisContinuation?.yield(.completed)
        try await waitUntil { !synthesisSession.isStreaming }
        expect(synthesisReply.content == "A finished answer from the selected sources." &&
               synthesisReply.responseMetadata?.phase == .completed &&
               synthesisReply.responseMetadata?.statusText == "Answered from returned sources",
               "Only the genuine synthesis answer may be persisted and labeled completed")
        expect(!synthesisReply.responseMetadata!.citations.contains(where: { $0.url == unreturnedSource.url }),
               "Synthesis annotations must never enlarge the selected evidence URL allowlist")
        let restrictedSynthesisLinks = CitedAnswer.markdown("[Returned](\(selectedEvidence.url)) [Invented](\(unreturnedSource.url))",
                                                          citations: synthesisReply.responseMetadata!.citations,
                                                          restrictLinksToSources: true)
        expect(restrictedSynthesisLinks.contains(selectedEvidence.url) && !restrictedSynthesisLinks.contains(unreturnedSource.url),
               "Unreturned synthesis source URLs must not become clickable citation links")
        let synthesisRoundTrip = try JSONDecoder().decode(ResponseMetadata.self, from: JSONEncoder().encode(synthesisReply.responseMetadata!))
        expect(synthesisRoundTrip.usesSourceSynthesis && synthesisRoundTrip.citations.count == 1,
               "Synthesis provenance must survive companion and backup encoding")
        var legacySynthesisObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(synthesisRoundTrip)) as! [String: Any]
        legacySynthesisObject.removeValue(forKey: "usesSourceSynthesis")
        let legacySynthesis = try JSONDecoder().decode(ResponseMetadata.self, from: JSONSerialization.data(withJSONObject: legacySynthesisObject))
        expect(!legacySynthesis.usesSourceSynthesis,
               "Legacy metadata remains readable without a synthesis flag")

        var boundedSynthesisContinuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation?
        let boundedSynthesisEngine = ChatEngine { _, _, _ in
            AsyncThrowingStream { boundedSynthesisContinuation = $0 }
        }
        boundedSynthesisEngine.send(endpoint: endpoint, apiKey: nil, messages: [.init(role: .user, content: "Question")],
                                   userMessageID: UUID(),
                                   budget: RequestBudget(firstResult: 0.2, inactivity: 0.2, overall: 0.12, pollInterval: 0.002),
                                   onDelta: { _ in }, onComplete: { _, _ in })
        try await waitUntil { boundedSynthesisContinuation != nil }
        boundedSynthesisContinuation?.yield(.processing)
        try await Task.sleep(nanoseconds: 80_000_000)
        boundedSynthesisContinuation?.yield(.answerStarted(sources: [selectedEvidence]))
        for _ in 0..<5 {
            boundedSynthesisContinuation?.yield(.processing)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        expect(!boundedSynthesisEngine.isStreaming && boundedSynthesisEngine.metadata?.usesSourceSynthesis == true &&
               boundedSynthesisEngine.metadata?.errorCode == "timeout",
               "Switching into synthesis must never reset or extend the original overall deadline")
        let draftCoordinator = ChatSessionCoordinator(observeChanges: false)
        let draftID = UUID()
        let originalPresentation = draftCoordinator.session(for: draftID)
        originalPresentation.draft = "Keep this draft while I fold."
        originalPresentation.searchEnabled = true
        let resizedPresentation = draftCoordinator.session(for: draftID)
        expect(resizedPresentation.draft == originalPresentation.draft && resizedPresentation.searchEnabled == true,
               "Recreating a conversation presentation must preserve its unsent draft and search choice")
        let otherDraft = draftCoordinator.session(for: UUID())
        expect(otherDraft.draft.isEmpty && otherDraft.searchEnabled == nil,
               "Another conversation must not inherit a draft or search choice")
        draftCoordinator.remove(conversationID: draftID)
        let reopenedDraft = draftCoordinator.session(for: draftID)
        expect(reopenedDraft.draft.isEmpty && reopenedDraft.searchEnabled == nil,
               "Deleting a conversation must evict its unsent draft and search choice")
        print("Recovery fixtures: \(checks) checks passed")
    }

    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        precondition(condition(), "Fixture did not settle within bounded deadline")
    }
}
