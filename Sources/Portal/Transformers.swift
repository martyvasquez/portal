import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine

/// What a transformer does with its result.
enum TransformAction: String, Codable, CaseIterable, Identifiable {
    case preview, replace, copy
    var id: String { rawValue }

    var title: String {
        switch self {
        case .preview: "Preview"
        case .replace: "Replace"
        case .copy: "Copy to Clipboard"
        }
    }
}

/// What a transformer's result pastes as.
enum TransformOutput: String, Codable, CaseIterable, Identifiable {
    case original, formatted, markdown, plain
    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Original"
        case .formatted: "Formatted"
        case .markdown: "Markdown"
        case .plain: "Plain Text"
        }
    }

    var help: String {
        switch self {
        case .original: "Pastes the way the selection was: formatted if it was formatted, plain text if it was plain."
        case .formatted: "Bold, lists, and links paste as formatting in Gmail, Notes, and Docs; other apps get plain text."
        case .markdown: "Pastes the Markdown itself, for GitHub, Obsidian, Reddit, and READMEs."
        case .plain: "Pastes clean text with no formatting or Markdown, for messages and forms."
        }
    }
}

/// An AI transformer: a saved prompt that rewrites the selected text (or a clip) with ChatGPT,
/// then pastes the result in its output format.
struct Transformer: Codable, Equatable, Identifiable, Scoped {
    var id = UUID()
    var name: String
    var prompt: String
    var action: TransformAction = .preview
    var output: TransformOutput = .original
    var hotKey: KeyCombo?
    /// nil = the model and thinking level from Settings → ChatGPT.
    var model: String?
    var effort: String?
    /// Where it shows: in any of these apps (bundle IDs) or on any of these sites. Neither = everywhere.
    var apps: [String] = []
    var sites: [String] = []
    /// For a global transformer: apps and sites where it stays hidden. Ignored once it's scoped.
    var excludedApps: [String] = []
    var excludedSites: [String] = []

    init(name: String, prompt: String, action: TransformAction = .preview, output: TransformOutput = .original) {
        self.name = name
        self.prompt = prompt
        self.action = action
        self.output = output
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        action = (try? c.decodeIfPresent(TransformAction.self, forKey: .action)) ?? .preview
        output = (try? c.decodeIfPresent(TransformOutput.self, forKey: .output)) ?? .original
        hotKey = try c.decodeIfPresent(KeyCombo.self, forKey: .hotKey)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        apps = (try? c.decodeIfPresent([String].self, forKey: .apps)) ?? []
        sites = (try? c.decodeIfPresent([String].self, forKey: .sites)) ?? []
        excludedApps = (try? c.decodeIfPresent([String].self, forKey: .excludedApps)) ?? []
        excludedSites = (try? c.decodeIfPresent([String].self, forKey: .excludedSites)) ?? []
    }

    static let starters: [Transformer] = [
        Transformer(name: "Polish", prompt: "Polish and refine {selection}\n\nFix grammar and awkward phrasing. Keep my voice, meaning, and formatting."),
        Transformer(name: "Less Formal", prompt: "Make this email less formal and friendlier, without getting sloppy:\n\n{selection}"),
        Transformer(name: "Extract Company Names", prompt: "List the company names mentioned in this text, one per line, with no other text:\n\n{selection}"),
        Transformer(name: "Clean Up JSON", prompt: "Fix and pretty-print this JSON with 2-space indentation. Keep every key and value:\n\n{selection}", action: .replace),
    ]
}

/// The text a transformer works on, and where it came from.
struct TransformInput: Equatable {
    enum Source { case selection, clipboard }
    var text: String
    var source: Source
    /// Its formatting, when the app copied it with some.
    var rich: RichContent?
    /// `rich` has been read. Accessibility reads only plain text, so a selection read that way
    /// gets its formatting from the app's Copy when a transformer runs.
    var formattingRead = false
}

// MARK: - Prompts

enum TransformPrompt {
    static let variables = ["{selection}", "{app}", "{url}", "{clipboard}"]

    /// Keeps the reply pasteable: no "Here's a polished version:", no fences the input didn't have.
    static let instructions = """
        You transform text for the user. Reply with only the transformed text: no preamble, no explanation, \
        no quotation marks around it, and no Markdown or code fences unless the user asked for them or the \
        input already had them. Keep the input's language, line breaks, and formatting unless asked to change them. \
        The input's formatting (headings, bold, lists, links, tables) is written in Markdown, and Markdown in your \
        reply pastes as that formatting. So keep the input's Markdown, and when asked to format text for an email, \
        a document, or anywhere else that shows formatting, use Markdown for it. \
        When the user follows up, reply with the full revised text again.
        """

    struct Context {
        var app: String?
        var url: URL?
        var clipboard: String?
    }

