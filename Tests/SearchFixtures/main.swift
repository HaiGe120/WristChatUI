import Foundation

private struct FixtureReply {
    var status = 200
    var headers = ["Content-Type": "application/json"]
    var chunks: [Data]
    var finish = true
}
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> FixtureReply)?
    static var stops = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let reply = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for data in reply.chunks { client?.urlProtocol(self, didLoad: data) }
            if reply.finish { client?.urlProtocolDidFinishLoading(self) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { Self.stops += 1 }
}

@main struct SearchFixtures {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ description: String) {
        precondition(value(), description); checks += 1
    }
    static func fails(_ description: String, _ action: () throws -> Void) {
        do { try action(); fatalError("Expected failure: " + description) } catch { checks += 1 }
    }
    static func object(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 2_048)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    fileprivate static func reply(_ request: URLRequest, result: [String: Any], sse: Bool = false) throws -> FixtureReply {
        let id = try object(request)["id"]!
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
        if sse {
            let wire = Data((": heartbeat\r\n\r\ndata: " + String(decoding: data, as: UTF8.self) + "\r\n\r\n").utf8)
            return FixtureReply(headers: ["Content-Type": "text/event-stream"], chunks: wire.map { Data([$0]) })
        }
        return FixtureReply(chunks: [data])
    }
    static func transport() -> SearchHTTP {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        return SearchHTTP(configuration: configuration)
    }
    static let schema: [String: Any] = ["type": "object", "properties": ["terms": ["type": "string"], "count": ["type": "integer"]], "required": ["terms", "count"], "additionalProperties": false]
    static var tool: [String: Any] { ["name": "lookup", "inputSchema": schema] }

    static func main() async throws {
        var source = SearchSourceProfile(name: "Fixture MCP", urlString: "https://search.example/mcp", authentication: .bearer,
            toolName: "lookup", queryField: "terms", fixedArgumentsJSON: "{\"count\":3,\"terms\":\"must be overwritten\"}")
        source.inputSchemaJSON = String(decoding: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), as: UTF8.self)
        let validatedURL = try source.validatedURL()
        expect(validatedURL.host == "search.example", "HTTPS remote profile")
        var invalid = source; invalid.urlString = "https://localhost/mcp"
        fails("localhost cannot reach phone/watch") { _ = try invalid.validatedURL() }
        invalid = source; invalid.urlString = "http://search.example/mcp"
        fails("no insecure credential destination") { _ = try invalid.validatedURL() }
        invalid = source; invalid.urlString = "https://search.example/mcp?api_key=never-save"
        fails("URL query credentials cannot enter profile JSON") { _ = try invalid.validatedURL() }
        invalid = source; invalid.authentication = .apiHeader; invalid.headerName = "MCP-Protocol-Version"
        fails("no transport-header override") { _ = try invalid.validatedURL() }
        invalid = source; invalid.fixedArgumentsJSON = "{\"nested\":{\"api_key\":\"secret\"}}"
        fails("no secret in profile fixed arguments") { _ = try invalid.fixedArguments() }
        let binding = SearchCredentialStore.binding(for: source)!
        expect(SearchCredentialStore.matches(binding: binding, profile: source), "credential binding matches original profile")
        invalid = source; invalid.urlString = "https://another.example/mcp"
        expect(!SearchCredentialStore.matches(binding: binding, profile: invalid), "interrupted destination update cannot expose new secret to old profile")
        invalid = source; invalid.authentication = .apiHeader
        expect(!SearchCredentialStore.matches(binding: binding, profile: invalid), "credential binding includes auth contract")
        expect(SearchSourceStore.isNewerRevision(2, than: 1) && !SearchSourceStore.isNewerRevision(1, than: 2), "same-second companion changes use monotonic revision ordering")
        let oldGeneration = UUID(), newGeneration = UUID()
        let oldDate = Date(timeIntervalSince1970: 1_000)
        func catalog(_ generation: UUID?, _ revision: UInt64, _ date: Date) -> SearchSourceCompanionPayload {
            SearchSourceCompanionPayload(sources: [], selectedSourceID: nil, credentials: [], sentAt: date, revision: revision, generation: generation)
        }
        var receipt = SearchCatalogReceipt(generation: oldGeneration, revision: 50, sentAt: oldDate)
        let fresh = catalog(newGeneration, 1, oldDate.addingTimeInterval(1))
        expect(receipt.shouldAccept(fresh), "new phone generation revision1 supersedes old generation revision50")
        receipt.accept(fresh)
        expect(!receipt.shouldAccept(catalog(oldGeneration, 100, oldDate.addingTimeInterval(2))), "retired generation queued payload rejected even with higher revision and later timestamp")
        expect(!receipt.shouldAccept(catalog(nil, 100, oldDate.addingTimeInterval(3))), "queued legacy payload cannot override a generation-aware phone")
        let restoredReceipt = try JSONDecoder().decode(SearchCatalogReceipt.self, from: JSONEncoder().encode(receipt))
        expect(!restoredReceipt.shouldAccept(catalog(oldGeneration, 100, oldDate.addingTimeInterval(2))), "retired generation guard survives Watch restart")
        expect(!receipt.shouldAccept(catalog(UUID(), 1, oldDate)), "unknown older generation cannot replace newer catalog")
        let rollback = SearchSourceStore.reconcileCatalogIdentity(savedGeneration: oldGeneration, savedRevision: 2,
            checkpointGeneration: oldGeneration, checkpointRevision: 50)
        expect(rollback.generation != oldGeneration && rollback.revision == 1, "restored defaults revision rollback starts a fresh generation")
        let stable = SearchSourceStore.reconcileCatalogIdentity(savedGeneration: newGeneration, savedRevision: 3,
            checkpointGeneration: newGeneration, checkpointRevision: 3)
        expect(stable.generation == newGeneration && stable.revision == 3, "ordinary restart retains generation/revision")
        let reinstall = SearchSourceStore.reconcileCatalogIdentity(savedGeneration: nil, savedRevision: 0,
            checkpointGeneration: oldGeneration, checkpointRevision: 50)
        expect(reinstall.generation != oldGeneration && reinstall.revision == 1, "reinstall creates a new catalog generation")
        expect(MCPHeaders.encodeValue("你好").hasPrefix("=?base64?"), "Unicode names use modern base64 sentinel")
        let headerSchema: [String: Any] = ["type": "object", "properties": ["region": ["type": "string", "x-mcp-header": "Region"]]]
        let mappedHeaders = try MCPHeaders.parameterHeaders(schema: headerSchema, arguments: ["region": "China"])
        expect(mappedHeaders == ["Mcp-Param-Region": "China"], "schema header mapping")
        fails("invalid annotation rejected") { _ = try MCPHeaders.parameterHeaders(schema: ["x-mcp-header": "Bad\r\nName"], arguments: [:]) }

        let json: [String: Any] = ["structuredContent": ["organic": [["link": "https://example.com/a", "title": "Returned", "snippet": "Current evidence"], ["url": "javascript:alert(1)", "title": "Invalid"]]], "content": [["type": "text", "text": "Uncited reference"]]]
        let normalized = try SearchResultNormalizer.normalize(result: json, source: source)
        expect(normalized.references.count == 1 && normalized.references[0].title == "Returned", "actual returned safe URLs only")
        expect(normalized.referenceText == "Uncited reference", "text without URLs stays uncited")
        expect(normalized.citations.count == 1 && normalized.modelContext().contains("untrusted reference data"), "bounded citation and untrusted context")
        fails("tool-level errors inside 200") { _ = try SearchResultNormalizer.normalize(result: ["isError": true, "content": []], source: source) }
        fails("modern input-required is actionable") { _ = try SearchResultNormalizer.normalize(result: ["resultType": "input_required"], source: source) }
        invalid = source; invalid.resultArrayPath = "data.results"
        fails("changed result mappings cannot fabricate sources") { _ = try SearchResultNormalizer.normalize(result: json, source: invalid) }

        var requests = 0
        FixtureProtocol.handler = { request in
            requests += 1
            let body = try object(request), params = body["params"] as! [String: Any]
            expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer separate-search-key", "dedicated source credential")
            expect(request.value(forHTTPHeaderField: "Mcp-Method") == body["method"] as? String, "modern method header")
            expect((params["_meta"] as? [String: Any])?["io.modelcontextprotocol/protocolVersion"] as? String == "2026-07-28", "modern request metadata")
            if requests == 1 { return try reply(request, result: ["resultType": "complete", "tools": [tool], "nextCursor": "page2"], sse: true) }
            expect(params["cursor"] as? String == "page2", "pagination cursor")
            return try reply(request, result: ["resultType": "complete", "tools": [["name": "second", "inputSchema": schema]]])
        }
        let discovered = try await MCPRemoteClient.listTools(source: source, credential: "separate-search-key", transport: transport())
        expect(discovered.map(\.name) == ["lookup", "second"] && requests == 2, "fragmented SSE + JSON paginated discovery")

        requests = 0
        FixtureProtocol.handler = { request in
            requests += 1
            let method = try object(request)["method"] as! String
            switch requests {
            case 1: return FixtureReply(status: 400, chunks: [Data("Missing session ID".utf8)])
            case 2:
                expect(method == "initialize", "legacy initialization after explicit discovery rejection")
                var value = try reply(request, result: ["protocolVersion": "2025-11-25", "capabilities": ["tools": [:]]])
                value.headers["MCP-Session-Id"] = "fixture-session"; return value
            case 3:
                expect(method == "notifications/initialized" && request.value(forHTTPHeaderField: "MCP-Session-Id") == "fixture-session", "legacy initialized + session header")
                return FixtureReply(status: 202, chunks: [])
            default:
                expect(method == "tools/list", "legacy listing after initialization")
                return try reply(request, result: ["tools": [tool]])
            }
        }
        let legacy = try await MCPRemoteClient.listTools(source: source, credential: "separate-search-key", transport: transport())
        expect(legacy.count == 1 && requests == 4, "legacy session compatibility without a GET stream")

        requests = 0
        FixtureProtocol.handler = { request in
            requests += 1
            let body = try object(request)
            if body["method"] as? String == "tools/list" { return try reply(request, result: ["resultType": "complete", "tools": [tool]]) }
            let args = (body["params"] as! [String: Any])["arguments"] as! [String: Any]
            expect(args["terms"] as? String == "actual query", "actual query cannot be overwritten by fixed arguments")
            return try reply(request, result: ["resultType": "input_required", "inputRequests": [:]])
        }
        do {
            _ = try await MCPRemoteClient.retrieve(query: "actual query", source: source, credential: "separate-search-key", transport: transport())
            fatalError("Expected unsupported input interaction")
        } catch SearchError.unsupportedInteraction { checks += 1 }
        expect(requests == 2, "ambiguous tool execution is never automatically replayed")

        requests = 0
        FixtureProtocol.handler = { request in
            requests += 1
            return FixtureReply(status: 401, headers: ["WWW-Authenticate": "Bearer resource_metadata=\"https://search.example/.well-known/oauth-protected-resource\""], chunks: [])
        }
        do {
            _ = try await MCPRemoteClient.listTools(source: source, credential: "expired", transport: transport())
            fatalError("Expected OAuth setup action")
        } catch SearchError.oauthRequired { checks += 1 }
        expect(requests == 1, "auth errors never trigger protocol retries")

        requests = 0
        FixtureProtocol.handler = { request in
            requests += 1
            return FixtureReply(status: 400, chunks: [Data("Invalid request parameter".utf8)])
        }
        do {
            _ = try await MCPRemoteClient.listTools(source: source, credential: "fixture", transport: transport())
            fatalError("Expected generic HTTP failure")
        } catch SearchError.http(400) { checks += 1 }
        expect(requests == 1, "generic 400 cannot establish legacy capability or replay discovery")

        let stopsBefore = FixtureProtocol.stops
        FixtureProtocol.handler = { request in FixtureReply(chunks: [], finish: false) }
        let hanging = Task { try await MCPRemoteClient.listTools(source: source, credential: "fixture", transport: transport()) }
        try await Task.sleep(nanoseconds: 20_000_000)
        hanging.cancel()
        do { _ = try await hanging.value; fatalError("Expected cancellation") }
        catch { checks += 1 }
        expect(FixtureProtocol.stops > stopsBefore, "cancellation closes underlying search transport")

        do {
            let _: Int = try await SearchDeadline.run(seconds: 0.01) { try await Task.sleep(nanoseconds: 5_000_000_000); return 1 }
            fatalError("Expected bounded setup deadline")
        } catch let error as URLError where error.code == .timedOut { checks += 1 }

        let encoded = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        expect(!encoded.contains("separate-search-key") && !encoded.contains("expired"), "profile JSON contains no credentials")
        print("Search fixtures passed (\(checks) checks).")
    }
}
