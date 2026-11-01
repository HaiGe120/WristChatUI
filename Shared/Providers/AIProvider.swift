import Foundation

public enum APIError: Error, LocalizedError, Sendable {
    case invalidURL(String), http(status: Int, body: String), decoding(String), missingAPIKey
    case cancelled, transport(String), incompleteStream, timeout, offline, connectionLost
    case authentication, oauthUnavailable, unsupportedTool(String), unsupportedInteraction(String), quota, server(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Check this connection's URL."
        case .http(let status, _): return "The server returned HTTP \(status)."
        case .decoding: return "The server returned an unreadable response."
        case .missingAPIKey: return "Missing API key for this connection."
        case .cancelled: return "Stopped"
        case .transport(let s): return s
        case .incompleteStream: return "Connection lost before the reply finished."
        case .timeout: return "Request timed out."
        case .offline: return "You appear to be offline."
        case .connectionLost: return "Connection lost."
        case .authentication: return "Sign in again or check this connection's API key."
        case .oauthUnavailable: return "Continue with ChatGPT requires a verified app registration and iPhone sign-in setup."
        case .unsupportedTool(let s), .unsupportedInteraction(let s): return s
        case .quota: return "This connection's usage limit was reached."
        case .server: return "The server could not finish this request."
        }
    }

    public static func from(_ error: Error) -> APIError {
        if let error = error as? APIError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timeout
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .offline
            case .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return .connectionLost
            default: return .transport("Unable to connect to this server.")
            }
        }
        return .transport("Unable to finish this request.")
    }

    static func response(status: Int, body: String) -> APIError {
        if status == 401 || status == 403 { return .authentication }
        if status == 429 { return .quota }
        if status >= 500 { return .server("HTTP \(status)") }
        if let obj = body.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
           let error = obj["error"] as? [String: Any] {
            let code = (error["code"] as? String ?? error["type"] as? String ?? "").lowercased()
            let message = (error["message"] as? String ?? "").lowercased()
            // Only an explicit tool capability rejection is cacheable. Generic 400s are not.
            if ["unsupported_tool", "unsupported_tool_type", "tool_not_supported"].contains(code)
                || (message.contains("web_search") && (message.contains("not supported") || message.contains("unsupported tool"))) {
                return .unsupportedTool("Live search is unavailable for this connection and model. Choose another search source or turn search off.")
            }
        }
        return .http(status: status, body: body)
    }
}

public struct SourceCitation: Codable, Hashable, Identifiable, Sendable {
    public var url: String
    public var title: String
    public var excerpt: String?
    public var startIndex: Int?
    public var endIndex: Int?
    public var id: String { "\(url)#\(startIndex.map(String.init) ?? ""):\(endIndex.map(String.init) ?? "")" }
    public init(url: String, title: String, excerpt: String? = nil, startIndex: Int? = nil, endIndex: Int? = nil) {
        self.url = url; self.title = title; self.excerpt = excerpt; self.startIndex = startIndex; self.endIndex = endIndex
    }
    public var safeURL: URL? {
        guard let value = URL(string: url), ["https", "http"].contains(value.scheme?.lowercased() ?? ""), value.host != nil else { return nil }
        return value
    }
}

public enum SearchActivity: String, Codable, Sendable { case searching, completed }
public enum ProviderStreamEvent: Sendable, Equatable {
    case text(String)
    case searchActivity(SearchActivity)
    case citation(SourceCitation)
    case completed
}

public protocol AIProvider: Sendable {
    var providerType: AIProviderType { get }
    func stream(endpoint: EndpointConfig, apiKey: String?, messages: [ChatMessage]) -> AsyncThrowingStream<ProviderStreamEvent, Error>
    func listModels(endpoint: EndpointConfig, apiKey: String?) async throws -> [String]
}
