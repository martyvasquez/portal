import Foundation
import CryptoKit

/// The ChatGPT account this install registered with. Kept after sign-out so the next sign-in reuses the client.
struct ChatGPTAccount: Codable, Sendable, Hashable {
    /// Issued by OpenAI at first sign-in (`oaiapp_…`); bound to this user and workspace.
    var clientID: String
    /// Verified ID-token subject.
    var subject: String
    var email: String?
    var name: String?

    init(clientID: String, subject: String, email: String? = nil, name: String? = nil) {
        self.clientID = clientID
        self.subject = subject
        self.email = email
        self.name = name
    }
}

/// A signed-in session. Cleared on sign-out.
struct ChatGPTTokens: Codable, Sendable, Hashable {
    var idToken: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var scopes: [String]

    init(idToken: String, accessToken: String, refreshToken: String?, expiresAt: Date, scopes: [String]) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    /// You let this app use their ChatGPT plan.
    var planUsageGranted: Bool { scopes.contains(ChatGPTAuth.planScope) }

    func needsRefresh(now: Date = Date()) -> Bool { expiresAt.timeIntervalSince(now) < 120 }
}

/// Sign in with ChatGPT for open-source apps: OAuth + PKCE with dynamic client registration and a loopback callback.
/// Spec: https://developers.openai.com/siwc/llms-full.txt ("Registration and sign-in" onward).
struct ChatGPTAuth: Sendable {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let planScope = "chatgpt.tokens.use.direct"
    static let scopes = "openid profile email offline_access resource.invoke \(planScope)"
    static let appName = "Portal"
    static let registrationClientID = "dynamic_agent_client"
    static let preferredPort: UInt16 = 1455
    static let manageUsageURL = URL(string: "https://chatgpt.com/settings/usage")!

    var session: URLSession
    var issuerURL = URL(string: issuer)!

    init(session: URLSession = .shared) {
        self.session = session
    }

