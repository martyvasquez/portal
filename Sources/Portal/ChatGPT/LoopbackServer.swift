import Foundation
import Network

/// Listens on 127.0.0.1 for the one `GET /auth/callback` that ends a browser sign-in.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackServer")
    private let lock = NSLock()
    private var pending: CheckedContinuation<[String: String], Error>?
    private var received: Result<[String: String], Error>?
    private(set) var port: UInt16 = 0

    private init(listener: NWListener) {
        self.listener = listener
    }

    /// Starts on `preferredPort`, or any free port when it's taken (only the port may vary between sign-ins).
    static func start(preferredPort: UInt16) async throws -> LoopbackServer {
        do {
            return try await start(port: preferredPort)
        } catch {
            return try await start(port: 0)
        }
    }

    private static func start(port: UInt16) async throws -> LoopbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let server = LoopbackServer(listener: try NWListener(using: parameters))
        try await server.run()
        return server
    }

    private func run() async throws {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = self?.listener.port?.rawValue ?? 0
                    if once.claim() { ready.resume() }
                case .failed(let error), .waiting(let error):
                    self?.listener.cancel()
                    if once.claim() { ready.resume(throwing: error) }
                    self?.finish(.failure(error))
                case .cancelled:
                    if once.claim() { ready.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    /// The callback's query items. Throws `CancellationError` if the calling task is cancelled first.
    func callback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let received {
                    lock.unlock()
                    continuation.resume(with: received)
                } else {
                    pending = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    func stop() {
        listener.cancel()
    }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        guard received == nil else { lock.unlock(); return }
        received = result
        let continuation = pending
        pending = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let query = Self.callbackQuery(fromRequest: data) else {
                Self.respond(connection, status: "404 Not Found", body: "")
                return
            }
            let ok = query["error"] == nil
            Self.respond(connection, status: "200 OK", body: Self.page(ok ? "You're signed in." : "Sign-in didn't finish.",
                                                                       ok ? "Return to Portal. You can close this tab." : "Return to Portal to try again."))
            self.finish(.success(query))
        }
    }

    /// Parses `GET /auth/callback?… HTTP/1.1`. Other paths (favicon, probes) return nil.
    static func callbackQuery(fromRequest data: Data) -> [String: String]? {
        guard let text = String(data: data, encoding: .utf8), let line = text.split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: String(parts[1])),
              components.path == "/auth/callback" else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return query
    }

    private static func respond(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(_ title: String, _ detail: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>Portal</title>
        <style>body{font:15px -apple-system,system-ui,sans-serif;display:flex;height:100vh;margin:0;align-items:center;justify-content:center;color:#1d1d1f;background:#fff}
        @media(prefers-color-scheme:dark){body{color:#f5f5f7;background:#1d1d1f}}h1{font-size:22px;font-weight:600;margin:0 0 6px}p{margin:0;opacity:.6}</style>
        </head><body><div><h1>\(title)</h1><p>\(detail)</p></div></body></html>
        """
    }
}

/// Lets exactly one caller through.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
