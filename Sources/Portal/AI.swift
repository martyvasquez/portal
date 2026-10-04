import AppKit
import Combine

/// Sign in with ChatGPT, the account's models, and which model transformers use.
/// The sign-in lives in this Mac's Keychain; the model choice syncs with the other settings.
@MainActor
final class AIService: ObservableObject {
    static let shared = AIService()

    @Published private(set) var account: ChatGPTAccount?
    @Published private(set) var isSignedIn = false
    @Published private(set) var planUsageGranted = false
    @Published private(set) var isSigningIn = false
    @Published var signInError: String?
    @Published private(set) var models: [ChatGPTClient.ModelInfo] = []
    @Published private(set) var modelsError: String?
    /// The newest Luna the account offers, remembered so Portal starts on it before the list loads.
    @Published private(set) var defaultModelID: String {
        didSet { UserDefaults.standard.set(defaultModelID, forKey: Keys.defaultModel) }
    }

    /// Transformers are short rewrites, so speed beats deep thinking.
    static let defaultEffort = "low"

    private let settings = SettingsStore.shared
    private var session: ChatGPTSession?
    private var signInTask: Task<Void, Never>?
    private let auth = ChatGPTAuth()

    private enum Keys {
        static let defaultModel = "chatGPTDefaultModel"
        static let vault = "chatgpt-session"
        static let host = "chatgpt-host-id"
    }

    private init() {
        defaultModelID = UserDefaults.standard.string(forKey: Keys.defaultModel) ?? ChatGPTClient.defaultModel
        if let record = Self.loadRecord() {
            account = record.account
            if let tokens = record.tokens { adopt(record.account, tokens) }
        }
        if isSignedIn { Task { await loadModels() } }
    }

    // MARK: - Requests

    /// The client for the next request, or nil while signed out.
    func client() -> ChatGPTClient? { session.map { ChatGPTClient(session: $0) } }

    /// The model a transformer runs on: its own pick, else the one in Settings, else the default.
    func modelID(for transformer: Transformer?) -> String {
        transformer?.model ?? settings.values.aiModel ?? defaultModelID
    }

    /// The thinking level: the transformer's, else Settings', else Low where the model offers it.
    func effort(for transformer: Transformer?) -> String? {
        let model = modelID(for: transformer)
        let choices = effortChoices(for: model)
        if let picked = transformer?.effort ?? settings.values.aiEffort, choices.contains(picked) { return picked }
        return choices.contains(Self.defaultEffort) ? Self.defaultEffort : nil
    }

    func effortChoices(for model: String) -> [String] {
        models.first { $0.id == model }?.efforts ?? ["low", "medium", "high"]
    }

    /// "GPT-5.6-Luna"; falls back to a name made from the ID.
    func displayName(for id: String) -> String {
        models.first { $0.id == id }?.name ?? Self.fallbackName(id)
    }

    static func fallbackName(_ id: String) -> String {
        guard id.hasPrefix("gpt-") else { return id }
        return "GPT-" + id.dropFirst(4).split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
    }

    // MARK: - Sign in / out

    /// Opens the browser for Sign in with ChatGPT. `askConsent` re-shows the permission screen (turning plan use back on).
    func signIn(askConsent: Bool = false) {
        guard signInTask == nil else { return }
        signInError = nil
        isSigningIn = true
        let previous = account
        let hint = Self.loadRecord()?.tokens?.idToken
        signInTask = Task {
            defer { isSigningIn = false; signInTask = nil }
            do {
                let (account, tokens) = try await auth.signIn(hostID: Self.hostID(), account: previous, idTokenHint: hint, askConsent: askConsent) { url in
                    await MainActor.run { _ = NSWorkspace.shared.open(url) }
                }
                Self.saveRecord(Record(account: account, tokens: tokens))
                adopt(account, tokens)
                Self.returnToSettings()
                await loadModels()
            } catch is CancellationError {
            } catch {
                signInError = error.localizedDescription
                Self.returnToSettings()
            }
        }
    }

    func cancelSignIn() { signInTask?.cancel() }

    /// Ends the session on OpenAI's side, then forgets the tokens. Keeps the registration so the next sign-in reuses it.
    func signOut() {
        let record = Self.loadRecord()
        session = nil
        isSignedIn = false
        planUsageGranted = false
        models = []
        if let account { Self.saveRecord(Record(account: account, tokens: nil)) }
        guard let record, let tokens = record.tokens else { return }
        Task {
            do {
                try await auth.revoke(tokens, account: record.account)
            } catch {
                signInError = "Signed out here, but ChatGPT didn't confirm it. You can disconnect Portal in ChatGPT settings."
            }
        }
    }

    /// Forget the saved registration so the next sign-in can pick any ChatGPT account.
    func useDifferentAccount() {
        signOut()
        account = nil
        Self.saveRecord(nil)
        signIn()
    }

    func loadModels() async {
        guard let client = client() else { return }
        do {
            let list = try await client.models()
            models = list
            modelsError = nil
            if let preferred = ChatGPTClient.preferredModel(in: list.map(\.id)) { defaultModelID = preferred }
            // A picked model OpenAI retired: back to the default.
            if let chosen = settings.values.aiModel, !list.isEmpty, !list.contains(where: { $0.id == chosen }) {
                settings.values.aiModel = nil
            }
        } catch {
            modelsError = error.localizedDescription
        }
    }

    private func adopt(_ account: ChatGPTAccount, _ tokens: ChatGPTTokens) {
        self.account = account
        isSignedIn = true
        planUsageGranted = tokens.planUsageGranted
        session = ChatGPTSession(account: account, tokens: tokens) { tokens in
            // Called off the main actor with each refreshed token set, or nil once the session can't be renewed.
            Self.saveRecord(Record(account: account, tokens: tokens))
            if tokens == nil { Task { @MainActor in AIService.shared.sessionEnded() } }
        }
    }

    private func sessionEnded() {
        session = nil
        isSignedIn = false
        planUsageGranted = false
    }

    /// The browser had focus for the sign-in; bring Settings back if it's open.
    private static func returnToSettings() {
        if NSApp.activationPolicy() == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: - Keychain

    nonisolated struct Record: Codable {
        var account: ChatGPTAccount
        var tokens: ChatGPTTokens?
    }

    nonisolated private static func loadRecord() -> Record? {
        Keychain.get(Keys.vault).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }

    nonisolated private static func saveRecord(_ record: Record?) {
        if let data = record.flatMap({ try? JSONEncoder().encode($0) }) {
            Keychain.set(data, for: Keys.vault)
        } else {
            Keychain.delete(Keys.vault)
        }
    }

    /// This install's opaque host ID, made once and kept for good.
    nonisolated private static func hostID() -> String {
        if let data = Keychain.get(Keys.host), let id = String(data: data, encoding: .utf8) { return id }
        let id = ChatGPTAuth.newHostID()
        Keychain.set(Data(id.utf8), for: Keys.host)
        return id
    }
}
