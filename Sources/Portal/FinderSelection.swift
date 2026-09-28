import AppKit

/// Reads what's selected in Finder (via Apple Events; macOS asks once for permission).
@MainActor
enum FinderSelection {
    struct Result {
        let folders: [URL]
        let fromSelection: Bool   // false = nothing selected, using the front window's folder
    }

    static var finderIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }

    private static let source = """
    tell application "Finder"
        set sel to selection as alias list
        if (count of sel) > 0 then
            set out to "S"
            repeat with a in sel
                set out to out & linefeed & POSIX path of a
            end repeat
            return out
        end if
        if (count of Finder windows) > 0 then
            return "W" & linefeed & POSIX path of (target of front Finder window as alias)
        end if
        return ""
    end tell
    """

    /// Folders to act on: selected folders, the parent folder of selected files,
    /// or the front window's folder when nothing is selected.
    static func current() -> Result? {
        var error: NSDictionary?
        guard let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else {
            if let error { NSLog("Portal: Finder selection unavailable: \(error)") }
            return nil
        }
        var lines = output.split(separator: "\n").map(String.init)
        guard let kind = lines.first else { return nil }
        lines.removeFirst()

        var seen = Set<String>()
        let folders: [URL] = lines.compactMap { path in
            var url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let isBundle = NSWorkspace.shared.isFilePackage(atPath: url.path)
            if !isDir.boolValue || isBundle { url.deleteLastPathComponent() }
            return seen.insert(url.standardizedFileURL.path).inserted ? url.standardizedFileURL : nil
        }
        guard !folders.isEmpty else { return nil }
        return Result(folders: Array(folders.prefix(8)), fromSelection: kind == "S")
    }

    static func open(_ folders: [URL], withAppAt appPath: String) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let app = URL(fileURLWithPath: appPath)
        for folder in folders {
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: cfg) { _, error in
                if let error { NSLog("Portal: couldn't open \(folder.path): \(error)") }
            }
        }
    }
}
