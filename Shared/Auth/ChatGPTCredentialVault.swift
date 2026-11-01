import Foundation
import Security

/// Tokens are confined to a separate non-synchronizing Keychain service. This
/// type must never be added to endpoint, backup, diagnostic or bulk-sync models.
public struct ChatGPTCredentialRecord: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "ChatGPTCredentialRecord(<redacted>)" }
    public var debugDescription: String { description }
    public let identity: ChatGPTVerifiedIdentity
    public let accessToken: String
    public let refreshToken: String
    public let idToken: String
    public let grantedScopes: Set<String>
    public let expiresAt: Date
    public let savedAt: Date

    public var permitsInference: Bool {
        grantedScopes.contains("resource.invoke") && grantedScopes.contains("chatgpt.tokens.use.direct")
    }

    public init(identity: ChatGPTVerifiedIdentity, accessToken: String, refreshToken: String,
                idToken: String, grantedScopes: Set<String>, expiresAt: Date, now: Date = Date()) throws {
        guard !accessToken.isEmpty, !refreshToken.isEmpty, !idToken.isEmpty,
              expiresAt > now, expiresAt.timeIntervalSince1970.isFinite else { throw ChatGPTOAuthError.invalidCredentials }
        self.identity = identity; self.accessToken = accessToken; self.refreshToken = refreshToken
        self.idToken = idToken; self.grantedScopes = grantedScopes; self.expiresAt = expiresAt; savedAt = now
    }
}

public actor ChatGPTCredentialVault {
    public static let shared = ChatGPTCredentialVault()
    private let storage: any ChatGPTSecureStorage
    private var refreshes: [String: Task<ChatGPTCredentialRecord, Error>] = [:]
    private var generations: [String: UUID] = [:]
    public init() { storage = ChatGPTKeychainStorage() }
    init(storage: any ChatGPTSecureStorage) { self.storage = storage }

    public func stableHostID() throws -> String {
        if let data = try storage.read("installation-host"), let existing = String(data: data, encoding: .utf8),
           existing.hasPrefix("urn:uuid:"), UUID(uuidString: String(existing.dropFirst(9))) != nil { return existing }
        let value = "urn:uuid:" + UUID().uuidString.lowercased()
        try storage.write(Data(value.utf8), account: "installation-host")
        return value
    }

    public func load(clientID: String) throws -> ChatGPTCredentialRecord? {
        guard ChatGPTOAuth.isIssuedClientID(clientID) else { throw ChatGPTOAuthError.invalidClientID }
        guard let data = try storage.read("session." + clientID) else { return nil }
        let record = try JSONDecoder().decode(ChatGPTCredentialRecord.self, from: data)
        guard record.identity.clientID == clientID, record.identity.issuer == ChatGPTOAuth.issuer else {
            throw ChatGPTOAuthError.invalidCredentials
        }
        return record
    }

    public func save(_ record: ChatGPTCredentialRecord) throws {
        let id = record.identity.clientID
        guard ChatGPTOAuth.isIssuedClientID(id) else { throw ChatGPTOAuthError.invalidClientID }
        if let previous = try load(clientID: id), previous.identity.subject != record.identity.subject {
            throw ChatGPTOAuthError.identityChanged
        }
        refreshes[id]?.cancel(); refreshes[id] = nil; generations[id] = UUID()
        try storage.write(try JSONEncoder().encode(record), account: "session." + id)
    }

    /// One in-flight refresh per registration. Rotation replaces the entire
    /// token set with SecItemUpdate, so a failed write retains the prior record.
    /// Sign-out or account replacement invalidates any late refresh callback.
    public func refreshed(clientID: String,
                          operation: @escaping @Sendable (ChatGPTCredentialRecord) async throws -> ChatGPTCredentialRecord) async throws -> ChatGPTCredentialRecord {
        if let existing = refreshes[clientID] { return try await existing.value }
        guard let current = try load(clientID: clientID) else { throw ChatGPTOAuthError.renewalRequired }
        let generation = generations[clientID] ?? UUID()
        generations[clientID] = generation
        let task = Task {
            let replacement = try await operation(current)
            try Task.checkCancellation()
            return try self.commitRotation(replacement, previous: current, generation: generation)
        }
        refreshes[clientID] = task
        do {
            let replacement = try await task.value
            if generations[clientID] == generation { refreshes[clientID] = nil }
            return replacement
        } catch {
            if generations[clientID] == generation { refreshes[clientID] = nil }
            throw error
        }
    }

    private func commitRotation(_ replacement: ChatGPTCredentialRecord, previous: ChatGPTCredentialRecord,
                                generation: UUID) throws -> ChatGPTCredentialRecord {
        let id = previous.identity.clientID
        guard generations[id] == generation else { throw ChatGPTOAuthError.sessionChanged }
        guard replacement.identity.clientID == id,
              replacement.identity.issuer == previous.identity.issuer,
              replacement.identity.subject == previous.identity.subject else { throw ChatGPTOAuthError.identityChanged }
        try storage.write(try JSONEncoder().encode(replacement), account: "session." + id)
        return replacement
    }

    /// The host ID remains stable after sign-out. Remote revocation must be
    /// attempted by the eventual session layer before calling this local clear.
    public func clear(clientID: String) throws {
        refreshes[clientID]?.cancel(); refreshes[clientID] = nil; generations[clientID] = UUID()
        try storage.delete("session." + clientID)
    }
}

protocol ChatGPTSecureStorage: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(_ account: String) throws
}

private struct ChatGPTKeychainStorage: ChatGPTSecureStorage {
    private let service = "com.wristassistant.chatgpt.oauth"

    func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ChatGPTOAuthError.credentialStorage(status) }
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw ChatGPTOAuthError.credentialStorage(status) }
        return data
    }
    func write(_ data: Data, account: String) throws {
        let base = query(account)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(base as CFDictionary, update as CFDictionary) }
        }
        guard status == errSecSuccess else { throw ChatGPTOAuthError.credentialStorage(status) }
    }
}
