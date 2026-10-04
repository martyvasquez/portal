import Foundation

/// Hands out a current access token for one signed-in account, refreshing at most once at a time.
actor ChatGPTSession {
    let account: ChatGPTAccount
    private(set) var tokens: ChatGPTTokens?
    private let auth: ChatGPTAuth
    private let persist: @Sendable (ChatGPTTokens?) -> Void
    private var refreshing: Task<ChatGPTTokens, Error>?

    /// `persist` is called with every replacement token set, and with nil once the session can't be renewed.
    init(account: ChatGPTAccount, tokens: ChatGPTTokens, auth: ChatGPTAuth = ChatGPTAuth(), persist: @escaping @Sendable (ChatGPTTokens?) -> Void) {
        self.account = account
        self.tokens = tokens
        self.auth = auth
        self.persist = persist
    }

    func accessToken(forceRefresh: Bool = false, now: Date = Date()) async throws -> String {
        guard let current = tokens else { throw ChatGPTAuth.AuthError.signInAgain }
        guard current.planUsageGranted else { throw ChatGPTClient.ClientError.planUsageOff }
        if !forceRefresh && !current.needsRefresh(now: now) { return current.accessToken }
        return try await refresh(from: current).accessToken
    }

    private func refresh(from current: ChatGPTTokens) async throws -> ChatGPTTokens {
        if let refreshing { return try await refreshing.value }
        let task = Task { [auth, account] in try await auth.refresh(current, account: account) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let updated = try await task.value
            tokens = updated
            persist(updated)
            return updated
        } catch ChatGPTAuth.AuthError.signInAgain {
            tokens = nil
            persist(nil)
            throw ChatGPTAuth.AuthError.signInAgain
        }
    }
}
