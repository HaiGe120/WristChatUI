import Foundation

public enum APIFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case chatCompletions, responses, anthropicMessages
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .chatCompletions: return "OpenAI Chat Completions"
        case .responses: return "OpenAI Responses"
        case .anthropicMessages: return "Anthropic Messages"
        }
    }
    var suffix: String {
        switch self {
        case .chatCompletions: return "chat/completions"
        case .responses: return "responses"
        case .anthropicMessages: return "messages"
        }
    }
}

public enum EndpointAuthentication: String, Codable, CaseIterable, Sendable {
    case apiKey, chatGPT
}

public enum SearchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, auto
    public var id: String { rawValue }
    public var displayName: String { self == .off ? "Off" : "Auto" }
}

public struct EndpointConfig: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var providerType: AIProviderType
    public var baseURLString: String
    public var model: String
    public var systemPrompt: String
    public var temperature: Double
    public var maxTokens: Int?
    public var customHeaders: [String: String]
    public var apiFormat: APIFormat
    public var authentication: EndpointAuthentication
    public var searchMode: SearchMode
    /// Enabled only after the user verifies their endpoint/model's Chat Completions search contract.
    public var chatSearchVerified: Bool
    private var preservesLegacyChatRoot: Bool
    /// Decode provenance lets sync distinguish an older companion snapshot from intentional new settings.
    /// Every local save writes the current configuration version.
    public private(set) var hasExtendedConfiguration: Bool

    public init(id: UUID = UUID(), name: String, providerType: AIProviderType,
                baseURLString: String, model: String, systemPrompt: String = "",
                temperature: Double = 0.7, maxTokens: Int? = nil,
                customHeaders: [String: String] = [:], apiFormat: APIFormat? = nil,
                authentication: EndpointAuthentication = .apiKey, searchMode: SearchMode = .off,
                chatSearchVerified: Bool = false) {
        self.id = id; self.name = name; self.providerType = providerType
        self.baseURLString = baseURLString; self.model = model; self.systemPrompt = systemPrompt
        self.temperature = temperature; self.maxTokens = maxTokens; self.customHeaders = customHeaders
        self.apiFormat = apiFormat ?? Self.legacyFormat(providerType: providerType, baseURLString: baseURLString)
        self.authentication = authentication; self.searchMode = searchMode
        self.chatSearchVerified = chatSearchVerified
        self.preservesLegacyChatRoot = false
        self.hasExtendedConfiguration = true
    }

    enum CodingKeys: String, CodingKey {
        case id, name, providerType, baseURLString, model, systemPrompt, temperature, maxTokens, customHeaders
        case apiFormat, authentication, searchMode, chatSearchVerified, preservesLegacyChatRoot, configurationVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        providerType = try c.decode(AIProviderType.self, forKey: .providerType)
        baseURLString = try c.decode(String.self, forKey: .baseURLString)
        model = try c.decode(String.self, forKey: .model)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.7
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        customHeaders = try c.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
        let storedFormat = try c.decodeIfPresent(APIFormat.self, forKey: .apiFormat)
        apiFormat = storedFormat ?? Self.legacyFormat(providerType: providerType, baseURLString: baseURLString)
        preservesLegacyChatRoot = try c.decodeIfPresent(Bool.self, forKey: .preservesLegacyChatRoot) ?? (storedFormat == nil)
        authentication = try c.decodeIfPresent(EndpointAuthentication.self, forKey: .authentication) ?? .apiKey
        searchMode = try c.decodeIfPresent(SearchMode.self, forKey: .searchMode) ?? .off
        chatSearchVerified = try c.decodeIfPresent(Bool.self, forKey: .chatSearchVerified) ?? false
        hasExtendedConfiguration = (try c.decodeIfPresent(Int.self, forKey: .configurationVersion) ?? 0) >= 2
            || c.contains(.apiFormat) || c.contains(.authentication) || c.contains(.searchMode)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(2, forKey: .configurationVersion)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(providerType, forKey: .providerType); try c.encode(baseURLString, forKey: .baseURLString)
        try c.encode(model, forKey: .model); try c.encode(systemPrompt, forKey: .systemPrompt)
        try c.encode(temperature, forKey: .temperature); try c.encodeIfPresent(maxTokens, forKey: .maxTokens)
        try c.encode(customHeaders, forKey: .customHeaders); try c.encode(apiFormat, forKey: .apiFormat)
        try c.encode(authentication, forKey: .authentication); try c.encode(searchMode, forKey: .searchMode)
        try c.encode(chatSearchVerified, forKey: .chatSearchVerified)
        try c.encode(preservesLegacyChatRoot, forKey: .preservesLegacyChatRoot)
    }

    /// Merge a legacy companion's editable common fields without erasing settings it cannot represent.
    public func preservingExtendedConfiguration(from current: EndpointConfig) -> EndpointConfig {
        var merged = self
        merged.apiFormat = current.apiFormat
        merged.authentication = current.authentication
        merged.searchMode = current.searchMode
        merged.chatSearchVerified = current.chatSearchVerified
        merged.preservesLegacyChatRoot = current.preservesLegacyChatRoot
        merged.hasExtendedConfiguration = current.hasExtendedConfiguration
        return merged
    }

    private static func legacyFormat(providerType: AIProviderType, baseURLString: String) -> APIFormat {
        if providerType == .anthropic || providerType == .anthropicCompatible { return .anthropicMessages }
        if URL(string: baseURLString)?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("responses") == true { return .responses }
        return .chatCompletions
    }

    public var baseURL: URL? {
        let value = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    public var canUseNativeSearch: Bool { apiFormat != .chatCompletions || chatSearchVerified }

    public func chatCompletionsURL() -> URL? {
        guard let base = baseURL else { return nil }
        return Self.resolveURL(base: base, suffix: apiFormat.suffix,
                               addDefaultVersion: !(preservesLegacyChatRoot && apiFormat == .chatCompletions))
    }

    public func modelsURL() -> URL? {
        guard let base = baseURL else { return nil }
        return Self.resolveURL(base: base, suffix: "models")
    }

    /// Keep the deployment prefix, remove an existing operation suffix, and attach the selected format.
    /// A root ending in /v1 never acquires another /v1; full endpoint URLs remain usable.
    static func resolveURL(base: URL, suffix: String, addDefaultVersion: Bool = true) -> URL? {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var parts = c.path.split(separator: "/").map(String.init)
        var hadOperation = false
        if parts.suffix(2) == ["chat", "completions"] { parts.removeLast(2); hadOperation = true }
        else if let last = parts.last, ["responses", "messages", "models"].contains(last) { parts.removeLast(); hadOperation = true }
        if !hadOperation && addDefaultVersion && parts.last != "v1" { parts.append("v1") }
        parts.append(contentsOf: suffix.split(separator: "/").map(String.init))
        c.path = "/" + parts.joined(separator: "/")
        // Query parameters on a pasted operation URL can carry deployment routing hints.
        c.fragment = nil
        return c.url
    }

    static func resolveChatURL(base: URL, chatPath: String) -> URL? {
        let path = chatPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return resolveURL(base: base, suffix: path.hasPrefix("v1/") ? String(path.dropFirst(3)) : path)
    }
    static func resolveModelsURL(base: URL) -> URL? { resolveURL(base: base, suffix: "models") }

    public static let sampleAnthropicCompat = EndpointConfig(name: "Anthropic-compatible (custom)", providerType: .anthropicCompatible, baseURLString: "", model: "claude-3-5-sonnet-latest")
    public static let sampleMiniMax = EndpointConfig(name: "MiniMax", providerType: .openAICompatible, baseURLString: "https://api.minimaxi.com/v1", model: "MiniMax-M3")
    public static let sampleMiniMaxAnthropic = EndpointConfig(name: "MiniMax (Anthropic-compatible)", providerType: .anthropicCompatible, baseURLString: "https://api.minimaxi.com/anthropic", model: "MiniMax-M3")
}
