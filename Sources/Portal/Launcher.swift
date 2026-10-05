import AppKit
import Combine

enum LaunchKind: Sendable { case transform, finder, snippet, folderAction, quicklink, app, command }

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
    var snippetText: String?
    var transformerID: UUID?
    /// Short label shown at the right of the row, like a transformer's action.
    var badge: String?
    /// Launcher section this row belongs to; defaults to one per kind.
    var section: String?

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
                var nameMatch = true
                if base == nil, hasSlash || item.kind != .app {
                    base = Fuzzy.score(query, item.lowerPath).map { $0 - 8 }
                    nameMatch = false
                }
                guard let base else { continue }
                // Frequent use shouldn't lift a keyword match over something whose name matches.
                let boost = usage[item.id]?.boost(now: now) ?? 0
                var total = Double(base) + (nameMatch ? boost : boost / 4)
                if item.kind == .quicklink || item.kind == .transform { total += 12 }   // yours outrank apps
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
    @Published var query = "" { didSet { if query != oldValue && pending == nil && !promptMode && run == nil { search() } } }
    @Published private(set) var results: [LaunchItem] = []
    @Published var selection = 0
    @Published private(set) var appCount = 0
    /// A quicklink with `{query}` waiting for its argument.
    @Published private(set) var pending: Quicklink?
    /// What was selected in Finder when the launcher opened.
    @Published private(set) var finder: FinderSelection.Result?
    /// The app the launcher was opened over, and the folder it's in (if it can tell).
    @Published private(set) var context = SnippetContext()
    /// One-line result of the last folder action, shown in the footer.
    @Published private(set) var notice: String?
    /// The selected text (or a clip) that transformers work on.
    @Published private(set) var transformInput: TransformInput?
    /// Typing a one-off prompt for "Transform with Prompt".
    @Published private(set) var promptMode = false
    /// The transformer that's running or showing its result.
    @Published private(set) var run: TransformRun?
    /// What happens to `run`'s result: the transformer's own action unless ⌘↩ or ⌥↩ picked another.
    @Published private(set) var runAction: TransformAction = .preview
    /// The result was just copied; the launcher shows a confirmation, then closes.
    @Published private(set) var copied = false
    /// Set before showing, to open on a clip's transformers or straight into a transformer.
    private var queued: (input: TransformInput, transformer: Transformer?)?
    /// Opened from clipboard history: only transformers, no apps or quicklinks.
    private var transformOnly = false
    private var showCount = 0
    let ai = AIService.shared
    /// Launcher row id → (items to open, app to open them with).
    private var finderTargets: [String: (urls: [URL], app: String)] = [:]

    var onCommand: (String) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    let settings: SettingsStore
    private let usage = UsageStore()
    private var apps: [LaunchItem] = []
    private var generation = 0
    /// Row to keep selected through the next search, like one just pinned.
    private var reselect: String?
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
        settings.$values
            .map(\.transformers)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.search() }
            .store(in: &cancellables)
        settings.$values
            .map { [$0.pinned, [String($0.recentLimit), String($0.recentLimitWithMatches)]] }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.search() }
            .store(in: &cancellables)
        ai.$isSignedIn
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

    /// Opens on `input`'s transformers the next time the launcher shows, or runs `transformer` on it right away.
    func queue(_ input: TransformInput, transformer: Transformer? = nil) {
        queued = (input, transformer)
    }

    func prepareForShow() {
        showCount += 1
        let shown = showCount
        run?.cancel()
        run = nil
        copied = false
        pending = nil
        promptMode = false
        query = ""
        finder = nil
        notice = nil
        let front = NSWorkspace.shared.frontmostApplication
        context = SnippetContext(appID: front?.bundleIdentifier, appName: front?.localizedName)
        let queued = self.queued
        self.queued = nil
        transformOnly = queued != nil && queued?.transformer == nil
        // Read the selection now, while the app still has the keyboard: Accessibility when the app
        // reports it (instant), else its Edit ▸ Copy, whose result is read once the panel is up.
        transformInput = queued?.input
        if queued == nil {
            switch SelectionReader.accessibilitySelection(in: front) {
            case .text(let text):
                transformInput = TransformInput(text: text, source: .selection)
            case .none:
                break
            case .unsupported:
                SelectionReader.copiedText(from: front, keystroke: false) { text in
                    guard let text, shown == self.showCount, self.transformInput == nil else { return }
                    self.transformInput = TransformInput(text: text, source: .selection)
                    if self.run == nil && self.pending == nil && !self.promptMode { self.search() }
                }
            }
        }
        search()
        // Ask Finder/Ghostty/Terminal after the panel is on screen so it opens instantly.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if FinderSelection.finderIsFrontmost, queued == nil {
                    self.finder = FinderSelection.current(excludedTypes: self.settings.values.excludedFileTypes)
                }
                if let folder = FolderContext.current(frontApp: self.context.appID) {
                    self.context.load(folder: folder)
                }
                self.context.url = BrowserContext.currentURL(frontApp: self.context.appID)
                if let transformer = queued?.transformer {
                    self.startTransform(transformer)   // after the page URL is known, for {url}
                    return
                }
                if self.finder != nil || self.context.folder != nil || self.context.url != nil { self.search() }
            }
        }
    }

    /// The panel closed: stop any run, so a late reply never pastes into whatever is in front now.
    func didHide() {
        run?.cancel()
    }

    /// Rows for the transformers, when there's selected text or a clip to work on: the ones that
    /// match where you are (or every global one, when none do), and the global ones left over.
    private func makeTransformItems() -> (matching: [LaunchItem], others: [LaunchItem]) {
        guard let input = transformInput else { return ([], []) }
        let section = input.source == .clipboard ? "Transform Clip" : "Transform Selection"
        guard ai.isSignedIn else {
            var item = LaunchItem(id: "ai:signin", name: "Sign In with ChatGPT",
                                  subtitle: "Transformers run on your ChatGPT Plus or Pro plan",
                                  path: "", kind: .transform, symbol: "sparkles",
                                  keywords: "transform transformer ai chatgpt")
            item.section = section
            return ([item], [])
        }
        // Scopes apply to selections; a clip can be headed anywhere, so it gets every transformer.
        var matching: [LaunchItem]
        var others: [LaunchItem] = []
        if input.source == .clipboard {
            matching = settings.values.transformers.map { transformRow($0, section: section) }
        } else {
            let all = settings.values.transformers
            let matches = all.filter { !$0.isGlobal && $0.applies(app: context.appID, url: context.url) }
            let global = all.filter { $0.isGlobal && $0.applies(app: context.appID, url: context.url) }
            if matches.isEmpty {
                matching = global.map { transformRow($0, section: section) }
            } else {
                let title = matchSection(matches)
                matching = matches.map { transformRow($0, section: title) }
                others = global.map { transformRow($0, section: "Everywhere") }
            }
        }
        var custom = LaunchItem(id: "transform:custom", name: "Transform with Prompt…",
                                subtitle: "Type what to do with the \(input.source == .clipboard ? "clip" : "selection")",
                                path: "", kind: .transform, symbol: "text.bubble",
                                keywords: "transformer ai prompt ask chatgpt custom")
        custom.section = matching.last?.section ?? section
        matching.append(custom)
        return (matching, others)
    }

    private func transformRow(_ t: Transformer, section: String?) -> LaunchItem {
        var item = LaunchItem(id: "transform:\(t.id)", name: t.name, subtitle: Self.promptSummary(t.prompt),
                              path: "", kind: .transform, symbol: "wand.and.sparkles",
                              keywords: "transform transformer ai")
        item.transformerID = t.id
        item.hotKey = t.hotKey?.display
        item.badge = actionLabel(t.action)
        item.section = section
        return item
    }

    /// "transform make it shorter" runs "make it shorter" as a one-off prompt.
    private func inlinePromptItem(_ query: String) -> LaunchItem? {
        guard let input = transformInput, ai.isSignedIn else { return nil }
        let prefix = "transform "
        guard query.lowercased().hasPrefix(prefix) else { return nil }
        let prompt = query.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return nil }
        var item = LaunchItem(id: "transform:inline", name: prompt,
                              subtitle: "Runs this prompt on the \(input.source == .clipboard ? "clip" : "selection")",
                              path: "", kind: .transform, symbol: "text.bubble")
        item.section = input.source == .clipboard ? "Transform Clip" : "Transform Selection"
        item.badge = actionLabel(settings.values.customPromptAction)
        return item
    }

    /// "For mail.google.com" or "For Mail": where the matching transformers apply.
    private func matchSection(_ matches: [Transformer]) -> String {
        if let url = context.url, matches.contains(where: { t in t.sites.contains { SiteMatcher.matches($0, url) } }) {
            return "For \(SiteMatcher.label(url))"
        }
        return "For \(context.appName ?? "This App")"
    }

    /// A prompt as a row's subtitle: one line, without the `{selection}` placeholder every prompt has.
    static func promptSummary(_ prompt: String) -> String {
        let lines = prompt.replacingOccurrences(of: "{selection}", with: " ")
            .split(whereSeparator: \.isNewline)
            .map { line -> String in
                var l = line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
                l = l.replacingOccurrences(of: " .", with: ".").replacingOccurrences(of: " :", with: ":")
                return l
            }
            .filter { !$0.isEmpty }
        // Lines become sentences: "Polish and refine. Fix grammar…", not "Polish and refine Fix grammar…".
        var text = lines.enumerated().map { i, line in
            i < lines.count - 1 && !".:!?;,".contains(line.last!) ? line + "." : line
        }.joined(separator: " ")
        while let last = text.last, last == ":" || last == " " { text.removeLast() }
        return text
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// What an action is called here: Replace becomes Paste for a clip, and Copy in Finder.
    func actionLabel(_ action: TransformAction) -> String {
        switch action {
        case .preview: "Preview"
        case .copy: "Copy"
        case .replace: !canPaste ? "Copy" : transformInput?.source == .clipboard ? "Paste" : "Replace"
        }
    }

    /// Pasting into Finder does nothing useful, so there results are copied.
    private var canPaste: Bool { context.appID != "com.apple.finder" }

    /// Rows for snippets: this folder's (.portal.json), this site's, this app's, then global.
    private func makeSnippetItems() -> (folder: [LaunchItem], site: [LaunchItem], app: [LaunchItem], global: [LaunchItem]) {
        func row(_ id: String, _ name: String, _ text: String, section: String) -> LaunchItem { Self.snippetRow(id, name, text, section: section) }
        var folder: [LaunchItem] = []
        if let root = context.root {
            let section = "Snippets · \(root.lastPathComponent)"
            if let error = context.fileError {
                var item = LaunchItem(id: "folder:fix", name: "Fix \(PortalFile.name)", subtitle: error,
                                      path: "", kind: .folderAction, symbol: "exclamationmark.triangle")
                item.section = section
                folder.append(item)
            }
            for (i, s) in (context.file?.snippets ?? []).enumerated() {
                folder.append(row("folder:\(i):\(s.text)", s.name, s.text, section: section))
            }
            let seedName = context.file == nil ? "Build Commands for \(root.lastPathComponent)"
                                               : "Update Commands for \(root.lastPathComponent)"
            var seed = LaunchItem(id: "folder:seed", name: seedName,
                                  subtitle: "Adds the repo's scripts and tasks to \(PortalFile.name)",
                                  path: "", kind: .folderAction, symbol: "arrow.triangle.2.circlepath",
                                  keywords: "build update seed generate commands snippets")
            seed.section = section
            folder.append(seed)
            if context.file != nil {
                var editRow = LaunchItem(id: "folder:edit", name: "Edit Snippets for \(root.lastPathComponent)",
                                         subtitle: Paths.abbreviate(root.appendingPathComponent(PortalFile.name).path),
                                         path: "", kind: .folderAction, symbol: "pencil",
                                         keywords: "edit snippets portal json")
                editRow.section = section
                folder.append(editRow)
            }
        }
        let all = settings.values.snippets
        var site: [LaunchItem] = []
        if let url = context.url {
            site = all.filter { s in s.sites.contains { SiteMatcher.matches($0, url) } }
                .map { row("snippet:\($0.id)", $0.name, $0.text, section: "Snippets · \(SiteMatcher.label(url))") }
        }
        let appName = context.appName ?? "This App"
        let app = all.filter { s in context.appID.map { s.apps.contains($0) } ?? false }
            .map { row("snippet:\($0.id)", $0.name, $0.text, section: "Snippets · \(appName)") }
        let global = all.filter(\.isGlobal).map { row("snippet:\($0.id)", $0.name, $0.text, section: "Snippets") }
        return (folder, site, app, global)
    }

    static func snippetRow(_ id: String, _ name: String, _ text: String, section: String?) -> LaunchItem {
        var item = LaunchItem(id: id, name: name.isEmpty ? text : name, subtitle: name.isEmpty ? "" : text,
                              path: "", kind: .snippet, symbol: "text.insert", keywords: text)
        item.snippetText = text
        item.section = section
        return item
    }

    /// One row per app, in the order set in Settings → Open With: folder apps, then file apps.
    private func makeFinderItems() -> [LaunchItem] {
        finderTargets = [:]
        guard let finder else { return [] }
        var items: [LaunchItem] = []
        func rows(_ urls: [URL], apps: [String], noun: String) {
            guard !urls.isEmpty else { return }
            let what = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) \(noun)s"
            let subtitle = urls.count == 1 ? Paths.abbreviate(urls[0].path) : urls.map(\.lastPathComponent).joined(separator: ", ")
            for app in apps {
                let name = SharedSettings.appName(app)
                let id = "finder:\(noun):\(app)"
                var item = LaunchItem(id: id, name: "Open \(what) in \(name)", subtitle: subtitle,
                                      path: urls[0].path, kind: .finder, keywords: "finder selection \(noun) \(name)")
                item.openWith = app
                finderTargets[id] = (urls, app)
                items.append(item)
            }
        }
        rows(finder.folders, apps: settings.values.folderOpenWith, noun: "folder")
        rows(finder.files, apps: settings.values.fileOpenWith, noun: "file")
        return items
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
        let finder = makeFinderItems()
        let snippets = makeSnippetItems()
        let transforms = makeTransformItems()
        let inline = inlinePromptItem(query.trimmingCharacters(in: .whitespaces)).map { [$0] } ?? []
        let transformOnly = transformOnly
        // What fits where you are: the selection's transformers, Finder's selection, this folder's,
        // site's, and app's snippets. These always show in full; everything else earns its place.
        let matching = transformOnly ? transforms.matching
            : transforms.matching + finder + snippets.folder + snippets.site + snippets.app
        let general = transformOnly ? [] : transforms.others + snippets.global + Self.commands + links + apps
        let items = matching + general
        let usage = usage.entries
        let shown = Set(matching.map(\.id))
        let pins = transformOnly ? [] : pinnedRows().filter { !shown.contains($0.id) }
        let skip = shown.union(pins.map(\.id)).union(["cmd:quit"])
        let limit = max(0, matching.isEmpty ? settings.values.recentLimit : settings.values.recentLimitWithMatches)
        let reselect = self.reselect
        self.reselect = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let ranked: [LaunchItem]
            if q.isEmpty {
                let pool = general.filter { !skip.contains($0.id) }
                var recent = Ranker.rank(query: [], items: pool, usage: usage, limit: limit)
                // Until there's history, quicklinks fill the rest, in the order you arranged them.
                let taken = Set(recent.map(\.id))
                recent += pool.filter { $0.kind == .quicklink && !taken.contains($0.id) }.prefix(limit - recent.count)
                ranked = matching + Self.sectioned(pins, "Pinned") + Self.sectioned(recent, "Recent")
            } else {
                ranked = inline + Ranker.rank(query: q, items: items, usage: usage, limit: 60)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard gen == self.generation else { return }
                    self.results = ranked
                    self.selection = reselect.flatMap { id in ranked.firstIndex { $0.id == id } } ?? 0
                }
            }
        }
    }

    nonisolated private static func sectioned(_ items: [LaunchItem], _ section: String) -> [LaunchItem] {
        items.map { var item = $0; item.section = section; return item }
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

    func showNotice(_ text: String) {
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.notice == text { self?.notice = nil }
        }
    }

    func cancelPending() {
        pending = nil
        promptMode = false
        query = ""
        search()
    }

    func handleKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if let run { return handleRunKey(e, run: run, flags: flags) }
        if promptMode {
            switch Int(e.keyCode) {
            case 36, 76:
                let prompt = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if !prompt.isEmpty { runPrompt(prompt, action: override(for: flags)) }
                return true
            case 53: cancelPending(); return true
            case 51 where query.isEmpty: cancelPending(); return true
            default: return false
            }
        }
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
        case 48:                                  // ⇥ fills in a {query} quicklink or a prompt
            if let link = quicklink(for: selectedItem), link.needsQuery { beginArgument(link) }
            if selectedItem?.id == "transform:custom" { beginPrompt() }
            return true
        case 53:                                  // ⎋
            if query.isEmpty { onDismiss() } else { query = "" }
            return true
        default: break
        }
        let chars = e.charactersIgnoringModifiers ?? ""
        if flags == .control && (chars == "n" || chars == "j") { move(1); return true }
        if flags == .control && (chars == "p" || chars == "k") { move(-1); return true }
        if flags == .command && chars == "p", let item = selectedItem, isPinnable(item) {
            togglePin(item)
            return true
        }
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
        case .transform:
            let chosen: TransformAction? = action == .copy ? .copy : action == .alternate ? .preview : nil
            switch item.id {
            case "ai:signin":
                onCommand("chatgpt")
                onDismiss()
            case "transform:custom":
                beginPrompt()
            case "transform:inline":
                runPrompt(item.name, action: chosen)
            default:
                guard let t = settings.values.transformers.first(where: { $0.id == item.transformerID }) else { return }
                usage.record(item.id)
                startTransform(t, action: chosen)
            }
        case .snippet:
            guard let text = item.snippetText else { return }
            onDismiss()
            usage.record(item.id)
            // Pasting into Finder does nothing useful, so there it copies.
            if action == .copy || context.appID == "com.apple.finder" {
                SnippetPaster.copy(text)
            } else {
                SnippetPaster.paste(text)
            }
        case .folderAction:
            performFolderAction(item.id)
        case .finder:
            onDismiss()
            guard let target = finderTargets[item.id] else { return }
            if action == .copy {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(target.urls.map(\.path).joined(separator: "\n"), forType: .string)
            } else {
                FinderSelection.open(target.urls, withAppAt: target.app)
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
        if promptMode { return [("↩", actionLabel(settings.values.customPromptAction)), ("⎋", "Back")] }
        guard let item else { return [("⎋", "Close")] }
        switch item.kind {
        case .transform:
            switch item.id {
            case "ai:signin": return [("↩", "Sign In")]
            case "transform:custom": return [("↩", "Write Prompt")]
            default:
                let own = item.id == "transform:inline" ? settings.values.customPromptAction
                    : settings.values.transformers.first { $0.id == item.transformerID }?.action ?? .preview
                var hints = [("↩", actionLabel(own))]
                if own != .preview { hints.append(("⌘↩", "Preview")) }
                if own != .copy { hints.append(("⌥↩", "Copy")) }
                return hints
            }
        case .snippet:
            return context.appID == "com.apple.finder" ? [("↩", "Copy")] : [("↩", "Paste"), ("⌥↩", "Copy")]
        case .folderAction:
            return [("↩", item.id == "folder:seed" ? "Scan Repo" : "Open File")]
        case .finder:
            return [("↩", "Open"), ("⌥↩", "Copy Path")]
        case .quicklink:
            guard let link = quicklink(for: item) else { return [] }
            if link.needsQuery { return [("↩", "Enter Query"), ("⌥↩", "Copy Link")] }
            var hints = [("↩", "Open in \(link.appName)")]
            if link.hasAlternateApp { hints.append(("⌘↩", link.isFolder ? "Finder" : "Default Browser")) }
            hints.append(("⌥↩", "Copy Link"))
            return hints
        case .app:
            return [("↩", "Open"), ("⌘↩", "Show in Finder")]
        case .command:
            return [("↩", "Run")]
        }
    }
}

