import AppKit
import Combine

enum LaunchKind: Sendable { case finder, quicklink, app, command }

struct LaunchItem: Identifiable, Hashable, Sendable {
    let id: String          // quicklink UUID, app path, or "cmd:<name>"
    let name: String
    let subtitle: String
    let path: String        // for icons: app path, folder path, or ""
    let kind: LaunchKind
    let symbol: String?
    let lowerName: [UInt8]
    let lowerPath: [UInt8]
    var quicklinkID: UUID?
    var hotKey: String?
    var openWith: String?

    init(id: String, name: String, subtitle: String = "", path: String, kind: LaunchKind,
         symbol: String? = nil, keywords: String = "") {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.path = path
        self.kind = kind
        self.symbol = symbol
        self.lowerName = Array(name.lowercased().utf8)
        self.lowerPath = Array("\(subtitle) \(keywords)".lowercased().utf8)
    }

    static func == (a: LaunchItem, b: LaunchItem) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - Indexing

enum Indexer {
    static func scanApps() -> [LaunchItem] {
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", Paths.home.appendingPathComponent("Applications").path]
        var seen = Set<String>()
        var items: [LaunchItem] = []
        func add(_ url: URL) {
            guard seen.insert(url.path).inserted else { return }
            var name = fm.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            items.append(LaunchItem(id: url.path, name: name, path: url.path, kind: .app))
        }
        for root in roots {
            guard let walker = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                             errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in walker {
                if url.pathExtension == "app" {
                    add(url)
                    walker.skipDescendants()
                } else if walker.level >= 2 {
                    walker.skipDescendants()
                }
            }
        }
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        return items
    }
}

// MARK: - Matching & ranking

enum Fuzzy {
    private static let separators: Set<UInt8> = Set(" -_./".utf8)

    /// Higher is better; nil means no match. `q` and `s` are lowercased UTF-8.
    static func score(_ q: [UInt8], _ s: [UInt8]) -> Int? {
        guard !q.isEmpty else { return 0 }
        guard q.count <= s.count else { return nil }

        // Greedy subsequence match with bonuses for word starts and runs.
        var qi = 0, total = 0, prev = -2, first = -1
        for i in 0..<s.count where qi < q.count {
            guard s[i] == q[qi] else { continue }
            var bonus = 1
            if i == 0 { bonus += 15 } else if separators.contains(s[i - 1]) { bonus += 8 }
            if prev == i - 1 { bonus += 9 }
            if first < 0 { first = i }
            total += bonus
            prev = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        total -= min(first, 10)

        // A contiguous substring usually beats a scattered match.
        if let at = indexOf(q, in: s) {
            var contiguous = q.count * 8
            if at == 0 { contiguous += 20 } else if separators.contains(s[at - 1]) { contiguous += 12 }
            total = max(total, contiguous)
        }
        if s == q { total += 40 } else if s.starts(with: q) { total += 15 }
        total -= (s.count - q.count) / 4
        return total
    }

    private static func indexOf(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard needle.count <= hay.count else { return nil }
        outer: for i in 0...(hay.count - needle.count) {
            for j in 0..<needle.count where hay[i + j] != needle[j] { continue outer }
            return i
        }
        return nil
    }
}

struct UsageEntry: Codable, Sendable {
    var count: Int
    var last: Date

    /// Frecency: frequency, weighted toward recent use.
    func boost(now: Date) -> Double {
        let age = now.timeIntervalSince(last)
        let recency: Double = age < 3600 ? 4 : age < 86400 ? 2.5 : age < 7 * 86400 ? 1.5 : age < 30 * 86400 ? 1 : 0.5
        return min(60, log2(Double(count) + 1) * 8 * recency)
    }
}

@MainActor
final class UsageStore {
    private(set) var entries: [String: UsageEntry] = [:]
    private let url = Paths.appSupport.appendingPathComponent("usage.json")

    init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: UsageEntry].self, from: data) {
            entries = decoded
        }
    }

    func record(_ id: String) {
        var e = entries[id] ?? UsageEntry(count: 0, last: .distantPast)
        e.count += 1
        e.last = Date()
        entries[id] = e
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
    }
}

enum Ranker {
    static func rank(query: [UInt8], items: [LaunchItem], usage: [String: UsageEntry], limit: Int) -> [LaunchItem] {
        let now = Date()
        var scored: [(LaunchItem, Double)] = []
        scored.reserveCapacity(256)

        if query.isEmpty {
            for item in items {
                guard let u = usage[item.id] else { continue }
                scored.append((item, u.boost(now: now)))
            }
        } else {
            let hasSlash = query.contains(UInt8(ascii: "/"))
            for item in items {
                var base = Fuzzy.score(query, item.lowerName)
                if base == nil, hasSlash || item.kind != .app {
                    base = Fuzzy.score(query, item.lowerPath).map { $0 - 8 }
                }
                guard let base else { continue }
                var total = Double(base) + (usage[item.id]?.boost(now: now) ?? 0)
                if item.kind == .quicklink { total += 12 }   // your quicklinks outrank apps
                if item.kind == .app { total += 3 }
                scored.append((item, total))
            }
        }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).map(\.0)
    }
}

