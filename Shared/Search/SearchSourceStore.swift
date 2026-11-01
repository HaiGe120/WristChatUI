import Foundation
import Combine
import Security

/// This dedicated credential payload is sent only through the companion search-source path.
/// It must never be included in chat backups, endpoint JSON, or generic API-key sync.
public struct SearchSourceCompanionPayload: Codable, Sendable {
    public let sources: [SearchSourceProfile]
    public let selectedSourceID: UUID?
    public let credentials: [SearchSourceCredential]
    public let sentAt: Date
    public let revision: UInt64
    public let generation: UUID?
    public init(sources: [SearchSourceProfile], selectedSourceID: UUID?, credentials: [SearchSourceCredential],
                sentAt: Date = Date(), revision: UInt64 = 0, generation: UUID? = nil) {
        self.sources = sources; self.selectedSourceID = selectedSourceID; self.credentials = credentials
        self.sentAt = sentAt
        self.revision = revision
        self.generation = generation
    }
}

/// A generation change represents a fresh catalog after reinstall or restored settings.
/// Revisions are meaningful only within the same generation.
struct SearchCatalogReceipt: Codable, Sendable {
    var generation: UUID?
    var revision: UInt64 = 0
    var sentAt: Date?
    var retiredGenerations: Set<UUID> = []

    func shouldAccept(_ payload: SearchSourceCompanionPayload) -> Bool {
        guard payload.sentAt.timeIntervalSince1970.isFinite, payload.revision < UInt64.max else { return false }
        if payload.generation == generation {
            if payload.revision > 0 || revision > 0 { return payload.revision > revision }
            return sentAt == nil || payload.sentAt > sentAt!
        }
        // Once a generation-aware phone has connected, a queued legacy payload cannot replace it.
        guard let incoming = payload.generation, !retiredGenerations.contains(incoming) else { return false }
        return sentAt == nil || payload.sentAt > sentAt!
    }

    mutating func accept(_ payload: SearchSourceCompanionPayload) {
        if generation != payload.generation, let generation { retiredGenerations.insert(generation) }
        generation = payload.generation; revision = payload.revision; sentAt = payload.sentAt
    }
}

private struct SearchCatalogCheckpoint: Codable {
    let generation: UUID
    let revision: UInt64
}

/// Kept outside UserDefaults and excluded from device backups so restoring an older defaults
/// snapshot cannot roll back the phone's generation/revision unnoticed.
private enum SearchCatalogCheckpointStore {
    static var url: URL? {
        #if os(macOS)
        // Standalone fixtures use isolated storage and never write application metadata to the host's defaults.
        if let directory = ProcessInfo.processInfo.environment["WA_SEARCH_FIXTURE_DIRECTORY"] {
            return URL(fileURLWithPath: directory).appendingPathComponent("SearchSourceCatalogCheckpoint.json")
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.wristassistant.search", isDirectory: true)
            .appendingPathComponent("SearchSourceCatalogCheckpoint.json")
    }
    static func read() -> SearchCatalogCheckpoint? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SearchCatalogCheckpoint.self, from: data)
    }
    static func write(generation: UUID, revision: UInt64) {
        guard var url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(SearchCatalogCheckpoint(generation: generation, revision: revision))
            try data.write(to: url, options: .atomic)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            // This contains no credentials. The defaults identity remains stable if a local
            // checkpoint cannot be written; credential writes still fail explicitly on error.
        }
    }
}

public struct SearchSourceCredential: Codable, Sendable {
    public let sourceID: UUID
    public let value: String
    public init(sourceID: UUID, value: String) { self.sourceID = sourceID; self.value = value }
}

