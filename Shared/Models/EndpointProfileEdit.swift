import Foundation

/// Fields the compact endpoint editor can change. Applying an edit preserves every
/// setting that editor cannot display, including authentication and legacy URL policy.
public struct EndpointProfileEdit: Sendable {
    public var name: String
    public var apiFormat: APIFormat
    public var baseURLString: String
    public var model: String
    public var systemPrompt: String
    public var temperature: Double
    public var searchMode: SearchMode

    public init(_ endpoint: EndpointConfig) {
        name = endpoint.name
        apiFormat = endpoint.apiFormat
        baseURLString = endpoint.baseURLString
        model = endpoint.model
        systemPrompt = endpoint.systemPrompt
        temperature = endpoint.temperature
        searchMode = endpoint.searchMode
    }

    public var hasRequiredFields: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Direct accounts must go through their dedicated account UI, never this API-key editor.
    public func applying(to current: EndpointConfig) -> EndpointConfig? {
        guard current.authentication == .apiKey else { return nil }
        var result = current
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.apiFormat = apiFormat
        result.providerType = apiFormat == .anthropicMessages ? .anthropicCompatible : .openAICompatible
        result.baseURLString = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        result.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        result.systemPrompt = systemPrompt
        result.temperature = temperature
        result.searchMode = searchMode
        if result.apiFormat != current.apiFormat || result.model != current.model ||
            result.baseURLString != current.baseURLString {
            result.chatSearchVerified = false
        }
        return result
    }
}
