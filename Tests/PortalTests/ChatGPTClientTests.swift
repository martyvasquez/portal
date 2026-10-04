import Foundation
import Testing
@testable import Portal

struct ResponsesStreamTests {
    func run(_ lines: [String]) throws -> String {
        var stream = ResponsesStream()
        for line in lines { if try stream.consume(line) { break } }
        return try stream.result()
    }

    @Test func collectsTextThroughCompleted() throws {
        let response = try run([
            "event: response.created",
            #"data: {"type":"response.created","response":{"id":"r1"}}"#,
            "",
            #"data: {"type":"response.output_text.delta","delta":"{\"batting"}"#,
            #"data: {"type":"response.output_text.delta","delta":"_order\": []}"}"#,
            #"data: {"type":"response.completed","response":{"model":"gpt-5.6-sol","usage":{"input_tokens":971,"output_tokens":630,"output_tokens_details":{"reasoning_tokens":58}}}}"#,
        ])
        #expect(response == #"{"batting_order": []}"#)
    }

    @Test func streamThatEndsEarlyIsNotASuccess() {
        #expect(throws: ChatGPTClient.ClientError.incomplete("the connection closed early")) {
            try run([#"data: {"type":"response.output_text.delta","delta":"partial"}"#])
        }
    }

    @Test func usageLimitMidStream() {
        #expect(throws: ChatGPTClient.ClientError.usageLimit) {
            try run([
                #"data: {"type":"response.output_text.delta","delta":"x"}"#,
                #"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}}"#,
            ])
        }
    }

