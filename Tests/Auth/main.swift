import Foundation
import Security
import CryptoKit

func require(_ condition: Bool, _ label: String) throws {
    if !condition { throw Failure(label) }
}
struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
func rejects(_ label: String, _ operation: () throws -> Void) throws {
    do { try operation(); throw Failure("accepted " + label) }
    catch is Failure { throw Failure("accepted " + label) }
    catch { }
}

final class MemoryCredentials: ChatGPTSecureStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: Data] = [:]
    var failWrites = false
    func read(_ account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return records[account] }
    func write(_ data: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw ChatGPTOAuthError.credentialStorage(-1) }
        records[account] = data
    }
    func delete(_ account: String) throws { lock.lock(); defer { lock.unlock() }; records[account] = nil }
}
actor Gate {
    var opened = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func release() { opened = true; waiters.forEach { $0.resume() }; waiters = [] }
}
actor Count { var value = 0; func increment() { value += 1 } }

struct RSAFixture {
    let privateKey: SecKey
    let jwks: Data
    init() throws {
        let params: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        var cryptoError: Unmanaged<CFError>?
        guard let generated = SecKeyCreateRandomKey(params as CFDictionary, &cryptoError),
              let key = SecKeyCopyPublicKey(generated),
              let representation = SecKeyCopyExternalRepresentation(key, &cryptoError) else {
            throw Failure("macOS RSA test service unavailable; run with crypto-service access")
        }
        privateKey = generated
        let encoded = representation as Data
        let bytes = [UInt8](encoded)
        var cursor = 0
        func length() -> Int {
            var size = Int(bytes[cursor]); cursor += 1
            if size & 0x80 != 0 {
                let count = size & 0x7f; size = 0
                for _ in 0..<count { size = size << 8 | Int(bytes[cursor]); cursor += 1 }
            }
            return size
        }
        func integer() -> Data {
            precondition(bytes[cursor] == 2); cursor += 1
            let size = length(); var result = Data(bytes[cursor..<cursor + size]); cursor += size
            while result.count > 1 && result.first == 0 { result.removeFirst() }
            return result
        }
        precondition(bytes[cursor] == 0x30); cursor += 1; _ = length()
        let modulus = integer(), exponent = integer()
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "kid": "fixture", "use": "sig", "alg": "RS256", "n": ChatGPTOAuth.base64URL(modulus), "e": ChatGPTOAuth.base64URL(exponent)]]])
    }
    func sign(_ claims: [String: Any], alg: String = "RS256") throws -> String {
        let head = ChatGPTOAuth.base64URL(try JSONSerialization.data(withJSONObject: ["alg": alg, "kid": "fixture"]))
        let body = ChatGPTOAuth.base64URL(try JSONSerialization.data(withJSONObject: claims))
        let input = head + "." + body
        let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)! as Data
        return input + "." + ChatGPTOAuth.base64URL(signature)
    }
}

