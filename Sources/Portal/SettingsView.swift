import SwiftUI
import UniformTypeIdentifiers

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", quicklinks = "Quicklinks", snippets = "Snippets", transformers = "Transformers"
    case openWith = "Open With", clipboard = "Clipboard", chatgpt = "ChatGPT", sync = "Sync"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .quicklinks: "link"
        case .openWith: "arrow.up.forward.app"
        case .snippets: "text.insert"
        case .transformers: "wand.and.sparkles"
        case .clipboard: "doc.on.clipboard"
        case .chatgpt: "sparkles"
        case .general: "gearshape"
        case .sync: "icloud"
        }
    }

    var tint: Color {
        switch self {
        case .quicklinks: Theme.accent
        case .openWith: .orange
        case .snippets: .pink
        case .transformers: .purple
        case .clipboard: .teal
        case .chatgpt: .indigo
        case .general: .gray
        case .sync: .green
        }
    }
}

/// Lets the launcher open Settings on a specific page or straight into a new quicklink.
@MainActor
final class SettingsRouter: ObservableObject {
    @Published var page: SettingsPage = .quicklinks
    @Published var editing: QuicklinkDraft?
}

struct QuicklinkDraft: Identifiable {
    var link: Quicklink
    let isNew: Bool
    var id: UUID { link.id }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var launcher: LauncherModel
    @ObservedObject var store: ClipStore
    @ObservedObject var keys: KeyManager
    @ObservedObject var router: SettingsRouter

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                switch router.page {
                case .quicklinks: QuicklinksPage(settings: settings, router: router)
                case .openWith: OpenWithPage(settings: settings)
                case .snippets: SnippetsPage(settings: settings)
                case .transformers: TransformersPage(settings: settings, router: router)
                case .chatgpt: ChatGPTPage(settings: settings)
                case .clipboard: ClipboardPage(settings: settings, store: store)
                case .general: GeneralPage(settings: settings, launcher: launcher)
                case .sync: SyncPage(settings: settings, store: store, keys: keys)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.content)
        }
        .ignoresSafeArea()
        .frame(minWidth: 780, minHeight: 540)
        .tint(Theme.accent)
        .sheet(item: $router.editing) { draft in
            QuicklinkEditor(draft: draft, settings: settings) { router.editing = nil }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(SettingsPage.allCases) { page in
                SidebarRow(title: page.rawValue, symbol: page.symbol, tint: page.tint,
                           isSelected: router.page == page,
                           badge: page == .quicklinks ? settings.values.quicklinks.count
                                : page == .snippets ? settings.values.snippets.count
                                : page == .transformers ? settings.values.transformers.count : 0)
                    .onTapGesture { router.page = page }
            }
            Spacer()
            Label(syncStatus, systemImage: store.mode == .sync ? "icloud" : "internaldrive")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .padding(.top, 52) // clear the traffic lights
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    private var syncStatus: String {
        guard settings.syncEnabled else { return "Sync off" }
        return store.mode == .sync ? "Synced with iCloud" : "Settings synced"
    }
}

/// Title block at the top of each page.
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 28)
        .padding(.top, 44)
        .padding(.bottom, 12)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Quicklinks