// MARK: - Pins

extension LauncherModel {
    /// Anything not tied to an app, site, folder, or selection can be pinned; those show up on their own.
    func isPinnable(_ item: LaunchItem) -> Bool {
        switch item.kind {
        case .quicklink, .app: return true
        case .command: return item.id != "cmd:quit"
        case .snippet: return settings.values.snippets.contains { "snippet:\($0.id)" == item.id && $0.isGlobal }
        case .transform: return settings.values.transformers.contains { $0.id == item.transformerID && $0.isGlobal }
        case .finder, .folderAction: return false
        }
    }

    func isPinned(_ item: LaunchItem) -> Bool { settings.values.pinned.contains(item.id) }

    func togglePin(_ item: LaunchItem) {
        reselect = item.id
        if isPinned(item) {
            settings.values.pinned.removeAll { $0 == item.id }
            showNotice("Unpinned \(item.name)")
        } else {
            settings.values.pinned.append(item.id)
            showNotice("Pinned \(item.name)")
        }
    }

    /// The row a pinned id stands for, or nil once it's deleted, scoped, or (for an app) not on this Mac.
    func pinnedRow(_ id: String) -> LaunchItem? {
        if id.hasPrefix("cmd:") { return Self.commands.first { $0.id == id } }
        if id.hasPrefix("snippet:") {
            guard let s = settings.values.snippets.first(where: { "snippet:\($0.id)" == id && $0.isGlobal }) else { return nil }
            return Self.snippetRow(id, s.name, s.text, section: nil)
        }
        if id.hasPrefix("transform:") {
            guard let t = settings.values.transformers.first(where: { "transform:\($0.id)" == id && $0.isGlobal }) else { return nil }
            return transformRow(t, section: nil)
        }
        if id.hasPrefix("/") {
            guard FileManager.default.fileExists(atPath: id) else { return nil }
            return LaunchItem(id: id, name: SharedSettings.appName(id), path: id, kind: .app)
        }
        return quicklinkItems.first { $0.id == id }
    }

