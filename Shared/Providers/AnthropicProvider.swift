import Foundation

public struct AnthropicProvider: AIProvider {
    public let providerType: AIProviderType
    private let makeSession: @Sendable () -> URLSession
    private let acquisitionTimeout: TimeInterval
    private let acquisitionIdleTimeout: TimeInterval
    public init(providerType: AIProviderType = .anthropic) {
        self.providerType = providerType
        makeSession = { StreamingHTTP.session() }
        acquisitionTimeout = NativeSearchAcquisitionPolicy.maximumDuration
        acquisitionIdleTimeout = 45
    }
    init(providerType: AIProviderType = .anthropic, sessionFactory: @escaping @Sendable () -> URLSession,
         acquisitionTimeout: TimeInterval = NativeSearchAcquisitionPolicy.maximumDuration,
         acquisitionIdleTimeout: TimeInterval = 45) {
        self.providerType = providerType
        makeSession = sessionFactory
        self.acquisitionTimeout = acquisitionTimeout
        self.acquisitionIdleTimeout = acquisitionIdleTimeout
    }

    public func stream(endpoint: EndpointConfig, apiKey: String?, messages: [ChatMessage]) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let session = makeSession()
            let task = Task {
                let watchdog = endpoint.searchMode == .auto ? NativeSearchAcquisitionWatchdog(session: session,
                    maximumDuration: acquisitionTimeout, idleDuration: acquisitionIdleTimeout) : nil
                defer { watchdog?.stop(); session.invalidateAndCancel() }
                do {
                    var exchange = AnthropicContinuationState()
                    var acquisition = NativeSearchAcquisitionPolicy()
                    var displayedTextSuffix: String?
                    var synthesis: NativeSearchSynthesis?
                    var collectedBlocks: [[String: Any]] = []
                    var hasReadableEvidence = false
                    var progressCitationIDs: Set<String> = []
                    func recordAcquisition(_ decoder: AnthropicStreamDecoder, values: [ProviderStreamEvent]) {
                        collectedBlocks = exchange.contentBlocks + decoder.contentBlocks
                        if !hasReadableEvidence,
                           values.contains(where: { if case .citation = $0 { return true }; return false }) || decoder.contentBlocks.contains(where: { ($0["citations"] as? [[String: Any]])?.isEmpty == false }) {
                            hasReadableEvidence = (try? NativeSearchSynthesis(endpoint: endpoint, messages: messages, blocks: collectedBlocks)) != nil
                        }
                        var useful = false
                        for value in values {
                            switch value {
                            case .processing: useful = true
                            case .text(let text): useful = useful || !text.isEmpty
                            case .searchActivity: useful = true
                            case .citation(let source): useful = progressCitationIDs.insert(source.id).inserted || useful
                            case .completed, .answerStarted: break
                            }
                        }
                        watchdog?.progress(hasReadableEvidence: hasReadableEvidence, useful: useful)
                    }
                    // Server tools can pause a turn; retain the original blocks, signatures and IDs.
                    // Never turn a paused server exchange into fabricated plain-text messages.
                    do {
                    acquisitionLoop: while true {
                        try Task.checkCancellation()
                        collectedBlocks = exchange.contentBlocks
                        let request = try Self.buildRequest(endpoint: endpoint, apiKey: apiKey, messages: messages,
                                                            continuationBlocks: exchange.contentBlocks)
                        let (bytes, _) = try await StreamingHTTP.send(request, session: session)
                        var parser = SSEParser()
                        var decoder = AnthropicStreamDecoder(priorTextSuffix: displayedTextSuffix)
                        do {
                            for try await line in bytes.lines {
                                try Task.checkCancellation()
                                if let event = parser.feed(line: line) {
                                    let values = try decoder.consume(event)
                                    recordAcquisition(decoder, values: values)
                                    try exchange.observe(decoder)
                                    for value in values {
                                        if case .text(let text) = value {
                                            displayedTextSuffix = String(((displayedTextSuffix ?? "") + text).suffix(2))
                                        }
                                        continuation.yield(value)
                                    }
                                    if decoder.stopped { break }
                                }
                                if endpoint.searchMode == .auto, acquisition.acquisitionExpired {
                                    synthesis = try NativeSearchSynthesis(endpoint: endpoint, messages: messages,
                                        blocks: exchange.contentBlocks + decoder.contentBlocks)
                                    break acquisitionLoop
                                }
                            }
                            if !decoder.stopped, let event = parser.flush() {
                                let values = try decoder.consume(event)
                                recordAcquisition(decoder, values: values)
                                try exchange.observe(decoder)
                                for value in values {
                                    if case .text(let text) = value {
                                        displayedTextSuffix = String(((displayedTextSuffix ?? "") + text).suffix(2))
                                    }
                                    continuation.yield(value)
                                }
                            }
                            if endpoint.searchMode == .auto, !decoder.completed, acquisition.acquisitionExpired {
                                synthesis = try NativeSearchSynthesis(endpoint: endpoint, messages: messages,
                                    blocks: exchange.contentBlocks + decoder.contentBlocks)
                                break acquisitionLoop
                            }
                            if try exchange.continueAfter(decoder) { continue }
                            continuation.finish(); return
                        } catch let failure as APIError where endpoint.searchMode == .auto && Self.isAcquisitionLimit(failure) {
                            if case .outputLimitReached = failure {
                                guard let plan = try? NativeSearchSynthesis(endpoint: endpoint, messages: messages,
                                    blocks: exchange.contentBlocks + decoder.contentBlocks) else { throw failure }
                                synthesis = plan
                            } else {
                                synthesis = try NativeSearchSynthesis(endpoint: endpoint, messages: messages,
                                    blocks: exchange.contentBlocks + decoder.contentBlocks)
                            }
                            break acquisitionLoop
                        }
                    }
                    } catch {
                        guard !Task.isCancelled, watchdog?.didExpire == true else { throw error }
                        synthesis = try NativeSearchSynthesis(endpoint: endpoint, messages: messages, blocks: collectedBlocks)
                    }
                    watchdog?.stop()
                    guard let synthesis else { throw APIError.incompleteStream }
                    try acquisition.beginSynthesis()
                    // End the abandoned SSE request before creating its single answer-only request.
                    session.invalidateAndCancel()
                    try await streamSynthesis(synthesis, apiKey: apiKey, continuation: continuation)
                    continuation.finish()
                } catch {
                    let failure = APIError.from(error)
                    continuation.finish(throwing: failure)
                }
            }
            continuation.onTermination = { _ in task.cancel(); session.invalidateAndCancel() }
        }
    }

    private static func isAcquisitionLimit(_ error: APIError) -> Bool {
        switch error {
        case .searchLimitReached, .continuationLimitReached, .outputLimitReached: return true
        default: return false
        }
    }

    private func streamSynthesis(_ plan: NativeSearchSynthesis, apiKey: String?,
                                 continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation) async throws {
        try Task.checkCancellation()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        try await withTaskCancellationHandler(operation: {
        let request = try Self.buildRequest(endpoint: plan.endpoint, apiKey: apiKey,
            messages: plan.messages, synthesis: true)
        let (bytes, _) = try await StreamingHTTP.send(request, session: session)
        try Task.checkCancellation()
        continuation.yield(.answerStarted(sources: plan.citations))
        var parser = SSEParser()
        var decoder = AnthropicStreamDecoder()
        var hasAnswerText = false
        let evidenceURLs = Set(plan.references.map(\.url))
        func forward(_ values: [ProviderStreamEvent]) throws {
            guard !decoder.contentBlocks.contains(where: {
                ["server_tool_use", "tool_use", "web_search_tool_result"].contains($0["type"] as? String ?? "")
            }) else { throw APIError.unsupportedInteraction("The answer-only request unexpectedly tried to use a tool.") }
            for value in values {
                if case .citation(let source) = value, !evidenceURLs.contains(source.url) { continue }
                if case .text(let text) = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hasAnswerText = true
                }
                if case .completed = value, !hasAnswerText { throw APIError.emptyResponse }
                continuation.yield(value)
            }
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = parser.feed(line: line) else { continue }
            try forward(decoder.consume(event))
            if decoder.stopped { break }
        }
        if !decoder.stopped, let event = parser.flush() { try forward(decoder.consume(event)) }
        guard decoder.completed else {
            if decoder.stopReason == "pause_turn" { throw APIError.continuationLimitReached }
            throw APIError.incompleteStream
        }
        }, onCancel: { session.invalidateAndCancel() })
    }

    public func listModels(endpoint: EndpointConfig, apiKey: String?) async throws -> [String] {
        guard let url = endpoint.modelsURL() else { throw APIError.invalidURL(endpoint.baseURLString) }
        guard endpoint.authentication != .chatGPT else { throw APIError.authentication }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        for (name, value) in endpoint.customHeaders { request.setValue(value, forHTTPHeaderField: name) }
        if let key = apiKey, !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        let session = StreamingHTTP.session()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("Non-HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.response(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try OpenAIProvider.decodeModels(data)
    }

    public static let defaultModelSuggestions = ["claude-3-5-sonnet-latest", "claude-3-5-haiku-latest"]

    static func buildRequest(endpoint: EndpointConfig, apiKey: String?, messages: [ChatMessage],
                             continuationBlocks: [[String: Any]] = [], synthesis: Bool = false) throws -> URLRequest {
        guard let url = endpoint.chatCompletionsURL() else { throw APIError.invalidURL(endpoint.baseURLString) }
        guard endpoint.authentication != .chatGPT else { throw APIError.authentication }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        for (name, value) in endpoint.customHeaders { request.setValue(value, forHTTPHeaderField: name) }
        if let key = apiKey, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
        var history: [[String: Any]] = []
        for message in messages where message.role != .system && !message.content.isEmpty {
            let role = message.role.rawValue
            // Anthropic merges adjacent same-role text turns; do it explicitly without invented replies.
            if let last = history.last, last["role"] as? String == role, let text = last["content"] as? String {
                history[history.count - 1]["content"] = text + "\n\n" + message.content
            } else { history.append(["role": role, "content": message.content]) }
        }
        if !continuationBlocks.isEmpty { history.append(["role": "assistant", "content": continuationBlocks]) }
        let system = ([endpoint.systemPrompt] + messages.filter { $0.role == .system }.map(\.content))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        var payload: [String: Any] = ["model": endpoint.model, "messages": history,
                                      "max_tokens": endpoint.maxTokens ?? 2048, "temperature": endpoint.temperature, "stream": true]
        if !system.isEmpty { payload["system"] = system }
        if synthesis, NativeSearchSynthesis.usesLowEffort(endpoint: endpoint) {
            payload["output_config"] = ["effort": "low"]
        }
        if endpoint.searchMode == .auto {
            let remaining = AnthropicContinuationState.maximumSearchUses - AnthropicContinuationState.searchUseIDs(in: continuationBlocks).count
            // MiniMax's Anthropic-compatible API documents only tool_choice:auto. It does
            // not establish max_uses:0 or tool_choice:none as a valid finalization request.
            guard remaining > 0 else { throw APIError.searchLimitReached }
            payload["tools"] = [["type": "web_search_20250305", "name": "web_search", "max_uses": remaining]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }
}

/// `max_uses` is a per-request server limit. Carry a single search budget across paused
/// responses instead of silently granting three fresh searches on every continuation.
struct AnthropicContinuationState {
    static let maximumSearchUses = 3
    static let maximumResponses = 8
    private(set) var contentBlocks: [[String: Any]] = []
    private(set) var responseCount = 0
    private var searchIDs: Set<String> = []
    private var deniedSearchIDs: Set<String> = []
    private var finishedSearchIDs: Set<String> = []

    var remainingSearchUses: Int { max(0, Self.maximumSearchUses - searchIDs.subtracting(deniedSearchIDs).count) }

    mutating func observe(_ decoder: AnthropicStreamDecoder) throws {
        searchIDs.formUnion(decoder.searchToolUseIDs)
        deniedSearchIDs.formUnion(decoder.deniedSearchToolUseIDs)
        finishedSearchIDs.formUnion(decoder.finishedSearchToolUseIDs)
        // A denied fourth attempt is a control result the model can use to finish. Wait
        // for the result before deciding that an extra server call actually ran.
        if finishedSearchIDs.subtracting(deniedSearchIDs).count > Self.maximumSearchUses {
            throw APIError.searchLimitReached
        }
        if decoder.stopped, searchIDs.subtracting(deniedSearchIDs).count > Self.maximumSearchUses {
            throw APIError.searchLimitReached
        }
    }

    mutating func continueAfter(_ decoder: AnthropicStreamDecoder) throws -> Bool {
        guard decoder.stopped else { throw APIError.incompleteStream }
        try observe(decoder)
        responseCount += 1
        guard searchIDs.subtracting(deniedSearchIDs).count <= Self.maximumSearchUses else {
            throw APIError.searchLimitReached
        }
        if decoder.stopReason == "pause_turn" {
            guard !decoder.contentBlocks.isEmpty else { throw APIError.continuationLimitReached }
            guard remainingSearchUses > 0 else { throw APIError.searchLimitReached }
            guard responseCount < Self.maximumResponses else { throw APIError.continuationLimitReached }
            contentBlocks += decoder.contentBlocks
            return true
        }
        guard decoder.completed else { throw APIError.incompleteStream }
        return false
    }

    static func searchUseIDs(in blocks: [[String: Any]]) -> Set<String> {
        let used = Set(blocks.compactMap { block -> String? in
            guard block["type"] as? String == "server_tool_use", block["name"] as? String == "web_search" else { return nil }
            return block["id"] as? String
        })
        let denied = Set(blocks.compactMap { block -> String? in
            guard block["type"] as? String == "web_search_tool_result",
                  let error = block["content"] as? [String: Any],
                  error["error_code"] as? String == "max_uses_exceeded" else { return nil }
            return block["tool_use_id"] as? String
        })
        return used.subtracting(denied)
    }
}

public struct AnthropicStreamDecoder {
    public private(set) var stopped = false
    public private(set) var completed = false
    public private(set) var stopReason: String?
    private var blocks: [Int: [String: Any]] = [:]
    private var inputJSON: [Int: String] = [:]
    private var citationIDs: Set<String> = []
    private var searchStarted = false
    public private(set) var searchToolUseIDs: Set<String> = []
    public private(set) var deniedSearchToolUseIDs: Set<String> = []
    public private(set) var finishedSearchToolUseIDs: Set<String> = []
    private var lastTextBlockIndex: Int?
    private var displayedTextSuffix: String
    public var contentBlocks: [[String: Any]] { blocks.keys.sorted().compactMap { blocks[$0] } }
    public init(priorTextSuffix: String? = nil) {
        lastTextBlockIndex = priorTextSuffix == nil ? nil : -1
        displayedTextSuffix = priorTextSuffix ?? ""
    }

    public mutating func consume(_ event: SSEEvent) throws -> [ProviderStreamEvent] {
        guard !stopped, !event.data.isEmpty else { return [] }
        guard let data = event.data.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decoding("Malformed stream event")
        }
        let type = obj["type"] as? String ?? event.event ?? ""
        let index = obj["index"] as? Int ?? 0
        var out: [ProviderStreamEvent] = []
        switch type {
        case "error": throw OpenAIStreamDecoder.streamError(obj)
        case "content_block_start":
            if let block = obj["content_block"] as? [String: Any] {
                blocks[index] = block
                if block["type"] as? String == "text", let text = block["text"] as? String { appendText(text, index: index, to: &out) }
                if block["type"] as? String == "server_tool_use", block["name"] as? String == "web_search" {
                    guard let id = block["id"] as? String, !id.isEmpty else { throw APIError.decoding("Missing server search identifier") }
                    searchToolUseIDs.insert(id)
                    startSearch(to: &out)
                }
                if block["type"] as? String == "web_search_tool_result" { try searchResult(block, to: &out) }
                for citation in block["citations"] as? [[String: Any]] ?? [] { appendCitation(citation, to: &out) }
            }
        case "content_block_delta":
            guard let delta = obj["delta"] as? [String: Any] else { break }
            switch delta["type"] as? String {
            case "text_delta":
                if let text = delta["text"] as? String {
                    let prior = blocks[index]?["text"] as? String ?? ""
                    blocks[index, default: ["type": "text"]]["text"] = prior + text
                    appendText(text, index: index, to: &out)
                }
            case "input_json_delta":
                inputJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
            case "citations_delta":
                if let citation = delta["citation"] as? [String: Any] {
                    var citations = blocks[index]?["citations"] as? [[String: Any]] ?? []
                    citations.append(citation); blocks[index, default: [:]]["citations"] = citations
                    appendCitation(citation, to: &out)
                }
            case "thinking_delta":
                let thinking = delta["thinking"] as? String ?? ""
                let prior = blocks[index]?["thinking"] as? String ?? ""
                blocks[index, default: [:]]["thinking"] = prior + thinking
                if !thinking.isEmpty { out.append(.processing) }
            case "signature_delta":
                let prior = blocks[index]?["signature"] as? String ?? ""
                blocks[index, default: [:]]["signature"] = prior + (delta["signature"] as? String ?? "")
            default: break
            }
        case "content_block_stop":
            if let json = inputJSON.removeValue(forKey: index) {
                guard let data = json.data(using: .utf8),
                      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw APIError.decoding("Malformed server tool input")
                }
                blocks[index, default: [:]]["input"] = value
            }
        case "message_delta":
            if let delta = obj["delta"] as? [String: Any] { stopReason = delta["stop_reason"] as? String }
        case "message_stop":
            stopped = true
            if stopReason == "pause_turn" { break }
            guard let reason = stopReason else { throw APIError.incompleteStream }
            if reason == "max_tokens" { throw APIError.outputLimitReached }
            if reason == "model_context_window_exceeded" { throw APIError.contextLimitReached }
            if reason == "tool_use" { throw APIError.unsupportedInteraction("This response requires an unconfigured client tool.") }
            guard ["end_turn", "stop_sequence", "refusal"].contains(reason) else { throw APIError.incompleteStream }
            completed = true; out.append(.completed)
        default: break
        }
        return out
    }

    private mutating func startSearch(to out: inout [ProviderStreamEvent]) {
        if !searchStarted { searchStarted = true; out.append(.searchActivity(.searching)) }
    }
    private mutating func searchResult(_ block: [String: Any], to out: inout [ProviderStreamEvent]) throws {
        startSearch(to: &out)
        if let error = block["content"] as? [String: Any], error["type"] as? String == "web_search_tool_result_error" {
            let code = error["error_code"] as? String ?? ""
            if code == "max_uses_exceeded" {
                if let id = block["tool_use_id"] as? String { deniedSearchToolUseIDs.insert(id) }
                out.append(.searchActivity(.limitReached))
                return
            }
            if ["unsupported_tool", "tool_not_supported"].contains(code) {
                throw APIError.unsupportedTool("Live search is unavailable for this connection and model.")
            }
            if code == "too_many_requests" { throw APIError.quota }
            throw APIError.server("Live search failed")
        }
        guard let results = block["content"] as? [[String: Any]] else { throw APIError.decoding("Search result") }
        if let id = block["tool_use_id"] as? String { finishedSearchToolUseIDs.insert(id) }
        for result in results { appendCitation(result, to: &out) }
        out.append(.searchActivity(.completed))
    }
    private mutating func appendText(_ text: String, index: Int, to out: inout [ProviderStreamEvent]) {
        guard !text.isEmpty else { return }
        if let previous = lastTextBlockIndex, previous != index {
            let trailing = displayedTextSuffix.reversed().prefix(while: { $0 == "\n" }).count
            let leading = text.prefix(while: { $0 == "\n" }).count
            let separator = String(repeating: "\n", count: max(0, 2 - trailing - leading))
            if !separator.isEmpty {
                out.append(.text(separator))
                displayedTextSuffix = String((displayedTextSuffix + separator).suffix(2))
            }
        }
        out.append(.text(text))
        displayedTextSuffix = String((displayedTextSuffix + text).suffix(2))
        lastTextBlockIndex = index
    }
    private mutating func appendCitation(_ value: [String: Any], to out: inout [ProviderStreamEvent]) {
        guard let url = value["url"] as? String else { return }
        let citation = SourceCitation(url: url, title: value["title"] as? String ?? URL(string: url)?.host ?? url,
                                      excerpt: (value["cited_text"] as? String ?? value["content"] as? String).map {
                                          String(String.UnicodeScalarView($0.unicodeScalars.prefix(200)))
                                      })
        guard citation.safeURL != nil, citationIDs.insert(citation.id).inserted else { return }
        out.append(.citation(citation))
    }
}
