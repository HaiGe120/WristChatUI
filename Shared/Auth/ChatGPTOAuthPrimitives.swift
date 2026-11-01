import Foundation
import CryptoKit
import Security

/// Protocol preparation only. The App Store/native-client gates remain closed in
/// `ChatGPTSignInReadiness`; creating a URL does not start an authentication UI.
public enum ChatGPTOAuth {
    public static let issuer = "https://auth.openai.com"
    public static let authorizationURL = URL(string: issuer + "/api/accounts/authorize")!
    public static let tokenURL = URL(string: issuer + "/api/accounts/oauth/token")!
    public static let resource = "https://api.openai.com/v1"
    public static let initialClientID = "dynamic_agent_client"
    public static let requestedScopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    public static func isIssuedClientID(_ value: String) -> Bool {
        value.hasPrefix("oaiapp_") && value.count > "oaiapp_".count && value.count < 512
            && !value.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    /// Use exact destinations. Neither custom endpoints nor cross-origin redirects
    /// can receive these credentials. Redirect policy must also be enforced by the
    /// eventual URLSession delegate before enabling sign-in/inference.
    public static func permitsCredentialDestination(_ url: URL, purpose: CredentialPurpose) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "https", c.user == nil, c.password == nil,
              c.port == nil || c.port == 443, c.fragment == nil else { return false }
        switch purpose {
        case .tokenExchange:
            return c.host == "auth.openai.com" && c.path == "/api/accounts/oauth/token" && c.query == nil
        case .revocation:
            return c.host == "auth.openai.com" && c.path == "/api/accounts/oauth/revoke" && c.query == nil
        case .inference:
            return c.host == "api.openai.com" && c.path == "/v1/responses" && c.query == nil
        case .models:
            return c.host == "api.openai.com" && c.path == "/v1/models" && c.query == nil
        }
    }

    public enum CredentialPurpose: Sendable { case tokenExchange, revocation, inference, models }