    /// Fills in the variables. A prompt without `{selection}` gets the text appended.
    static func render(_ prompt: String, text: String, context: Context) -> String {
        var p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.contains("{selection}") { p += "\n\n{selection}" }
        // Text last, so a selection that happens to contain "{app}" isn't touched.
        return p.replacingOccurrences(of: "{app}", with: context.app ?? "")
            .replacingOccurrences(of: "{url}", with: context.url?.absoluteString ?? "")
            .replacingOccurrences(of: "{clipboard}", with: context.clipboard ?? "")
            .replacingOccurrences(of: "{selection}", with: text)
    }
}

// MARK: - Running one

/// One transformer run: streams the reply, then takes follow-ups that refine it. A formatted
/// selection goes to ChatGPT as Markdown, so its formatting can come back.
@MainActor
final class TransformRun: ObservableObject {
    let transformer: Transformer
    let input: TransformInput
    @Published private(set) var output = ""
    @Published private(set) var isRunning = false
    @Published private(set) var error: String?
    /// Follow-ups sent so far, shown above the result.
    @Published private(set) var followUps: [String] = []
    let modelName: String
    /// What the result pastes as. Original becomes formatted for a formatted selection, else the text as written.
    let pasteFormat: TransformOutput

    /// Called once the first reply finishes, for transformers that replace or copy without a preview.
    var onFirstReply: ((String) -> Void)?

    private let ai: AIService
    private var messages: [ChatMessage]
    private var task: Task<Void, Never>?

    init(transformer: Transformer, input: TransformInput, context: TransformPrompt.Context, ai: AIService) {
        self.transformer = transformer
        self.input = input
        self.ai = ai
        modelName = ai.displayName(for: ai.modelID(for: transformer))
        pasteFormat = transformer.output != .original ? transformer.output : input.rich != nil ? .formatted : .markdown
        let text = input.rich.flatMap(RichText.markdown(from:)) ?? input.text
        messages = [ChatMessage(role: .user, content: TransformPrompt.render(transformer.prompt, text: text, context: context))]
    }

    var isDone: Bool { !isRunning && error == nil && !output.isEmpty }

    func start() { send() }

    /// Asks for changes to the current result.
    func refine(_ followUp: String) {
        guard isDone else { return }
        messages.append(ChatMessage(role: .assistant, content: output))
        messages.append(ChatMessage(role: .user, content: followUp))
        followUps.append(followUp)
        send()
    }

