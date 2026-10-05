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

/// A saved prompt that rewrites the selected text (or a clip) with ChatGPT.
struct Transformer: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var prompt: String
    var action: TransformAction = .preview
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

    var isGlobal: Bool { apps.isEmpty && sites.isEmpty }

    /// True in one of its apps or on one of its sites; for a global one, anywhere it isn't excluded.
    func applies(app: String?, url: URL?) -> Bool {
        if isGlobal { return !isExcluded(app: app, url: url) }
        if let app, apps.contains(app) { return true }
        if let url, sites.contains(where: { SiteMatcher.matches($0, url) }) { return true }
        return false
    }

    func isExcluded(app: String?, url: URL?) -> Bool {
        guard isGlobal else { return false }
        if let app, excludedApps.contains(app) { return true }
        if let url, excludedSites.contains(where: { SiteMatcher.matches($0, url) }) { return true }
        return false
    }

    /// Whether both could show in the same place, so one hotkey can't serve both.
    func overlaps(_ other: Transformer) -> Bool {
        if isGlobal && other.isGlobal { return true }
        if isGlobal { return !other.isInside(exclusionsOf: self) }
        if other.isGlobal { return !isInside(exclusionsOf: other) }
        if !Set(apps).isDisjoint(with: other.apps) { return true }
        // Sites only match in browsers: a browser in one and a site in the other can meet.
        if apps.contains(where: BrowserContext.isBrowser) && !other.sites.isEmpty { return true }
        if other.apps.contains(where: BrowserContext.isBrowser) && !sites.isEmpty { return true }
        return sites.contains { a in other.sites.contains { b in Self.sitesOverlap(a, b) } }
    }

    /// True when every place this scoped transformer shows is one `global` is hidden from.
    private func isInside(exclusionsOf global: Transformer) -> Bool {
        apps.allSatisfy(global.excludedApps.contains)
            && sites.allSatisfy { site in global.excludedSites.contains { Self.covers($0, site) } }
    }

    /// Whether every URL `site` matches is also matched by `pattern`.
    private static func covers(_ pattern: String, _ site: String) -> Bool {
        var p = site.lowercased()
        if p.hasPrefix("*.") { p.removeFirst(2) }
        return URL(string: "https://" + p).map { SiteMatcher.matches(pattern, $0) } ?? false
    }

    /// `github.com` and `gist.github.com/me` overlap; `github.com` and `gitlab.com` don't.
    static func sitesOverlap(_ a: String, _ b: String) -> Bool {
        func probe(_ pattern: String) -> URL? {
            var p = pattern.lowercased()
            if p.hasPrefix("*.") { p.removeFirst(2) }
            return URL(string: "https://" + p)
        }
        if let u = probe(b), SiteMatcher.matches(a, u) { return true }
        if let u = probe(a), SiteMatcher.matches(b, u) { return true }
        return false
    }

    init(name: String, prompt: String, action: TransformAction = .preview) {
        self.name = name
        self.prompt = prompt
        self.action = action
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        action = (try? c.decodeIfPresent(TransformAction.self, forKey: .action)) ?? .preview
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
        Transformer(name: "Convert to Markdown", prompt: "Convert this into clean Markdown:\n\n{selection}", action: .replace),
    ]
}

/// The text a transformer works on, and where it came from.
struct TransformInput: Equatable {
    enum Source { case selection, clipboard }
    var text: String
    var source: Source
}

// MARK: - Prompts

enum TransformPrompt {
    static let variables = ["{selection}", "{app}", "{url}", "{clipboard}"]

    /// Keeps the reply pasteable: no "Here's a polished version:", no fences the input didn't have.
    static let instructions = """
        You transform text for the user. Reply with only the transformed text: no preamble, no explanation, \
        no quotation marks around it, and no Markdown or code fences unless the user asked for them or the \
        input already had them. Keep the input's language, line breaks, and formatting unless asked to change them. \
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

/// One transformer run: streams the reply, then takes follow-ups that refine it.
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
        messages = [ChatMessage(role: .user, content: TransformPrompt.render(transformer.prompt, text: input.text, context: context))]
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
    /// only reaches them when `keystroke` is true (no panel in the way).
    static func copiedText(from app: NSRunningApplication?, keystroke: Bool, completion: @escaping (String?) -> Void) {
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
                let lineCopy = isLineCopy(pb, text: text, app: app.bundleIdentifier)
                saved.restore(pb)
                completion(!lineCopy && text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil)
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
    static func read(from app: NSRunningApplication?, completion: @escaping (String?) -> Void) {
        switch accessibilitySelection(in: app) {
        case .text(let text): completion(text)
        case .none: completion(nil)
        case .unsupported: copiedText(from: app, keystroke: true, completion: completion)
        }
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
