import Foundation

var checks = 0
func check(_ condition: Bool, _ description: String) {
    checks += 1
    guard condition else { fatalError("Fixture failed: \(description)") }
}
func event(_ object: [String: Any], type: String? = nil) -> SSEEvent {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return SSEEvent(event: type, data: String(data: data, encoding: .utf8)!, id: nil)
}
func texts(_ events: [ProviderStreamEvent]) -> String {
    events.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined()
}
func citations(_ events: [ProviderStreamEvent]) -> [SourceCitation] {
    events.compactMap { if case .citation(let source) = $0 { return source }; return nil }
}
func body(_ request: URLRequest) -> [String: Any] { try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any] }
func mustFail(_ description: String, _ block: () throws -> Void) {
    do { try block(); fatalError("Fixture should fail: \(description)") } catch { checks += 1 }
}

let id = UUID()
let old: [String: Any] = ["id": id.uuidString, "name": "Old gateway", "providerType": "openAICompatible", "baseURLString": "https://gateway.example/proxy/v1/responses", "model": "model", "systemPrompt": "", "temperature": 0.3, "customHeaders": [:]]
let migrated = try JSONDecoder().decode(EndpointConfig.self, from: JSONSerialization.data(withJSONObject: old))
check(migrated.id == id && migrated.apiFormat == .responses && migrated.authentication == .apiKey && migrated.searchMode == .off, "legacy endpoint defaults without identity change")
for format in APIFormat.allCases {
    var value = migrated; value.apiFormat = format
    check(value.chatCompletionsURL()?.path == "/proxy/v1/" + format.suffix, "format switch preserves proxy prefix and /v1")
    check(value.modelsURL()?.path == "/proxy/v1/models", "models path strips old operation")
}
var full = migrated; full.baseURLString = "https://gateway.example/proxy/responses?deployment=test"
check(full.chatCompletionsURL()?.absoluteString == full.baseURLString, "full URL without /v1 remains exact")
full.baseURLString = "https://gateway.example/proxy/v1"
full.apiFormat = .anthropicMessages
check(full.chatCompletionsURL()?.path == "/proxy/v1/messages", "Messages /v1 root no duplication")
var customRoot = old
customRoot["baseURLString"] = "https://gateway.example/proxy"
let legacyRoot = try JSONDecoder().decode(EndpointConfig.self, from: JSONSerialization.data(withJSONObject: customRoot))
check(legacyRoot.chatCompletionsURL()?.path == "/proxy/chat/completions", "legacy custom Chat Completions root remains compatible")
let roundTrip = try JSONDecoder().decode(EndpointConfig.self, from: JSONEncoder().encode(migrated))
check(roundTrip.id == migrated.id && roundTrip.apiFormat == migrated.apiFormat && roundTrip.baseURLString == migrated.baseURLString, "new endpoint round-trip")
check(!migrated.hasExtendedConfiguration && roundTrip.hasExtendedConfiguration, "persisted migration adds version marker; legacy wire provenance remains visible")

