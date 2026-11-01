import Foundation

public struct MCPToolDefinition: Identifiable, Sendable, Hashable {
    public let name: String
    public let title: String
    public let description: String
    public let inputSchemaJSON: String
    public var id: String { name }
    public var stringInputFields: [String] {
        guard let schema = schema, let properties = schema["properties"] as? [String: [String: Any]] else { return [] }
        return properties.filter { $0.value["type"] as? String == "string" }.map(\.key).sorted()
    }
    public var requiredInputFields: [String] { schema?["required"] as? [String] ?? [] }
    var schema: [String: Any]? {
        inputSchemaJSON.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

public enum MCPRemoteClient {
    public static func listTools(source: SearchSourceProfile, credential: String?) async throws -> [MCPToolDefinition] {
        try await listTools(source: source, credential: credential, transport: SearchHTTP())
    }

    static func listTools(source: SearchSourceProfile, credential: String?, transport: SearchHTTP) async throws -> [MCPToolDefinition] {
        let client = MCPSession(source: source, credential: credential, http: transport)
        defer { client.close() }
        return try await SearchDeadline.run { try await client.discover() }
    }

    static func retrieve(query: String, source: SearchSourceProfile, credential: String?) async throws -> SearchRetrievalResult {
        try await retrieve(query: query, source: source, credential: credential, transport: SearchHTTP())
    }

    static func retrieve(query: String, source: SearchSourceProfile, credential: String?, transport: SearchHTTP) async throws -> SearchRetrievalResult {
        let client = MCPSession(source: source, credential: credential, http: transport)
        defer { client.close() }
        let tools = try await client.discover()
        guard let tool = tools.first(where: { $0.name == source.toolName }) else { throw SearchError.schemaChanged }
        guard let savedSchema = source.inputSchemaJSON, savedSchema == tool.inputSchemaJSON else { throw SearchError.schemaChanged }
        var arguments = try source.fixedArguments()
        guard !source.queryField.isEmpty else { throw SearchError.invalidConfiguration("Choose the tool's query field on iPhone.") }
        // The actual user's query always wins over configured fixed arguments.
        arguments[source.queryField] = String(query.prefix(4_000))
        try validateArguments(arguments, tool: tool)
        let result = try await client.call(tool: tool, arguments: arguments)
        return try SearchResultNormalizer.normalize(result: result, source: source)
    }

    public static func validateConfiguration(source: SearchSourceProfile, tool: MCPToolDefinition) throws {
        var arguments = try source.fixedArguments()
        arguments[source.queryField] = "search query"
        try validateArguments(arguments, tool: tool)
    }

    static func validateArguments(_ arguments: [String: Any], tool: MCPToolDefinition) throws {
        guard let schema = tool.schema else { throw SearchError.schemaChanged }
        let required = schema["required"] as? [String] ?? []
        let missing = required.filter { arguments[$0] == nil }
        guard missing.isEmpty else {
            throw SearchError.invalidConfiguration("Supply required fixed arguments: \(missing.joined(separator: ", ")).")
        }
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        if schema["additionalProperties"] as? Bool == false,
           arguments.keys.contains(where: { properties[$0] == nil }) {
            throw SearchError.invalidConfiguration("An argument is absent from the selected tool's input schema.")
        }
        for (name, value) in arguments {
            guard let field = properties[name] else { continue }
            let matches: Bool
            switch field["type"] as? String {
            case "string": matches = value is String
            case "object": matches = value is [String: Any]
            case "array": matches = value is [Any]
            case "boolean": matches = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            case "integer": matches = (value as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.rounded() == $0.doubleValue } ?? false
            case "number": matches = (value as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } ?? false
            default: matches = true
            }
            guard matches else { throw SearchError.invalidConfiguration("The value for '\(name)' has the wrong type.") }
            if let allowed = field["enum"] as? [Any], !allowed.contains(where: { String(describing: $0) == String(describing: value) }) {
                throw SearchError.invalidConfiguration("The value for '\(name)' is not accepted by this tool.")
            }
        }
    }
}

private struct MCPFailure: Error {
    let status: Int
    let code: Int?
    let message: String
    let data: [String: Any]?
    var isRecognizedModern: Bool { [-32020, -32021, -32022, -32601].contains(code ?? 0) }
    var explicitlyRequiresLegacyInitialization: Bool {
        let message = message.lowercased()
        return status == 400 && !isRecognizedModern && (
            message.contains("not initialized") || message.contains("not initialised") ||
            message.contains("initialize first") || message.contains("initialization required") ||
            (message.contains("session") && message.contains("id") &&
                (message.contains("missing") || message.contains("required"))))
    }
}

private final class MCPSession {
    let source: SearchSourceProfile
    let credential: String?
    let http: SearchHTTP
    var version = "2026-07-28"
    var legacy = false
    var sessionID: String?
    init(source: SearchSourceProfile, credential: String?, http: SearchHTTP = SearchHTTP()) {
        self.source = source; self.credential = credential; self.http = http
    }
    func close() { http.close() }

    func discover() async throws -> [MCPToolDefinition] {
        var first: [String: Any]
        do {
            first = try await rpc(method: "tools/list", params: [:])
        } catch let failure as MCPFailure {
            if failure.code == -32022 {
                let supported = failure.data?["supported"] as? [String] ?? []
                guard let selected = ["2025-11-25", "2025-06-18", "2025-03-26"].first(where: supported.contains) else {
                    throw SearchError.incompatibleProtocol
                }
                try await initialize(version: selected)
            } else if failure.explicitlyRequiresLegacyInitialization {
                // Discovery is read-only. No search call is replayed during negotiation.
                try await initialize(version: "2025-11-25")
            } else { throw publicError(failure) }
            do { first = try await rpc(method: "tools/list", params: [:]) }
            catch let failure as MCPFailure { throw publicError(failure) }
        }
        var result: [MCPToolDefinition] = []
        var seenCursors = Set<String>()
        var page = first
        for pageNumber in 0..<16 {
            try Task.checkCancellation()
            try validateResult(page)
            guard let tools = page["tools"] as? [[String: Any]] else {
                throw SearchError.invalidResult("The server did not return a valid tool list.")
            }
            for item in tools {
                guard let name = item["name"] as? String, !name.isEmpty, name.count <= 256,
                      let schema = item["inputSchema"] as? [String: Any],
                      (try? MCPHeaders.parameterHeaders(schema: schema, arguments: [:])) != nil,
                      let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), data.count <= 32_768,
                      let schemaJSON = String(data: data, encoding: .utf8) else { continue }
                if !result.contains(where: { $0.name == name }) {
                    result.append(MCPToolDefinition(name: name, title: item["title"] as? String ?? name,
                        description: String((item["description"] as? String ?? "").prefix(1_000)), inputSchemaJSON: schemaJSON))
                }
                guard result.count <= 256 else { throw SearchError.tooLarge }
            }
            guard let cursor = page["nextCursor"] as? String, !cursor.isEmpty else { return result }
            guard pageNumber < 15, cursor.count <= 4_096, seenCursors.insert(cursor).inserted else { throw SearchError.tooLarge }
            do { page = try await rpc(method: "tools/list", params: ["cursor": cursor]) }
            catch let failure as MCPFailure { throw publicError(failure) }
        }
        throw SearchError.tooLarge
    }

    func call(tool: MCPToolDefinition, arguments: [String: Any]) async throws -> [String: Any] {
        do {
            let headers = try MCPHeaders.parameterHeaders(schema: tool.schema ?? [:], arguments: arguments)
            let result = try await rpc(method: "tools/call", params: ["name": tool.name, "arguments": arguments], headers: headers)
            try validateResult(result)
            return result
        } catch let failure as MCPFailure { throw publicError(failure) }
    }

    func initialize(version: String) async throws {
        legacy = true; self.version = version
        let result: [String: Any]
        do {
            result = try await rpc(method: "initialize", params: ["protocolVersion": version, "capabilities": [:],
                "clientInfo": ["name": "WristChatUI", "version": "1.0"]])
        } catch let failure as MCPFailure { throw publicError(failure) }
        guard let negotiated = result["protocolVersion"] as? String,
              ["2025-11-25", "2025-06-18", "2025-03-26"].contains(negotiated) else {
            throw SearchError.incompatibleProtocol
        }
        self.version = negotiated
        do { _ = try await rpc(method: "notifications/initialized", params: [:], notification: true) }
        catch let failure as MCPFailure { throw publicError(failure) }
    }

    func rpc(method: String, params: [String: Any], headers: [String: String] = [:], notification: Bool = false) async throws -> [String: Any] {
        try Task.checkCancellation()
        var request = try SearchHTTP.request(source: source, credential: credential)
        request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID, legacy { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
        var parameters = params
        if !legacy {
            parameters["_meta"] = ["io.modelcontextprotocol/protocolVersion": version,
                "io.modelcontextprotocol/clientInfo": ["name": "WristChatUI", "version": "1.0"],
                "io.modelcontextprotocol/clientCapabilities": [:]] as [String: Any]
            request.setValue(method, forHTTPHeaderField: "Mcp-Method")
            if let name = params["name"] as? String { request.setValue(MCPHeaders.encodeValue(name), forHTTPHeaderField: "Mcp-Name") }
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        }
        let id = UUID().uuidString
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": parameters]
        if !notification { body["id"] = id }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (bytes, response) = try await http.session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw SearchError.interrupted }
        if response.statusCode == 401 || response.statusCode == 403 { try SearchHTTP.validateStatus(response) }
        if method == "initialize", let sessionID = response.value(forHTTPHeaderField: "MCP-Session-Id") {
            guard sessionID.count <= 1_024, !sessionID.contains("\r"), !sessionID.contains("\n") else { throw SearchError.incompatibleProtocol }
            self.sessionID = sessionID
        }
        if notification, response.statusCode == 202 { return [:] }
        let object: [String: Any]
        var responseText = ""
        if response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true,
           (200..<300).contains(response.statusCode) {
            object = try await readSSE(bytes, matchingID: id)
        } else {
            let data = try await SearchHTTP.collect(bytes)
            responseText = String(decoding: data.prefix(2_000), as: UTF8.self)
            object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        if let error = object["error"] as? [String: Any] {
            throw MCPFailure(status: response.statusCode, code: error["code"] as? Int,
                message: error["message"] as? String ?? "", data: error["data"] as? [String: Any])
        }
        guard (200..<300).contains(response.statusCode) else {
            throw MCPFailure(status: response.statusCode, code: nil, message: responseText, data: nil)
        }
        guard object["jsonrpc"] as? String == "2.0", object["id"] as? String == id,
              let result = object["result"] as? [String: Any] else { throw SearchError.invalidResult("The search server returned an invalid JSON-RPC response.") }
        return result
    }

    func readSSE(_ bytes: URLSession.AsyncBytes, matchingID: String) async throws -> [String: Any] {
        var line = Data(); var dataLines: [String] = []; var total = 0
        func responseFromEvent() throws -> [String: Any]? {
            guard !dataLines.isEmpty else { return nil }
            let text = dataLines.joined(separator: "\n")
            guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SearchError.invalidResult("The search server sent malformed SSE data.")
            }
            if object["method"] != nil, object["id"] != nil { throw SearchError.unsupportedInteraction }
            guard object["id"] as? String == matchingID else { return nil }
            return object
        }
        for try await byte in bytes {
            try Task.checkCancellation(); total += 1
            guard total <= 524_288 else { throw SearchError.tooLarge }
            if byte != 10 { line.append(byte); continue }
            let value = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines)
            line.removeAll(keepingCapacity: true)
            if value.isEmpty {
                if let result = try responseFromEvent() { return result }
                dataLines.removeAll(keepingCapacity: true)
            } else if value.hasPrefix("data:") {
                var data = String(value.dropFirst(5)); if data.first == " " { data.removeFirst() }; dataLines.append(data)
            }
        }
        // Some servers end the final event at EOF without an empty separator.
        if !line.isEmpty {
            let value = String(decoding: line, as: UTF8.self)
            if value.hasPrefix("data:") { dataLines.append(String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        }
        if let result = try responseFromEvent() { return result }
        throw SearchError.interrupted
    }

    func validateResult(_ result: [String: Any]) throws {
        if result["resultType"] as? String == "input_required" || result["inputRequests"] != nil { throw SearchError.unsupportedInteraction }
        if let type = result["resultType"] as? String, type != "complete" { throw SearchError.unsupportedInteraction }
        if result["isError"] as? Bool == true { throw SearchError.tool("Server tool error") }
    }
    func publicError(_ failure: MCPFailure) -> SearchError {
        if failure.code == -32021 { return .unsupportedInteraction }
        if let code = failure.code { return .rpc(code, failure.message) }
        return .http(failure.status)
    }
}

enum MCPHeaders {
    static func encodeValue(_ value: String) -> String {
        let ascii = value.utf8.allSatisfy { $0 >= 32 && $0 <= 126 || $0 == 9 }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines) == value
        let sentinel = value.hasPrefix("=?base64?") && value.hasSuffix("?=")
        return ascii && trimmed && !sentinel ? value : "=?base64?\(Data(value.utf8).base64EncodedString())?="
    }

    static func parameterHeaders(schema: [String: Any], arguments: [String: Any]) throws -> [String: String] {
        var result: [String: String] = [:]; var names = Set<String>(); var nodes = 0
        func walk(_ node: Any, path: [String], reachable: Bool) throws {
            nodes += 1; guard nodes <= 1_024, path.count <= 16 else { throw SearchError.tooLarge }
            if let object = node as? [String: Any] {
                if let annotation = object["x-mcp-header"] {
                    guard reachable, !path.isEmpty, let name = annotation as? String, SearchSourceProfile.isHeaderName(name),
                          names.insert(name.lowercased()).inserted,
                          ["string", "integer", "boolean"].contains(object["type"] as? String ?? "") else {
                        throw SearchError.invalidConfiguration("The selected tool contains an unsupported header annotation.")
                    }
                    var value: Any = arguments
                    for component in path {
                        guard let next = (value as? [String: Any])?[component] else { return }
                        value = next
                    }
                    let text: String
                    if let number = value as? NSNumber {
                        if CFGetTypeID(number) == CFBooleanGetTypeID() { text = number.boolValue ? "true" : "false" }
                        else {
                            guard number.doubleValue.rounded() == number.doubleValue, abs(number.doubleValue) <= 9_007_199_254_740_991 else {
                                throw SearchError.invalidConfiguration("An MCP integer header is out of range.")
                            }
                            text = number.stringValue
                        }
                    } else if let string = value as? String { text = string }
                    else { throw SearchError.invalidConfiguration("An MCP header parameter has the wrong type.") }
                    result["Mcp-Param-" + name] = encodeValue(text)
                }
                for (key, child) in object where key != "x-mcp-header" {
                    if key == "properties", let properties = child as? [String: Any] {
                        for (name, field) in properties { try walk(field, path: path + [name], reachable: reachable) }
                    } else if child is [String: Any] || child is [Any] {
                        try walk(child, path: path, reachable: false)
                    }
                }
            } else if let array = node as? [Any] { for child in array { try walk(child, path: path, reachable: false) } }
        }
        try walk(schema, path: [], reachable: true)
        return result
    }
}
