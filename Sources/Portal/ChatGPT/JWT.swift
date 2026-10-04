import Foundation
import Security

/// Just enough JWT to verify an OpenID Connect ID token: RS256 against a published key set, plus the standard claims.
enum JWT {
    struct Header: Decodable {
        var alg: String
        var kid: String?
    }

    struct Claims: Decodable, Sendable {
        var iss: String
        var sub: String
        var aud: [String]
        var exp: Double
        var nonce: String?
        var email: String?
        var name: String?

        enum CodingKeys: String, CodingKey { case iss, sub, aud, exp, nonce, email, name }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            iss = try c.decode(String.self, forKey: .iss)
            sub = try c.decode(String.self, forKey: .sub)
            if let one = try? c.decode(String.self, forKey: .aud) { aud = [one] } else { aud = try c.decode([String].self, forKey: .aud) }
            exp = try c.decode(Double.self, forKey: .exp)
            nonce = try c.decodeIfPresent(String.self, forKey: .nonce)
            email = try c.decodeIfPresent(String.self, forKey: .email)
            name = try c.decodeIfPresent(String.self, forKey: .name)
        }
    }

    struct KeySet: Decodable {
        struct Key: Decodable {
            var kty: String
            var kid: String?
            var n: String?
            var e: String?
        }
        var keys: [Key]
    }

    typealias AuthError = ChatGPTAuth.AuthError

    static func verify(_ token: String, keys: KeySet, issuer: String, audience: String, nonce: String?, now: Date) throws -> Claims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headerData = base64URLDecode(parts[0]), let payload = base64URLDecode(parts[1]),
              let signature = base64URLDecode(parts[2]) else { throw AuthError.invalidIDToken("malformed") }
        let header = try decode(Header.self, headerData)
        guard header.alg == "RS256" else { throw AuthError.invalidIDToken("unsupported algorithm \(header.alg)") }
        let candidates = keys.keys.filter { $0.kty == "RSA" && (header.kid == nil || $0.kid == header.kid) }
        guard !candidates.isEmpty else { throw AuthError.invalidIDToken("unknown signing key") }
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        let valid = candidates.contains { key in
            guard let publicKey = rsaKey(key) else { return false }
            return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil)
        }
        guard valid else { throw AuthError.invalidIDToken("bad signature") }

        let claims = try decode(Claims.self, payload)
        guard claims.iss == issuer else { throw AuthError.invalidIDToken("wrong issuer") }
        guard claims.aud.contains(audience) else { throw AuthError.invalidIDToken("wrong audience") }
        guard Date(timeIntervalSince1970: claims.exp).addingTimeInterval(300) > now else { throw AuthError.invalidIDToken("expired") }
        if let nonce { guard claims.nonce == nonce else { throw AuthError.invalidIDToken("nonce mismatch") } }
        return claims
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw AuthError.invalidIDToken("unreadable") }
    }

    static func base64URLDecode<S: StringProtocol>(_ string: S) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    /// A JWK RSA public key as a SecKey (PKCS #1 RSAPublicKey DER: SEQUENCE { INTEGER n, INTEGER e }).
    static func rsaKey(_ key: KeySet.Key) -> SecKey? {
        guard let n = key.n.flatMap(base64URLDecode), let e = key.e.flatMap(base64URLDecode) else { return nil }
        let der = derSequence(derInteger(n) + derInteger(e))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: n.drop { $0 == 0 }.count * 8,
        ]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }

    private static func derInteger(_ bytes: Data) -> Data {
        var value = Data(bytes.drop { $0 == 0 })
        if value.isEmpty { value = Data([0]) }
        if value.first! & 0x80 != 0 { value.insert(0, at: 0) }
        return Data([0x02]) + derLength(value.count) + value
    }

    private static func derSequence(_ content: Data) -> Data {
        Data([0x30]) + derLength(content.count) + content
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        var bytes: [UInt8] = []
        var remaining = length
        while remaining > 0 { bytes.insert(UInt8(remaining & 0xff), at: 0); remaining >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
