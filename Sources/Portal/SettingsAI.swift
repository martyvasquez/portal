import SwiftUI

// MARK: - Transformers

struct TransformersPage: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var router: SettingsRouter
    @ObservedObject private var ai = AIService.shared
    @State private var editing: TransformerDraft?
    @State private var selected: UUID?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Transformers", subtitle: "Prompts that rewrite the text you've selected, with ChatGPT.") {
                Button {
                    editing = TransformerDraft(transformer: Transformer(name: "", prompt: ""), isNew: true)
                } label: {
                    Label("New Transformer", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n")
            }

            if !ai.isSignedIn {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles").foregroundStyle(.indigo).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sign in with ChatGPT to use transformers")
                        Text("They run on your ChatGPT Plus or Pro plan. No API key needed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Set Up…") { router.page = .chatgpt }
                }
                .padding(12)
                .card()
                .padding(.horizontal, 28)
                .padding(.bottom, 6)
            }

            if settings.values.transformers.isEmpty {
                ContentUnavailableView {
                    Label("No Transformers", systemImage: "wand.and.sparkles")
                } description: {
                    Text("Add a prompt like “Polish and refine {selection}”.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(settings.values.transformers) { t in
                        TransformerCard(transformer: t, modelName: t.model.map(ai.displayName(for:)), isSelected: selected == t.id,
                                        edit: { edit(t) }, duplicate: { duplicate(t) }, delete: { delete(t) })
                            .onTapGesture(count: 2) { edit(t) }
                            .onTapGesture { selected = t.id }
                            .listRowInsets(EdgeInsets(top: 3, leading: 20, bottom: 3, trailing: 20))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .onMove { settings.values.transformers.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onDeleteCommand {
                    if let id = selected, let t = settings.values.transformers.first(where: { $0.id == id }) { delete(t) }
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
                Text("Select text in any app, then open the launcher: transformers come first, in this order (drag to reorder). Type **transform** and a prompt for a one-off, or press **⌘T** on a clip in clipboard history.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editing) { draft in
            TransformerEditor(draft: draft, settings: settings) { editing = nil }
        }
    }

    private func edit(_ t: Transformer) {
        selected = t.id
        editing = TransformerDraft(transformer: t, isNew: false)
    }

    private func duplicate(_ t: Transformer) {
        var copy = t
        copy.id = UUID()
        copy.name += " Copy"
        copy.hotKey = nil
        if let i = settings.values.transformers.firstIndex(where: { $0.id == t.id }) {
            settings.values.transformers.insert(copy, at: i + 1)
        }
    }

    private func delete(_ t: Transformer) {
        withAnimation(Motion.standard) { settings.values.transformers.removeAll { $0.id == t.id } }
    }
}

private struct TransformerDraft: Identifiable {
    var transformer: Transformer
    let isNew: Bool
    var id: UUID { transformer.id }
}

private struct TransformerCard: View {
    let transformer: Transformer
    let modelName: String?
    let isSelected: Bool
    let edit: () -> Void
    let duplicate: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.sparkles").foregroundStyle(.purple).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(transformer.name.isEmpty ? "Untitled" : transformer.name).lineLimit(1)
                Text(LauncherModel.oneLine(transformer.prompt))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let modelName { Pill(text: modelName) }
            Pill(text: transformer.action.title)
            if let hotKey = transformer.hotKey { KeyCap(text: hotKey.display) }
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

private struct TransformerEditor: View {
    @State private var transformer: Transformer
    let isNew: Bool
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var ai = AIService.shared
    let dismiss: () -> Void

    init(draft: TransformerDraft, settings: SettingsStore, dismiss: @escaping () -> Void) {
        _transformer = State(initialValue: draft.transformer)
        isNew = draft.isNew
        self.settings = settings
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.sparkles").font(.title2).foregroundStyle(.purple)
                TextField("Name", text: $transformer.name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt").foregroundStyle(.secondary)
                TextEditor(text: $transformer.prompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 110, maxHeight: 200)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 6) {
                    Text("Insert").font(.caption).foregroundStyle(.tertiary)
                    ForEach(TransformPrompt.variables, id: \.self) { variable in
                        Button(variable) { insert(variable) }
                            .buttonStyle(.plain)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            .help(Self.help[variable] ?? "")
                    }
                }
                Text("**{selection}** is the highlighted text; if the prompt doesn't use it, the text goes at the end.")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow {
                    Text("When done").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 5) {
                        Picker("", selection: $transformer.action) {
                            ForEach(TransformAction.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Text(actionHelp).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                GridRow {
                    Text("Hotkey").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        HotKeyRecorder(combo: $transformer.hotKey, placeholder: "Record Hotkey")
                        if let clash = hotKeyClash {
                            Label("Already used by \(clash).", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Text("Runs on the selection from anywhere, no launcher needed.")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                GridRow {
                    Text("Model").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Picker("", selection: $transformer.model) {
                            Text("Default (\(ai.displayName(for: ai.modelID(for: nil))))").tag(String?.none)
                            Divider()
                            if let chosen = transformer.model, !ai.models.contains(where: { $0.id == chosen }) {
                                Text(ai.displayName(for: chosen)).tag(Optional(chosen))
                            }
                            ForEach(ai.models) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Picker("", selection: $transformer.effort) {
                            Text("Default Thinking").tag(String?.none)
                            Divider()
                            ForEach(ai.effortChoices(for: ai.modelID(for: transformer)), id: \.self) {
                                Text($0.capitalized).tag(Optional($0))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        settings.values.transformers.removeAll { $0.id == transformer.id }
                        dismiss()
                    }
                    .tint(.red)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Transformer" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(transformer.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 540)
        .tint(Theme.accent)
        .task { if ai.isSignedIn && ai.models.isEmpty { await ai.loadModels() } }
    }

    private static let help = [
        "{selection}": "The highlighted text, or the clip",
        "{app}": "The app you're in, like Mail",
        "{url}": "The page your browser is on",
        "{clipboard}": "What's on the clipboard",
    ]

    private var actionHelp: String {
        switch transformer.action {
        case .preview: "Shows the result first. Return replaces the selection; you can also ask for changes."
        case .replace: "Pastes the result over the selection as soon as it's ready."
        case .copy: "Puts the result on the clipboard, for things like lists you'll paste elsewhere."
        }
    }

    private var hotKeyClash: String? {
        transformer.hotKey.flatMap { HotKeyClash.owner(of: $0, in: settings.values, excluding: transformer.id) }
    }

    private func insert(_ variable: String) {
        if !transformer.prompt.isEmpty && !transformer.prompt.hasSuffix(" ") && !transformer.prompt.hasSuffix("\n") {
            transformer.prompt += " "
        }
        transformer.prompt += variable
    }

    private func save() {
        var saved = transformer
        saved.name = saved.name.trimmingCharacters(in: .whitespaces)
        if saved.name.isEmpty { saved.name = String(LauncherModel.oneLine(saved.prompt).prefix(40)) }
        if let i = settings.values.transformers.firstIndex(where: { $0.id == saved.id }) {
            settings.values.transformers[i] = saved
        } else {
            settings.values.transformers.append(saved)
        }
        dismiss()
    }
}

// MARK: - ChatGPT

struct ChatGPTPage: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var ai = AIService.shared

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "ChatGPT", subtitle: "The account and model transformers run on.")
            Form {
                if ai.isSignedIn {
                    signedIn
                } else {
                    signedOut
                }

                Section {
                    Picker("Transform with Prompt", selection: $settings.values.customPromptAction) {
                        ForEach(TransformAction.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("What a one-off prompt does with its result. Type **transform** and your prompt in the launcher with text selected.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var signedIn: some View {
        Section {
            LabeledContent("Account", value: ai.account?.email ?? ai.account?.name ?? "ChatGPT")
            if ai.planUsageGranted {
                LabeledContent("Billing", value: "Your ChatGPT plan")
            } else {
                LabeledContent("Billing") {
                    HStack {
                        Text("Plan use is off").foregroundStyle(.secondary)
                        Button("Turn On") { ai.signIn(askConsent: true) }
                    }
                }
            }
            HStack {
                Link("Manage Usage", destination: ChatGPTAuth.manageUsageURL)
                Spacer()
                Button("Sign Out") { ai.signOut() }
            }
        } footer: {
            Text("Your sign-in stays in this Mac's Keychain. Sign in on each Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Picker("Model", selection: $settings.values.aiModel) {
                Text("Default (\(ai.displayName(for: ai.defaultModelID)))").tag(String?.none)
                Divider()
                if ai.models.isEmpty, let chosen = settings.values.aiModel { Text(ai.displayName(for: chosen)).tag(Optional(chosen)) }
                ForEach(ai.models) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("Thinking", selection: $settings.values.aiEffort) {
                Text("Default (Low)").tag(String?.none)
                Divider()
                ForEach(ai.effortChoices(for: ai.modelID(for: nil)), id: \.self) { Text($0.capitalized).tag(Optional($0)) }
            }
        } footer: {
            if let error = ai.modelsError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Low thinking keeps rewrites quick. Each transformer can pick its own model.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { if ai.models.isEmpty { await ai.loadModels() } }
        if let error = ai.signInError {
            Section { Text(error).foregroundStyle(.secondary) }
        }
    }

    private var signedOut: some View {
        Section {
            VStack(spacing: 12) {
                Text("Use Your ChatGPT Plan").font(.title3.weight(.semibold))
                Text("Transformers run on your ChatGPT Plus or Pro plan. No API key needed.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if ai.isSigningIn {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in your browser…").foregroundStyle(.secondary)
                        Button("Cancel") { ai.cancelSignIn() }
                    }
                    .frame(height: 36)
                } else {
                    ContinueWithChatGPTButton { ai.signIn() }
                }
                if let error = ai.signInError {
                    Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                if ai.account != nil && !ai.isSigningIn {
                    Button("Use a Different Account") { ai.useDifferentAccount() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }
}

/// OpenAI's sign-in button style: black, rounded, "Continue with ChatGPT".
private struct ContinueWithChatGPTButton: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text("Continue with ChatGPT")
                .font(.body.weight(.medium))
                .padding(.horizontal, 22)
                .frame(height: 36)
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .background(colorScheme == .dark ? Color.white : Color.black, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