public enum SearchCredentialStore {
    private static let service = "com.wristassistant.search-credentials"
    private struct Record: Codable { let binding: String; let value: String }
    /// Bind each secret to its exact destination and authentication contract. An interrupted
    /// profile/credential update can temporarily make it unavailable, never send it to an old URL.
    static func binding(for profile: SearchSourceProfile) -> String? {
        guard let url = try? profile.validatedURL(), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme?.lowercased(); components.host = components.host?.lowercased()
        guard let destination = components.url?.absoluteString else { return nil }
        return [profile.kind.rawValue, destination, profile.authentication.rawValue, profile.headerName.lowercased()].joined(separator: "\u{1F}")
    }
    static func matches(binding stored: String, profile: SearchSourceProfile) -> Bool { binding(for: profile) == stored }
    public static func get(_ profile: SearchSourceProfile) -> String? {
        var query = base(profile.id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        guard let record = try? JSONDecoder().decode(Record.self, from: data), matches(binding: record.binding, profile: profile) else { return nil }
        return record.value
    }
    public static func set(_ value: String, for profile: SearchSourceProfile) throws {
        let query = base(profile.id)
        if value.isEmpty { try delete(profile.id); return }
        guard let binding = binding(for: profile) else { throw SearchError.invalidConfiguration("The search destination is invalid.") }
        let data = try JSONEncoder().encode(Record(binding: binding, value: value))
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw SearchError.invalidConfiguration("The search credential could not be saved securely. Unlock the device and try again.")
        }
    }
    public static func delete(_ id: UUID) throws {
        let status = SecItemDelete(base(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SearchError.invalidConfiguration("The search credential could not be removed securely. Unlock the device and try again.")
        }
    }
    private static func base(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
}

@MainActor
public final class SearchSourceStore: ObservableObject {
    public static let shared = SearchSourceStore()
    @Published public private(set) var sources: [SearchSourceProfile] = []
    @Published public private(set) var selectedSourceID: UUID?
    public var selectedSource: SearchSourceProfile? { sources.first { $0.id == selectedSourceID } }
    /// Consumers cancel active searches when the chosen source or its credentials change.
    public static let didChange = Notification.Name("WristAssistantSearchSourcesDidChange")
    private let defaults: UserDefaults
    private let profilesKey = "search-source-profiles-v1"
    private let selectedKey = "search-source-selected-v1"
    private let receivedKey = "search-source-received-at-v1"
    private let revisionKey = "search-source-revision-v1"
    private let receivedRevisionKey = "search-source-received-revision-v1"
    private let generationKey = "search-source-generation-v1"
    private let receiptKey = "search-source-receipt-v1"
    private var catalogRevision: UInt64
    private var catalogGeneration: UUID
    private var receipt: SearchCatalogReceipt

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedRevision = defaults.string(forKey: revisionKey).flatMap(UInt64.init) ?? 0
        let savedGeneration = defaults.string(forKey: generationKey).flatMap(UUID.init(uuidString:))
        let checkpoint = SearchCatalogCheckpointStore.read()
        let identity = Self.reconcileCatalogIdentity(savedGeneration: savedGeneration, savedRevision: savedRevision,
            checkpointGeneration: checkpoint?.generation, checkpointRevision: checkpoint?.revision)
        self.catalogGeneration = identity.generation
        self.catalogRevision = identity.revision
        self.receipt = defaults.data(forKey: receiptKey).flatMap { try? JSONDecoder().decode(SearchCatalogReceipt.self, from: $0) }
            ?? SearchCatalogReceipt(generation: nil, revision: defaults.string(forKey: receivedRevisionKey).flatMap(UInt64.init) ?? 0,
                sentAt: defaults.object(forKey: receivedKey) as? Date)
        if let data = defaults.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([SearchSourceProfile].self, from: data) {
            sources = decoded
        }
        selectedSourceID = defaults.string(forKey: selectedKey).flatMap(UUID.init(uuidString:))
        if !sources.contains(where: { $0.id == selectedSourceID }) { selectedSourceID = nil }
        defaults.set(catalogGeneration.uuidString, forKey: generationKey)
        defaults.set(String(catalogRevision), forKey: revisionKey)
        SearchCatalogCheckpointStore.write(generation: catalogGeneration, revision: catalogRevision)
    }
    public func credential(for sourceID: UUID) -> String? {
        guard let profile = sources.first(where: { $0.id == sourceID }) else { return nil }
        return SearchCredentialStore.get(profile)
    }
    public func select(_ id: UUID?) {
        guard id == nil || sources.contains(where: { $0.id == id }) else { return }
        selectedSourceID = id; persist()
    }
    public func upsert(_ profile: SearchSourceProfile, credential: String) throws {
        _ = try profile.validatedURL()
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, profile.name.count <= 100 else {
            throw SearchError.invalidConfiguration("Give the search source a name.")
        }
        guard sources.contains(where: { $0.id == profile.id }) || sources.count < 32 else {
            throw SearchError.invalidConfiguration("Keep up to 32 saved search sources.")
        }
        if profile.authentication != .none || profile.kind == .miniMaxPlan {
            guard !credential.isEmpty, credential.count <= 16_384, !credential.contains("\r"), !credential.contains("\n") else {
                throw SearchError.missingCredential
            }
        }
        if profile.kind == .customMCP {
            guard !profile.toolName.isEmpty, !profile.queryField.isEmpty, profile.inputSchemaJSON != nil else {
                throw SearchError.invalidConfiguration("Test the connection and select a search tool before saving.")
            }
            _ = try profile.fixedArguments()
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        try SearchCredentialStore.set(profile.authentication == .none && profile.kind == .customMCP ? "" : credential, for: profile)
        if let index = sources.firstIndex(where: { $0.id == profile.id }) { sources[index] = profile }
        else { sources.append(profile) }
        persist()
    }
    public func delete(_ id: UUID) throws {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        try SearchCredentialStore.delete(id)
        sources.removeAll { $0.id == id }
        if selectedSourceID == id { selectedSourceID = nil }
        persist()
    }
    public func companionPayload() -> SearchSourceCompanionPayload {
        SearchSourceCompanionPayload(sources: sources, selectedSourceID: selectedSourceID,
            credentials: sources.map { SearchSourceCredential(sourceID: $0.id, value: credential(for: $0.id) ?? "") },
            revision: catalogRevision, generation: catalogGeneration)
    }
    public func applyCompanionPayload(_ payload: SearchSourceCompanionPayload) throws {
        guard receipt.shouldAccept(payload) else { return }
        // Validate everything before replacing a local catalog or any credential.
        guard payload.sources.count <= 32, Set(payload.sources.map(\.id)).count == payload.sources.count else {
            throw SearchError.invalidConfiguration("Invalid companion search catalog.")
        }
        for profile in payload.sources { _ = try profile.validatedURL(); _ = try profile.fixedArguments() }
        let allowed = Set(payload.sources.map(\.id))
        guard Set(payload.credentials.map(\.sourceID)) == allowed,
              payload.credentials.count == allowed.count else {
            throw SearchError.invalidConfiguration("The companion search credential set is incomplete.")
        }
        for credential in payload.credentials where allowed.contains(credential.sourceID) {
            guard credential.value.count <= 16_384, !credential.value.contains("\r"), !credential.value.contains("\n") else {
                throw SearchError.invalidConfiguration("Invalid companion search credential.")
            }
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        for credential in payload.credentials where allowed.contains(credential.sourceID) {
            guard let profile = payload.sources.first(where: { $0.id == credential.sourceID }) else { continue }
            try SearchCredentialStore.set(credential.value, for: profile)
        }
        for removed in sources where !allowed.contains(removed.id) { try SearchCredentialStore.delete(removed.id) }
        sources = payload.sources
        selectedSourceID = allowed.contains(payload.selectedSourceID ?? UUID()) ? payload.selectedSourceID : nil
        defaults.set(payload.sentAt, forKey: receivedKey)
        defaults.set(String(payload.revision), forKey: receivedRevisionKey)
        receipt.accept(payload)
        if let data = try? JSONEncoder().encode(receipt) { defaults.set(data, forKey: receiptKey) }
        catalogRevision = payload.revision
        if let generation = payload.generation { catalogGeneration = generation }
        persist(incrementRevision: false)
    }
    nonisolated static func isNewerRevision(_ incoming: UInt64, than received: UInt64) -> Bool { incoming > received }
    nonisolated static func reconcileCatalogIdentity(savedGeneration: UUID?, savedRevision: UInt64,
        checkpointGeneration: UUID?, checkpointRevision: UInt64?) -> (generation: UUID, revision: UInt64) {
        if let savedGeneration, savedGeneration == checkpointGeneration,
           let checkpointRevision, savedRevision >= checkpointRevision, savedRevision < UInt64.max {
            return (savedGeneration, savedRevision)
        }
        return (UUID(), 1)
    }
    private func persist(incrementRevision: Bool = true) {
        if incrementRevision {
            if catalogRevision == UInt64.max - 1 { catalogGeneration = UUID(); catalogRevision = 1 }
            else { catalogRevision += 1 }
        }
        defaults.set(String(catalogRevision), forKey: revisionKey)
        defaults.set(catalogGeneration.uuidString, forKey: generationKey)
        SearchCatalogCheckpointStore.write(generation: catalogGeneration, revision: catalogRevision)
        if let data = try? JSONEncoder().encode(sources) { defaults.set(data, forKey: profilesKey) }
        defaults.set(selectedSourceID?.uuidString, forKey: selectedKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
