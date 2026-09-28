import Foundation
import CryptoKit
import CommonCrypto
import Security

struct PortalError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Crypto {
    static let iterations = 600_000

    static func deriveKey(passphrase: String, salt: Data, iterations: Int) -> SymmetricKey {
        var derived = Data(count: 32)
        let pwLength = passphrase.utf8.count
        _ = passphrase.withCString { pw in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { out in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pwLength,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         out.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        return SymmetricKey(data: derived)
    }

    static func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw PortalError("Encryption failed") }
        return combined
    }

    static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }

    static func randomBytes(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum Keychain {
    static let service = "com.martyvasquez.portal"

    static func get(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func set(_ data: Data, for account: String) {
        delete(account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Portal (\(account))",
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { NSLog("Portal: keychain write failed (\(status))") }
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum SyncKeyState: Equatable {
    case disabled
    case needsPassphrase(existing: Bool)   // existing = another Mac already set one
    case ready
}

/// Owns the encryption keys. Clips are always encrypted: with a random per-Mac key
/// when stored locally, or a passphrase-derived key shared by all your Macs when synced.
@MainActor
final class KeyManager: ObservableObject {
    @Published private(set) var state: SyncKeyState = .disabled
    private(set) var syncKey: SymmetricKey?
    let localKey: SymmetricKey
    private let settings: SettingsStore

    private struct KeyCheck: Codable {
        var version = 1
        var salt: Data
        var iterations: Int
        var verifier: Data
        var created: Date
        var createdBy: String
    }

    private struct StoredSyncKey: Codable {
        var salt: Data
        var key: Data
    }

    private static let verifierPlaintext = Data("portal-keycheck-v1".utf8)

    init(settings: SettingsStore) {
        self.settings = settings
        if let data = Keychain.get("local-key"), data.count == 32 {
            localKey = SymmetricKey(data: data)
        } else {
            let data = Crypto.randomBytes(32)
            Keychain.set(data, for: "local-key")
            localKey = SymmetricKey(data: data)
        }
    }

    private var keyCheckURL: URL { settings.syncFolderURL.appendingPathComponent("keycheck.json") }

    private func readKeyCheck() -> KeyCheck? {
        guard let data = try? Data(contentsOf: keyCheckURL) else { return nil }
        return try? JSONDecoder().decode(KeyCheck.self, from: data)
    }

    private func setState(_ s: SyncKeyState) { if state != s { state = s } }

    func evaluate() {
        guard settings.syncEnabled else {
            syncKey = nil
            setState(.disabled)
            return
        }
        guard let check = readKeyCheck() else {
            syncKey = nil
            setState(.needsPassphrase(existing: false))
            return
        }
        if let raw = Keychain.get("sync-key"),
           let stored = try? JSONDecoder().decode(StoredSyncKey.self, from: raw),
           stored.salt == check.salt {
            let key = SymmetricKey(data: stored.key)
            if (try? Crypto.open(check.verifier, key: key)) == Self.verifierPlaintext {
                syncKey = key
                setState(.ready)
                return
            }
        }
        syncKey = nil
        setState(.needsPassphrase(existing: true))
    }

    func setPassphrase(_ passphrase: String) throws {
        let key: SymmetricKey
        let salt: Data
        if let check = readKeyCheck() {
            key = Crypto.deriveKey(passphrase: passphrase, salt: check.salt, iterations: check.iterations)
            guard (try? Crypto.open(check.verifier, key: key)) == Self.verifierPlaintext else {
                throw PortalError("That passphrase doesn't match the one set on your other Mac.")
            }
            salt = check.salt
        } else {
            guard passphrase.count >= 8 else { throw PortalError("Use at least 8 characters.") }
            salt = Crypto.randomBytes(16)
            key = Crypto.deriveKey(passphrase: passphrase, salt: salt, iterations: Crypto.iterations)
            let check = KeyCheck(salt: salt, iterations: Crypto.iterations,
                                 verifier: try Crypto.seal(Self.verifierPlaintext, key: key),
                                 created: Date(), createdBy: settings.machineName)
            try FileManager.default.createDirectory(at: settings.syncFolderURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            try encoder.encode(check).write(to: keyCheckURL, options: .atomic)
        }
        let stored = StoredSyncKey(salt: salt, key: key.withUnsafeBytes { Data($0) })
        Keychain.set(try JSONEncoder().encode(stored), for: "sync-key")
        evaluate()
    }

    func forgetOnThisMac() {
        Keychain.delete("sync-key")
        evaluate()
    }

    /// Deletes the shared passphrase check and all synced clips. Other Macs will be asked for a new passphrase.
    func resetSync() {
        let fm = FileManager.default
        try? fm.removeItem(at: keyCheckURL)
        try? fm.removeItem(at: settings.syncFolderURL.appendingPathComponent("Clipboard"))
        Keychain.delete("sync-key")
        evaluate()
    }
}
