import Foundation

public enum NativeSearchCapability: String, Codable { case unknown, supported, unsupported }

/// Only explicit tool rejections establish lack of capability. Connectivity/quota/auth failures do not.
@MainActor
public final class NativeSearchCapabilities {
    public static let shared = NativeSearchCapabilities()
    private let defaults: UserDefaults
    private let storageKey = "nativeSearch.capabilities.v1"
    private var entries: [String: NativeSearchCapability]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([String: NativeSearchCapability].self, from: $0) } ?? [:]
    }
    public func state(for endpoint: EndpointConfig) -> NativeSearchCapability { entries[key(endpoint)] ?? .unknown }
    public func record(_ capability: NativeSearchCapability, for endpoint: EndpointConfig) {
        entries[key(endpoint)] = capability
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: storageKey) }
    }
    public func clear(for endpoint: EndpointConfig) { record(.unknown, for: endpoint) }
    private func key(_ endpoint: EndpointConfig) -> String {
        // URL/model/format/auth changes naturally invalidate previous evidence.
        [endpoint.id.uuidString, endpoint.baseURLString, endpoint.model, endpoint.apiFormat.rawValue,
         endpoint.authentication.rawValue, String(endpoint.chatSearchVerified)].joined(separator: "|")
    }
}
