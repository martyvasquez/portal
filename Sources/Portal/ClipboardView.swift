import SwiftUI
import Combine

enum ClipFilter: String, CaseIterable, Identifiable {
    case all = "All", thisMac = "This Mac", otherMacs = "Other Macs", secrets = "Secrets", pinned = "Pinned"
    var id: String { rawValue }
}

@MainActor
final class ClipboardModel: ObservableObject {
    @Published var query = "" { didSet { selection = 0 } }
    @Published var filter: ClipFilter = .all { didSet { selection = 0 } }
    @Published var selection = 0
    @Published var revealed: Set<UUID> = []

    let store: ClipStore
    let settings: SettingsStore
    var onDismiss: () -> Void = {}
    /// Opens the launcher on the clip's text, to pick a transformer.
    var onTransform: (String) -> Void = { _ in }
    private var cancellables = Set<AnyCancellable>()

    init(store: ClipStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        // Re-render when the store changes.
        store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    var visible: [Clip] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let me = settings.machineID
        return store.clips.filter { clip in
            switch filter {
            case .all: break
            case .thisMac: guard clip.payload.machineID == me else { return false }
            case .otherMacs: guard clip.payload.machineID != me else { return false }
            case .secrets: guard clip.isSecret else { return false }
            case .pinned: guard clip.pinned else { return false }
            }
            return q.isEmpty || clip.searchable(q)
        }
    }

    var selected: Clip? {
        let v = visible
        return v.indices.contains(selection) ? v[selection] : nil
    }

    func prepareForShow() {
        query = ""
        filter = .all
        selection = 0
        revealed = []
    }

    func move(_ delta: Int) {
        let count = visible.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    /// ⇧⌘↑ / ⇧⌘↓: previous or next sidebar filter. Stops at the ends, like Managed's sidebar.
    func stepFilter(_ delta: Int) {
        let all = ClipFilter.allCases
        guard let i = all.firstIndex(of: filter), all.indices.contains(i + delta) else { return }
        filter = all[i + delta]
    }

    func cycleFilter(_ delta: Int) {
        let all = ClipFilter.allCases
        let i = all.firstIndex(of: filter) ?? 0
        filter = all[(i + delta + all.count) % all.count]
    }

    /// Copies the clip; if `paste`, also pastes it into the app that was frontmost.
    func use(_ clip: Clip, paste: Bool, original: Bool = false) {
        Paster.write(clip, original: original)
        onDismiss()
        guard paste else { return }
        if Permissions.accessibilityGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Paster.sendPaste() }
        } else {
            Permissions.requestAccessibility()
        }
    }

    func handleKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == [.command, .shift], e.keyCode == 125 || e.keyCode == 126 {
            stepFilter(e.keyCode == 125 ? 1 : -1)
            return true
        }
        switch Int(e.keyCode) {
        case 125: move(1); return true
        case 126: move(-1); return true
        case 48: cycleFilter(flags.contains(.shift) ? -1 : 1); return true   // ⇥
        case 36, 76:
            guard let clip = selected else { return true }
            let pasteDefault = settings.values.pasteOnSelect
            use(clip, paste: flags.contains(.command) ? !pasteDefault : pasteDefault,
                original: flags.contains(.shift) && clip.payload.originalText != nil)
            return true
        case 53:
            if query.isEmpty { onDismiss() } else { query = "" }
            return true
        case 51 where flags == .command:                                      // ⌘⌫
            if let clip = selected {
                store.delete(clip)
                selection = min(selection, max(0, visible.count - 1))
            }
            return true
        default: break
        }
        if flags == .command {
            switch chars {
            case "p": if let clip = selected { store.togglePin(clip) }; return true
            case "t":
                if let clip = selected, let text = clip.transformableText {
                    onDismiss()
                    DispatchQueue.main.async { self.onTransform(text) }
                } else {
                    NSSound.beep()
                }
                return true
            case "r":
                if let clip = selected, clip.isSecret {
                    if revealed.contains(clip.id) { revealed.remove(clip.id) } else { revealed.insert(clip.id) }
                }
                return true
            default:
                if let n = Int(chars), (1...9).contains(n), n <= visible.count {
                    use(visible[n - 1], paste: settings.values.pasteOnSelect)
                    return true
                }
            }
        }
        if flags == .control && (chars == "n" || chars == "j") { move(1); return true }
        if flags == .control && (chars == "p" || chars == "k") { move(-1); return true }
        return false
    }
}

extension ClipFilter {
    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .thisMac: "laptopcomputer"
        case .otherMacs: "macbook.and.iphone"
        case .secrets: "key.fill"
        case .pinned: "pin.fill"
        }
    }

    var tint: Color {
        switch self {
        case .all: Theme.accent
        case .thisMac: .teal
        case .otherMacs: .green
        case .secrets: Theme.secret
        case .pinned: .orange
        }
    }
}

struct ClipboardView: View {
    @ObservedObject var model: ClipboardModel

