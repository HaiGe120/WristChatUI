import Foundation

public struct OpenAIProvider: AIProvider {
    public let providerType: AIProviderType
    public init(providerType: AIProviderType) { self.providerType = providerType }

    public func stream(endpoint: EndpointConfig, apiKey: String?, messages: [ChatMessage]) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let session = StreamingHTTP.session(allowsSameOriginRedirects: endpoint.authentication != .chatGPT)
            let task = Task {
                defer { session.invalidateAndCancel() }
                do {
                    try Task.checkCancellation()
                    let request = try Self.buildRequest(endpoint: endpoint, apiKey: apiKey, messages: messages, stream: true)
                    let (bytes, _) = try await StreamingHTTP.send(request, session: session)
                    var parser = SSEParser()
                    var decoder = OpenAIStreamDecoder(format: endpoint.apiFormat)
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let event = parser.feed(line: line) else { continue }
                        for value in try decoder.consume(event) {
                            continuation.yield(value)
                        }
                        if decoder.completed { continuation.finish(); return }
                    }
                    if let event = parser.flush() {
                        for value in try decoder.consume(event) {
                            continuation.yield(value)
                        }
                    }
                    guard decoder.completed else { throw APIError.incompleteStream }
                    continuation.finish()
                } catch {
                    let failure = APIError.from(error)
                    continuation.finish(throwing: failure)
                }
            }
            continuation.onTermination = { _ in task.cancel(); session.invalidateAndCancel() }
        }
    }

    public func listModels(endpoint: EndpointConfig, apiKey: String?) async throws -> [String] {
        let request = try Self.buildModelsRequest(endpoint: endpoint, apiKey: apiKey)
        let session = StreamingHTTP.session(allowsSameOriginRedirects: endpoint.authentication != .chatGPT)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("Non-HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.response(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.decodeModels(data)
    }

    static func decodeModels(_ data: Data) throws -> [String] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.decoding("models") }
        for key in ["data", "models"] {
            if let arr = obj[key] as? [[String: Any]] {
                return arr.compactMap { $0["id"] as? String ?? $0["slug"] as? String ?? $0["name"] as? String }.sorted()
            }
        }
        return []
    }

    static func buildRequest(endpoint: EndpointConfig, apiKey: String?, messages: [ChatMessage], stream: Bool) throws -> URLRequest {
        guard let url = endpoint.chatCompletionsURL() else { throw APIError.invalidURL(endpoint.baseURLString) }
        try validateAuthenticationDestination(endpoint: endpoint, url: url)
        if endpoint.searchMode == .auto && !endpoint.canUseNativeSearch {
            throw APIError.unsupportedTool("Native search has not been verified for this Chat Completions connection. Choose another search source or turn search off.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyHeaders(endpoint: endpoint, key: apiKey, request: &request)
        let system = ([endpoint.systemPrompt] + messages.filter { $0.role == .system }.map(\.content))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        let history = messages.filter { $0.role != .system && !$0.content.isEmpty }
            .map { ["role": $0.role.rawValue, "content": $0.content] }
        var payload: [String: Any] = ["model": endpoint.model, "stream": stream]
        if endpoint.apiFormat == .responses {
            payload["input"] = history
            if !system.isEmpty { payload["instructions"] = system }
            if endpoint.authentication == .chatGPT {
                // The public ChatGPT token-sharing inference contract requires streaming and no storage.
                payload["stream"] = true; payload["store"] = false
            } else {
                payload["temperature"] = endpoint.temperature
                if let limit = endpoint.maxTokens { payload["max_output_tokens"] = limit }
            }
            if endpoint.searchMode == .auto {
                payload["tools"] = [["type": "web_search"]]
                payload["include"] = ["web_search_call.action.sources"]
            }
        } else {
            var chat = history
            if !system.isEmpty { chat.insert(["role": "system", "content": system], at: 0) }
            payload["messages"] = chat
            payload["temperature"] = endpoint.temperature
            if let limit = endpoint.maxTokens { payload["max_tokens"] = limit }
            if endpoint.searchMode == .auto { payload["web_search_options"] = [String: String]() }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    static func buildModelsRequest(endpoint: EndpointConfig, apiKey: String?) throws -> URLRequest {
        guard let url = endpoint.modelsURL() else { throw APIError.invalidURL(endpoint.baseURLString) }
        try validateAuthenticationDestination(endpoint: endpoint, url: url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyHeaders(endpoint: endpoint, key: apiKey, request: &request)
        return request
    }

    private static func validateAuthenticationDestination(endpoint: EndpointConfig, url: URL) throws {
        if endpoint.authentication == .chatGPT {
            // OAuth credentials require the dedicated verified account/session path.
            // Ordinary endpoint API-key requests must never be repurposed as that path.
            throw APIError.oauthUnavailable
        }
    }
    private static func applyHeaders(endpoint: EndpointConfig, key: String?, request: inout URLRequest) {
        if endpoint.authentication != .chatGPT {
            for (name, value) in endpoint.customHeaders { request.setValue(value, forHTTPHeaderField: name) }
        }
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    }
}

/// Stateful decoding prevents Responses final snapshots from replaying already delivered deltas.
public struct OpenAIStreamDecoder {
    public let format: APIFormat
    public private(set) var completed = false
    private var textByPart: [String: String] = [:]
    private var partStarts: [String: Int] = [:]
    private var outputCount = 0
    private var citationIDs: Set<String> = []
    private var searchStarted = false
    public init(format: APIFormat) { self.format = format }

    public mutating func consume(_ event: SSEEvent) throws -> [ProviderStreamEvent] {
        guard !completed else { return [] }
        if event.data == "[DONE]" {
            guard format == .chatCompletions else { throw APIError.incompleteStream }
            completed = true; return [.completed]
        }
        if event.data.isEmpty { return [] }
        guard let data = event.data.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decoding("Malformed stream event")
        }
        if obj["error"] != nil || obj["type"] as? String == "error" || event.event == "error" {
            throw Self.streamError(obj)
        }
        return try format == .responses ? responses(obj) : chat(obj)
    }

    private mutating func responses(_ obj: [String: Any]) throws -> [ProviderStreamEvent] {
        var out: [ProviderStreamEvent] = []
        let type = obj["type"] as? String ?? ""
        let oi = obj["output_index"] as? Int ?? 0
        let ci = obj["content_index"] as? Int ?? 0
        let key = "\(oi):\(ci)"
        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            if let delta = obj["delta"] as? String, !delta.isEmpty {
                if partStarts[key] == nil { partStarts[key] = outputCount }
                textByPart[key, default: ""] += delta; outputCount += delta.utf16.count; out.append(.text(delta))
            }
        case "response.output_text.done", "response.refusal.done":
            appendFinal(obj["text"] as? String ?? obj["refusal"] as? String, key: key, to: &out)
        case "response.output_text.annotation.added":
            if let annotation = obj["annotation"] as? [String: Any] { appendCitation(annotation, baseOffset: partStarts[key], to: &out) }
        case "response.web_search_call.in_progress", "response.web_search_call.searching":
            startSearch(to: &out)
        case "response.web_search_call.failed": throw APIError.server("Live search failed")
        case "response.web_search_call.completed":
            startSearch(to: &out); out.append(.searchActivity(.completed))
        case "response.output_item.added", "response.output_item.done":
            if let item = obj["item"] as? [String: Any] { try consumeItem(item, index: oi, final: type.hasSuffix("done"), to: &out) }
        case "response.completed":
            let response = obj["response"] as? [String: Any] ?? obj
            guard response["status"] as? String == nil || response["status"] as? String == "completed" else { throw APIError.incompleteStream }
            if let items = response["output"] as? [[String: Any]] {
                for (index, item) in items.enumerated() { try consumeItem(item, index: index, final: true, to: &out) }
            }
            completed = true; out.append(.completed)
        case "response.failed":
            throw Self.streamError(obj["response"] as? [String: Any] ?? obj)
        case "response.incomplete", "response.cancelled": throw APIError.incompleteStream
        default: break
        }
        return out
    }

    private mutating func consumeItem(_ item: [String: Any], index: Int, final: Bool, to out: inout [ProviderStreamEvent]) throws {
        if item["type"] as? String == "web_search_call" {
            if ["failed", "incomplete"].contains(item["status"] as? String ?? "") || item["error"] != nil
                || (final && item["status"] as? String != "completed") {
                throw APIError.server("Live search failed")
            }
            startSearch(to: &out)
            if item["status"] as? String == "completed" { out.append(.searchActivity(.completed)) }
            if let action = item["action"] as? [String: Any], let sources = action["sources"] as? [[String: Any]] {
                for source in sources { appendCitation(source, to: &out) }
            }
        }
        guard let parts = item["content"] as? [[String: Any]] else { return }
        for (ci, part) in parts.enumerated() {
            if final { appendFinal(part["text"] as? String ?? part["refusal"] as? String, key: "\(index):\(ci)", to: &out) }
            for annotation in part["annotations"] as? [[String: Any]] ?? [] { appendCitation(annotation, baseOffset: partStarts["\(index):\(ci)"], to: &out) }
        }
    }

    private mutating func appendFinal(_ text: String?, key: String, to out: inout [ProviderStreamEvent]) {
        guard let text, !text.isEmpty else { return }
        let delivered = textByPart[key] ?? ""
        if text.hasPrefix(delivered) {
            let suffix = String(text.dropFirst(delivered.count))
            if !suffix.isEmpty {
                if partStarts[key] == nil { partStarts[key] = outputCount }
                outputCount += suffix.utf16.count; out.append(.text(suffix))
            }
        }
        // A differing snapshot must not corrupt an answer already emitted to the UI.
        textByPart[key] = text
    }

    private mutating func chat(_ obj: [String: Any]) throws -> [ProviderStreamEvent] {
        var out: [ProviderStreamEvent] = []
        guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first else { return [] }
        let part = first["delta"] as? [String: Any] ?? first["message"] as? [String: Any] ?? [:]
        if let text = part["content"] as? String, !text.isEmpty {
            if first["delta"] != nil { textByPart["chat", default: ""] += text; out.append(.text(text)) }
            else { appendFinal(text, key: "chat", to: &out) }
        }
        for annotation in part["annotations"] as? [[String: Any]] ?? [] { appendCitation(annotation, baseOffset: 0, to: &out) }
        if let reason = first["finish_reason"] as? String {
            if reason == "length" { throw APIError.incompleteStream }
            if reason == "tool_calls" || reason == "function_call" { throw APIError.unsupportedInteraction("This response requires a tool that has not been configured.") }
            completed = true; out.append(.completed)
        }
        return out
    }

    private mutating func appendCitation(_ value: [String: Any], baseOffset: Int? = nil, to out: inout [ProviderStreamEvent]) {
        let value = value["url_citation"] as? [String: Any] ?? value
        guard let url = value["url"] as? String else { return }
        let citation = SourceCitation(url: url, title: value["title"] as? String ?? URL(string: url)?.host ?? url,
                                      excerpt: value["cited_text"] as? String,
                                      startIndex: baseOffset.flatMap { start in (value["start_index"] as? Int).map { start + $0 } },
                                      endIndex: baseOffset.flatMap { start in (value["end_index"] as? Int).map { start + $0 } })
        guard citation.safeURL != nil, citationIDs.insert(citation.id).inserted else { return }
        out.append(.citation(citation))
    }
    private mutating func startSearch(to out: inout [ProviderStreamEvent]) {
        if !searchStarted { searchStarted = true; out.append(.searchActivity(.searching)) }
    }
    static func streamError(_ obj: [String: Any]) -> APIError {
        let error = obj["error"] as? [String: Any] ?? obj
        let code = (error["code"] as? String ?? error["type"] as? String ?? "").lowercased()
        if code.contains("auth") || code.contains("invalid_api_key") { return .authentication }
        if code.contains("rate_limit") || code.contains("quota") { return .quota }
        let body = (try? JSONSerialization.data(withJSONObject: ["error": error])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if case .unsupportedTool(let text) = APIError.response(status: 400, body: body) { return .unsupportedTool(text) }
        return .server("Stream error")
    }
}
