import Foundation
import Combine

@MainActor
public final class EndpointStore: ObservableObject {
    public static let shared = EndpointStore()
    public static let willChange = Notification.Name("EndpointStoreWillChange")

    private let key = "endpoints.v1"
    private let activeKey = "endpoint.active.v1"
    private let hasSeededKey = "endpoints.seeded.v1"

    /// Marker indicating which side of the paired system is hosting this
    /// process. Set by each app's entry point (iPhone sets it to `true`,
    /// watch to `false`) for diagnostics and UI hints. It is NOT used to
    /// gate publishing — both sides mirror their own local changes to
    /// the other. Loops are prevented by `applyRemoteEndpoints`, which
    /// writes the received snapshot without re-publishing it.
    public static var isPrimaryForEndpoints: Bool = false

    @Published public private(set) var endpoints: [EndpointConfig] = []
    @Published public private(set) var activeEndpointID: UUID?

    public var activeEndpoint: EndpointConfig? {
        guard let id = activeEndpointID else { return endpoints.first }
        return endpoints.first(where: { $0.id == id }) ?? endpoints.first
    }

    public init() {
        load()
        if endpoints.isEmpty, !UserDefaults.standard.bool(forKey: hasSeededKey) {
            // First-launch seed. Native OpenAI / Anthropic are no longer
            // seeded because the picker was collapsed — users who want
            // those services tap "+" and type the URL themselves.
            endpoints = [
                .sampleAnthropicCompat,
                .sampleMiniMax,
                .sampleMiniMaxAnthropic
            ]
            activeEndpointID = endpoints.first?.id
            persist()
            UserDefaults.standard.set(true, forKey: hasSeededKey)
        } else if activeEndpointID == nil {
            activeEndpointID = endpoints.first?.id
        }
    }

    public func load() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        if let decoded = try? JSONDecoder().decode([EndpointConfig].self, from: data) {
            endpoints = decoded.filter { !Self.isLegacyLlamaSeed($0) }
        }
        if let raw = UserDefaults.standard.string(forKey: activeKey) {
            activeEndpointID = UUID(uuidString: raw)
        }
        if activeEndpointID.map({ id in !endpoints.contains(where: { $0.id == id }) }) == true {
            activeEndpointID = endpoints.first?.id
        }
        persist()
    }

    public func save(_ updated: EndpointConfig) {
        NotificationCenter.default.post(name: Self.willChange, object: updated.id)
        if let idx = endpoints.firstIndex(where: { $0.id == updated.id }) {
            endpoints[idx] = updated
        } else {
            endpoints.append(updated)
        }
        persist()
        publishIfPrimary()
    }

    public func delete(_ id: UUID) {
        NotificationCenter.default.post(name: Self.willChange, object: id)
        endpoints.removeAll { $0.id == id }
        if activeEndpointID == id {
            activeEndpointID = endpoints.first?.id
        }
        KeychainStore.delete("\(id.uuidString).apikey")
        persist()
        publishIfPrimary()
    }

    public func setActive(_ id: UUID) {
        activeEndpointID = id
        UserDefaults.standard.set(id.uuidString, forKey: activeKey)
        objectWillChange.send()
        publishIfPrimary()
    }

    /// Apply a snapshot received from the paired device. Idempotent: any
    /// remote update is treated as the new source of truth, but the change
    /// does NOT republish (we don't want a phone↔watch ping-pong loop).
    public func applyRemoteEndpoints(_ remote: [EndpointConfig], activeID: UUID?) {
        if endpoints != remote {
            NotificationCenter.default.post(name: Self.willChange, object: nil)
        }
        let currentByID = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.id, $0) })
        endpoints = remote.map { incoming in
            guard !incoming.hasExtendedConfiguration, let current = currentByID[incoming.id] else { return incoming }
            if current.authentication == .chatGPT { return current }
            return incoming.preservingExtendedConfiguration(from: current)
        }
        if let activeID, remote.contains(where: { $0.id == activeID }) {
            activeEndpointID = activeID
        } else {
            activeEndpointID = remote.first?.id
        }
        persist()
    }

    private func publishIfPrimary() {
        // Always publish; both sides are equal peers for endpoint state.
        // The receive path uses applyRemoteEndpoints (which does NOT call
        // back into publishIfPrimary) so this can't loop.
        SyncCoordinator.shared.publishEndpoints(endpoints, activeID: activeEndpointID)
    }

    /// Mirror an API-key change to the paired device. Callers should
    /// invoke this whenever they set or clear a key for an endpoint.
    public func publishAPIKey(_ value: String, for endpointID: UUID) {
        SyncCoordinator.shared.publishAPIKey(value, for: endpointID)
    }

    public func apiKey(for endpointID: UUID) -> String? {
        guard endpoints.first(where: { $0.id == endpointID })?.authentication != .chatGPT else { return nil }
        return KeychainStore.get("\(endpointID.uuidString).apikey")
    }

    public func setAPIKey(_ value: String, for endpointID: UUID) {
        guard endpoints.first(where: { $0.id == endpointID })?.authentication != .chatGPT else { return }
        NotificationCenter.default.post(name: Self.willChange, object: endpointID)
        if value.isEmpty {
            KeychainStore.delete("\(endpointID.uuidString).apikey")
        } else {
            KeychainStore.set(value, for: "\(endpointID.uuidString).apikey")
        }
        // Mirror to the companion device. The receive path writes the
        // key into the local keychain directly (it does not call back
        // into setAPIKey), so this can't loop.
        SyncCoordinator.shared.publishAPIKey(value, for: endpointID)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(endpoints) {
            UserDefaults.standard.set(data, forKey: key)
        }
        if let id = activeEndpointID {
            UserDefaults.standard.set(id.uuidString, forKey: activeKey)
        }
    }

    private static func isLegacyLlamaSeed(_ endpoint: EndpointConfig) -> Bool {
        endpoint.name == "Open WebUI (local)"
            && endpoint.baseURLString == "http://localhost:8080/v1"
            && endpoint.model == "llama3.1"
    }
}