@main struct AuthFixtures {
    static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let callback = URL(string: "http://127.0.0.1:1455/auth/callback")!
        let host = "urn:uuid:" + UUID().uuidString
        let attempt = try ChatGPTAuthorizationAttempt(redirectURI: callback, hostID: host, now: now)
        try require(attempt.codeVerifier.count == 43 && attempt.state != attempt.nonce, "fresh secure values")
        try require(attempt.codeChallenge == ChatGPTOAuth.base64URL(Data(SHA256.hash(data: Data(attempt.codeVerifier.utf8)))), "PKCE S256")
        let initial = URLComponents(url: attempt.authorizationURL(), resolvingAgainstBaseURL: false)!.queryItems!
        try require(initial.contains { $0.name == "client_id" && $0.value == "dynamic_agent_client" }, "dynamic registration")
        let valid = URL(string: callback.absoluteString + "?code=code&state=" + attempt.state + "&client_id=oaiapp_fixture")!
        try require(try attempt.validateCallback(valid, now: now).clientID == "oaiapp_fixture", "issued registration ID")
        try rejects("expired callback") { _ = try attempt.validateCallback(valid, now: now.addingTimeInterval(301)) }
        try rejects("wrong state") { _ = try attempt.validateCallback(URL(string: callback.absoluteString + "?code=x&state=wrong&client_id=oaiapp_fixture")!, now: now) }
        try rejects("duplicate state") { _ = try attempt.validateCallback(URL(string: valid.absoluteString + "&state=" + attempt.state)!, now: now) }
        try rejects("custom-scheme callback") { _ = try ChatGPTAuthorizationAttempt(redirectURI: URL(string: "wristassistant://auth/callback")!, hostID: host) }
        try rejects("localhost callback") { _ = try ChatGPTAuthorizationAttempt(redirectURI: URL(string: "http://localhost:1455/auth/callback")!, hostID: host) }
        try rejects("changed callback path") { _ = try attempt.validateCallback(URL(string: valid.absoluteString.replacingOccurrences(of: "/auth/callback", with: "/callback"))!, now: now) }
        try rejects("denial with wrong state") { _ = try attempt.validateCallback(URL(string: callback.absoluteString + "?state=wrong&error=access_denied")!, now: now) }
        let returning = try ChatGPTAuthorizationAttempt(redirectURI: callback, hostID: host, existingClientID: "oaiapp_returning", now: now)
        let returningURL = URL(string: callback.absoluteString + "?code=code&state=" + returning.state)!
        try require(try returning.validateCallback(returningURL, now: now).clientID == "oaiapp_returning", "reuse existing ID")
        try rejects("registration replacement") { _ = try returning.validateCallback(URL(string: returningURL.absoluteString + "&client_id=oaiapp_other")!, now: now) }
        let broker = ChatGPTAuthorizationBroker()
        await broker.begin(attempt)
        _ = try await broker.consume(valid, now: now)
        do { _ = try await broker.consume(valid, now: now); throw Failure("replayed callback") }
        catch ChatGPTOAuthError.noPendingAttempt { }
        try require(ChatGPTOAuth.permitsCredentialDestination(URL(string: "https://api.openai.com/v1/responses")!, purpose: .inference), "official inference destination")
        for wrong in ["https://gateway.example/v1/responses", "https://api.openai.com.evil.example/v1/responses", "https://api.openai.com:444/v1/responses", "https://api.openai.com/v1/chat/completions", "https://api.openai.com/v1/responses?redirect=evil"] {
            try require(!ChatGPTOAuth.permitsCredentialDestination(URL(string: wrong)!, purpose: .inference), "reject non-official destination")
        }
        let rsa = try RSAFixture()
        let claims: [String: Any] = ["iss": ChatGPTOAuth.issuer, "sub": "subject", "aud": "oaiapp_fixture", "exp": now.timeIntervalSince1970 + 600,
                                    "iat": now.timeIntervalSince1970, "nonce": attempt.nonce]
        let signed = try rsa.sign(claims)
        let identity = try ChatGPTIDTokenVerifier.verify(signed, jwks: rsa.jwks, clientID: "oaiapp_fixture", nonce: attempt.nonce, now: now)
        try require(identity.subject == "subject", "verified signature and claims")
        for (field, value) in [("iss", "https://evil.example"), ("aud", "oaiapp_other"), ("nonce", "wrong")] {
            var changed = claims; changed[field] = value
            let invalid = try rsa.sign(changed)
            try rejects("wrong " + field) { _ = try ChatGPTIDTokenVerifier.verify(invalid, jwks: rsa.jwks, clientID: "oaiapp_fixture", nonce: attempt.nonce, now: now) }
        }
        try rejects("expired token") { _ = try ChatGPTIDTokenVerifier.verify(signed, jwks: rsa.jwks, clientID: "oaiapp_fixture", nonce: attempt.nonce, now: now.addingTimeInterval(606)) }
        try rejects("changed returning account") { _ = try ChatGPTIDTokenVerifier.verify(signed, jwks: rsa.jwks, clientID: "oaiapp_fixture", nonce: attempt.nonce, expectedSubject: "other", now: now) }
        let wrongAlg = try rsa.sign(claims, alg: "none")
        try rejects("algorithm substitution") { _ = try ChatGPTIDTokenVerifier.verify(wrongAlg, jwks: rsa.jwks, clientID: "oaiapp_fixture", nonce: attempt.nonce, now: now) }
        let pieces = signed.split(separator: ".").map(String.init)
        let tampered = pieces[0] + "." + pieces[1] + "." + String(repeating: "A", count: pieces[2].count)
        try rejects("invalid signature") { _ = try ChatGPTIDTokenVerifier.verify(tampered, jwks: rsa.jwks, clientID: "oaiapp_fixture", nonce: attempt.nonce, now: now) }

