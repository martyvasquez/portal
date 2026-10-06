import AppKit
import SwiftUI
import Combine

@main
enum PortalMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let settings = SettingsStore.shared
    private lazy var keys = KeyManager(settings: settings)
    private lazy var clipStore = ClipStore(settings: settings, keys: keys)
    private lazy var monitor = ClipboardMonitor(store: clipStore, settings: settings)
    private lazy var launcher = LauncherModel(settings: settings)
    private lazy var clipModel = ClipboardModel(store: clipStore, settings: settings)
    private let router = SettingsRouter()

    private var launcherPanel: PanelController!
    private var clipboardPanel: PanelController!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var pauseItem: NSMenuItem!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings.load()
        keys.evaluate()
        clipStore.start()
        monitor.start()
        launcher.reindex()

        launcherPanel = PanelController(size: NSSize(width: 680, height: 440), rootView: AnyView(LauncherView(model: launcher)))
        launcherPanel.keyHandler = { [unowned self] in launcher.handleKey($0) }
        launcherPanel.onShow = { [unowned self] in launcher.prepareForShow() }
        launcherPanel.onHide = { [unowned self] in launcher.didHide() }
        launcher.onDismiss = { [unowned self] in launcherPanel.hide() }
        launcher.onCommand = { [unowned self] in run(command: $0) }

        clipboardPanel = PanelController(size: NSSize(width: 820, height: 500), rootView: AnyView(ClipboardView(model: clipModel)))
        clipboardPanel.keyHandler = { [unowned self] in clipModel.handleKey($0) }
        clipboardPanel.onShow = { [unowned self] in clipModel.prepareForShow() }
        clipModel.onDismiss = { [unowned self] in clipboardPanel.hide() }
        clipModel.onTransform = { [unowned self] input in
            launcher.queue(input)
            launcherPanel.show()
        }

        AppUpdater.shared.isBusy = { [unowned self] in
            launcherPanel.isVisible || clipboardPanel.isVisible || settingsWindow?.isVisible == true
        }
        AppUpdater.shared.start()

        buildMainMenu()
        buildStatusItem()

        settings.$values
            .map { HotKeyConfig(launcher: $0.launcherHotKey, clipboard: $0.clipboardHotKey,
                                finder: $0.finderSelectionHotKey, links: $0.quicklinks, transformers: $0.transformers) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.registerHotKeys() }
            .store(in: &cancellables)

        settings.$values
            .map(\.showMenuBarIcon)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in self?.statusItem.isVisible = show }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateFinderHotKey()
                self?.updateScopedHotKeys()
            }
            .store(in: &cancellables)

        // Scriptable entry point, also handy for testing:
        //   swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.martyvasquez.portal.show"), object: "launcher")'
        DistributedNotificationCenter.default().addObserver(forName: .init("com.martyvasquez.portal.show"), object: nil, queue: .main) { [weak self] note in
            let target = note.object as? String
            MainActor.assumeIsolated {
                switch target {
                case "launcher": self?.toggleLauncher()
                case "clipboard": self?.toggleClipboard()
                case "new": self?.run(command: "new")
                case let t? where t.hasPrefix("transform:"):
                    // Previews the named transformer on the clipboard's text ("transform:Polish"), or copies its
                    // result ("transform:Polish:copy"). Never pastes.
                    guard let self, let text = NSPasteboard.general.string(forType: .string) else { return }
                    let copy = t.hasSuffix(":copy")
                    let name = t.dropFirst("transform:".count).dropLast(copy ? ":copy".count : 0)
                    var transformer = self.settings.values.transformers.first { $0.name == name }
                    transformer?.action = copy ? .copy : .preview
                    let input = TransformInput(text: text, source: .clipboard, rich: RichContent.read(from: .general))
                    self.launcher.queue(input, transformer: transformer)
                    self.launcherPanel.show()
                case let t? where t.hasPrefix("page:"):
                    if let page = SettingsPage.allCases.first(where: { "page:\($0)" == t }) { self?.router.page = page }
                    self?.showSettings()
                default: self?.showSettings()
                }
            }
        }

        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            showSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    private struct HotKeyConfig: Equatable {
        let launcher: KeyCombo, clipboard: KeyCombo, finder: KeyCombo?, links: [Quicklink], transformers: [Transformer]
    }

    private var scopedHotKeyIDs: [UInt32] = []

    private func registerHotKeys() {
        HotKeyCenter.shared.register(id: 1, combo: settings.values.launcherHotKey) { [weak self] in self?.toggleLauncher() }
        HotKeyCenter.shared.register(id: 2, combo: settings.values.clipboardHotKey) { [weak self] in self?.toggleClipboard() }

        updateFinderHotKey()
        updateScopedHotKeys()
    }

    /// What a quicklink or transformer hotkey runs.
    private enum HotKeyTarget { case quicklink(UUID), transformer(UUID) }

    /// Quicklink and transformer hotkeys, held only while one of their owners could apply in the
    /// front app, so a scoped key keeps its normal meaning everywhere else. Owners in separate
    /// scopes can share a key: it's registered once and runs whichever one applies.
    private func updateScopedHotKeys() {
        scopedHotKeyIDs.forEach { HotKeyCenter.shared.unregister($0) }
        scopedHotKeyIDs = []
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var groups: [(combo: KeyCombo, targets: [HotKeyTarget], live: Bool)] = []
        func add(_ combo: KeyCombo?, _ target: HotKeyTarget, _ scope: any Scoped) {
            guard let combo else { return }
            let live = scope.couldApply(frontApp: front)
            if let i = groups.firstIndex(where: { $0.combo.keyCode == combo.keyCode && $0.combo.modifiers == combo.modifiers }) {
                groups[i].targets.append(target)
                groups[i].live = groups[i].live || live
            } else {
                groups.append((combo, [target], live))
            }
        }
        for q in settings.values.quicklinks { add(q.hotKey, .quicklink(q.id), q) }
        for t in settings.values.transformers { add(t.hotKey, .transformer(t.id), t) }
        for (i, group) in groups.enumerated() where group.live {
            let id = UInt32(1000 + i)
            scopedHotKeyIDs.append(id)
            HotKeyCenter.shared.register(id: id, combo: group.combo) { [weak self] in self?.runHotKey(group.targets) }
        }
    }

    /// Of the owners sharing a key, a scoped one that applies here wins over a global one.
    private func runHotKey(_ targets: [HotKeyTarget]) {
        let v = settings.values
        let candidates: [(target: HotKeyTarget, scope: any Scoped)] = targets.compactMap { target in
            switch target {
            case .quicklink(let id): v.quicklinks.first { $0.id == id }.map { (target, $0) }
            case .transformer(let id): v.transformers.first { $0.id == id }.map { (target, $0) }
            }
        }
        let front = NSWorkspace.shared.frontmostApplication
        let needsURL = candidates.contains { !$0.scope.sites.isEmpty || !$0.scope.excludedSites.isEmpty }
        let url = needsURL ? BrowserContext.currentURL(frontApp: front?.bundleIdentifier) : nil
        let applies = candidates.filter { $0.scope.applies(app: front?.bundleIdentifier, url: url) }
        guard let pick = applies.first(where: { !$0.scope.isGlobal }) ?? applies.first else { NSSound.beep(); return }
        switch pick.target {
        case .quicklink(let id): if let link = v.quicklinks.first(where: { $0.id == id }) { openFromHotKey(link) }
        case .transformer(let id): if let t = v.transformers.first(where: { $0.id == id }) { transform(t, front: front) }
        }
    }

    /// Runs a transformer on the selection without picking it in the launcher. The launcher
    /// opens to show it working (and the result, for Preview); Replace and Copy close it when done.
    private func transform(_ transformer: Transformer, front: NSRunningApplication?) {
        clipboardPanel.hide()
        launcherPanel.hide()
        guard AIService.shared.isSignedIn else {
            run(command: "chatgpt")
            return
        }
        SelectionReader.read(from: front) { [weak self] input in
            guard let self else { return }
            guard let input else { NSSound.beep(); return }   // nothing selected
            launcher.queue(input, transformer: transformer)
            launcherPanel.show()
        }
    }

    /// The Finder selection hotkey is only held while Finder is in front, so the same
    /// combo (e.g. ⇧⌘O) keeps its normal meaning in every other app.
    private func updateFinderHotKey() {
        if let combo = settings.values.finderSelectionHotKey, FinderSelection.finderIsFrontmost {
            HotKeyCenter.shared.register(id: 3, combo: combo) { [weak self] in self?.openFinderSelection() }
        } else {
            HotKeyCenter.shared.unregister(3)
        }
    }

    /// Hotkey version: open whatever's selected in Finder without the launcher.
    private func openFinderSelection() {
        let v = settings.values
        guard FinderSelection.finderIsFrontmost, let result = FinderSelection.current(excludedTypes: v.excludedFileTypes) else {
            NSSound.beep()
            return
        }
        // Each kind opens with its first (default) app.
        if let app = v.folderOpenWith.first { FinderSelection.open(result.folders, withAppAt: app) }
        if let app = v.fileOpenWith.first { FinderSelection.open(result.files, withAppAt: app) }
    }

    /// A {query} quicklink opens the launcher to ask for its text; others open immediately.
    private func openFromHotKey(_ link: Quicklink) {
        clipboardPanel.hide()
        if link.needsQuery {
            launcherPanel.show()
            launcher.beginArgument(link)
        } else {
            launcherPanel.hide()
            QuicklinkOpener.open(link)
        }
    }

    @objc func toggleLauncher() {
        clipboardPanel.hide()
        launcherPanel.toggle()
    }

    @objc func toggleClipboard() {
        launcherPanel.hide()
        clipboardPanel.toggle()
    }

    private func run(command: String) {
        switch command {
        case "clipboard": DispatchQueue.main.async { self.clipboardPanel.show() }
        case "settings": showSettings()
        case "chatgpt":
            router.page = .chatgpt
            showSettings()
            if !AIService.shared.isSignedIn { AIService.shared.signIn() }
        case "new":
            router.page = .quicklinks
            showSettings()
            router.editing = QuicklinkDraft(link: Quicklink(name: "", link: ""), isNew: true)
        case "update": AppUpdater.shared.checkForUpdates()
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, launcher: launcher, store: clipStore, keys: keys, router: router)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Portal"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.setContentSize(NSSize(width: 880, height: 620))
            window.setFrameAutosaveName("PortalSettings")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        // The launcher never activates Portal (so pastes land in the app you were in), and macOS
        // won't let an inactive menu bar app pull itself forward. So: become a regular app while
        // Settings is open (Dock icon, ⌘Tab), activate while the launcher still holds the
        // keypress, and order the window front regardless. Panels close last for the same reason.
        NSApp.setActivationPolicy(.regular)
        // The cooperative NSApp.activate() is refused when another app is active and hasn't yielded,
        // which is always the case coming from the launcher. The older call still forces it.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
        launcherPanel?.hide()
        clipboardPanel?.hide()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func checkForUpdates() {
        AppUpdater.shared.checkForUpdates()
    }

    @objc private func togglePause() {
        monitor.paused.toggle()
        pauseItem.state = monitor.paused ? .on : .off
        statusItem.button?.image = Self.menuBarIcon(paused: monitor.paused)
    }

    // MARK: Menus

    /// The app icon's pyramid as a monochrome menu bar template. Dimmed while recording is paused.
    static func menuBarIcon(paused: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let color = NSColor.black.withAlphaComponent(paused ? 0.35 : 1)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 9, y: 3.5))
            path.line(to: NSPoint(x: 16, y: 14.5))
            path.line(to: NSPoint(x: 2, y: 14.5))
            path.close()
            path.lineJoinStyle = .round
            path.lineWidth = 1.6   // stroking with round joins softens the corners
            color.setFill()
            color.setStroke()
            path.fill()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Portal"
        return image
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon(paused: false)

        let menu = NSMenu()
        menu.addItem(withTitle: "Open Launcher", action: #selector(toggleLauncher), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Clipboard History", action: #selector(toggleClipboard), keyEquivalent: "").target = self
        menu.addItem(.separator())
        pauseItem = menu.addItem(withTitle: "Pause Clipboard Recording", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        if AppUpdater.shared.canCheck {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Quit Portal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    /// Accessory apps still need an Edit menu for ⌘C/⌘V/⌘A in text fields.
    /// Deliberately no ⌘Q here, so a stray ⌘Q in the launcher can't quit Portal.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
