import Foundation

public enum SearchRetriever {
    /// A single, explicitly selected destination receives the query. There is no fallback replay.
    public static func retrieve(query: String, source: SearchSourceProfile, credential: String?) async throws -> SearchRetrievalResult {
        try Task.checkCancellation()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 4_000 else {
            throw SearchError.invalidConfiguration("Use a search question of 4,000 characters or fewer.")
        }
        return try await SearchDeadline.run {
            switch source.kind {
            case .customMCP: return try await MCPRemoteClient.retrieve(query: query, source: source, credential: credential)
            case .miniMaxPlan: return try await miniMax(query: query, source: source, credential: credential)
            }
        }
    }

    private static func miniMax(query: String, source: SearchSourceProfile, credential: String?) async throws -> SearchRetrievalResult {
        var request = try SearchHTTP.request(source: source, credential: credential)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Minimax-MCP", forHTTPHeaderField: "MM-API-Source")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["q": query])
        let http = SearchHTTP(); defer { http.close() }
        let (bytes, response) = try await http.session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw SearchError.interrupted }
        try SearchHTTP.validateStatus(response)
        let data = try await SearchHTTP.collect(bytes)
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = result["base_resp"] as? [String: Any], let status = base["status_code"] as? Int else {
            throw SearchError.invalidResult("MiniMax returned an invalid search result.")
        }
        if status == 1004 { throw SearchError.authenticationRequired }
        guard status == 0 else { throw SearchError.tool("MiniMax search failed") }
        return try SearchResultNormalizer.normalize(result: ["structuredContent": result], source: source)
    }
}

enum SearchResultNormalizer {
    static func normalize(result: [String: Any], source: SearchSourceProfile) throws -> SearchRetrievalResult {
        if result["isError"] as? Bool == true { throw SearchError.tool("Server tool error") }
        if result["resultType"] as? String == "input_required" || result["inputRequests"] != nil { throw SearchError.unsupportedInteraction }
        var references: [SearchReference] = []
        var uncited: [String] = []
        var visited = 0
        var textualBudget = 12_000
        func addText(_ text: String) {
            guard textualBudget > 0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let bounded = String(text.prefix(min(textualBudget, 4_000)))
            uncited.append(bounded); textualBudget -= bounded.count
        }
        func walk(_ value: Any, depth: Int = 0) {
            guard depth <= 8, visited < 1_024 else { return }; visited += 1
            if let object = value as? [String: Any] {
                let rawURL = object[source.urlField] as? String ?? object["url"] as? String ?? object["link"] as? String
                if let rawURL, let url = safeURL(rawURL), !references.contains(where: { $0.url == url }), references.count < 12 {
                    let title = object[source.titleField] as? String ?? object["title"] as? String ?? object["name"] as? String ?? rawURL
                    let excerpt = object[source.excerptField] as? String ?? object["snippet"] as? String ?? object["excerpt"] as? String ?? object["description"] as? String ?? ""
                    references.append(SearchReference(url: url, title: String(title.prefix(300)), excerpt: String(excerpt.prefix(1_200))))
                    return
                }
                if object["type"] as? String == "text", let text = object["text"] as? String {
                    if let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) {
                        walk(json, depth: depth + 1)
                    } else { addText(text) }
                    return
                }
                // Binary, image, audio and resource-link blocks are outside this search subset.
                if let type = object["type"] as? String, ["image", "audio", "resource_link"].contains(type) { return }
                for key in object.keys.sorted() where !["_meta", "inputRequests", "requestState"].contains(key) {
                    if let child = object[key], child is [Any] || child is [String: Any] { walk(child, depth: depth + 1) }
                }
            } else if let array = value as? [Any] { for item in array.prefix(256) { walk(item, depth: depth + 1) } }
            else if let text = value as? String { addText(text) }
        }
        if !source.resultArrayPath.isEmpty {
            let root: Any = result["structuredContent"] ?? result
            var selected: Any? = root
            for component in source.resultArrayPath.split(separator: ".") {
                selected = (selected as? [String: Any])?[String(component)]
            }
            guard let selected else { throw SearchError.invalidResult("The result-field mapping no longer matches this search tool. Edit it on iPhone.") }
            walk(selected)
        } else {
            if let structured = result["structuredContent"] { walk(structured) }
            if let content = result["content"] { walk(content) }
        }
        guard !references.isEmpty || !uncited.isEmpty else { throw SearchError.noResults }
        return SearchRetrievalResult(references: references, referenceText: uncited.joined(separator: "\n\n"), sourceName: source.name)
    }

    static func safeURL(_ string: String) -> String? {
        guard string.count <= 4_096, let url = URL(string: string),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url.absoluteString
    }
}