    @Test func incompleteCarriesItsReason() {
        #expect(throws: ChatGPTClient.ClientError.incomplete("max_output_tokens")) {
            try run([#"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#])
        }
    }

    @Test func emptyCompletedReplyIsAnError() {
        #expect(throws: ChatGPTClient.ClientError.emptyReply) {
            try run([#"data: {"type":"response.completed","response":{}}"#])
        }
    }
}

struct ChatGPTErrorTests {
    @Test func mapsDocumentedErrors() {
        let limit = ChatGPTClient.error(status: 429, data: Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"m"}}"#.utf8))
        #expect(limit == .usageLimit)

        let ineligible = ChatGPTClient.error(status: 403, data: Data(#"{"error":{"code":"subscription_sharing_user_not_eligible","message":"m"}}"#.utf8))
        #expect(ineligible == .notEligible)

        let admission = ChatGPTClient.error(status: 503, data: Data(#"{"detail":"direct routing unavailable"}"#.utf8))
        #expect(admission == .unavailable("direct routing unavailable"))

        let unsupported = ChatGPTClient.error(status: 400, data: Data(#"{"error":{"code":"subscription_sharing_unsupported_capability","message":"temperature","param":"temperature"}}"#.utf8))
        #expect(unsupported == .rejected(status: 400, code: "subscription_sharing_unsupported_capability", message: "temperature"))
    }

    @Test func modelListKeepsDisplayedModelsInServerOrder() throws {
        let data = Data("""
        {"models":[
          {"slug":"gpt-6-astra","display_name":"GPT-6-Astra","visibility":"list","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]},
          {"slug":"gpt-reserve","display_name":"GPT-Reserve","visibility":"hide"},
          {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","visibility":"list","description":"Workhorse"}
        ]}
        """.utf8)
        let models = try ChatGPTClient.decodeModels(data)
        #expect(models.map(\.id) == ["gpt-6-astra", "gpt-5.6-sol"])
        #expect(models[0].efforts == ["low", "high"])
        #expect(models[1].summary == "Workhorse")
    }

    @Test func preferredModelIsNewestLuna() {
        #expect(ChatGPTClient.preferredModel(in: ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"]) == "gpt-5.6-luna")
        #expect(ChatGPTClient.preferredModel(in: ["gpt-5.6-luna", "gpt-6.6-luna", "gpt-6.10-luna"]) == "gpt-6.10-luna")
        #expect(ChatGPTClient.preferredModel(in: ["gpt-6-astra", "gpt-7-luna", "gpt-6.6-luna"]) == "gpt-7-luna")
        // No Luna: the newest Sol, else the first in the list.
        #expect(ChatGPTClient.preferredModel(in: ["gpt-6-astra", "gpt-5.6-sol", "gpt-6.6-sol"]) == "gpt-6.6-sol")
        #expect(ChatGPTClient.preferredModel(in: ["gpt-6-astra", "gpt-5.5"]) == "gpt-6-astra")
        // Variants like previews don't count.
        #expect(ChatGPTClient.preferredModel(in: ["gpt-5.5", "gpt-6.6-luna-preview", "gpt-5.6-luna"]) == "gpt-5.6-luna")
        #expect(ChatGPTClient.preferredModel(in: []) == nil)
    }
}

// MARK: - Network-backed tests

/// Answers requests from a per-test script, keyed by path.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            stream.close()
            request.httpBody = data
        }
        Self.lock.withLock { Self.requests.append(request) }
        let (status, body) = Self.handler?(request) ?? (500, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) -> URLSession {
        lock.withLock { requests = [] }
        self.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    static func form(_ request: URLRequest) -> [String: String] {
        var c = URLComponents(); c.percentEncodedQuery = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}

@Suite(.serialized)
struct ChatGPTNetworkTests {
    let account = ChatGPTAccount(clientID: "oaiapp_1", subject: "u1", email: "you@example.com")

    func tokens(access: String = "a0", expiresIn: TimeInterval = 3600, scopes: [String] = ["chatgpt.tokens.use.direct", "openid"]) -> ChatGPTTokens {
        ChatGPTTokens(idToken: "id0", accessToken: access, refreshToken: "r0", expiresAt: Date().addingTimeInterval(expiresIn), scopes: scopes)
    }

    static let completedStream = Data("""
    data: {"type":"response.output_text.delta","delta":"Hello"}

    data: {"type":"response.completed","response":{"model":"gpt-5.6-sol","usage":{"input_tokens":5,"output_tokens":1}}}

    """.utf8)

    @Test func requestFollowsTheRouteRules() async throws {
        let urlSession = StubProtocol.session { _ in (200, Self.completedStream) }
        let session = ChatGPTSession(account: account, tokens: tokens(), auth: ChatGPTAuth(session: urlSession)) { _ in }
        let client = ChatGPTClient(session: session, urlSession: urlSession)
        let partials = Partials()
        let reply = try await client.respond(model: "gpt-5.6-sol", effort: "low", instructions: "Be brief.",
                                             messages: [ChatMessage(role: .user, content: "Hi"), ChatMessage(role: .assistant, content: "Yo"), ChatMessage(role: .user, content: "Again")]) { partials.add($0) }
        #expect(reply == "Hello")
        #expect(partials.values == ["Hello"])

        let request = try #require(StubProtocol.requests.last)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer a0")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["instructions"] as? String == "Be brief.")
        #expect(body["max_output_tokens"] == nil && body["temperature"] == nil)
        #expect((body["reasoning"] as? [String: String])?["effort"] == "low")
        let input = try #require(body["input"] as? [[String: String]])
        #expect(input.map { $0["role"] } == ["user", "assistant", "user"])
    }

    @Test func expiringTokenIsRefreshedOnceForConcurrentCallers() async throws {
        let urlSession = StubProtocol.session { request in
            if request.url?.path == "/api/accounts/oauth/token" {
                Thread.sleep(forTimeInterval: 0.2)
                return (200, Data(#"{"access_token":"a1","refresh_token":"r1","expires_in":3600,"scope":"chatgpt.tokens.use.direct openid"}"#.utf8))
            }
            return (404, Data())
        }
        let saved = Saved()
        let session = ChatGPTSession(account: account, tokens: tokens(expiresIn: 30), auth: ChatGPTAuth(session: urlSession)) { saved.set($0) }
        async let first = session.accessToken()
        async let second = session.accessToken()
        let results = try await [first, second]
        #expect(results == ["a1", "a1"])
        let refreshes = StubProtocol.requests.filter { $0.url?.path == "/api/accounts/oauth/token" }
        #expect(refreshes.count == 1)
        let form = StubProtocol.form(try #require(refreshes.first))
        #expect(form["grant_type"] == "refresh_token")
        #expect(form["client_id"] == "oaiapp_1")
        #expect(form["refresh_token"] == "r0")
        #expect(form["resource"] == "https://api.openai.com/v1")
        #expect(saved.value??.refreshToken == "r1")
    }

    @Test func deadRefreshTokenSignsOut() async throws {
        let urlSession = StubProtocol.session { _ in (400, Data(#"{"error":"invalid_grant","error_description":"refresh token expired"}"#.utf8)) }
        let saved = Saved()
        let session = ChatGPTSession(account: account, tokens: tokens(expiresIn: 0), auth: ChatGPTAuth(session: urlSession)) { saved.set($0) }
        await #expect(throws: ChatGPTAuth.AuthError.signInAgain) { try await session.accessToken() }
        #expect(saved.value != nil && saved.value! == nil)
        await #expect(throws: ChatGPTAuth.AuthError.signInAgain) { try await session.accessToken() }
    }

    @Test func noPlanPermissionNeverCallsTheModel() async throws {
        let urlSession = StubProtocol.session { _ in (200, Self.completedStream) }
        let session = ChatGPTSession(account: account, tokens: tokens(scopes: ["openid", "email"]), auth: ChatGPTAuth(session: urlSession)) { _ in }
        let client = ChatGPTClient(session: session, urlSession: urlSession)
        await #expect(throws: ChatGPTClient.ClientError.planUsageOff) {
            try await client.respond(model: "m", effort: nil, instructions: "s", messages: [ChatMessage(role: .user, content: "u")])
        }
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test func rejectedTokenIsRenewedOnceThenRetried() async throws {
        let urlSession = StubProtocol.session { request in
            switch request.url?.path {
            case "/api/accounts/oauth/token":
                return (200, Data(#"{"access_token":"a1","refresh_token":"r1","expires_in":3600,"scope":"chatgpt.tokens.use.direct"}"#.utf8))
            default:
                return request.value(forHTTPHeaderField: "Authorization") == "Bearer a1" ? (200, Self.completedStream) : (401, Data(#"{"detail":"unauthorized"}"#.utf8))
            }
        }
        let session = ChatGPTSession(account: account, tokens: tokens(), auth: ChatGPTAuth(session: urlSession)) { _ in }
        let reply = try await ChatGPTClient(session: session, urlSession: urlSession)
            .respond(model: "m", effort: nil, instructions: "s", messages: [ChatMessage(role: .user, content: "u")])
        #expect(reply == "Hello")
        #expect(StubProtocol.requests.map { $0.url?.path ?? "" } == ["/v1/responses", "/api/accounts/oauth/token", "/v1/responses"])
    }
}

/// Records the last value passed to `persist` (nil means "signed out").
final class Saved: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ChatGPTTokens??
    var value: ChatGPTTokens?? { lock.withLock { stored } }
    func set(_ tokens: ChatGPTTokens?) { lock.withLock { stored = .some(tokens) } }
}

/// Collects the partial replies passed to `onText`.
final class Partials: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func add(_ text: String) { lock.withLock { stored.append(text) } }
}
