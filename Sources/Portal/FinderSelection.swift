import AppKit

/// Reads what's selected in Finder (via Apple Events; macOS asks once for permission).
@MainActor
enum FinderSelection {
    struct Result {
        let folders: [URL]
        let files: [URL]
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

    /// Selected folders, and selected files (except excluded types, which count as
    /// their folder). With nothing selected, the front window's folder.
    static func current(excludedTypes: [String]) -> Result? {
        var error: NSDictionary?
        guard let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else {
            if let error { NSLog("Portal: Finder selection unavailable: \(error)") }
            return nil
        }
        var lines = output.split(separator: "\n").map(String.init)
        guard let kind = lines.first else { return nil }
        lines.removeFirst()

        let (folders, files) = classify(lines, excludedTypes: excludedTypes)
        guard !folders.isEmpty || !files.isEmpty else { return nil }
        return Result(folders: Array(folders.prefix(8)), files: Array(files.prefix(8)), fromSelection: kind == "S")
    }

    /// Splits paths into folders and files. Packages (apps, .pages docs) count as files; excluded file
    /// types become their parent folder. Duplicates are dropped, order is kept.
    nonisolated static func classify(_ paths: [String], excludedTypes: [String]) -> (folders: [URL], files: [URL]) {
        let excluded = Set(excludedTypes.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) })
        var folders: [URL] = [], files: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL, to list: inout [URL]) {
            let url = url.standardizedFileURL
            if seen.insert(url.path).inserted { list.append(url) }
        }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let isFolder = isDir.boolValue && !NSWorkspace.shared.isFilePackage(atPath: url.path)
            if isFolder {
                add(url, to: &folders)
            } else if excluded.contains(url.pathExtension.lowercased()) {
                add(url.deletingLastPathComponent(), to: &folders)
            } else {
                add(url, to: &files)
            }
        }
        return (folders, files)
    }

    static func open(_ urls: [URL], withAppAt appPath: String) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let app = URL(fileURLWithPath: appPath)
        for url in urls {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg) { _, error in
                if let error { NSLog("Portal: couldn't open \(url.path): \(error)") }
            }
        }
    }
}