    /// Asks again for the last turn.
    func regenerate() {
        guard !isRunning else { return }
        send()
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func send() {
        guard let client = ai.client() else {
            error = "Sign in with ChatGPT in Settings to use transformers."
            return
        }
        let firstReply = followUps.isEmpty
        let model = ai.modelID(for: transformer)
        let effort = ai.effort(for: transformer)
        let messages = messages
        output = ""
        error = nil
        isRunning = true
        task?.cancel()
        task = Task { [weak self] in
            do {
                let text = try await client.respond(model: model, effort: effort, instructions: TransformPrompt.instructions,
                                                    messages: messages) { partial in
                    Task { @MainActor in
                        guard let self, self.isRunning else { return }
                        self.output = partial
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.output = text
                self.isRunning = false
                if firstReply { self.onFirstReply?(text) }
            } catch is CancellationError {
            } catch let urlError as URLError where urlError.code == .cancelled {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isRunning = false
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Reading the selection

/// Saves everything on the pasteboard so it can be put back after a temporary write.
@MainActor
struct PasteboardSnapshot {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ pb: NSPasteboard = .general) {
        items = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    /// Puts the saved items back, marked so clipboard history ignores them.
    func restore(_ pb: NSPasteboard = .general) {
        pb.clearContents()
        let restored = items.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            item.setData(Data(), forType: .portalMarker)
            return item
        }
        if !restored.isEmpty { pb.writeObjects(restored) }
    }
}

@MainActor
enum SelectionReader {
    /// Apps whose ⌘C copies something other than selected text (Finder copies files).
    private static let noCopyFallback: Set<String> = ["com.apple.finder", "com.martyvasquez.portal"]

    enum Selection: Equatable {
        case text(String)
        /// The app reported its selection and nothing is selected.
        case none
        /// The app doesn't report its selection to Accessibility.
        case unsupported
    }

    /// The selected text in `app`'s focused element, through Accessibility. Instant; works in most native apps.
    static func accessibilitySelection(in app: NSRunningApplication?) -> Selection {
        guard Permissions.accessibilityGranted, let pid = app?.processIdentifier else { return .unsupported }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unsupported }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String else { return .unsupported }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .text(text)
    }

    /// For apps that don't share their selection with Accessibility (Chrome, terminals, Electron):
    /// copies through the app's own Edit ▸ Copy menu item, reads what landed on the clipboard, then
    /// puts the clipboard back. Pressing the menu item works while Portal's panel has the keyboard;
    /// a disabled Copy item means nothing is selected. Apps without one get a ⌘C keystroke, which
    /// only reaches them when `keystroke` is true (no panel in the way). The copy's formatting comes too.
    static func copiedSelection(from app: NSRunningApplication?, keystroke: Bool, completion: @escaping (TransformInput?) -> Void) {
        guard Permissions.accessibilityGranted, let app, !noCopyFallback.contains(app.bundleIdentifier ?? "") else {
            completion(nil)
            return
        }
        let pb = NSPasteboard.general
        let saved = PasteboardSnapshot(pb)
        let before = pb.changeCount
        ClipboardMonitor.ignoreChanges(for: 1.5)
        switch pressCopyMenuItem(of: app.processIdentifier) {
        case .pressed: break
        case .disabled: return completion(nil)
        case .missing:
            guard keystroke else { return completion(nil) }
            sendCopyKeystroke()
        }

        var waited = 0.0
        func poll() {
            if pb.changeCount != before {
                let text = pb.string(forType: .string)
                let rich = RichContent.read(from: pb)
                let lineCopy = isLineCopy(pb, text: text, app: app.bundleIdentifier)
                saved.restore(pb)
                guard !lineCopy, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return completion(nil) }
                completion(TransformInput(text: text, source: .selection, rich: rich, formattingRead: true))
            } else if waited >= 0.5 {
                completion(nil)   // the app didn't copy anything
            } else {
                waited += 0.02
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() }
    }

    /// Code editors whose Copy, with nothing highlighted, copies the line the cursor is on.
    private static let lineCopyEditors: Set<String> = [
        "com.sublimetext.4", "com.sublimetext.3", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.vscodium", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.google.android.studio",
    ]

    /// True when the copy was the cursor's line rather than a highlight, so it isn't offered as a selection.
    /// VS Code and its forks say so on the clipboard; other editors copy one whole line ending in a newline.
    static func isLineCopy(_ pb: NSPasteboard, text: String?, app bundleID: String?) -> Bool {
        if let data = pb.data(forType: NSPasteboard.PasteboardType("vscode-editor-data")),
           let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let empty = info["isFromEmptySelection"] as? Bool {
            return empty
        }
        guard let bundleID, lineCopyEditors.contains(bundleID) || bundleID.hasPrefix("com.jetbrains."),
              let text else { return false }
        return isWholeLine(text)
    }

    /// One line plus its newline: what an editor copies with nothing highlighted.
    static func isWholeLine(_ text: String) -> Bool {
        guard let last = text.last, last.isNewline else { return false }
        return !text.dropLast().contains(where: \.isNewline)
    }

    private enum CopyItem { case pressed, disabled, missing }

    /// Finds the menu item whose shortcut is ⌘C (Edit ▸ Copy, in any language) and presses it.
    private static func pressCopyMenuItem(of pid: pid_t) -> CopyItem {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var out: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success ? out : nil
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        guard let bar = value(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return .missing }
        for top in children(bar as! AXUIElement) {
            for menu in children(top) {
                for item in children(menu) {
                    guard (value(item, kAXMenuItemCmdCharAttribute) as? String)?.uppercased() == "C",
                          (value(item, kAXMenuItemCmdModifiersAttribute) as? Int) == 0 else { continue }
                    guard (value(item, kAXEnabledAttribute) as? Bool) != false else { return .disabled }
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success ? .pressed : .missing
                }
            }
        }
        return .missing
    }

    /// Accessibility first, then ⌘C. For hotkeys, where no panel is in the way.
    static func read(from app: NSRunningApplication?, completion: @escaping (TransformInput?) -> Void) {
        switch accessibilitySelection(in: app) {
        case .text(let text):
            withFormatting(TransformInput(text: text, source: .selection), from: app, keystroke: true, completion: completion)
        case .none: completion(nil)
        case .unsupported: copiedSelection(from: app, keystroke: true, completion: completion)
        }
    }

    /// Adds the formatting Accessibility leaves out, from the app's own Copy, when that copies
    /// the same text. Without it (nothing copied, or something else was), the input stays plain.
    static func withFormatting(_ input: TransformInput, from app: NSRunningApplication?, keystroke: Bool,
                               completion: @escaping (TransformInput) -> Void) {
        guard input.source == .selection, !input.formattingRead else { return completion(input) }
        copiedSelection(from: app, keystroke: keystroke) { copied in
            var input = input
            input.formattingRead = true
            if let copied, sameText(copied.text, input.text) { input.rich = copied.rich }
            completion(input)
        }
    }

    /// Equal apart from whitespace, which apps copy differently from what they report.
    static func sameText(_ a: String, _ b: String) -> Bool {
        func squeeze(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return squeeze(a) == squeeze(b)
    }

    private static func sendCopyKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let c = CGKeyCode(kVK_ANSI_C)
        let down = CGEvent(keyboardEventSource: source, virtualKey: c, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: c, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
