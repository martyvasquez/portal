import AppKit
import Carbon.HIToolbox
import ServiceManagement
import ApplicationServices

// MARK: - Global hotkeys (Carbon; no Accessibility permission needed)

final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var combos: [UInt32: KeyCombo] = [:]
    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private(set) var failed: Set<UInt32> = []
    private var installed = false
    private var paused = false
    private var retryTimer: Timer?

    func register(id: UInt32, combo: KeyCombo, handler: @escaping @MainActor () -> Void) {
        installHandlerIfNeeded()
        unregister(id)
        combos[id] = combo
        handlers[id] = handler
        if !paused { activate(id) }
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        combos[id] = nil
        failed.remove(id)
    }

    /// Temporarily release all hotkeys (while recording a new shortcut).
    func pause() {
        paused = true
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    func resume() {
        paused = false
        for id in combos.keys where refs[id] == nil { activate(id) }
    }

    private func activate(_ id: UInt32) {
        guard let combo = combos[id], refs[id] == nil else { return }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5052_5441), id: id) // 'PRTA'
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
            failed.remove(id)
        } else {
            failed.insert(id)
            scheduleRetry()
        }
    }

    /// Another app (e.g. Raycast) may be holding the combo; keep trying until it lets go.
    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            if !self.paused { for id in self.failed { self.activate(id) } }
            if self.failed.isEmpty {
                timer.invalidate()
                self.retryTimer = nil
            }
        }
    }

    fileprivate func fire(_ id: UInt32) {
        MainActor.assumeIsolated { handlers[id]?() }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

extension KeyCombo {
    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        text += KeyCombo.keyName(event)
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(carbon), display: text)
    }

    static func keyName(_ event: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[Int(event.keyCode)] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }

    static func isFunctionKey(_ code: UInt16) -> Bool {
        [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
         kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19].contains(Int(code))
    }
}

// MARK: - Conflicts with macOS's own shortcuts

enum SystemHotKeys {
    /// Names for the symbolic hotkeys people most often collide with.
    private static let names: [String: String] = [
        "64": "Spotlight (Show Spotlight search)",
        "65": "Spotlight (Show Finder search window)",
        "60": "Input Sources (Select the previous input source)",
        "61": "Input Sources (Select next source in Input menu)",
    ]

    /// Returns the name of the enabled macOS shortcut that uses `combo`, if any.
    static func conflict(for combo: KeyCombo) -> String? {
        guard let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys") else {
            // No prefs written means macOS defaults: Spotlight on ⌘Space.
            return combo == .launcherDefault ? names["64"] : nil
        }
        let wantedMods = cocoaModifiers(fromCarbon: combo.modifiers)
        for (key, raw) in all {
            guard let entry = raw as? [String: Any],
                  (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any],
                  let params = value["parameters"] as? [NSNumber], params.count == 3 else { continue }
            if params[1].uint32Value == combo.keyCode && params[2].uintValue == wantedMods {
                return names[key] ?? "a macOS keyboard shortcut (#\(key))"
            }
        }
        if all["64"] == nil && combo == .launcherDefault { return names["64"] }
        return nil
    }

    private static func cocoaModifiers(fromCarbon m: UInt32) -> UInt {
        var flags: NSEvent.ModifierFlags = []
        if m & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if m & UInt32(optionKey) != 0 { flags.insert(.option) }
        if m & UInt32(controlKey) != 0 { flags.insert(.control) }
        if m & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags.rawValue
    }

    static func openKeyboardShortcuts() {
        let urls = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts",
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
        ]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
    }

    /// Apps that commonly grab ⌘Space themselves.
    static func runningLauncherApps() -> [String] {
        let ids = ["com.raycast.macos": "Raycast", "com.runningwithcrayons.Alfred": "Alfred"]
        return NSWorkspace.shared.runningApplications.compactMap { ids[$0.bundleIdentifier ?? ""] }
    }
}

// MARK: - Login item & permissions

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openPrivacySettings() {
        open("x-apple.systempreferences:com.apple.preference.security")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