var modernRoot = EndpointConfig(id: id, name: "New", providerType: .openAICompatible, baseURLString: "https://gateway.example/proxy", model: "current", apiFormat: .responses, authentication: .chatGPT, searchMode: .auto, chatSearchVerified: true)
let preserved = legacyRoot.preservingExtendedConfiguration(from: modernRoot)
check(preserved.name == legacyRoot.name && preserved.model == legacyRoot.model, "legacy common fields remain editable")
check(preserved.apiFormat == .responses && preserved.authentication == .chatGPT && preserved.searchMode == .auto && preserved.chatSearchVerified, "legacy snapshots cannot erase extended account/search/format fields")
check(preserved.chatCompletionsURL()?.path == "/proxy/v1/responses", "legacy snapshot preserves explicit modern URL policy")
var responses = migrated; responses.searchMode = .auto
let searchBody = body(try OpenAIProvider.buildRequest(endpoint: responses, apiKey: "fixture-key", messages: [.init(role: .user, content: "today")], stream: true))
check((searchBody["tools"] as? [[String: String]])?.first?["type"] == "web_search", "Responses native search declaration")
check((searchBody["include"] as? [String]) == ["web_search_call.action.sources"], "request source metadata")
responses.searchMode = .off
check(body(try OpenAIProvider.buildRequest(endpoint: responses, apiKey: nil, messages: [], stream: true))["tools"] == nil, "search Off has no tools")
responses.authentication = .chatGPT
mustFail("direct OAuth cannot enter API-key request") { _ = try OpenAIProvider.buildRequest(endpoint: responses, apiKey: "fixture-key", messages: [], stream: true) }
var chat = migrated; chat.apiFormat = .chatCompletions; chat.searchMode = .auto
mustFail("generic Chat Completions does not establish search") { _ = try OpenAIProvider.buildRequest(endpoint: chat, apiKey: nil, messages: [], stream: true) }
chat.chatSearchVerified = true
check(body(try OpenAIProvider.buildRequest(endpoint: chat, apiKey: nil, messages: [], stream: true))["web_search_options"] != nil, "explicit verified CC search")

var d = OpenAIStreamDecoder(format: .responses)
var result: [ProviderStreamEvent] = []
result += try d.consume(event(["type": "response.output_text.delta", "output_index": 1, "content_index": 0, "delta": "First"]))
result += try d.consume(event(["type": "response.output_text.done", "output_index": 1, "content_index": 0, "text": "First"]))
result += try d.consume(event(["type": "response.output_text.annotation.added", "output_index": 1, "content_index": 0, "annotation": ["type": "url_citation", "url": "https://example.com/a", "title": "A", "start_index": 0, "end_index": 5]]))
result += try d.consume(event(["type": "response.completed", "response": ["status": "completed", "output": [["type": "web_search_call", "status": "completed", "action": ["sources": [["url": "https://example.com/a", "title": "A"]]]], ["type": "message", "content": [["type": "output_text", "text": "First"]]], ["type": "message", "content": [["type": "output_text", "text": "Second", "annotations": [["type": "url_citation", "url": "https://example.com/b", "title": "B", "start_index": 0, "end_index": 6]]]]]]]]))
check(texts(result) == "FirstSecond", "delta/final dedup plus multiple output items")
check(d.completed && result.last == .completed, "Responses terminal completion")
check(citations(result).last?.startIndex == 5, "citation offset after earlier output item")
check(result.contains(.searchActivity(.searching)) && result.contains(.searchActivity(.completed)), "search state comes from native activity")
check(try d.consume(event(["type": "response.output_text.delta", "delta": "late"])).isEmpty, "decoder ignores late completed stream events")
var incomplete = OpenAIStreamDecoder(format: .responses)
mustFail("Responses incomplete differs from completed") { _ = try incomplete.consume(event(["type": "response.incomplete", "response": ["status": "incomplete"]])) }
var errorDecoder = OpenAIStreamDecoder(format: .responses)
mustFail("in-stream HTTP 200 error") { _ = try errorDecoder.consume(event(["type": "error", "error": ["code": "invalid_api_key"]])) }
var eof = OpenAIStreamDecoder(format: .responses)
_ = try eof.consume(event(["type": "response.output_text.delta", "delta": "partial"]))
check(!eof.completed, "delta-only EOF cannot mark completion")
var cc = OpenAIStreamDecoder(format: .chatCompletions)
let ccEvents = try cc.consume(event(["choices": [["delta": ["content": "Answer", "annotations": [["type": "url_citation", "url_citation": ["url": "https://example.com", "title": "Example", "start_index": 0, "end_index": 6]]]], "finish_reason": "stop"]]]))
check(texts(ccEvents) == "Answer" && citations(ccEvents).count == 1 && cc.completed, "CC text annotations and stop")
var parser = SSEParser()
check(parser.feed(line: ": heartbeat") == nil, "heartbeat creates no useful progress event")
_ = parser.feed(line: "event: response.output_text.delta")
_ = parser.feed(line: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"x\"}")
check(parser.feed(line: "")?.event == "response.output_text.delta", "SSE dispatch after separator")
_ = parser.feed(line: "event: first"); _ = parser.feed(line: "data: one")
check(parser.feed(line: "event: second")?.data == "one", "compatible server missing separator")
_ = parser.feed(line: "data: two")
check(parser.flush()?.data == "two", "flush final unterminated event")