        let storage = MemoryCredentials(), vault = ChatGPTCredentialVault(storage: MemoryCredentials())
        let stable = try await vault.stableHostID()
        try require(try await vault.stableHostID() == stable, "persistent installation host")
        let sessions = ChatGPTCredentialVault(storage: storage)
        let original = try ChatGPTCredentialRecord(identity: identity, accessToken: "old-access", refreshToken: "old-refresh", idToken: signed,
                                                  grantedScopes: ["openid"], expiresAt: now.addingTimeInterval(1000), now: now)
        let renewed = try ChatGPTCredentialRecord(identity: identity, accessToken: "new-access", refreshToken: "rotated-refresh", idToken: signed,
                                                 grantedScopes: ["resource.invoke", "chatgpt.tokens.use.direct"], expiresAt: now.addingTimeInterval(2000), now: now)
        try require(!original.permitsInference && renewed.permitsInference, "identity distinct from inference permission")
        try await sessions.save(original)
        let gate = Gate(), started = Gate(), counter = Count()
        let operation: @Sendable (ChatGPTCredentialRecord) async throws -> ChatGPTCredentialRecord = { _ in
            await counter.increment(); await started.release(); await gate.wait(); return renewed
        }
        let first = Task { try await sessions.refreshed(clientID: "oaiapp_fixture", operation: operation) }
        await started.wait()
        let second = Task { try await sessions.refreshed(clientID: "oaiapp_fixture", operation: operation) }
        for _ in 0..<100 { await Task.yield() }
        await gate.release()
        _ = try await first.value; _ = try await second.value
        try require(await counter.value == 1, "serialized token refresh")
        try require(try await sessions.load(clientID: "oaiapp_fixture")?.refreshToken == "rotated-refresh", "atomic rotation persisted")
        let logoutGate = Gate(), logoutStarted = Gate()
        let late = Task { try await sessions.refreshed(clientID: "oaiapp_fixture") { _ in
            await logoutStarted.release(); await logoutGate.wait(); return renewed
        } }
        await logoutStarted.wait(); try await sessions.clear(clientID: "oaiapp_fixture"); await logoutGate.release()
        do { _ = try await late.value; throw Failure("late refresh survived sign-out") } catch is Failure { throw Failure("late refresh survived sign-out") } catch { }
        try require(try await sessions.load(clientID: "oaiapp_fixture") == nil, "sign-out cleared credentials")
        try await sessions.save(original); storage.failWrites = true
        do { try await sessions.save(renewed); throw Failure("failed write accepted") } catch is Failure { throw Failure("failed write accepted") } catch { }
        storage.failWrites = false
        try require(try await sessions.load(clientID: "oaiapp_fixture")?.refreshToken == "old-refresh", "failed rotation retains prior tokens")
        try require(!ChatGPTSignInReadiness.isEnabled, "unverified native/product flow remains gated")
        print("OAuth fixtures passed: callbacks/PKCE/replay, credential destinations, real RSA signatures/claims, single-flight rotation, sign-out race, atomic persistence")
    }
}
