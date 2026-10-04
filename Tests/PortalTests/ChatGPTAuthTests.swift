import Foundation
import Security
import Testing
@testable import Portal

struct ChatGPTAuthTests {
    @Test func pkceChallengeMatchesRFC7636() {
        #expect(ChatGPTAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func registrationURLAsksForPlanUsageAndNamesTheApp() throws {
        let attempt = ChatGPTAuth.Attempt(clientID: ChatGPTAuth.registrationClientID, port: 1455, state: "s", nonce: "n", verifier: "v")
        let url = ChatGPTAuth().authorizeURL(attempt, hostID: "urn:uuid:abc", idTokenHint: "ignored", loginHint: "ignored")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let items = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        #expect(url.absoluteString.hasPrefix("https://auth.openai.com/api/accounts/authorize?"))
        #expect(items["client_id"] == "dynamic_agent_client")
        #expect(items["agent_name_hint"] == "Portal")
        #expect(items["ext_agent_host_id"] == "urn:uuid:abc")
        #expect(items["redirect_uri"] == "http://127.0.0.1:1455/auth/callback")
        #expect(items["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        #expect(items["resource"] == "https://api.openai.com/v1")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["code_challenge"] == ChatGPTAuth.challenge(for: "v"))
        #expect(items["id_token_hint"] == nil && items["login_hint"] == nil)
        #expect(!url.absoluteString.contains("+"))
    }

    @Test func returningURLUsesIssuedClientAndHints() throws {
        let attempt = ChatGPTAuth.Attempt(clientID: "oaiapp_123", port: 50000)
        let url = ChatGPTAuth().authorizeURL(attempt, hostID: "urn:uuid:abc", idTokenHint: "id.tok.en", loginHint: "coach+1@example.com")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["client_id"] == "oaiapp_123")
        #expect(items["agent_name_hint"] == nil)
        #expect(items["id_token_hint"] == "id.tok.en")
        #expect(items["login_hint"] == "coach+1@example.com")
        #expect(url.absoluteString.contains("login_hint=coach%2B1%40example.com"))
    }

    @Test func callbackValidation() throws {
        let registering = ChatGPTAuth.Attempt(clientID: ChatGPTAuth.registrationClientID, port: 1455, state: "s")
        #expect(try ChatGPTAuth.validateCallback(["state": "s", "code": "c", "client_id": "oaiapp_1"], attempt: registering) == "oaiapp_1")
        #expect(throws: ChatGPTAuth.AuthError.stateMismatch) { try ChatGPTAuth.validateCallback(["state": "x", "code": "c", "client_id": "oaiapp_1"], attempt: registering) }
        #expect(throws: ChatGPTAuth.AuthError.declined) { try ChatGPTAuth.validateCallback(["state": "s", "error": "access_denied"], attempt: registering) }
        #expect(throws: ChatGPTAuth.AuthError.registrationIncomplete) { try ChatGPTAuth.validateCallback(["state": "s", "code": "c"], attempt: registering) }

        let returning = ChatGPTAuth.Attempt(clientID: "oaiapp_1", port: 1455, state: "s")
        #expect(try ChatGPTAuth.validateCallback(["state": "s", "code": "c"], attempt: returning) == "oaiapp_1")
        #expect(throws: ChatGPTAuth.AuthError.differentClient) { try ChatGPTAuth.validateCallback(["state": "s", "code": "c", "client_id": "oaiapp_2"], attempt: returning) }
    }

    @Test func hostIDIsAUUIDURN() {
        let id = ChatGPTAuth.newHostID()
        #expect(id.hasPrefix("urn:uuid:"))
        #expect(UUID(uuidString: String(id.dropFirst(9))) != nil)
    }

    @Test func loopbackParsesOnlyTheCallbackPath() {
        let request = Data("GET /auth/callback?code=abc&state=xyz&scope=openid+email HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        #expect(LoopbackServer.callbackQuery(fromRequest: request)?["code"] == "abc")
        #expect(LoopbackServer.callbackQuery(fromRequest: Data("GET /favicon.ico HTTP/1.1\r\n\r\n".utf8)) == nil)
        #expect(LoopbackServer.callbackQuery(fromRequest: Data("GET /callback?code=1 HTTP/1.1\r\n\r\n".utf8)) == nil)
    }

    @Test func loopbackServerReceivesTheBrowserRedirect() async throws {
        let server = try await LoopbackServer.start(preferredPort: 0)
        defer { server.stop() }
        #expect(server.port != 0)
        let url = URL(string: "http://127.0.0.1:\(server.port)/auth/callback?code=abc&state=s1")!
        async let page = URLSession.shared.data(from: url)
        let query = try await server.callback()
        #expect(query == ["code": "abc", "state": "s1"])
        let (data, _) = try await page
        #expect(String(decoding: data, as: UTF8.self).contains("signed in"))
    }

    @Test func cancellingAnUnfinishedSignInStopsWaiting() async throws {
        let server = try await LoopbackServer.start(preferredPort: 0)
        defer { server.stop() }
        let waiting = Task { try await server.callback() }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    @Test func refreshErrorsThatNeedANewSignIn() {
        #expect(ChatGPTAuth.isUnusableRefresh("invalid_grant: refresh token expired"))
        #expect(ChatGPTAuth.isUnusableRefresh("refresh_token_reused"))
        #expect(!ChatGPTAuth.isUnusableRefresh("invalid_client"))
    }
}

struct JWTTests {
    let signer = TestSigner()

    @Test func validTokenPasses() throws {
        let token = try signer.token(["iss": "https://auth.openai.com", "sub": "user-1", "aud": "oaiapp_1", "exp": 4_000_000_000, "nonce": "n1", "email": "coach@example.com"])
        let claims = try JWT.verify(token, keys: signer.keySet, issuer: "https://auth.openai.com", audience: "oaiapp_1", nonce: "n1", now: Date())
        #expect(claims.sub == "user-1")
        #expect(claims.email == "coach@example.com")
    }

    @Test func audienceArrayIsAccepted() throws {
        let token = try signer.token(["iss": "https://auth.openai.com", "sub": "u", "aud": ["other", "oaiapp_1"], "exp": 4_000_000_000])
        _ = try JWT.verify(token, keys: signer.keySet, issuer: "https://auth.openai.com", audience: "oaiapp_1", nonce: nil, now: Date())
    }

    @Test func badTokensFail() throws {
        let base: [String: Any] = ["iss": "https://auth.openai.com", "sub": "u", "aud": "oaiapp_1", "exp": 4_000_000_000, "nonce": "n1"]
        func check(_ claims: [String: Any], nonce: String? = "n1", keys: JWT.KeySet? = nil, reason: String) throws {
            let token = try signer.token(claims)
            #expect(throws: ChatGPTAuth.AuthError.invalidIDToken(reason)) {
                try JWT.verify(token, keys: keys ?? signer.keySet, issuer: "https://auth.openai.com", audience: "oaiapp_1", nonce: nonce, now: Date())
            }
        }
        try check(base.merging(["iss": "https://evil.example"]) { $1 }, reason: "wrong issuer")
        try check(base.merging(["aud": "oaiapp_2"]) { $1 }, reason: "wrong audience")
        try check(base.merging(["exp": 1_000_000_000]) { $1 }, reason: "expired")
        try check(base, nonce: "other", reason: "nonce mismatch")
        try check(base, keys: TestSigner().keySet, reason: "bad signature")
    }

    @Test func tamperedPayloadFails() throws {
        let token = try signer.token(["iss": "https://auth.openai.com", "sub": "u", "aud": "oaiapp_1", "exp": 4_000_000_000])
        let parts = token.split(separator: ".")
        let forged = try signer.token(["iss": "https://auth.openai.com", "sub": "admin", "aud": "oaiapp_1", "exp": 4_000_000_000]).split(separator: ".")[1]
        #expect(throws: ChatGPTAuth.AuthError.invalidIDToken("bad signature")) {
            try JWT.verify("\(parts[0]).\(forged).\(parts[2])", keys: signer.keySet, issuer: "https://auth.openai.com", audience: "oaiapp_1", nonce: nil, now: Date())
        }
    }
}