    var body: some View {
        let clips = model.visible
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                    SearchField(text: $model.query, placeholder: "Search \(model.filter.rawValue.lowercased())", fontSize: 17)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                Divider()
                if clips.isEmpty {
                    ContentUnavailableView(model.store.clips.isEmpty ? "Nothing Copied Yet" : "No Clips",
                                           systemImage: model.filter.symbol,
                                           description: Text(emptyDescription))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        list(clips).frame(width: 300)
                        Divider()
                        if let clip = model.selected {
                            ClipPreview(clip: clip, revealed: model.revealed.contains(clip.id))
                        } else {
                            Spacer()
                        }
                    }
                }
                Divider()
                footer
            }
        }
    }

    private var emptyDescription: String {
        let days = model.settings.values.clipboardRetentionDays
        return "Keeping \(days) days of history" + (model.store.mode == .sync ? ", synced through iCloud Drive." : " on this Mac.")
    }

    private var sidebar: some View {
        let me = model.settings.machineID
        let all = model.store.clips
        func count(_ f: ClipFilter) -> Int {
            switch f {
            case .all: all.count
            case .thisMac: all.filter { $0.payload.machineID == me }.count
            case .otherMacs: all.filter { $0.payload.machineID != me }.count
            case .secrets: all.filter(\.isSecret).count
            case .pinned: all.filter(\.pinned).count
            }
        }
        return VStack(alignment: .leading, spacing: 1) {
            SectionTitle(text: "Clipboard").padding(.top, 14)
            ForEach(ClipFilter.allCases) { f in
                SidebarRow(title: f.rawValue, symbol: f.symbol, tint: f.tint,
                           isSelected: model.filter == f, badge: count(f))
                    .onTapGesture { model.filter = f }
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: model.store.mode == .sync ? "icloud" : "internaldrive")
                Text(model.store.mode == .sync ? "Synced" : "This Mac only")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 10)
        .frame(width: 180)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    private func list(_ clips: [Clip]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                        ClipRow(clip: clip, index: index, selected: index == model.selection,
                                isMine: clip.payload.machineID == model.settings.machineID)
                            .id(clip.id)
                            .onTapGesture(count: 2) { model.use(clip, paste: model.settings.values.pasteOnSelect) }
                            .onTapGesture { model.selection = index }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selection) { _, new in
                if clips.indices.contains(new) { proxy.scrollTo(clips[new].id) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if model.store.undecryptable > 0 {
                Label("\(model.store.undecryptable) can't be decrypted", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .help("Clips from a Mac using a different passphrase, or files still syncing.")
            }
            Spacer()
            let pasteFirst = model.settings.values.pasteOnSelect
            KeyHint(keys: "↩", label: pasteFirst ? "Paste" : "Copy")
            KeyHint(keys: "⌘↩", label: pasteFirst ? "Copy" : "Paste")
            KeyHint(keys: "⌘P", label: model.selected?.pinned == true ? "Unpin" : "Pin")
            if model.selected?.isSecret == true { KeyHint(keys: "⌘R", label: "Reveal") }
            if model.selected?.payload.originalText != nil { KeyHint(keys: "⇧↩", label: "Original") }
            if model.selected?.transformableText != nil { KeyHint(keys: "⌘T", label: "Transform") }
            KeyHint(keys: "⌘⌫", label: "Delete")
            KeyHint(keys: "⇧⌘↑↓", label: "Filter")
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }
}

private struct ClipRow: View {
    let clip: Clip
    let index: Int
    let selected: Bool
    let isMine: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon.frame(width: 18, height: 18).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.title)
                    .font(clip.isSecret ? .body.monospaced() : .body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(clip.created, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                    if !isMine { Text("· \(clip.payload.machineName)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if clip.pinned {
                Image(systemName: "pin.fill").imageScale(.small).foregroundStyle(.orange)
            }
            if index < 9 {
                Text("⌘\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background { if selected { SelectionFill() } }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        if clip.isSecret {
            Image(systemName: "key.fill").foregroundStyle(Theme.secret)
        } else if let id = clip.payload.sourceBundleID, let img = IconCache.appIcon(bundleID: id) {
            Image(nsImage: img).resizable()
        } else {
            Image(systemName: Self.symbol(clip.payload.kind)).foregroundStyle(.secondary)
        }
    }

    static func symbol(_ kind: ClipKind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .url: "link"
        case .image: "photo"
        case .files: "doc"
        }
    }
}

private struct ClipPreview: View {
    let clip: Clip
    let revealed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                meta("Copied", clip.created.formatted(date: .abbreviated, time: .shortened))
                meta("From", [clip.payload.sourceApp, clip.payload.machineName].compactMap { $0 }.joined(separator: " on "))
                if let text = clip.payload.text { meta("Length", "\(text.count.formatted()) characters") }
                if clip.payload.originalText != nil {
                    HStack(spacing: 5) {
                        Image(systemName: "wand.and.sparkles").foregroundStyle(Theme.accent)
                        Text("Cleaned up from \(clip.payload.sourceApp ?? "the terminal") — ⇧↩ pastes the original")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if clip.isSecret {
                    HStack(spacing: 5) {
                        Image(systemName: "key.fill").foregroundStyle(Theme.secret)
                        Text(revealed ? "Secret — ⌘R to hide" : "Secret — ⌘R to reveal")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder private var content: some View {
        switch clip.payload.kind {
        case .text, .url:
            ScrollView {
                Text(clip.isSecret && !revealed ? SecretDetector.mask(clip.payload.text ?? "") : (clip.payload.text ?? ""))
                    .font(clip.isSecret ? .callout.monospaced() : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        case .image:
            if let data = clip.payload.image, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .files:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(clip.payload.files ?? [], id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(nsImage: IconCache.icon(forPath: path)).resizable().frame(width: 20, height: 20)
                            Text(Paths.abbreviate(path)).font(.callout).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func meta(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
            Text(value).lineLimit(2)
        }
        .font(.caption)
    }
}

extension Clip {
    /// Text a transformer can work on. Never secrets: those don't leave the Mac.
    var transformableText: String? {
        guard !isSecret, payload.kind == .text || payload.kind == .url,
              let text = payload.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