    /// Pinned rows for the launcher right now. Transformers only show with a selection to work on.
    fileprivate func pinnedRows() -> [LaunchItem] {
        settings.values.pinned.compactMap(pinnedRow).filter { item in
            guard item.kind == .transform else { return true }
            guard transformInput != nil, ai.isSignedIn,
                  let t = settings.values.transformers.first(where: { $0.id == item.transformerID }) else { return false }
            return t.applies(app: context.appID, url: context.url)
        }
    }
}

// MARK: - Snippet context

/// The app the launcher opened over and, when known, its folder and `.portal.json`.
struct SnippetContext {
    var appID: String?
    var appName: String?
    /// The front browser tab's page, when the launcher opened over a browser.
    var url: URL?
    var folder: URL?
    /// Where `.portal.json` lives (or would be created): the existing file's folder, else the git root.
    var root: URL?
    var file: PortalFile?
    var fileError: String?

    mutating func load(folder: URL) {
        self.folder = folder
        file = nil
        fileError = nil
        if let url = PortalFile.find(from: folder) {
            root = url.deletingLastPathComponent()
            do { file = try PortalFile.load(url) } catch { fileError = Self.describe(error) }
        } else {
            root = PortalFile.projectRoot(for: folder)
        }
    }

    private static func describe(_ error: Error) -> String {
        if case PortalFile.LoadError.invalid(_, let why) = error { return why }
        let text = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
        return "Not valid JSON: \(text)"
    }
}

