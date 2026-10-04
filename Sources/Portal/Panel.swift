import AppKit
import SwiftUI

/// Borderless, non-activating floating panel: takes keyboard focus without
/// pulling the app you were in out of the foreground (so paste goes back to it).
final class FloatingPanel: NSPanel {
    var onResignKey: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

@MainActor
final class PanelController {
    let panel: FloatingPanel
    var keyHandler: ((NSEvent) -> Bool)?
    var onShow: (() -> Void)?
    var onHide: (() -> Void)?
    private var monitor: Any?

    init(size: NSSize, rootView: AnyView) {
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size))

        // SwiftUI draws the rounded, solid panel (PanelChrome); the window itself is clear.
        let host = NSHostingView(rootView: AnyView(rootView.modifier(PanelChrome())))
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host
        panel.onResignKey = { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        onShow?()
        position()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.invalidateShadow()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.focusSearchField() }
        }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.window === self.panel else { return event }
                    return (self.keyHandler?(event) ?? false) ? nil : event
                }
            }
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onHide?()
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - visible.height * 0.2 - size.height
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: max(visible.minY + 20, y).rounded()))
    }

    private func focusSearchField() {
        guard let content = panel.contentView, let field = Self.findTextField(in: content) else { return }
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0)
    }

    private static func findTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews { if let f = findTextField(in: sub) { return f } }
        return nil
    }
}

// MARK: - Shared SwiftUI bits

/// Plain AppKit text field so focus and key handling are predictable inside the panel.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat = 20

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.placeholderString = placeholder
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSTextField { text.wrappedValue = field.stringValue }
        }
    }
}

@MainActor
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(forPath path: String) -> NSImage {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 64, height: 64)
        cache.setObject(img, forKey: path as NSString)
        return img
    }

    /// Menus draw an NSImage at its own size, so they need a copy that is already small.
    static func menuIcon(forPath path: String, size: CGFloat = 16) -> NSImage {
        let key = "menu:\(size):\(path)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let img = (NSWorkspace.shared.icon(forFile: path).copy() as? NSImage) ?? NSImage()
        img.size = NSSize(width: size, height: size)
        cache.setObject(img, forKey: key)
        return img
    }

    static func defaultBrowserIcon() -> NSImage? {
        guard let probe = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return icon(forPath: app.path)
    }

    static func appIcon(bundleID: String) -> NSImage? {
        let key = "bundle:\(bundleID)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(img, forKey: key)
        return img
    }
}