var anthropic = migrated; anthropic.apiFormat = .anthropicMessages; anthropic.searchMode = .auto
let anthBody = body(try AnthropicProvider.buildRequest(endpoint: anthropic, apiKey: "fixture", messages: [.init(role: .system, content: "Reference context"), .init(role: .user, content: "first"), .init(role: .user, content: "second")]))
check((anthBody["tools"] as? [[String: Any]])?.first?["type"] as? String == "web_search_20250305", "versioned Anthropic native tool")
check((anthBody["system"] as? String)?.contains("Reference context") == true, "retrieval system context kept")
check((anthBody["messages"] as? [[String: String]])?.count == 1, "adjacent user messages normalized without fabricated assistant")
var ad = AnthropicStreamDecoder()
var ar: [ProviderStreamEvent] = []
ar += try ad.consume(event(["type": "content_block_start", "index": 0, "content_block": ["type": "server_tool_use", "id": "tool-id", "name": "web_search", "input": [:]]]))
ar += try ad.consume(event(["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": "{\"query\":\"current\"}"]]))
ar += try ad.consume(event(["type": "content_block_stop", "index": 0]))
ar += try ad.consume(event(["type": "content_block_start", "index": 1, "content_block": ["type": "web_search_tool_result", "tool_use_id": "tool-id", "content": [["type": "web_search_result", "url": "https://example.com", "title": "Example", "encrypted_content": "opaque"]]]]))
ar += try ad.consume(event(["type": "content_block_start", "index": 2, "content_block": ["type": "text", "text": ""]]))
ar += try ad.consume(event(["type": "content_block_delta", "index": 2, "delta": ["type": "text_delta", "text": "Answer"]]))
ar += try ad.consume(event(["type": "content_block_delta", "index": 2, "delta": ["type": "citations_delta", "citation": ["type": "web_search_result_location", "url": "https://example.com", "title": "Example", "cited_text": "returned excerpt"]]]))
_ = try ad.consume(event(["type": "message_delta", "delta": ["stop_reason": "pause_turn"]]))
ar += try ad.consume(event(["type": "message_stop"]))
check(ad.stopped && !ad.completed && !ar.contains(.completed), "paused tool turn is not completion")
check((ad.contentBlocks.first?["input"] as? [String: String])?["query"] == "current", "server tool input retained for continuation")
check(((ad.contentBlocks[1]["content"] as? [[String: String]])?.first?["encrypted_content"]) == "opaque", "opaque server tool content preserved")
check(texts(ar) == "Answer" && citations(ar).count >= 1, "Anthropic text/search result/citations")
var adError = AnthropicStreamDecoder()
mustFail("server search error inside HTTP 200") { _ = try adError.consume(event(["type": "content_block_start", "index": 0, "content_block": ["type": "web_search_tool_result", "content": ["type": "web_search_tool_result_error", "error_code": "unavailable"]]])) }
var adDone = AnthropicStreamDecoder()
_ = try adDone.consume(event(["type": "message_delta", "delta": ["stop_reason": "end_turn"]]))
check(try adDone.consume(event(["type": "message_stop"])) == [.completed], "Anthropic terminal stop")
if case .http = APIError.response(status: 400, body: "{\"error\":{\"message\":\"bad request\"}}") { checks += 1 } else { fatalError("Generic 400 must not establish unsupported capability") }
if case .unsupportedTool = APIError.response(status: 400, body: "{\"error\":{\"code\":\"unsupported_tool\"}}") { checks += 1 } else { fatalError("Explicit unsupported tool is typed") }
check(SourceCitation(url: "javascript:alert(1)", title: "bad").safeURL == nil, "only actual HTTP source URLs can open")
print("Provider fixtures passed: \(checks)")