/// Signs RS256 tokens with a throwaway key and publishes it as a JWK set.
struct TestSigner: @unchecked Sendable {
    let privateKey: SecKey
    let keySet: JWT.KeySet

    init() {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
        let der = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data
        let (n, e) = Self.parseRSAPublicKey(der)
        keySet = JWT.KeySet(keys: [.init(kty: "RSA", kid: "k1", n: ChatGPTAuth.base64URL(n), e: ChatGPTAuth.base64URL(e))])
    }

    func token(_ claims: [String: Any]) throws -> String {
        let header = ChatGPTAuth.base64URL(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "k1", "typ": "JWT"]))
        let payload = ChatGPTAuth.base64URL(try JSONSerialization.data(withJSONObject: claims))
        let signed = Data("\(header).\(payload)".utf8)
        let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, nil)! as Data
        return "\(header).\(payload).\(ChatGPTAuth.base64URL(signature))"
    }

    /// SEQUENCE { INTEGER n, INTEGER e }
    static func parseRSAPublicKey(_ der: Data) -> (Data, Data) {
        var bytes = [UInt8](der)[...]
        func length() -> Int {
            let first = Int(bytes.removeFirst())
            guard first & 0x80 != 0 else { return first }
            var value = 0
            for _ in 0..<(first & 0x7f) { value = value << 8 | Int(bytes.removeFirst()) }
            return value
        }
        func integer() -> Data {
            precondition(bytes.removeFirst() == 0x02)
            let count = length()
            defer { bytes.removeFirst(count) }
            return Data(bytes.prefix(count))
        }
        precondition(bytes.removeFirst() == 0x30)
        _ = length()
        return (integer(), integer())
    }
}
