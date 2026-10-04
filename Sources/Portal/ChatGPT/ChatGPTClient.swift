import Foundation

/// One turn of a conversation with the model.
struct ChatMessage: Codable, Sendable, Hashable {
    enum Role: String, Codable, Sendable { case user, assistant }
    var role: Role
    var content: String
}

/// Runs requests on your ChatGPT plan through the public Responses API (Sign in with ChatGPT).
/// The route requires `stream: true` and `store: false` and rejects `max_output_tokens` and `temperature`.
/// Copied from Peanut Manager's LineupAI, changed to report text as it streams in.
struct ChatGPTClient: Sendable {
    /// The default until the account's model list loads; after that, `preferredModel(in:)` decides.
    static let defaultModel = "gpt-5.6-luna"

    /// The newest Luna the account offers (fast, and plenty for rewriting text), so Portal moves
    /// up as OpenAI ships new ones. Falls back to the newest Sol, then the first in the list.
    static func preferredModel(in ids: [String]) -> String? {
        func newest(_ family: String) -> String? {
            ids.compactMap { id -> (String, [Int])? in
                guard let match = id.wholeMatch(of: #/gpt-(\d+(?:\.\d+)*)-([a-z]+)/#), match.2 == family else { return nil }
                return (id, match.1.split(separator: ".").compactMap { Int($0) })
            }
            .max { $0.1.lexicographicallyPrecedes($1.1) }?.0
        }
        return newest("luna") ?? newest("sol") ?? ids.first
    }

    var session: ChatGPTSession
    var urlSession: URLSession = .shared
    var baseURL = URL(string: ChatGPTAuth.resource)!

    enum ClientError: Error, LocalizedError, Equatable {
        case planUsageOff
        case usageLimit
        case notEligible
        case unavailable(String)
        case rejected(status: Int, code: String?, message: String)
        case incomplete(String)
        case failed(code: String?, message: String)
        case emptyReply

        var errorDescription: String? {
            switch self {
            case .planUsageOff: "Portal isn't allowed to use your ChatGPT plan. Turn it on in Settings → ChatGPT."
            case .usageLimit: "You've reached your ChatGPT usage limit. Check Manage Usage in Settings, or try again later."
            case .notEligible: "This ChatGPT account can't use its plan in other apps. ChatGPT Plus or Pro is required."
            case .unavailable(let message): "ChatGPT is temporarily unavailable\(message.isEmpty ? "" : " (\(message))"). Try again in a moment."
            case .rejected(let status, let code, let message): "ChatGPT error \(status)\(code.map { " (\($0))" } ?? ""): \(message)"
            case .incomplete(let reason): "The model stopped before finishing (\(reason)). Try again."
            case .failed(let code, let message): "The model failed\(code.map { " (\($0))" } ?? ""): \(message)"
            case .emptyReply: "The model returned an empty reply. Try again or pick another model."
            }
        }
    }

    /// Sends the conversation and returns the full reply. `onText` gets the reply so far as it streams.
    func respond(model: String, effort: String?, instructions: String, messages: [ChatMessage],
                 onText: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        let body = try Self.body(model: model, effort: effort, instructions: instructions, messages: messages)
        do {
            return try await send(body, token: try await session.accessToken(), onText: onText)
        } catch ClientError.rejected(status: 401, _, _) {
            // The token may have been revoked or rotated early: renew once, then give up.
            do {
                return try await send(body, token: try await session.accessToken(forceRefresh: true), onText: onText)
            } catch ClientError.rejected(status: 401, _, _) {
                throw ChatGPTAuth.AuthError.signInAgain
            }
        }
    }

    static func body(model: String, effort: String?, instructions: String, messages: [ChatMessage]) throws -> Data {
        struct Reasoning: Encodable { var effort: String }
        struct Body: Encodable {
            var model: String
            var instructions: String
            var input: [ChatMessage]
            var store = false
            var stream = true
            var reasoning: Reasoning?
        }
        return try JSONEncoder().encode(Body(model: model, instructions: instructions, input: messages,
                                             reasoning: effort.map(Reasoning.init)))
    }

    private func send(_ body: Data, token: String, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        var urlRequest = URLRequest(url: baseURL.appending(path: "responses"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = body

        let (bytes, response) = try await urlSession.bytes(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > 4096 { break } }
            throw Self.error(status: status, data: data)
        }
        var stream = ResponsesStream()
        for try await line in bytes.lines {
            let before = stream.text.count
            let done = try stream.consume(line)
            if stream.text.count != before { onText(stream.text) }
            if done { break }
        }
        return try stream.result()
    }

    /// Maps a non-2xx reply. Admission errors can be `{"detail": "..."}` rather than the usual `error` object.
    static func error(status: Int, data: Data) -> ClientError {
        struct Body: Decodable {
            struct E: Decodable { var code: String?; var message: String?; var param: String? }
            var error: E?
            var detail: String?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        let code = body?.error?.code
        let message = body?.error?.message ?? body?.detail ?? String(decoding: data.prefix(300), as: UTF8.self)
        if let coded = mapped(code: code, message: message) { return coded }
        if status == 503 { return .unavailable(message) }
        return .rejected(status: status, code: code, message: message)
    }

    static func mapped(code: String?, message: String) -> ClientError? {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": .usageLimit
        case "subscription_sharing_user_not_eligible": .notEligible
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": .unavailable(message)
        default: nil
        }
    }

    // MARK: - Models

    /// A model the signed-in account can use.
    struct ModelInfo: Identifiable, Hashable, Sendable {
        var id: String
        var name: String
        var summary: String?
        var defaultEffort: String?
        var efforts: [String]
    }

    /// The account's model list, in the server's order, keeping only models meant for display.
    func models() async throws -> [ModelInfo] {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        request.setValue("Bearer \(try await session.accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
        return try Self.decodeModels(data)
    }

    static func decodeModels(_ data: Data) throws -> [ModelInfo] {
        struct Body: Decodable {
            struct Level: Decodable { var effort: String? }
            struct Model: Decodable {
                var slug: String
                var display_name: String?
                var description: String?
                var visibility: String?
                var default_reasoning_level: String?
                var supported_reasoning_levels: [Level]?
            }
            var models: [Model]
        }
        return try JSONDecoder().decode(Body.self, from: data).models
            .filter { $0.visibility == nil || $0.visibility == "list" }
            .map { ModelInfo(id: $0.slug, name: $0.display_name ?? $0.slug, summary: $0.description,
                             defaultEffort: $0.default_reasoning_level, efforts: ($0.supported_reasoning_levels ?? []).compactMap(\.effort)) }
    }
}

/// Reads a Responses API server-sent event stream. Success only on `response.completed`.
struct ResponsesStream {
    private(set) var text = ""
    private var completed = false

    private struct Event: Decodable {
        struct Failure: Decodable {
            struct E: Decodable { var code: String?; var message: String? }
            struct Incomplete: Decodable { var reason: String? }
            var error: E?
            var incomplete_details: Incomplete?
        }
        var type: String
        var delta: String?
        var code: String?
        var message: String?
        var response: Failure?
    }

    /// Feeds one line; returns true once the stream is finished.
    mutating func consume(_ line: String) throws -> Bool {
        guard line.hasPrefix("data:") else { return false }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return true }
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(payload.utf8)) else { return false }
        switch event.type {
        case "response.output_text.delta":
            text += event.delta ?? ""
        case "response.completed":
            completed = true
            return true
        case "response.incomplete":
            throw ChatGPTClient.ClientError.incomplete(event.response?.incomplete_details?.reason ?? "unknown reason")
        case "response.failed":
            let code = event.response?.error?.code
            let message = event.response?.error?.message ?? "no details"
            throw ChatGPTClient.mapped(code: code, message: message) ?? .failed(code: code, message: message)
        case "error":
            let message = event.message ?? "no details"
            throw ChatGPTClient.mapped(code: event.code, message: message) ?? .failed(code: event.code, message: message)
        default:
            break
        }
        return false
    }

    func result() throws -> String {
        guard completed else { throw ChatGPTClient.ClientError.incomplete("the connection closed early") }
        guard !text.isEmpty else { throw ChatGPTClient.ClientError.emptyReply }
        return text
    }
}