// MARK: - Opening quicklinks

@MainActor
enum QuicklinkOpener {
    static func open(_ link: Quicklink, query: String = "", useDefaultApp: Bool = false) {
        guard let url = link.resolvedURL(query: query) else { NSSound.beep(); return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let app = link.appURL, !useDefaultApp {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg) { _, error in
                if let error { NSLog("Portal: couldn't open \(url) with \(app.lastPathComponent): \(error)") }
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Model

enum LaunchAction { case primary, alternate, copy }

@MainActor
final class LauncherModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue && pending == nil { search() } } }
    @Published private(set) var results: [LaunchItem] = []
    @Published var selection = 0
    @Published private(set) var appCount = 0
    /// A quicklink with `{query}` waiting for its argument.
    @Published private(set) var pending: Quicklink?
    /// Folders selected in Finder when the launcher opened.
    @Published private(set) var finderFolders: [URL] = []
    private var finderFromSelection = true

    var onCommand: (String) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    let settings: SettingsStore
    private let usage = UsageStore()
    private var apps: [LaunchItem] = []
    private var generation = 0
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?

    static let commands: [LaunchItem] = [
        LaunchItem(id: "cmd:clipboard", name: "Clipboard History", path: "", kind: .command, symbol: "doc.on.clipboard", keywords: "paste"),
        LaunchItem(id: "cmd:new", name: "New Quicklink", path: "", kind: .command, symbol: "plus", keywords: "add create"),
        LaunchItem(id: "cmd:settings", name: "Portal Settings", path: "", kind: .command, symbol: "gearshape", keywords: "preferences"),
        LaunchItem(id: "cmd:quit", name: "Quit Portal", path: "", kind: .command, symbol: "power", keywords: "exit"),
    ]

    init(settings: SettingsStore) {
        self.settings = settings
        settings.$values
            .map(\.includeApps)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reindex() }
            .store(in: &cancellables)
        settings.$values
            .map(\.quicklinks)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.search() }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reindex() }
        }
    }

    func reindex() {
        let includeApps = settings.values.includeApps
        DispatchQueue.global(qos: .utility).async {
            let apps = includeApps ? Indexer.scanApps() : []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.apps = apps
                    self.appCount = apps.count
                    self.search()
                }
            }
        }
    }

    func prepareForShow() {
        pending = nil
        query = ""
        finderFolders = []
        let askFinder = FinderSelection.finderIsFrontmost
        search()
        // Ask Finder after the panel is on screen so it opens instantly.
        if askFinder {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let result = FinderSelection.current() else { return }
                    self.finderFolders = result.folders
                    self.finderFromSelection = result.fromSelection
                    self.search()
                }
            }
        }
    }

    var finderAppName: String {
        let n = FileManager.default.displayName(atPath: settings.values.finderSelectionAppPath)
        return n.hasSuffix(".app") ? String(n.dropLast(4)) : n
    }

    private var finderItems: [LaunchItem] {
        let app = finderAppName
        return finderFolders.map { url in
            var item = LaunchItem(id: "finder:\(url.path)", name: "Open “\(url.lastPathComponent)” in \(app)",
                                  subtitle: Paths.abbreviate(url.path), path: url.path, kind: .finder,
                                  keywords: "finder selection \(app) terminal")
            item.openWith = settings.values.finderSelectionAppPath
            return item
        }
    }

    private var quicklinkItems: [LaunchItem] {
        settings.values.quicklinks.map { q in
            let shown = q.isFolder ? Paths.abbreviate(Paths.expand(q.link).path) : q.link
            var item = LaunchItem(id: q.id.uuidString, name: q.name, subtitle: shown,
                                  path: q.isFolder ? Paths.expand(q.link).path : "", kind: .quicklink,
                                  keywords: q.appName)
            item.quicklinkID = q.id
            item.hotKey = q.hotKey?.display
            item.openWith = q.appPath
            return item
        }
    }

    func search() {
        generation += 1
        let gen = generation
        let q = Array(query.trimmingCharacters(in: .whitespaces).lowercased().utf8)
        let links = quicklinkItems
        let finder = finderItems
        let items = finder + Self.commands + links + apps
        let usage = usage.entries
        DispatchQueue.global(qos: .userInitiated).async {
            let ranked: [LaunchItem]
            if q.isEmpty {
                // Quicklinks in the order you arranged them, then recently used apps.
                ranked = finder + links + Ranker.rank(query: [], items: items.filter { $0.kind == .app }, usage: usage, limit: 5)
            } else {
                ranked = Ranker.rank(query: q, items: items, usage: usage, limit: 60)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard gen == self.generation else { return }
                    self.results = ranked
                    self.selection = 0
                }
            }
        }
    }

    var selectedItem: LaunchItem? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    func quicklink(for item: LaunchItem?) -> Quicklink? {
        guard let id = item?.quicklinkID else { return nil }
        return settings.values.quicklinks.first { $0.id == id }
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    func cancelPending() {
        pending = nil
        query = ""
        search()
    }

    func handleKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if let link = pending {
            switch Int(e.keyCode) {
            case 36, 76:
                let text = query
                onDismiss()
                usage.record(link.id.uuidString)
                QuicklinkOpener.open(link, query: text, useDefaultApp: flags.contains(.command))
                return true
            case 53: cancelPending(); return true
            case 51 where query.isEmpty: cancelPending(); return true
            default: return false
            }
        }
        switch Int(e.keyCode) {
        case 125: move(1); return true            // ↓
        case 126: move(-1); return true           // ↑
        case 36, 76:                              // ↩
            perform(flags.contains(.option) ? .copy : flags.contains(.command) ? .alternate : .primary)
            return true
        case 48:                                  // ⇥ fills in a {query} quicklink
            if let link = quicklink(for: selectedItem), link.needsQuery { beginArgument(link) }
            return true
        case 53:                                  // ⎋
            if query.isEmpty { onDismiss() } else { query = "" }
            return true
        default: break
        }
        let chars = e.charactersIgnoringModifiers ?? ""
        if flags == .control && (chars == "n" || chars == "j") { move(1); return true }
        if flags == .control && (chars == "p" || chars == "k") { move(-1); return true }
        if flags == .command, let n = Int(chars), (1...9).contains(n), n <= results.count {
            selection = n - 1
            perform(.primary)
            return true
        }
        return false
    }

    func beginArgument(_ link: Quicklink) {
        pending = link
        query = ""
    }

    func perform(_ action: LaunchAction, item: LaunchItem? = nil) {
        guard let item = item ?? selectedItem else { return }
        switch item.kind {
        case .finder:
            onDismiss()
            let url = URL(fileURLWithPath: item.path)
            if action == .copy {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            } else if action == .alternate {
                FinderSelection.open(finderFolders, withAppAt: settings.values.finderSelectionAppPath)
            } else {
                FinderSelection.open([url], withAppAt: settings.values.finderSelectionAppPath)
            }
        case .command:
            usage.record(item.id)
            onCommand(String(item.id.dropFirst(4)))   // before dismissing, so Settings can take focus
            onDismiss()
        case .quicklink:
            guard let link = quicklink(for: item) else { return }
            if action == .copy {
                onDismiss()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.resolvedURL()?.absoluteString.removingPercentEncoding ?? link.link, forType: .string)
                return
            }
            if link.needsQuery { beginArgument(link); return }
            onDismiss()
            usage.record(item.id)
            QuicklinkOpener.open(link, useDefaultApp: action == .alternate)
        case .app:
            onDismiss()
            let url = URL(fileURLWithPath: item.path)
            switch action {
            case .primary:
                usage.record(item.id)
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            case .alternate:
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .copy:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
        }
    }

    func hints(for item: LaunchItem?) -> [(String, String)] {
        if let pending { return [("↩", "Open in \(pending.appName)"), ("⎋", "Back")] }
        guard let item else { return [("⎋", "Close")] }
        switch item.kind {
        case .finder:
            var hints = [("↩", "Open in \(finderAppName)")]
            if finderFolders.count > 1 { hints.append(("⌘↩", "Open All \(finderFolders.count)")) }
            hints.append(("⌥↩", "Copy Path"))
            return hints
        case .quicklink:
            guard let link = quicklink(for: item) else { return [] }
            if link.needsQuery { return [("↩", "Enter Query"), ("⌥↩", "Copy Link")] }
            var hints = [("↩", "Open in \(link.appName)")]
            if link.appPath != nil { hints.append(("⌘↩", link.isFolder ? "Finder" : "Default Browser")) }
            hints.append(("⌥↩", "Copy Link"))
            return hints
        case .app:
            return [("↩", "Open"), ("⌘↩", "Show in Finder")]
        case .command:
            return [("↩", "Run")]
        }
    }
}
