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
        launcher.onDismiss = { [unowned self] in launcherPanel.hide() }
        launcher.onCommand = { [unowned self] in run(command: $0) }

        clipboardPanel = PanelController(size: NSSize(width: 820, height: 500), rootView: AnyView(ClipboardView(model: clipModel)))
        clipboardPanel.keyHandler = { [unowned self] in clipModel.handleKey($0) }
        clipboardPanel.onShow = { [unowned self] in clipModel.prepareForShow() }
        clipModel.onDismiss = { [unowned self] in clipboardPanel.hide() }

        buildMainMenu()
        buildStatusItem()

        settings.$values
            .map { HotKeyConfig(launcher: $0.launcherHotKey, clipboard: $0.clipboardHotKey,
                                     finder: $0.finderSelectionHotKey, links: $0.quicklinks) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.registerHotKeys() }
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
        let launcher: KeyCombo, clipboard: KeyCombo, finder: KeyCombo?, links: [Quicklink]
    }

    private var linkHotKeyIDs: [UInt32] = []

    private func registerHotKeys() {
        HotKeyCenter.shared.register(id: 1, combo: settings.values.launcherHotKey) { [weak self] in self?.toggleLauncher() }
        HotKeyCenter.shared.register(id: 2, combo: settings.values.clipboardHotKey) { [weak self] in self?.toggleClipboard() }

        if let combo = settings.values.finderSelectionHotKey {
            HotKeyCenter.shared.register(id: 3, combo: combo) { [weak self] in self?.openFinderSelection() }
        } else {
            HotKeyCenter.shared.unregister(3)
        }

        linkHotKeyIDs.forEach { HotKeyCenter.shared.unregister($0) }
        linkHotKeyIDs = []
        for (i, link) in settings.values.quicklinks.enumerated() {
            guard let combo = link.hotKey else { continue }
            let id = UInt32(100 + i)
            linkHotKeyIDs.append(id)
            HotKeyCenter.shared.register(id: id, combo: combo) { [weak self] in self?.openFromHotKey(link) }
        }
    }

    /// Hotkey version: open whatever's selected in Finder without the launcher.
    private func openFinderSelection() {
        guard FinderSelection.finderIsFrontmost, let result = FinderSelection.current() else {
            NSSound.beep()
            return
        }
        FinderSelection.open(result.folders, withAppAt: settings.values.finderSelectionAppPath)
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
        case "new":
            router.page = .quicklinks
            showSettings()
            router.editing = QuicklinkDraft(link: Quicklink(name: "", link: ""), isNew: true)
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

    @objc private func togglePause() {
        monitor.paused.toggle()
        pauseItem.state = monitor.paused ? .on : .off
        statusItem.button?.image = Self.menuBarIcon(paused: monitor.paused)
    }

    // MARK: Menus

    /// The app icon's stacked bars as a monochrome menu bar template. Dimmed while recording is paused.
    static func menuBarIcon(paused: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.withAlphaComponent(paused ? 0.35 : 1).setFill()
            let bars: [(width: CGFloat, y: CGFloat, height: CGFloat)] = [
                (4, 3.5, 1.6), (8, 6.5, 2.2), (12, 10, 2.6), (16, 13.8, 3),
            ]
            for bar in bars {
                let rect = NSRect(x: (18 - bar.width) / 2, y: bar.y, width: bar.width, height: bar.height)
                NSBezierPath(roundedRect: rect, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
            }
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
