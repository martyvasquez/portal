import AppKit
import Combine
import CryptoKit

enum ClipKind: String, Codable, Sendable { case text, url, image, files }

struct ClipPayload: Codable, Sendable {
    var id = UUID()
    var created = Date()
    var machineID: String
    var machineName: String
    var kind: ClipKind
    var text: String?
    var originalText: String?   // before terminal cleanup, when it changed anything
    var image: Data?
    var imageWidth: Int?
    var imageHeight: Int?
    var files: [String]?
    var isSecret = false
    var sourceApp: String?
    var sourceBundleID: String?
    var hash: String
}

struct Clip: Identifiable, Sendable {
    let payload: ClipPayload
    let fileURL: URL
    let pinned: Bool

    var id: UUID { payload.id }
    var created: Date { payload.created }
    var isSecret: Bool { payload.isSecret }

    var title: String {
        switch payload.kind {
        case .text, .url:
            let t = (payload.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if isSecret { return SecretDetector.mask(t) }
            let firstLine = t.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? t
            return String(firstLine.prefix(200))
        case .image:
            if let w = payload.imageWidth, let h = payload.imageHeight { return "Image \(w)×\(h)" }
            return "Image"
        case .files:
            let names = (payload.files ?? []).map { ($0 as NSString).lastPathComponent }
            return names.count == 1 ? names[0] : "\(names.count) files: " + names.joined(separator: ", ")
        }
    }

    func searchable(_ q: String) -> Bool {
        let hay: String
        switch payload.kind {
        case .text, .url: hay = payload.text ?? ""
        case .files: hay = (payload.files ?? []).joined(separator: " ")
        case .image: hay = "image \(payload.sourceApp ?? "")"
        }
        return hay.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// `<epoch-ms>_<uuid>_<flags>.clip` — flags are p (pinned) / s (secret) / n (none).
/// Metadata lives in the name so expiry can run without decrypting anything.
enum ClipFileName {
    static func make(created: Date, id: UUID, pinned: Bool, secret: Bool) -> String {
        var flags = ""
        if pinned { flags += "p" }
        if secret { flags += "s" }
        if flags.isEmpty { flags = "n" }
        return "\(Int64(created.timeIntervalSince1970 * 1000))_\(id.uuidString)_\(flags).clip"
    }

    static func parse(_ name: String) -> (created: Date, id: UUID, pinned: Bool, secret: Bool)? {
        guard name.hasSuffix(".clip") else { return nil }
        let parts = name.dropLast(5).split(separator: "_")
        guard parts.count == 3, let ms = Int64(parts[0]), let id = UUID(uuidString: String(parts[1])) else { return nil }
        return (Date(timeIntervalSince1970: Double(ms) / 1000), id, parts[2].contains("p"), parts[2].contains("s"))
    }
}

enum StorageMode: Equatable, Sendable { case local, sync }

@MainActor
final class ClipStore: ObservableObject {
    @Published private(set) var clips: [Clip] = []
    @Published private(set) var undecryptable = 0
    @Published private(set) var mode: StorageMode = .local

    let settings: SettingsStore
    let keys: KeyManager

    private var cache: [String: Clip] = [:]
    private let io = DispatchQueue(label: "com.martyvasquez.portal.clips", qos: .utility)
    private var timers: [Timer] = []
    private var cancellables = Set<AnyCancellable>()
    private var lastContext: Context?

    struct Context: Sendable {
        let mode: StorageMode
        let key: SymmetricKey
        let root: URL
        let machineID: String
        let retentionDays: Int
        let secretRetentionDays: Int
        let maxPerMachine: Int
        var ownDir: URL { root.appendingPathComponent(machineID, isDirectory: true) }
        func sameLocation(_ other: Context?) -> Bool { other?.root == root && other?.mode == mode }
    }

    init(settings: SettingsStore, keys: KeyManager) {
        self.settings = settings
        self.keys = keys
    }

    var context: Context {
        let v = settings.values
        let syncing = settings.syncEnabled && keys.syncKey != nil
        return Context(
            mode: syncing ? .sync : .local,
            key: syncing ? keys.syncKey! : keys.localKey,
            root: syncing ? settings.syncFolderURL.appendingPathComponent("Clipboard", isDirectory: true)
                          : Paths.appSupport.appendingPathComponent("Clipboard", isDirectory: true),
            machineID: settings.machineID,
            retentionDays: max(1, v.clipboardRetentionDays),
            secretRetentionDays: max(1, v.secretRetentionDays),
            maxPerMachine: max(50, v.maxClipsPerMac))
    }

    func start() {
        lastContext = context
        mode = lastContext!.mode
        refresh()
        timers.append(Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        // Notice a passphrase reset or change made on the other Mac.
        timers.append(Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.keys.evaluate() }
        })
        Publishers.Merge3(
            settings.$syncEnabled.map { _ in () },
            settings.$syncFolderPath.map { _ in () },
            keys.$state.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.locationMayHaveChanged() }
            .store(in: &cancellables)
    }

    private func locationMayHaveChanged() {
        keys.evaluate()
        let new = context
        guard !new.sameLocation(lastContext) else { return }
        if let old = lastContext { migrateOwnClips(from: old, to: new) }
        lastContext = new
        mode = new.mode
        cache = [:]
        clips = []
        refresh()
    }

    // MARK: Mutations

    func add(_ payload: ClipPayload) {
        let ctx = context
        // Same content copied again: drop the older copy (keeping its pin) so it moves to the top.
        let dupes = clips.filter { $0.payload.hash == payload.hash }
        let pinned = dupes.contains { $0.pinned }
        let name = ClipFileName.make(created: payload.created, id: payload.id, pinned: pinned, secret: payload.isSecret)
        let url = ctx.ownDir.appendingPathComponent(name)
        let clip = Clip(payload: payload, fileURL: url, pinned: pinned)

        clips.removeAll { $0.payload.hash == payload.hash }
        clips.insert(clip, at: 0)
        for d in dupes { cache[d.fileURL.path] = nil }
        cache[url.path] = clip

        io.async {
            let fm = FileManager.default
            for d in dupes { try? fm.removeItem(at: d.fileURL) }
            do {
                try fm.createDirectory(at: ctx.ownDir, withIntermediateDirectories: true)
                let sealed = try Crypto.seal(try JSONEncoder().encode(payload), key: ctx.key)
                try sealed.write(to: url, options: .atomic)
            } catch {
                NSLog("Portal: failed to write clip: \(error)")
            }
        }
    }

    func delete(_ clip: Clip) {
        clips.removeAll { $0.id == clip.id }
        cache[clip.fileURL.path] = nil
        io.async { try? FileManager.default.removeItem(at: clip.fileURL) }
    }

    func togglePin(_ clip: Clip) {
        let newName = ClipFileName.make(created: clip.created, id: clip.id, pinned: !clip.pinned, secret: clip.isSecret)
        let newURL = clip.fileURL.deletingLastPathComponent().appendingPathComponent(newName)
        let updated = Clip(payload: clip.payload, fileURL: newURL, pinned: !clip.pinned)
        if let i = clips.firstIndex(where: { $0.id == clip.id }) { clips[i] = updated }
        cache[clip.fileURL.path] = nil
        cache[newURL.path] = updated
        io.async { try? FileManager.default.moveItem(at: clip.fileURL, to: newURL) }
    }

    func clearThisMac() {
        let dir = context.ownDir
        let mine = settings.machineID
        clips.removeAll { $0.payload.machineID == mine && !$0.pinned }
        io.async {
            let fm = FileManager.default
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                if let meta = ClipFileName.parse(f.lastPathComponent), meta.pinned { continue }
                try? fm.removeItem(at: f)
            }
        }
    }

    // MARK: Sync

    func refresh() {
        let ctx = context
        guard ctx.sameLocation(lastContext) || lastContext == nil else { return }
        let known = cache
        io.async {
            let result = Self.scan(ctx, known: known)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.apply(result, for: ctx) }
            }
        }
    }

    private func apply(_ result: ScanResult, for ctx: Context) {
        guard ctx.sameLocation(context) else { return }
        cache = result.cache
        if undecryptable != result.failed { undecryptable = result.failed }
        let sorted = result.cache.values.sorted { $0.created > $1.created }
        let changed = sorted.count != clips.count
            || zip(sorted, clips).contains { $0.fileURL != $1.fileURL }
        if changed { clips = sorted }
    }

    private struct ScanResult: Sendable {
        var cache: [String: Clip] = [:]
        var failed = 0
    }

    nonisolated private static func scan(_ ctx: Context, known: [String: Clip]) -> ScanResult {
        let fm = FileManager.default
        var result = ScanResult()
        let now = Date()
        var ownUnpinned: [Clip] = []
        let machineDirs = (try? fm.contentsOfDirectory(at: ctx.root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        for dir in machineDirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let isOwn = dir.lastPathComponent == ctx.machineID
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                var name = file.lastPathComponent
                var placeholder = false
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    name = String(name.dropFirst().dropLast(7))
                    placeholder = true
                }
                guard let meta = ClipFileName.parse(name) else { continue }
                let real = dir.appendingPathComponent(name)

                // Expire. Any Mac may remove expired files, so one that's been asleep for a week can't keep them alive.
                let days = meta.secret ? ctx.secretRetentionDays : ctx.retentionDays
                if !meta.pinned && now.timeIntervalSince(meta.created) > Double(days) * 86400 {
                    try? fm.removeItem(at: file)
                    continue
                }
                if placeholder {
                    try? fm.startDownloadingUbiquitousItem(at: real)
                    continue
                }
                let clip: Clip
                if let hit = known[real.path] {
                    clip = hit
                } else {
                    guard let data = try? Data(contentsOf: real),
                          let plain = try? Crypto.open(data, key: ctx.key),
                          let payload = try? JSONDecoder().decode(ClipPayload.self, from: plain) else {
                        result.failed += 1
                        continue
                    }
                    clip = Clip(payload: payload, fileURL: real, pinned: meta.pinned)
                }
                result.cache[real.path] = clip
                if isOwn && !clip.pinned { ownUnpinned.append(clip) }
            }
        }

        if ownUnpinned.count > ctx.maxPerMachine {
            ownUnpinned.sort { $0.created > $1.created }
            for extra in ownUnpinned.dropFirst(ctx.maxPerMachine) {
                try? fm.removeItem(at: extra.fileURL)
                result.cache[extra.fileURL.path] = nil
            }
        }
        return result
    }

    /// Moves this Mac's clips when switching between local and iCloud storage, re-encrypting with the new key.
    private func migrateOwnClips(from old: Context, to new: Context) {
        io.async {
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: old.ownDir, includingPropertiesForKeys: nil)) ?? []
            guard !files.isEmpty else { return }
            try? fm.createDirectory(at: new.ownDir, withIntermediateDirectories: true)
            for f in files where ClipFileName.parse(f.lastPathComponent) != nil {
                guard let data = try? Data(contentsOf: f),
                      let plain = try? Crypto.open(data, key: old.key),
                      let sealed = try? Crypto.seal(plain, key: new.key) else { continue }
                let dest = new.ownDir.appendingPathComponent(f.lastPathComponent)
                if (try? sealed.write(to: dest, options: .atomic)) != nil { try? fm.removeItem(at: f) }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } }
        }
    }
}
