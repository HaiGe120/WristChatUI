import Foundation
import Security

public struct ChatGPTVerifiedIdentity: Codable, Hashable, Sendable {
    public let issuer: String
    public let clientID: String
    public let subject: String
    public let email: String?
    public let name: String?
    // Created by the verifier; persisted only inside the protected credential record.
    fileprivate init(clientID: String, claims: ChatGPTIDTokenVerifier.Claims) {
        issuer = claims.iss; self.clientID = clientID; subject = claims.sub
        email = claims.email; name = claims.name
    }
}

/// Narrow RS256 verifier for OpenAI's published OIDC signing contract. JWKS must
/// be obtained from the trusted discovery destination, never a JWT header URL.
public enum ChatGPTIDTokenVerifier {
    public static let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!

    public static func verify(_ token: String, jwks: Data, clientID: String, nonce: String,
                              expectedSubject: String? = nil, now: Date = Date()) throws -> ChatGPTVerifiedIdentity {
        guard token.utf8.count <= 32768, jwks.count <= 262144,
              ChatGPTOAuth.isIssuedClientID(clientID), !nonce.isEmpty else { throw ChatGPTOAuthError.invalidIDToken }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = ChatGPTOAuth.decodeBase64URL(parts[0]),
              let payload = ChatGPTOAuth.decodeBase64URL(parts[1]),
              let signature = ChatGPTOAuth.decodeBase64URL(parts[2]),
              let header = try? JSONDecoder().decode(Header.self, from: headerData),
              header.alg == "RS256", header.crit == nil || header.crit?.isEmpty == true,
              let keys = try? JSONDecoder().decode(JWKSet.self, from: jwks),
              let kid = header.kid, !kid.isEmpty else { throw ChatGPTOAuthError.invalidIDToken }
        let matches = keys.keys.filter { $0.kid == kid && $0.kty == "RSA" && ($0.alg == nil || $0.alg == "RS256")
            && ($0.use == nil || $0.use == "sig") && ($0.key_ops == nil || $0.key_ops?.contains("verify") == true) }
        guard matches.count == 1, let jwk = matches.first,
              let modulus = ChatGPTOAuth.decodeBase64URL(jwk.n), modulus.count >= 256, modulus.count <= 1024,
              let exponent = ChatGPTOAuth.decodeBase64URL(jwk.e), !exponent.isEmpty, exponent.count <= 8 else { throw ChatGPTOAuthError.invalidIDToken }
        let keyData = sequence(integer(modulus) + integer(exponent))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                      kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil),
              let keyAttributes = SecKeyCopyAttributes(key) as? [String: Any],
              let keyBits = keyAttributes[kSecAttrKeySizeInBits as String] as? Int, keyBits >= 2048,
              SecKeyIsAlgorithmSupported(key, .verify, .rsaSignatureMessagePKCS1v15SHA256),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data((parts[0] + "." + parts[1]).utf8) as CFData,
                                    signature as CFData, nil),
              let claims = try? JSONDecoder().decode(Claims.self, from: payload) else { throw ChatGPTOAuthError.invalidIDToken }
        let time = now.timeIntervalSince1970
        guard claims.iss == ChatGPTOAuth.issuer, !claims.sub.isEmpty,
              claims.aud.values.contains(clientID),
              (claims.aud.values.count == 1 || claims.azp == clientID),
              (claims.azp == nil || claims.azp == clientID),
              claims.exp.isFinite, claims.iat.isFinite, claims.exp > claims.iat,
              time < claims.exp + 5, claims.iat <= time + 5,
              claims.nbf == nil || (claims.nbf!.isFinite && claims.nbf! <= time + 5),
              let returnedNonce = claims.nonce,
              ChatGPTOAuth.constantTimeEqual(returnedNonce, nonce) else { throw ChatGPTOAuthError.invalidIDToken }
        if let expectedSubject, claims.sub != expectedSubject { throw ChatGPTOAuthError.identityChanged }
        return ChatGPTVerifiedIdentity(clientID: clientID, claims: claims)
    }

    private struct Header: Decodable { let alg: String; let kid: String?; let crit: [String]? }
    private struct JWKSet: Decodable { let keys: [JWK] }
    private struct JWK: Decodable {
        let kty: String; let kid: String?; let alg: String?; let use: String?
        let key_ops: [String]?; let n: String; let e: String
    }
    fileprivate struct Claims: Decodable {
        let iss: String; let sub: String; let aud: Audience; let azp: String?
        let exp: Double; let iat: Double; let nbf: Double?; let nonce: String?
        let email: String?; let name: String?
    }
    fileprivate enum Audience: Decodable {
        case one(String), many([String])
        var values: [String] { switch self { case .one(let value): return [value]; case .many(let values): return values } }
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) { self = .one(value) }
            else { self = .many(try container.decode([String].self)) }
        }
    }
    private static func integer(_ value: Data) -> Data {
        var bytes = value
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        return Data([0x02]) + length(bytes.count) + bytes
    }
    private static func sequence(_ value: Data) -> Data { Data([0x30]) + length(value.count) + value }
    private static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var count = count, bytes = [UInt8]()
        while count > 0 { bytes.insert(UInt8(count & 0xff), at: 0); count >>= 8 }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }
}
