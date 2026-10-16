import SwiftUI
import Speech

struct DictationPage: View {
    @ObservedObject var settings: SettingsStore
    @State private var write = ""
    @State private var hear = ""
    @State private var languages: [Locale] = []
    @FocusState private var focus: Field?

    private enum Field { case write, hear }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Dictation", subtitle: "Talk, watch the words appear, and insert them where you were typing.")
            Form {
                Section {
                    LabeledContent("Shortcut") {
                        HotKeyRecorder(combo: $settings.values.dictationHotKey, placeholder: "Record Shortcut")
                    }
                    if let clash = clash {
                        Label("\(settings.values.dictationHotKey?.display ?? "") is also set for \(clash).",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Picker("Language", selection: $settings.values.dictationLocale) {
                        Text("Same as macOS (\(Self.name(Locale.current)))").tag(String?.none)
                        if !languages.isEmpty { Divider() }
                        ForEach(languages, id: \.identifier) { Text(Self.name($0)).tag(String?.some($0.identifier)) }
                    }
                } footer: {
                    Text("You can also type “dictate” in the launcher, or pin it there. Hold Space to pause, ↩ inserts, ⌘↩ copies, esc cancels. Speech is recognized on this Mac and never leaves it.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    addRow
                    ForEach($settings.values.dictionary) { $entry in
                        DictionaryRow(entry: $entry) {
                            withAnimation(Motion.standard) { settings.values.dictionary.removeAll { $0.id == entry.id } }
                        }
                    }
                    .onMove { settings.values.dictionary.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Dictionary")
                } footer: {
                    Text("A word on its own, like a name or product, helps dictation expect it. With “When it hears”, every match is replaced, ignoring case and run-together words. Dictation is told about the first \(DictionaryCorrector.hintLimit) words; replacements always apply.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .task {
            let all = await SpeechTranscriber.supportedLocales
            languages = all.sorted { Self.name($0) < Self.name($1) }
        }
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Word or phrase", text: $write, prompt: Text("Word or phrase, like Claude Code"))
                    .focused($focus, equals: .write)
                    .onSubmit(add)
                Image(systemName: "arrow.left").foregroundStyle(.tertiary)
                TextField("When it hears", text: $hear, prompt: Text("When it hears (optional)"))
                    .focused($focus, equals: .hear)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(write.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            if let warning = draft.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var draft: DictionaryEntry {
        let w = write.trimmingCharacters(in: .whitespaces), h = hear.trimmingCharacters(in: .whitespaces)
        return h.isEmpty ? .term(w) : .correction(hear: h, write: w)
    }

    private func add() {
        let entry = draft
        guard !entry.write.isEmpty else { return }
        withAnimation(Motion.standard) { settings.values.dictionary.insert(entry, at: 0) }
        write = ""
        hear = ""
        focus = .write
    }

    private var clash: String? {
        guard let combo = settings.values.dictationHotKey else { return nil }
        let v = settings.values
        func same(_ other: KeyCombo?) -> Bool { other?.keyCode == combo.keyCode && other?.modifiers == combo.modifiers }
        if same(v.launcherHotKey) { return "the launcher" }
        if same(v.clipboardHotKey) { return "clipboard history" }
        if let q = v.quicklinks.first(where: { same($0.hotKey) }) { return "“\(q.name)”" }
        if let t = v.transformers.first(where: { same($0.hotKey) }) { return "“\(t.name)”" }
        return SystemHotKeys.conflict(for: combo)
    }

    static func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

private struct DictionaryRow: View {
    @Binding var entry: DictionaryEntry
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $entry.isEnabled).labelsHidden().toggleStyle(.checkbox)
            Image(systemName: entry.kind == .term ? "character.book.closed" : "arrow.2.squarepath")
                .foregroundStyle(entry.kind == .term ? Theme.accent : .purple)
                .frame(width: 18)
            if entry.kind == .correction {
                Text(entry.hear).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
            }
            Text(entry.write)
            if let warning = entry.warning {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(warning)
            }
            Spacer()
            Button(action: onDelete) { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help("Remove")
        }
        .opacity(entry.isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { Button("Remove", role: .destructive, action: onDelete) }
    }
}
