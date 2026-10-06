import SwiftUI
import Combine

@MainActor
final class ClipboardModel: ObservableObject {
    @Published var query = "" { didSet { selection = 0 } }
    @Published var selection = 0
    @Published var revealed: Set<UUID> = []

    let store: ClipStore
    let settings: SettingsStore
    var onDismiss: () -> Void = {}
    /// Opens the launcher on the clip, to pick an AI transformer.
    var onTransform: (TransformInput) -> Void = { _ in }
    private var cancellables = Set<AnyCancellable>()

    init(store: ClipStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        // Re-render when the store changes.
        store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    var visible: [Clip] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? store.clips : store.clips.filter { $0.searchable(q) }
    }

    var selected: Clip? {
        let v = visible
        return v.indices.contains(selection) ? v[selection] : nil
    }

    func prepareForShow() {
        query = ""
        selection = 0
        revealed = []
    }

    func move(_ delta: Int) {
        let count = visible.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    /// Copies the clip as it was copied, or in `format`; if `paste`, also pastes it into the app that was frontmost.
    func use(_ clip: Clip, paste: Bool, format: ClipFormat? = nil, original: Bool = false) {
        Paster.write(clip, format: format, original: original)
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
        let pasteDefault = settings.values.pasteOnSelect
        switch Int(e.keyCode) {
        case 125: move(1); return true
        case 126: move(-1); return true
        case 36, 76:
            guard let clip = selected else { return true }
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
            case "f", "m", "p":
                // A format that doesn't apply (Markdown of plain text) pastes the clip as it is.
                if let clip = selected {
                    let format: ClipFormat = chars == "f" ? .formatted : chars == "m" ? .markdown : .plain
                    use(clip, paste: pasteDefault, format: clip.payload.offers(format) ? format : nil)
                }
                return true
            case "a":
                if let clip = selected, let input = clip.transformInput {
                    onDismiss()
                    DispatchQueue.main.async { self.onTransform(input) }
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
                    use(visible[n - 1], paste: pasteDefault)
                    return true
                }
            }
        }
        if flags == .control && (chars == "n" || chars == "j") { move(1); return true }
        if flags == .control && (chars == "p" || chars == "k") { move(-1); return true }
        return false
    }
}

struct ClipboardView: View {
    @ObservedObject var model: ClipboardModel

    var body: some View {
        let clips = model.visible
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                SearchField(text: $model.query, placeholder: "Search clipboard history", fontSize: 17)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Divider()
            if clips.isEmpty {
                ContentUnavailableView(model.store.clips.isEmpty ? "Nothing Copied Yet" : "No Clips",
                                       systemImage: "doc.on.clipboard",
                                       description: Text(emptyDescription))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    list(clips).frame(width: 340)
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

    private var emptyDescription: String {
        let days = model.settings.values.clipboardRetentionDays
        return "Keeping \(days) days of history" + (model.store.mode == .sync ? ", synced through iCloud Drive." : " on this Mac.")
    }

    private func list(_ clips: [Clip]) -> some View {
        let me = model.settings.machineID
        // Which Mac a clip came from only matters once there's more than one.
        let manyMacs = model.store.clips.contains { $0.payload.machineID != me }
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                        let isMine = clip.payload.machineID == me
                        ClipRow(clip: clip, index: index, selected: index == model.selection,
                                machine: manyMacs ? (isMine ? "This Mac" : clip.payload.machineName) : nil)
                            .id(clip.id)
                            .onTapGesture(count: 2) { model.use(clip, paste: model.settings.values.pasteOnSelect) }
                            .onTapGesture { model.selection = index }
                    }
                }
                .padding(8)
            }
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
            } else {
                Label(model.store.mode == .sync ? "Synced" : "This Mac only",
                      systemImage: model.store.mode == .sync ? "icloud" : "internaldrive")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            let pasteFirst = model.settings.values.pasteOnSelect
            let clip = model.selected?.payload
            KeyHint(keys: "↩", label: pasteFirst ? "Paste" : "Copy")
            KeyHint(keys: "⌘↩", label: pasteFirst ? "Copy" : "Paste")
            // Only the formats that would change something.
            if clip?.offers(.formatted) == true { KeyHint(keys: "⌘F", label: "Formatted") }
            if clip?.offers(.markdown) == true { KeyHint(keys: "⌘M", label: "Markdown") }
            if clip?.offers(.plain) == true { KeyHint(keys: "⌘P", label: "Plain Text") }
            if clip?.originalText != nil { KeyHint(keys: "⇧↩", label: "Original") }
            if clip?.isSecret == true { KeyHint(keys: "⌘R", label: "Reveal") }
            if model.selected?.transformInput != nil { KeyHint(keys: "⌘A", label: "AI Transform") }
            KeyHint(keys: "⌘⌫", label: "Delete")
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }
}

private struct ClipRow: View {
    let clip: Clip
    let index: Int
    let selected: Bool
    /// "This Mac" or the other Mac's name, when clips come from more than one.
    let machine: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon.frame(width: 18, height: 18).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.title)
                    .font(clip.isSecret ? .body.monospaced() : .body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    ClipAge(date: clip.created)
                    if let machine { Text("· \(machine)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
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
                if let format = clip.payload.formatName { meta("Format", format) }
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
    /// The clip as a transformer's input, formatting included. Never secrets: those don't leave the Mac.
    var transformInput: TransformInput? {
        guard !isSecret, payload.kind == .text || payload.kind == .url,
              let text = payload.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TransformInput(text: text, source: .clipboard, rich: payload.rich, formattingRead: true)
    }
}

/// How long ago a clip was copied: "Just now" for the first minute, then "5 min. ago", kept current while shown.
struct ClipAge: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: date, by: 60)) { context in
            Text(Self.label(date, now: context.date))
        }
    }

    static func label(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "Just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }
}