    static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatGPTOAuthError.randomGenerationFailed
        }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ value: String) -> Data? {
        guard value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public enum ChatGPTOAuthError: Error, LocalizedError, Equatable {
    case randomGenerationFailed, invalidRedirect, invalidClientID, invalidCallback
    case expiredAttempt, stateMismatch, permissionDenied, authorizationFailed
    case noPendingAttempt, invalidIDToken, identityChanged, invalidCredentials
    case credentialStorage(Int32), sessionChanged, renewalRequired

    public var errorDescription: String? {
        switch self {
        case .randomGenerationFailed: return "Could not prepare a secure sign-in attempt."
        case .invalidRedirect: return "ChatGPT sign-in requires the verified HTTP loopback callback."
        case .invalidClientID: return "ChatGPT registration did not return a valid issued client ID."
        case .invalidCallback: return "The ChatGPT callback was invalid. Start sign-in again."
        case .expiredAttempt: return "ChatGPT sign-in timed out. Start sign-in again."
        case .stateMismatch: return "ChatGPT sign-in could not be verified. Start sign-in again."
        case .permissionDenied: return "ChatGPT permission was declined."
        case .authorizationFailed: return "ChatGPT authorization failed. Start sign-in again."
        case .noPendingAttempt: return "This sign-in attempt has already ended."
        case .invalidIDToken: return "The ChatGPT identity token could not be verified."
        case .identityChanged: return "The signed-in ChatGPT account did not match the selected account."
        case .invalidCredentials: return "The ChatGPT credential response was incomplete."
        case .credentialStorage: return "ChatGPT credentials could not be saved securely."
        case .sessionChanged: return "The ChatGPT account changed. Start the request again."
        case .renewalRequired: return "Reconnect to iPhone to renew ChatGPT access."
        }
    }
}

public struct ChatGPTAuthorizationAttempt: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "ChatGPTAuthorizationAttempt(<redacted>)" }
    public var debugDescription: String { description }
    public let state: String
    public let nonce: String
    public let codeVerifier: String
    public let redirectURI: URL
    public let hostID: String
    public let existingClientID: String?
    public let createdAt: Date

    public var codeChallenge: String { ChatGPTOAuth.base64URL(Data(SHA256.hash(data: Data(codeVerifier.utf8)))) }

    public init(redirectURI: URL, hostID: String, existingClientID: String? = nil, now: Date = Date()) throws {
        guard let c = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false),
              c.scheme == "http", c.host == "127.0.0.1", c.percentEncodedPath == "/auth/callback",
              let port = c.port, (1...65535).contains(port), c.user == nil,
              c.password == nil, c.query == nil, c.fragment == nil else { throw ChatGPTOAuthError.invalidRedirect }
        guard hostID.hasPrefix("urn:uuid:"), UUID(uuidString: String(hostID.dropFirst("urn:uuid:".count))) != nil else {
            throw ChatGPTOAuthError.invalidCredentials
        }
        if let existingClientID, !ChatGPTOAuth.isIssuedClientID(existingClientID) { throw ChatGPTOAuthError.invalidClientID }
        self.redirectURI = redirectURI
        self.hostID = hostID
        self.existingClientID = existingClientID
        self.createdAt = now
        self.state = try ChatGPTOAuth.randomValue()
        self.nonce = try ChatGPTOAuth.randomValue()
        self.codeVerifier = try ChatGPTOAuth.randomValue()
    }

    /// Never log this URL: returning sign-in may include an ID-token hint.
    public func authorizationURL(idTokenHint: String? = nil, emailHint: String? = nil) -> URL {
        var components = URLComponents(url: ChatGPTOAuth.authorizationURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: existingClientID ?? ChatGPTOAuth.initialClientID),
            URLQueryItem(name: "ext_agent_host_id", value: hostID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: ChatGPTOAuth.requestedScopes),
            URLQueryItem(name: "resource", value: ChatGPTOAuth.resource),
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge)
        ]
        if existingClientID == nil { items.append(URLQueryItem(name: "agent_name_hint", value: "WristChatUI")) }
        if existingClientID != nil {
            if let idTokenHint { items.append(URLQueryItem(name: "id_token_hint", value: idTokenHint)) }
            if let emailHint { items.append(URLQueryItem(name: "login_hint", value: emailHint)) }
        }
        components.queryItems = items
        return components.url!
    }

    public func validateCallback(_ callback: URL, now: Date = Date()) throws -> ChatGPTAuthorizationGrant {
        guard now.timeIntervalSince(createdAt) >= 0, now.timeIntervalSince(createdAt) < 300 else { throw ChatGPTOAuthError.expiredAttempt }
        guard let c = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              c.scheme == redirectURI.scheme, c.host == redirectURI.host, c.port == redirectURI.port,
              c.percentEncodedPath == redirectURI.path, c.user == nil, c.password == nil, c.fragment == nil else { throw ChatGPTOAuthError.invalidCallback }
        let items = c.queryItems ?? []
        var query: [String: String] = [:]
        for item in items {
            guard query[item.name] == nil, let value = item.value else { throw ChatGPTOAuthError.invalidCallback }
            query[item.name] = value
        }
        guard let returnedState = query["state"], ChatGPTOAuth.constantTimeEqual(returnedState, state) else {
            throw ChatGPTOAuthError.stateMismatch
        }
        if let error = query["error"] {
            throw error == "access_denied" ? ChatGPTOAuthError.permissionDenied : ChatGPTOAuthError.authorizationFailed
        }
        guard let code = query["code"], !code.isEmpty, code.count < 8192 else { throw ChatGPTOAuthError.invalidCallback }
        let issued = query["client_id"] ?? existingClientID
        guard let issued, ChatGPTOAuth.isIssuedClientID(issued) else { throw ChatGPTOAuthError.invalidClientID }
        if let existingClientID, issued != existingClientID { throw ChatGPTOAuthError.invalidClientID }
        return ChatGPTAuthorizationGrant(code: code, clientID: issued, codeVerifier: codeVerifier, redirectURI: redirectURI)
    }
}

/// Kept out of Codable/profile/sync models. Consume a callback through the broker
/// once; only exchange with the official token endpoint after release gates pass.
public struct ChatGPTAuthorizationGrant: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "ChatGPTAuthorizationGrant(<redacted>)" }
    public var debugDescription: String { description }
    public let code: String
    public let clientID: String
    public let codeVerifier: String
    public let redirectURI: URL
}

public actor ChatGPTAuthorizationBroker {
    private var pending: ChatGPTAuthorizationAttempt?
    public init() {}
    public func begin(_ attempt: ChatGPTAuthorizationAttempt) { pending = attempt }
    public func cancel() { pending = nil }
    public func consume(_ callback: URL, now: Date = Date()) throws -> ChatGPTAuthorizationGrant {
        guard let pending else { throw ChatGPTOAuthError.noPendingAttempt }
        self.pending = nil
        return try pending.validateCallback(callback, now: now)
    }
}