extension LauncherModel {
    fileprivate func performFolderAction(_ id: String) {
        guard let root = context.root else { return }
        let file = root.appendingPathComponent(PortalFile.name)
        switch id {
        case "folder:seed":
            do {
                let added = try PortalFile.seed(at: root, with: CommandDetector.detect(in: root))
                context.load(folder: context.folder ?? root)
                showNotice(added == 0 ? "No new commands found in \(root.lastPathComponent)"
                                      : "Added \(added) command\(added == 1 ? "" : "s") to \(PortalFile.name)")
                search()
            } catch {
                NSSound.beep()
                showNotice("Couldn't update \(PortalFile.name): fix it first")
            }
        default: // edit or fix: open the file in the first Files app
            onDismiss()
            if let app = settings.values.fileOpenWith.first {
                FinderSelection.open([file], withAppAt: app)
            } else {
                NSWorkspace.shared.open(file)
            }
        }
    }
}

// MARK: - Transformers

extension LauncherModel {
    func beginPrompt() {
        promptMode = true
        query = ""
    }

    /// ⌘↩ previews and ⌥↩ copies, whatever the transformer normally does.
    fileprivate func override(for flags: NSEvent.ModifierFlags) -> TransformAction? {
        flags.contains(.option) ? .copy : flags.contains(.command) ? .preview : nil
    }