    enum AuthError: Error, LocalizedError, Equatable {
        case declined
        case authorization(String)
        case stateMismatch
        case registrationIncomplete
        case differentClient
        case differentAccount
        case invalidIDToken(String)
        case signInAgain
        case tokenEndpoint(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .declined: "Sign-in was cancelled in the browser."
            case .authorization(let message): "ChatGPT sign-in failed: \(message)"
            case .stateMismatch, .differentClient: "The sign-in reply didn't match this request. Try again."
            case .registrationIncomplete: "ChatGPT didn't finish registering Portal. Try again."
            case .differentAccount: "That's a different ChatGPT account than the one saved here. Sign out first to switch accounts."
            case .invalidIDToken(let reason): "ChatGPT's sign-in couldn't be verified (\(reason))."
            case .signInAgain: "Your ChatGPT sign-in has expired. Sign in again in Settings."
            case .tokenEndpoint(let status, let message): "ChatGPT sign-in error \(status): \(message)"
            }
        }
    }

    // MARK: - Authorization request

    /// One authorization attempt's secrets. Fresh for every attempt.
    struct Attempt: Sendable {
        var clientID: String
        var redirectURI: String
        var state: String
        var nonce: String
        var verifier: String
        var isRegistration: Bool { clientID == ChatGPTAuth.registrationClientID }

        init(clientID: String, port: UInt16, state: String = randomToken(), nonce: String = randomToken(), verifier: String = randomToken(48)) {
            self.clientID = clientID
            self.redirectURI = "http://127.0.0.1:\(port)/auth/callback"
            self.state = state
            self.nonce = nonce
            self.verifier = verifier
        }

        var challenge: String { ChatGPTAuth.challenge(for: verifier) }
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomToken(_ bytes: Int = 32) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64URL(data)
    }

    /// New-host install ID: an opaque `urn:uuid:` value, generated once per install and kept forever.
    static func newHostID() -> String { "urn:uuid:" + UUID().uuidString.lowercased() }

    /// `idTokenHint`/`loginHint` only for a returning account that hasn't signed out.
    /// `askConsent` re-shows the permission screen, e.g. to turn plan use on after declining it.
    func authorizeURL(_ attempt: Attempt, hostID: String, idTokenHint: String? = nil, loginHint: String? = nil, askConsent: Bool = false) -> URL {
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: attempt.clientID),
            .init(name: "ext_agent_host_id", value: hostID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: attempt.redirectURI),
            .init(name: "scope", value: Self.scopes),
            .init(name: "resource", value: Self.resource),
            .init(name: "state", value: attempt.state),
            .init(name: "nonce", value: attempt.nonce),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: attempt.challenge),
        ]
        if attempt.isRegistration {
            items.append(.init(name: "agent_name_hint", value: Self.appName))
        } else {
            if let idTokenHint { items.append(.init(name: "id_token_hint", value: idTokenHint)) }
            if let loginHint { items.append(.init(name: "login_hint", value: loginHint)) }
        }
        if askConsent { items.append(.init(name: "prompt", value: "consent")) }
        var components = URLComponents(url: issuerURL.appending(path: "api/accounts/authorize"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = Self.formEncode(items)
        return components.url!
    }

    // MARK: - Sign in

    /// Runs the whole browser sign-in. `open` shows the authorization page (the app opens the default browser).
    /// Cancel the calling task to abandon a sign-in you never finished.
    func signIn(hostID: String, account: ChatGPTAccount?, idTokenHint: String?, askConsent: Bool = false, open: @Sendable (URL) async -> Void) async throws -> (ChatGPTAccount, ChatGPTTokens) {
        let server = try await LoopbackServer.start(preferredPort: Self.preferredPort)
        defer { server.stop() }
        let attempt = Attempt(clientID: account?.clientID ?? Self.registrationClientID, port: server.port)
        await open(authorizeURL(attempt, hostID: hostID, idTokenHint: idTokenHint, loginHint: account?.email, askConsent: askConsent))
        let callback = try await server.callback()
        let clientID = try Self.validateCallback(callback, attempt: attempt)
        let response = try await exchange(code: callback["code"] ?? "", clientID: clientID, attempt: attempt)
        return try await accept(response, clientID: clientID, nonce: attempt.nonce, previous: account)
    }

    /// Checks the loopback callback and returns the client ID to use for the code exchange.
    static func validateCallback(_ query: [String: String], attempt: Attempt) throws -> String {
        guard query["state"] == attempt.state else { throw AuthError.stateMismatch }
        if let error = query["error"] {
            if error == "access_denied" { throw AuthError.declined }
            throw AuthError.authorization(query["error_description"] ?? error)
        }
        guard let code = query["code"], !code.isEmpty else { throw AuthError.authorization("no authorization code") }
        if attempt.isRegistration {
            guard let issued = query["client_id"], !issued.isEmpty, issued != registrationClientID else { throw AuthError.registrationIncomplete }
            return issued
        }
        if let returned = query["client_id"], returned != attempt.clientID { throw AuthError.differentClient }
        return attempt.clientID
    }

    struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var id_token: String?
        var expires_in: Int?
        var scope: String?
    }

    func exchange(code: String, clientID: String, attempt: Attempt) async throws -> TokenResponse {
        try await postToken([
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", attempt.verifier),
            ("redirect_uri", attempt.redirectURI),
            ("resource", Self.resource),
        ])
    }

    func accept(_ response: TokenResponse, clientID: String, nonce: String, previous: ChatGPTAccount?, now: Date = Date()) async throws -> (ChatGPTAccount, ChatGPTTokens) {
        guard let idToken = response.id_token else { throw AuthError.invalidIDToken("no ID token") }
        let claims = try await verifyIDToken(idToken, clientID: clientID, nonce: nonce, now: now)
        if let previous, previous.subject != claims.sub { throw AuthError.differentAccount }
        let account = ChatGPTAccount(clientID: clientID, subject: claims.sub, email: claims.email, name: claims.name)
        let tokens = ChatGPTTokens(idToken: idToken, accessToken: response.access_token, refreshToken: response.refresh_token,
                                   expiresAt: now.addingTimeInterval(TimeInterval(response.expires_in ?? 3600)),
                                   scopes: Self.scopeList(response.scope))
        return (account, tokens)
    }

    // MARK: - Refresh and sign out

    /// Trades the refresh token for a new access token (and a replacement refresh token).
    /// Throws `.signInAgain` when the refresh token is no longer usable.
    func refresh(_ tokens: ChatGPTTokens, account: ChatGPTAccount, now: Date = Date()) async throws -> ChatGPTTokens {
        guard let refreshToken = tokens.refreshToken else { throw AuthError.signInAgain }
        let response: TokenResponse
        do {
            response = try await postToken([
                ("grant_type", "refresh_token"),
                ("client_id", account.clientID),
                ("refresh_token", refreshToken),
                ("resource", Self.resource),
            ])
        } catch AuthError.tokenEndpoint(let status, let message) where (400..<500).contains(status) && Self.isUnusableRefresh(message) {
            throw AuthError.signInAgain
        }
        var updated = tokens
        updated.accessToken = response.access_token
        if let refresh = response.refresh_token { updated.refreshToken = refresh }
        if let id = response.id_token { updated.idToken = id }
        if response.scope != nil { updated.scopes = Self.scopeList(response.scope) }
        updated.expiresAt = now.addingTimeInterval(TimeInterval(response.expires_in ?? 3600))
        return updated
    }

    static func isUnusableRefresh(_ message: String) -> Bool {
        ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]
            .contains { message.contains($0) }
    }

    /// Ends the renewable session on OpenAI's side. Succeeds for an already-invalid token.
    func revoke(_ tokens: ChatGPTTokens, account: ChatGPTAccount) async throws {
        guard let refreshToken = tokens.refreshToken else { return }
        let config = try await configuration()
        guard let endpoint = config.revocation_endpoint.flatMap(URL.init(string:)) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode([
            URLQueryItem(name: "token", value: refreshToken),
            URLQueryItem(name: "token_type_hint", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: account.clientID),
        ]).utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AuthError.tokenEndpoint(status: status, message: String(decoding: data.prefix(300), as: UTF8.self)) }
    }

    // MARK: - ID token

    struct Configuration: Decodable {
        var jwks_uri: String
        var revocation_endpoint: String?
    }

    func configuration() async throws -> Configuration {
        let (data, _) = try await session.data(from: issuerURL.appending(path: ".well-known/openid-configuration"))
        return try JSONDecoder().decode(Configuration.self, from: data)
    }

    func verifyIDToken(_ token: String, clientID: String, nonce: String, now: Date) async throws -> JWT.Claims {
        let config = try await configuration()
        guard let url = URL(string: config.jwks_uri) else { throw AuthError.invalidIDToken("no key set") }
        let (data, _) = try await session.data(from: url)
        let keys = try JSONDecoder().decode(JWT.KeySet.self, from: data)
        return try JWT.verify(token, keys: keys, issuer: Self.issuer, audience: clientID, nonce: nonce, now: now)
    }

    // MARK: - HTTP

    func postToken(_ fields: [(String, String)]) async throws -> TokenResponse {
        var request = URLRequest(url: issuerURL.appending(path: "api/accounts/oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(fields.map { URLQueryItem(name: $0.0, value: $0.1) }).utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            struct Body: Decodable { var error: String?; var error_description: String? }
            let body = try? JSONDecoder().decode(Body.self, from: data)
            let message = [body?.error, body?.error_description].compactMap { $0 }.joined(separator: ": ")
            throw AuthError.tokenEndpoint(status: status, message: message.isEmpty ? String(decoding: data.prefix(300), as: UTF8.self) : message)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    static func scopeList(_ scope: String?) -> [String] {
        (scope ?? "").split(separator: " ").map(String.init).sorted()
    }

    /// application/x-www-form-urlencoded, which also suits query strings. URLComponents leaves `+` and `&`-safe characters alone, so encode strictly.
    static func formEncode(_ items: [URLQueryItem]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return items.map { "\($0.name)=\(($0.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
