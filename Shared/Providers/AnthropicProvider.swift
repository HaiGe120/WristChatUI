import Foundation

public struct AnthropicProvider: AIProvider {
    public let providerType: AIProviderType
    public init(providerType: AIProviderType = .anthropic) { self.providerType = providerType }

    public func stream(endpoint: EndpointConfig, apiKey: String?, messages: [ChatMessage]) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let session = StreamingHTTP.session()
            let task = Task {
                defer { session.invalidateAndCancel() }
                do {
                    var continuationBlocks: [[String: Any]] = []
                    // Server tools can pause a turn; retain the original blocks, signatures and IDs.
                    // Never turn a paused server exchange into fabricated plain-text messages.
                    for turn in 0..<3 {
                        try Task.checkCancellation()
                        let request = try Self.buildRequest(endpoint: endpoint, apiKey: apiKey, messages: messages, continuationBlocks: continuationBlocks)
                        let (bytes, _) = try await StreamingHTTP.send(request, session: session)
                        var parser = SSEParser()
                        var decoder = AnthropicStreamDecoder()
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            guard let event = parser.feed(line: line) else { continue }
                            for value in try decoder.consume(event) { continuation.yield(value) }
                            if decoder.stopped { break }
                        }
                        if !decoder.stopped, let event = parser.flush() {
                            for value in try decoder.consume(event) { continuation.yield(value) }
                        }
                        guard decoder.stopped else { throw APIError.incompleteStream }
                        if decoder.stopReason == "pause_turn" {
                            guard turn < 2, !decoder.contentBlocks.isEmpty else {
                                throw APIError.server("Server tool continuation limit reached")
                            }
                            continuationBlocks += decoder.contentBlocks
                            continue
                        }
                        guard decoder.completed else { throw APIError.incompleteStream }
                        continuation.finish(); return
                    }
                    throw APIError.incompleteStream
                } catch {
                    let failure = APIError.from(error)
                    continuation.finish(throwing: failure)
                }
            }
            continuation.onTermination = { _ in task.cancel(); session.invalidateAndCancel() }
        }
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

    static func buildRequest(endpoint: EndpointConfig, apiKey: String?, messages: [ChatMessage], continuationBlocks: [[String: Any]] = []) throws -> URLRequest {
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
        if endpoint.searchMode == .auto {
            payload["tools"] = [["type": "web_search_20250305", "name": "web_search", "max_uses": 3]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
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
    public var contentBlocks: [[String: Any]] { blocks.keys.sorted().compactMap { blocks[$0] } }
    public init() {}

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
                if block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty { out.append(.text(text)) }
                if block["type"] as? String == "server_tool_use", block["name"] as? String == "web_search" { startSearch(to: &out) }
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
                    if !text.isEmpty { out.append(.text(text)) }
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
                let prior = blocks[index]?["thinking"] as? String ?? ""
                blocks[index, default: [:]]["thinking"] = prior + (delta["thinking"] as? String ?? "")
            case "signature_delta":
                let prior = blocks[index]?["signature"] as? String ?? ""
                blocks[index, default: [:]]["signature"] = prior + (delta["signature"] as? String ?? "")
            default: break
            }
        case "content_block_stop":
            if let json = inputJSON.removeValue(forKey: index), let data = json.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) {
                blocks[index, default: [:]]["input"] = value
            }
        case "message_delta":
            if let delta = obj["delta"] as? [String: Any] { stopReason = delta["stop_reason"] as? String }
        case "message_stop":
            stopped = true
            if stopReason == "pause_turn" { break }
            guard let reason = stopReason else { throw APIError.incompleteStream }
            if reason == "max_tokens" { throw APIError.incompleteStream }
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
            if ["unsupported_tool", "tool_not_supported"].contains(code) {
                throw APIError.unsupportedTool("Live search is unavailable for this connection and model.")
            }
            if code == "too_many_requests" { throw APIError.quota }
            throw APIError.server("Live search failed")
        }
        guard let results = block["content"] as? [[String: Any]] else { throw APIError.decoding("Search result") }
        for result in results { appendCitation(result, to: &out) }
        out.append(.searchActivity(.completed))
    }
    private mutating func appendCitation(_ value: [String: Any], to out: inout [ProviderStreamEvent]) {
        guard let url = value["url"] as? String else { return }
        let citation = SourceCitation(url: url, title: value["title"] as? String ?? URL(string: url)?.host ?? url,
                                      excerpt: value["cited_text"] as? String)
        guard citation.safeURL != nil, citationIDs.insert(citation.id).inserted else { return }
        out.append(.citation(citation))
    }
}