private struct QuicklinksPage: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var router: SettingsRouter
    @State private var selected: UUID?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Quicklinks", subtitle: "Folders and URLs, each opening in the app you choose.") {
                Button {
                    router.editing = QuicklinkDraft(link: Quicklink(name: "", link: ""), isNew: true)
                } label: {
                    Label("New Quicklink", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n")
            }

            if settings.values.quicklinks.isEmpty {
                ContentUnavailableView {
                    Label("No Quicklinks", systemImage: "link")
                } description: {
                    Text("Add a folder to open in Finder or Ghostty, or a URL to open in Chrome.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.key) { group in
                        HStack(spacing: 6) {
                            group.icon.resizable().interpolation(.high).frame(width: 14, height: 14)
                            Text(group.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4).padding(.top, 14).padding(.bottom, 2)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .moveDisabled(true)

                        ForEach(group.links) { link in
                            QuicklinkCard(link: link, isSelected: selected == link.id,
                                          edit: { edit(link) }, duplicate: { duplicate(link) }, delete: { delete(link) })
                                .onTapGesture(count: 2) { edit(link) }
                                .onTapGesture { selected = link.id }
                                .listRowInsets(EdgeInsets(top: 3, leading: 20, bottom: 3, trailing: 20))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                        .onMove { move(in: group, from: $0, to: $1) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onDeleteCommand {
                    if let id = selected, let link = settings.values.quicklinks.first(where: { $0.id == id }) { delete(link) }
                }

                HStack(spacing: 6) {
                    Image(systemName: "lightbulb").foregroundStyle(.yellow)
                    Text("Grouped by the app each opens in. Drag to reorder within a group. Put **{query}** in a link to type something when you open it, like `https://github.com/search?q={query}`.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Quicklinks grouped by the app they open in, alphabetically; within a group they keep
    /// their saved order (which is also the launcher's order).
    private var groups: [QuicklinkGroup] {
        var byKey: [String: QuicklinkGroup] = [:]
        for link in settings.values.quicklinks {
            // Group by the app that actually opens it, so "Default (Finder)" and an explicit
            // Finder land together (same for the default browser).
            let key = QuicklinkGroup.resolvedApp(link)
            byKey[key, default: QuicklinkGroup(appPath: key)].links.append(link)
        }
        return byKey.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Reorders within one group by swapping the group's links among the slots they already
    /// occupy in the full list, so other groups don't move.
    private func move(in group: QuicklinkGroup, from source: IndexSet, to destination: Int) {
        var reordered = group.links
        reordered.move(fromOffsets: source, toOffset: destination)
        let ids = Set(group.links.map(\.id))
        var next = reordered.makeIterator()
        settings.values.quicklinks = settings.values.quicklinks.map { ids.contains($0.id) ? next.next()! : $0 }
    }

    private func edit(_ link: Quicklink) {
        selected = link.id
        router.editing = QuicklinkDraft(link: link, isNew: false)
    }

    private func duplicate(_ link: Quicklink) {
        var copy = link
        copy.id = UUID()
        copy.name += " Copy"
        copy.hotKey = nil
        if let i = settings.values.quicklinks.firstIndex(where: { $0.id == link.id }) {
            settings.values.quicklinks.insert(copy, at: i + 1)
        }
    }

    private func delete(_ link: Quicklink) {
        withAnimation(Motion.standard) { settings.values.quicklinks.removeAll { $0.id == link.id } }
    }
}

@MainActor
private struct QuicklinkGroup {
    let key: String
    let title: String
    let icon: Image
    var links: [Quicklink] = []

    init(appPath: String) {
        key = appPath
        title = appPath.isEmpty ? "Default Browser" : SharedSettings.appName(appPath)
        icon = appPath.isEmpty ? Image(systemName: "globe") : Image(nsImage: IconCache.icon(forPath: appPath))
    }

    /// The app path that will open this link ("" if there's no default browser).
    static func resolvedApp(_ link: Quicklink) -> String { link.resolvedAppPath ?? "" }
}

private struct QuicklinkCard: View {
    let link: Quicklink
    let isSelected: Bool
    let edit: () -> Void
    let duplicate: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            QuicklinkIcon(link: link).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.name).lineLimit(1)
                HStack(spacing: 4) {
                    if link.isFolder && !link.needsQuery && !FileManager.default.fileExists(atPath: Paths.expand(link.link).path) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .help("This folder doesn't exist on this Mac.")
                    }
                    Text(link.link).lineLimit(1).truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if link.needsQuery { Pill(text: "Query") }
            Pill(text: link.appName)
            if let hotKey = link.hotKey { KeyCap(text: hotKey.display) }
            Menu {
                Button("Edit…", action: edit)
                Button("Duplicate", action: duplicate)
                Divider()
                Button("Delete", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering || isSelected ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .card(isSelected: isSelected)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Edit…", action: edit)
            Button("Duplicate", action: duplicate)
            Divider()
            Button("Delete", role: .destructive, action: delete)
        }
    }
}

/// Apps offered in "Open with"; only the installed ones are shown.
private enum OpenWithApps {
    static let candidates = [
        "/System/Library/CoreServices/Finder.app",
        "/Applications/Ghostty.app",
        "/Applications/Google Chrome.app",
        "/Applications/Safari.app",
        "/Applications/Arc.app",
        "/Applications/Firefox.app",
        "/Applications/Cursor.app",
        "/Applications/Visual Studio Code.app",
        "/Applications/Zed.app",
        "/System/Applications/Utilities/Terminal.app",
        "/Applications/iTerm.app",
    ]

    static var installed: [String] { candidates.filter { FileManager.default.fileExists(atPath: $0) } }

    static func name(_ path: String) -> String {
        let n = FileManager.default.displayName(atPath: path)
        return n.hasSuffix(".app") ? String(n.dropLast(4)) : n
    }
}

private struct QuicklinkEditor: View {
    @State private var link: Quicklink
    let isNew: Bool
    @ObservedObject var settings: SettingsStore
    let dismiss: () -> Void
    private static let other = "__other__"

    init(draft: QuicklinkDraft, settings: SettingsStore, dismiss: @escaping () -> Void) {
        _link = State(initialValue: draft.link)
        isNew = draft.isNew
        self.settings = settings
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                QuicklinkIcon(link: link).frame(width: 36, height: 36)
                TextField("Name", text: $link.name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow {
                    Text("Link").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            TextField("~/Development or https://…", text: $link.link)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.large)
                            Button { chooseFolder() } label: { Image(systemName: "folder") }
                                .controlSize(.large)
                                .help("Choose a folder")
                        }
                        Text("A folder or URL. Add {query} to type something each time you open it.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                GridRow {
                    Text("Open with").foregroundStyle(.secondary)
                    Picker("", selection: openWith) {
                        Text(link.isFolder ? "Default (Finder)" : "Default Browser").tag("")
                        Divider()
                        ForEach(appChoices, id: \.self) { path in
                            Label {
                                Text(OpenWithApps.name(path))
                            } icon: {
                                Image(nsImage: IconCache.menuIcon(forPath: path))
                            }
                            .tag(path)
                        }
                        Divider()
                        Text("Other App…").tag(Self.other)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Hotkey").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        HotKeyRecorder(combo: $link.hotKey, placeholder: "Record Hotkey")
                        if let clash = hotKeyClash {
                            Label("Already used by \(clash).", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Text("Opens this quicklink from anywhere, no launcher needed.")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        settings.values.quicklinks.removeAll { $0.id == link.id }
                        dismiss()
                    }
                    .tint(.red)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Quicklink" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(22)
        .frame(width: 500)
        .tint(Theme.accent)
    }

    private var isValid: Bool {
        !link.link.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var appChoices: [String] {
        var apps = OpenWithApps.installed
        if let custom = link.appPath, !apps.contains(custom) { apps.append(custom) }
        return apps
    }

    private var openWith: Binding<String> {
        Binding(
            get: { link.appPath ?? "" },
            set: { value in
                if value == Self.other { chooseApp() } else { link.appPath = value.isEmpty ? nil : value }
            })
    }

    private var hotKeyClash: String? {
        link.hotKey.flatMap { HotKeyClash.owner(of: $0, in: settings.values, excluding: link.id) }
    }

    private func save() {
        var saved = link
        saved.link = saved.link.trimmingCharacters(in: .whitespaces)
        if saved.isFolder { saved.link = Paths.abbreviate(Paths.expand(saved.link).path) }
        if saved.name.trimmingCharacters(in: .whitespaces).isEmpty { saved.name = defaultName(for: saved) }
        if let i = settings.values.quicklinks.firstIndex(where: { $0.id == saved.id }) {
            settings.values.quicklinks[i] = saved
        } else {
            settings.values.quicklinks.append(saved)
        }
        dismiss()
    }

    private func defaultName(for link: Quicklink) -> String {
        if link.isFolder { return Paths.expand(link.link).lastPathComponent }
        return URL(string: link.link)?.host() ?? link.link
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        link.link = Paths.abbreviate(url.path)
        if link.name.isEmpty { link.name = url.lastPathComponent }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { link.appPath = url.path }
    }
}

// MARK: - Snippets

private struct SnippetsPage: View {
    @ObservedObject var settings: SettingsStore
    @State private var editing: SnippetDraft?
    @State private var selected: UUID?

    /// Global first, then one group per site, then per app, alphabetically.
    private var groups: [(title: String, app: String?, snippets: [Snippet])] {
        let all = settings.values.snippets
        var result: [(String, String?, [Snippet])] = []
        let global = all.filter(\.isGlobal)
        if !global.isEmpty { result.append(("Everywhere", nil, global)) }
        for site in Set(all.flatMap(\.sites)).sorted() {
            result.append((site, nil, all.filter { $0.sites.contains(site) }))
        }
        let apps = Set(all.flatMap(\.apps)).sorted { Self.appName($0) < Self.appName($1) }
        for app in apps { result.append((Self.appName(app), app, all.filter { $0.apps.contains(app) })) }
        return result
    }

    static func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { SharedSettings.appName($0.path) } ?? bundleID
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Snippets", subtitle: "Text the launcher pastes into the app you're in.") {
                Button {
                    editing = SnippetDraft(snippet: Snippet(name: "", text: ""), isNew: true)
                } label: {
                    Label("New Snippet", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n")
            }

            if settings.values.snippets.isEmpty {
                ContentUnavailableView {
                    Label("No Snippets", systemImage: "text.insert")
                } description: {
                    Text("Add text you paste often, everywhere or only in certain apps.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.title) { group in
                        HStack(spacing: 6) {
                            if let app = group.app, let icon = IconCache.appIcon(bundleID: app) {
                                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                            } else if group.title == "Everywhere" {
                                Image(systemName: "square.grid.2x2").foregroundStyle(Theme.accent).imageScale(.small)
                            } else {
                                Image(systemName: "globe").foregroundStyle(.teal).imageScale(.small)
                            }
                            Text(group.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4).padding(.top, 14).padding(.bottom, 2)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)

                        ForEach(group.snippets.map { SnippetEntry(group: group.title, snippet: $0) }) { entry in
                            SnippetCard(snippet: entry.snippet, isSelected: selected == entry.snippet.id)
                                .onTapGesture(count: 2) { edit(entry.snippet) }
                                .onTapGesture { selected = entry.snippet.id }
                                .contextMenu {
                                    Button("Edit…") { edit(entry.snippet) }
                                    Divider()
                                    Button("Delete", role: .destructive) { delete(entry.snippet) }
                                }
                                .listRowInsets(EdgeInsets(top: 3, leading: 20, bottom: 3, trailing: 20))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onDeleteCommand {
                    if let id = selected, let s = settings.values.snippets.first(where: { $0.id == id }) { delete(s) }
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.blue)
                Text("Site snippets show when Chrome, Safari, Arc, Brave, or Edge is on a matching page. Folder snippets live in **\(PortalFile.name)** in each repo, so they travel with git; in the launcher, **Build Commands** creates one from the repo's scripts.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editing) { draft in
            SnippetEditor(draft: draft, settings: settings) { editing = nil }
        }
    }

    private func edit(_ s: Snippet) {
        selected = s.id
        editing = SnippetDraft(snippet: s, isNew: false)
    }

    private func delete(_ s: Snippet) {
        withAnimation(Motion.standard) { settings.values.snippets.removeAll { $0.id == s.id } }
    }
}

private struct SnippetEntry: Identifiable {
    let group: String
    let snippet: Snippet
    var id: String { "\(group)|\(snippet.id)" }   // a snippet can appear under several apps
}

private struct SnippetDraft: Identifiable {
    var snippet: Snippet
    let isNew: Bool
    var id: UUID { snippet.id }
}

private enum SnippetScope: Hashable { case everywhere, apps, sites }

private struct Chip: View {
    let label: String
    let icon: NSImage?
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
            Text(label)
            Button(action: remove) { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct SnippetCard: View {
    let snippet: Snippet
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.insert").foregroundStyle(.pink).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.title).lineLimit(1)
                if !snippet.name.isEmpty {
                    Text(snippet.text).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if snippet.apps.count > 1 { Pill(text: "\(snippet.apps.count) apps") }
            if snippet.sites.count > 1 { Pill(text: "\(snippet.sites.count) sites") }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .card(isSelected: isSelected)
        .contentShape(Rectangle())
    }
}

private struct SnippetEditor: View {
    @State private var snippet: Snippet
    let isNew: Bool
    @ObservedObject var settings: SettingsStore
    let dismiss: () -> Void

    init(draft: SnippetDraft, settings: SettingsStore, dismiss: @escaping () -> Void) {
        _snippet = State(initialValue: draft.snippet)
        _scope = State(initialValue: !draft.snippet.sites.isEmpty ? .sites : !draft.snippet.apps.isEmpty ? .apps : .everywhere)
        isNew = draft.isNew
        self.settings = settings
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Name (optional)", text: $snippet.name)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Text").foregroundStyle(.secondary)
                TextEditor(text: $snippet.text)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 90, maxHeight: 180)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 8) {
                Picker("Show in", selection: $scope) {
                    Text("Every App").tag(SnippetScope.everywhere)
                    Text("Only These Apps").tag(SnippetScope.apps)
                    Text("Only These Sites").tag(SnippetScope.sites)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                switch scope {
                case .everywhere:
                    EmptyView()
                case .apps:
                    FlowLayout(spacing: 6) {
                        ForEach(snippet.apps, id: \.self) { id in
                            Chip(label: SnippetsPage.appName(id), icon: IconCache.appIcon(bundleID: id)) {
                                snippet.apps.removeAll { $0 == id }
                            }
                        }
                        Button("Add App…", action: addApp)
                    }
                case .sites:
                    FlowLayout(spacing: 6) {
                        ForEach(snippet.sites, id: \.self) { site in
                            Chip(label: site, icon: nil) { snippet.sites.removeAll { $0 == site } }
                        }
                        TextField("github.com", text: $newSite)
                            .textFieldStyle(.plain)
                            .font(.callout)
                            .frame(width: 150)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .onSubmit(addSite)
                    }
                    Text("Press Return to add. `github.com` includes its subdomains; `*.atlassian.net` matches any; `github.com/martyvasquez` limits to that path.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        settings.values.snippets.removeAll { $0.id == snippet.id }
                        dismiss()
                    }
                    .tint(.red)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Snippet" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(snippet.text.isEmpty
                              || (scope == .apps && snippet.apps.isEmpty)
                              || (scope == .sites && snippet.sites.isEmpty && newSite.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(22)
        .frame(width: 520)
        .tint(Theme.accent)
    }

    @State private var scope: SnippetScope = .everywhere
    @State private var newSite = ""

    private func addSite() {
        var site = newSite.trimmingCharacters(in: .whitespaces).lowercased()
        if let scheme = site.range(of: "://") { site = String(site[scheme.upperBound...]) }
        while site.hasSuffix("/") { site.removeLast() }
        newSite = ""
        guard !site.isEmpty, !snippet.sites.contains(site) else { return }
        snippet.sites.append(site)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !snippet.apps.contains(id) { snippet.apps.append(id) }
        }
    }

    private func save() {
        if !newSite.isEmpty { addSite() }
        // One scope at a time: keep only the list for the chosen one.
        if scope != .apps { snippet.apps = [] }
        if scope != .sites { snippet.sites = [] }
        if let i = settings.values.snippets.firstIndex(where: { $0.id == snippet.id }) {
            settings.values.snippets[i] = snippet
        } else {
            settings.values.snippets.append(snippet)
        }
        dismiss()
    }
}

// MARK: - Open With

/// Apps for whatever's selected in Finder: one ordered list for folders, one for files.
private struct OpenWithPage: View {
    @ObservedObject var settings: SettingsStore
    @State private var newType = ""

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Open With",
                       subtitle: "With Finder in front, the launcher offers these apps for what you've selected.")
            List {
                AppListSection(title: "Folders", symbol: "folder.fill", tint: .blue,
                               apps: $settings.values.folderOpenWith,
                               empty: "Add an app to open selected folders with.")
                AppListSection(title: "Files", symbol: "doc.fill", tint: .secondary,
                               apps: $settings.values.fileOpenWith,
                               empty: "Add an app to open selected files with.")

                Section {
                    SectionHeader(title: "Treat as Folder", symbol: "nosign", tint: .red).plainRow()
                    VStack(alignment: .leading, spacing: 10) {
                        FlowLayout(spacing: 6) {
                            ForEach(settings.values.excludedFileTypes, id: \.self) { type in
                                TypeChip(type: type) {
                                    settings.values.excludedFileTypes.removeAll { $0 == type }
                                }
                            }
                            TextField("Add type", text: $newType)
                                .textFieldStyle(.plain)
                                .font(.callout.monospaced())
                                .frame(width: 90)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                .onSubmit(addType)
                        }
                        Text("Selected files of these types open their folder with the folder apps instead.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .card()
                    .listRowInsets(EdgeInsets(top: 3, leading: 20, bottom: 3, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }

                Section {
                    SectionHeader(title: "Hotkey", symbol: "command", tint: .purple).plainRow()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open selection with the default apps")
                            Text("Skips the launcher. Folders open with the first folder app, files with the first file app. Only active while Finder is in front, so other apps keep this shortcut.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        HotKeyRecorder(combo: $settings.values.finderSelectionHotKey, placeholder: "Record Hotkey")
                    }
                    .padding(12)
                    .card()
                    .listRowInsets(EdgeInsets(top: 3, leading: 20, bottom: 3, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func addType() {
        let type = newType.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        newType = ""
        guard !type.isEmpty, !settings.values.excludedFileTypes.contains(type) else { return }
        settings.values.excludedFileTypes.append(type)
    }
}

private struct AppEntry: Identifiable {
    let section: String
    let index: Int
    let path: String
    var id: String { "\(section)|\(path)" }
}

private extension View {
    /// A list row with no chrome, inset to line up with the cards.
    func plainRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .moveDisabled(true)
    }
}

private struct SectionHeader: View {
    let title: String
    let symbol: String
    let tint: Color
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).imageScale(.small)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }
}

/// Ordered, drag-to-reorder list of apps. The first one is the default (↩).
private struct AppListSection: View {
    let title: String
    let symbol: String
    let tint: Color
    @Binding var apps: [String]
    let empty: String

    var body: some View {
        Section {
            SectionHeader(title: title, symbol: symbol, tint: tint).plainRow()
            // Ids include the section: the same app can be in both lists.
            ForEach(apps.indices.map { AppEntry(section: title, index: $0, path: apps[$0]) }) { entry in
                AppRow(path: entry.path, isDefault: entry.index == 0,
                       missing: !FileManager.default.fileExists(atPath: entry.path)) {
                    apps.removeAll { $0 == entry.path }
                }
                .listRowInsets(EdgeInsets(top: 3, leading: 20, bottom: 3, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .onMove { apps.move(fromOffsets: $0, toOffset: $1) }

            Button(action: addApps) {
                Label(apps.isEmpty ? empty : "Add App…", systemImage: "plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !apps.contains(url.path) { apps.append(url.path) }
    }
}

private struct AppRow: View {
    let path: String
    let isDefault: Bool
    let missing: Bool
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.icon(forPath: path)).resizable().interpolation(.high).frame(width: 24, height: 24)
            Text(SharedSettings.appName(path))
            if missing {
                Label("Not installed on this Mac", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            if isDefault { Pill(text: "↩ Default") }
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0)
                .help("Remove")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .card()
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct TypeChip: View {
    let type: String
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Text(".\(type)").font(.callout.monospaced())
            Button(action: remove) { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Wraps its children onto new lines, left to right.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in rows.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, maxX, y + rowHeight)
    }
}

// MARK: - Hotkey recorder

struct HotKeyRecorder: View {
    @Binding var combo: KeyCombo?
    var defaultCombo: KeyCombo?
    var placeholder = "Record Shortcut"
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button { recording ? stop() : start() } label: {
                Text(recording ? "Type shortcut…" : (combo?.display ?? placeholder))
                    .font(combo == nil || recording ? .callout : .callout.monospaced())
                    .foregroundStyle(combo == nil || recording ? .secondary : .primary)
                    .frame(minWidth: 110)
            }
            if !recording, let current = combo {
                if let defaultCombo, current != defaultCombo {
                    Button { combo = defaultCombo } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .help("Reset to \(defaultCombo.display)")
                } else if defaultCombo == nil {
                    Button { combo = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                        .help("Remove hotkey")
                }
            }
        }
        .onDisappear { if recording { stop() } }
    }

    private func start() {
        recording = true
        HotKeyCenter.shared.pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.isEmpty || KeyCombo.isFunctionKey(event.keyCode) else {
                NSSound.beep()
                return nil
            }
            combo = KeyCombo(event: event)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        DispatchQueue.main.async { HotKeyCenter.shared.resume() }
    }
}

extension HotKeyRecorder {
    /// For shortcuts that always exist (launcher, clipboard): no clear button, only reset.
    init(required: Binding<KeyCombo>, defaultCombo: KeyCombo) {
        self.init(combo: Binding(get: { required.wrappedValue }, set: { if let v = $0 { required.wrappedValue = v } }),
                  defaultCombo: defaultCombo)
    }
}

// MARK: - General

private struct GeneralPage: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var launcher: LauncherModel
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var axGranted = Permissions.accessibilityGranted
    @State private var tick = 0
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "General", subtitle: "How you summon Portal, and what it needs from macOS.")
            Form {
                Section {
                    LabeledContent("Launcher") {
                        HotKeyRecorder(required: $settings.values.launcherHotKey, defaultCombo: .launcherDefault)
                    }
                    conflictWarning(for: settings.values.launcherHotKey, id: 1)
                    LabeledContent("Clipboard history") {
                        HotKeyRecorder(required: $settings.values.clipboardHotKey, defaultCombo: .clipboardDefault)
                    }
                    conflictWarning(for: settings.values.clipboardHotKey, id: 2)
                }

                Section {
                    Toggle("Show apps in the launcher", isOn: $settings.values.includeApps)
                } footer: {
                    Text("\(launcher.appCount) apps found in /Applications.").font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Show Portal in the menu bar", isOn: $settings.values.showMenuBarIcon)
                    Toggle("Open Portal at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, on in
                            do { try LoginItem.set(on); loginError = nil }
                            catch { loginError = error.localizedDescription; launchAtLogin = LoginItem.isEnabled }
                        }
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                } footer: {
                    if !settings.values.showMenuBarIcon {
                        Text("With the icon hidden, open Settings by typing “settings” in the launcher, or by opening Portal again from Finder or Spotlight.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    LabeledContent("Accessibility") {
                        if axGranted {
                            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Allow…") {
                                Permissions.requestAccessibility()
                                Permissions.openAccessibilitySettings()
                            }
                        }
                    }
                    LabeledContent("Paste from other apps") {
                        Button("Privacy Settings…") { Permissions.openPrivacySettings() }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("Accessibility lets Portal paste into the app you were using. If macOS asks whether Portal may paste from other apps, choose Always Allow.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onReceive(timer) { _ in
            axGranted = Permissions.accessibilityGranted
            tick += 1
        }
    }

    @ViewBuilder
    private func conflictWarning(for combo: KeyCombo, id: UInt32) -> some View {
        let _ = tick // re-check so the warning clears once fixed in System Settings
        if let owner = SystemHotKeys.conflict(for: combo) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(combo.display) is also set for \(owner). Turn that off so Portal gets it.")
                    Button("Open Keyboard Shortcuts…") { SystemHotKeys.openKeyboardShortcuts() }
                        .buttonStyle(.link)
                }
            }
            .font(.callout)
        } else if combo == .launcherDefault, !SystemHotKeys.runningLauncherApps().isEmpty {
            Label("\(SystemHotKeys.runningLauncherApps().joined(separator: " and ")) is running and may be holding \(combo.display). Quit it or change its hotkey.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
        } else if HotKeyCenter.shared.failed.contains(id) {
            Label("Another app already registered \(combo.display).", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
        }
    }
}

// MARK: - Clipboard

private struct ClipboardPage: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var store: ClipStore
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Clipboard", subtitle: "A rolling history of what you copy, shared between your Macs.")
            Form {
                Section("History") {
                    Stepper(value: $settings.values.clipboardRetentionDays, in: 1...60) {
                        LabeledContent("Keep clips for", value: days(settings.values.clipboardRetentionDays))
                    }
                    Stepper(value: $settings.values.maxClipsPerMac, in: 100...10_000, step: 100) {
                        LabeledContent("Most clips per Mac", value: settings.values.maxClipsPerMac.formatted())
                    }
                    Stepper(value: $settings.values.maxImageMB, in: 1...50) {
                        LabeledContent("Skip images over", value: "\(settings.values.maxImageMB) MB")
                    }
                }

                Section {
                    Toggle("Record secrets", isOn: $settings.values.recordSecrets)
                    Stepper(value: $settings.values.secretRetentionDays, in: 1...60) {
                        LabeledContent("Keep secrets for", value: days(settings.values.secretRetentionDays))
                    }
                    .disabled(!settings.values.recordSecrets)
                } header: {
                    Text("Secrets")
                } footer: {
                    Text("Copies from password managers, plus anything that looks like an API key, token, or private key. They're masked in the list and ⌘R reveals them.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Picker("Return", selection: $settings.values.pasteOnSelect) {
                        Text("Pastes into the current app").tag(true)
                        Text("Copies to the clipboard").tag(false)
                    }
                } header: {
                    Text("Pasting")
                } footer: {
                    Text("⌘Return does the other one. Pinned clips (⌘P) never expire.").font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Clean up text copied from terminals", isOn: $settings.values.cleanTerminalCopies)
                    Toggle("Rejoin lines the terminal wrapped", isOn: $settings.values.unwrapTerminalLines)
                        .disabled(!settings.values.cleanTerminalCopies)
                } header: {
                    Text("Terminal Copies")
                } footer: {
                    Text("For Ghostty, Terminal, iTerm, and similar: removes trailing spaces, shared indentation, box borders, and Claude Code's ⏺ marker, and rejoins wrapped sentences. Commands and code keep their line breaks. The cleaned text is what ⌘V pastes; ⇧↩ in clipboard history pastes the original.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Never record from") {
                    ForEach(settings.values.ignoredBundleIDs, id: \.self) { id in
                        HStack {
                            if let icon = IconCache.appIcon(bundleID: id) {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            }
                            Text(appName(id))
                            Spacer()
                            Button { settings.values.ignoredBundleIDs.removeAll { $0 == id } } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                    Button("Add App…", action: addIgnoredApp)
                }

                Section {
                    let mine = store.clips.filter { $0.payload.machineID == settings.machineID }.count
                    LabeledContent("Stored", value: "\(store.clips.count) clips, \(mine) from this Mac")
                    Button("Clear History from This Mac…", role: .destructive) { confirmClear = true }
                        .confirmationDialog("Delete every unpinned clip copied on this Mac?", isPresented: $confirmClear) {
                            Button("Delete", role: .destructive) { store.clearThisMac() }
                        }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private func days(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }

    private func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return OpenWithApps.name(url.path)
    }

    private func addIgnoredApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !settings.values.ignoredBundleIDs.contains(id) {
                settings.values.ignoredBundleIDs.append(id)
            }
        }
    }
}

// MARK: - Sync

private struct SyncPage: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var store: ClipStore
    @ObservedObject var keys: KeyManager
    @State private var pass1 = ""
    @State private var pass2 = ""
    @State private var error: String?
    @State private var busy = false
    @State private var confirmReset = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Sync", subtitle: "Quicklinks, settings, and clipboard history across your Macs.")
            Form {
                Section {
                    Toggle("Sync through iCloud Drive", isOn: $settings.syncEnabled)
                    if !Paths.iCloudDriveAvailable {
                        Label("iCloud Drive is off on this Mac. Turn it on in System Settings → Apple Account → iCloud, or choose another synced folder.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    LabeledContent("Folder") {
                        HStack {
                            Text(settings.syncFolderPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button("Change…", action: chooseFolder)
                            Button {
                                try? FileManager.default.createDirectory(at: settings.syncFolderURL, withIntermediateDirectories: true)
                                NSWorkspace.shared.open(settings.syncFolderURL)
                            } label: { Image(systemName: "arrow.up.forward.square") }
                                .buttonStyle(.borderless)
                                .help("Show in Finder")
                        }
                    }
                    .disabled(!settings.syncEnabled)
                } footer: {
                    Text("Use the same folder on each Mac. Each Mac writes only its own files, so they never overwrite each other.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if settings.syncEnabled {
                    encryptionSection
                    statusSection
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var encryptionSection: some View {
        Section {
            switch keys.state {
            case .ready:
                Label("Clipboard history is encrypted and syncing.", systemImage: "lock.fill")
                    .foregroundStyle(.green)
                HStack {
                    Button("Forget Passphrase on This Mac") { keys.forgetOnThisMac() }
                    Spacer()
                    Button("Reset Encryption…", role: .destructive) { confirmReset = true }
                }
            case .needsPassphrase(let existing):
                Text(existing
                     ? "Your other Mac already set a passphrase. Enter it to share clipboard history."
                     : "Choose a passphrase, then enter the same one on your other Mac. It stays in this Mac's Keychain and never goes to iCloud.")
                    .font(.callout)
                SecureField("Passphrase", text: $pass1)
                if !existing { SecureField("Confirm", text: $pass2) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    if existing {
                        Button("Forgot it?", role: .destructive) { confirmReset = true }.buttonStyle(.link)
                    }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button(existing ? "Unlock" : "Set Passphrase") { submit(existing: existing) }
                        .buttonStyle(.borderedProminent)
                        .disabled(pass1.isEmpty || busy)
                }
            case .disabled:
                EmptyView()
            }
        } header: {
            Text("Encryption")
        } footer: {
            Text("Clips are encrypted (AES-256) before they reach iCloud Drive. Until you set a passphrase, clipboard history stays on this Mac; quicklinks and settings still sync.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Reset sync encryption?", isPresented: $confirmReset) {
            Button("Delete Synced Clips and Reset", role: .destructive) { keys.resetSync() }
        } message: {
            Text("This deletes all synced clipboard history. Your other Macs will ask for the new passphrase.")
        }
    }

    @ViewBuilder private var statusSection: some View {
        Section("Macs") {
            let groups = Dictionary(grouping: store.clips, by: { $0.payload.machineID })
            LabeledContent(settings.machineName, value: "This Mac · \(groups[settings.machineID]?.count ?? 0) clips")
            ForEach(groups.keys.sorted().filter { $0 != settings.machineID }, id: \.self) { id in
                let clips = groups[id] ?? []
                LabeledContent(clips.first?.payload.machineName ?? "Other Mac", value: "\(clips.count) clips")
            }
            if store.undecryptable > 0 {
                Label("\(store.undecryptable) clips couldn't be decrypted. They may still be downloading, or came from a Mac using a different passphrase.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private func submit(existing: Bool) {
        error = nil
        if !existing && pass1 != pass2 {
            error = "Those don't match."
            return
        }
        busy = true
        let passphrase = pass1
        DispatchQueue.main.async { // let the spinner draw; key derivation is deliberately slow
            do {
                try keys.setPassphrase(passphrase)
                pass1 = ""
                pass2 = ""
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Paths.iCloudDrive
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { settings.syncFolderPath = Paths.abbreviate(url.path) }
    }
}

// MARK: - Hotkey clashes

enum HotKeyClash {
    /// Who else uses `combo`: Portal's own hotkeys, another quicklink or transformer, or macOS.
    static func owner(of combo: KeyCombo, in v: SharedSettings, excluding id: UUID) -> String? {
        func same(_ other: KeyCombo?) -> Bool { other?.keyCode == combo.keyCode && other?.modifiers == combo.modifiers }
        if same(v.launcherHotKey) { return "the launcher" }
        if same(v.clipboardHotKey) { return "clipboard history" }
        if let other = v.quicklinks.first(where: { $0.id != id && same($0.hotKey) }) { return "“\(other.name)”" }
        if let other = v.transformers.first(where: { $0.id != id && same($0.hotKey) }) { return "“\(other.name)”" }
        return SystemHotKeys.conflict(for: combo)
    }
}