    func runPrompt(_ prompt: String, action: TransformAction?) {
        startTransform(Transformer(name: prompt, prompt: prompt), action: action ?? settings.values.customPromptAction)
    }

    func startTransform(_ transformer: Transformer, action: TransformAction? = nil) {
        guard let input = transformInput else { return }
        let context = TransformPrompt.Context(app: context.appName, url: context.url,
                                              clipboard: NSPasteboard.general.string(forType: .string))
        let run = TransformRun(transformer: transformer, input: input, context: context, ai: ai)
        let action = action ?? transformer.action
        runAction = action
        if action != .preview {
            run.onFirstReply = { [weak self] text in self?.deliver(text, action) }
        }
        pending = nil
        promptMode = false
        self.run = run
        query = ""
        run.start()
    }

    /// Pastes over the selection (or into the app, for a clip) once the launcher closes,
    /// or copies and shows a confirmation before closing.
    func deliver(_ text: String, _ action: TransformAction) {
        guard action == .copy || !canPaste else {
            onDismiss()
            SnippetPaster.paste(text)
            return
        }
        SnippetPaster.copy(text)
        copied = true
        let shown = showCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.copied, self.showCount == shown else { return }
                self.onDismiss()
            }
        }
    }

    /// Back from a run to the transformers.
    func endRun() {
        run?.cancel()
        run = nil
        copied = false
        query = ""
        search()
    }

    fileprivate func handleRunKey(_ e: NSEvent, run: TransformRun, flags: NSEvent.ModifierFlags) -> Bool {
        if copied { return true }
        // Replace and Copy runs have nothing to type into: only ⎋ and ⌘R.
        guard runAction == .preview else {
            if Int(e.keyCode) == 53 { endRun() }
            else if flags == .command, e.charactersIgnoringModifiers?.lowercased() == "r", run.error != nil { run.regenerate() }
            return true
        }
        switch Int(e.keyCode) {
        case 36, 76:
            let followUp = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !followUp.isEmpty {
                if run.isDone {
                    run.refine(followUp)
                    query = ""
                }
            } else if run.isDone {
                deliver(run.output, .replace)
            }
            return true
        case 53:
            endRun()
            return true
        default:
            guard flags == .command else { return false }
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "r":
                run.regenerate()
                return true
            case "c":
                // Text highlighted in the field or the result copies as usual.
                if let editor = e.window?.firstResponder as? NSTextView, editor.selectedRange().length > 0 { return false }
                if run.isDone { deliver(run.output, .copy) }
                return true
            default:
                return false
            }
        }
    }
}

