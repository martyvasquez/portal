import AppKit
import Carbon.HIToolbox

/// A global, per-app, or per-site snippet, stored in settings (synced via iCloud).
struct Snippet: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var text: String
    var apps: [String] = []     // bundle IDs
    var sites: [String] = []    // site patterns like "github.com" or "*.atlassian.net/wiki"
                                // (neither set = every app)

    var isGlobal: Bool { apps.isEmpty && sites.isEmpty }
    var title: String { name.isEmpty ? text : name }

    init(name: String, text: String, apps: [String] = [], sites: [String] = []) {
        self.name = name
        self.text = text
        self.apps = apps
        self.sites = sites
    }

    // Snippets saved before `sites` existed must still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        text = try c.decode(String.self, forKey: .text)
        apps = try c.decodeIfPresent([String].self, forKey: .apps) ?? []
        sites = try c.decodeIfPresent([String].self, forKey: .sites) ?? []
    }
}

// MARK: - Which page is the front browser on?

@MainActor
enum BrowserContext {
    /// Browsers that report their current tab to AppleScript. Chromium-based ones share
    /// Chrome's dictionary; Safari names the tab differently.
    nonisolated private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium",
        "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
    ]

    nonisolated static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return chromium.contains(bundleID) || bundleID == "com.apple.Safari"
    }

    static func currentURL(frontApp bundleID: String?) -> URL? {
        guard let bundleID, isBrowser(bundleID) else { return nil }
        let tab = bundleID == "com.apple.Safari" ? "current tab" : "active tab"
        var error: NSDictionary?
        let script = "tell application id \"\(bundleID)\" to get URL of \(tab) of front window"
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue
        if let error { NSLog("Portal: couldn't read the browser tab: \(error)") }
        return result.flatMap(URL.init(string:))
    }
}

/// Matches a URL against a site pattern:
/// `github.com` (and its subdomains), `*.atlassian.net`, or a path prefix like `github.com/martyvasquez`.
enum SiteMatcher {
    static func matches(_ pattern: String, _ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        var p = pattern.lowercased().trimmingCharacters(in: .whitespaces)
        if let scheme = p.range(of: "://") { p = String(p[scheme.upperBound...]) }
        while p.hasSuffix("/") { p.removeLast() }
        let slash = p.firstIndex(of: "/")
        var patternHost = String(p[..<(slash ?? p.endIndex)])
        let patternPath = slash.map { String(p[$0...]) } ?? ""
        if patternHost.hasPrefix("*.") { patternHost.removeFirst(2) }
        if patternHost.hasPrefix("www.") { patternHost.removeFirst(4) }
        guard !patternHost.isEmpty,
              host == patternHost || host.hasSuffix("." + patternHost) else { return false }
        guard !patternPath.isEmpty else { return true }
        let path = url.path().lowercased()
        return path == patternPath || path.hasPrefix(patternPath + "/")
    }

    /// Short label for a URL's site: the host without "www.".
    static func label(_ url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - Which folder is the front app in?

@MainActor
enum FolderContext {
    /// The folder the front terminal is working in, if it can tell us. Folder snippets are
    /// for typing commands, so only terminals count (Finder has Open With instead).
    /// Ghostty: the focused terminal's working directory. Terminal: the front tab's shell directory.
    static func current(frontApp bundleID: String?) -> URL? {
        switch bundleID {
        case "com.mitchellh.ghostty":
            return run("tell application \"Ghostty\" to get working directory of focused terminal of selected tab of front window")
                .map { URL(fileURLWithPath: $0) }
        case "com.apple.Terminal":
            guard let tty = run("tell application \"Terminal\" to get tty of selected tab of front window") else { return nil }
            return shellDirectory(tty: tty)
        default:
            return nil
        }
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
        if let error { NSLog("Portal: folder lookup failed: \(error)") }
        return result?.isEmpty == false ? result : nil
    }

    /// Terminal only knows the tab's tty; ask macOS for the cwd of the process in front on it.
    private static func shellDirectory(tty: String) -> URL? {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-t", (tty as NSString).lastPathComponent, "-o", "pid=,stat="]
        p.standardOutput = out
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let rows = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line -> (pid: Int32, foreground: Bool)? in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, let pid = Int32(parts[0]) else { return nil }
                return (pid, parts[1].contains("+"))
            }
        let pid = (rows.last { $0.foreground } ?? rows.last)?.pid
        return pid.flatMap(cwd(of:))
    }

    private static func cwd(of pid: Int32) -> URL? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }
}

// MARK: - .portal.json

/// Folder snippets live in `.portal.json`, committed with the repo:
///
///     { "snippets": [ { "name": "Dev server", "text": "npm run dev" } ],
///       "seeded": ["npm run dev"] }
///
/// `seeded` lists commands Build / Update already added, so deleting one keeps it deleted.
struct PortalFile {
    static let name = ".portal.json"

    let url: URL
    var snippets: [(name: String, text: String)]
    var seeded: [String]
    var root: URL { url.deletingLastPathComponent() }

    enum LoadError: Error { case invalid(URL, String) }

    /// The nearest `.portal.json` at or above `folder`, stopping at the home folder.
    static func find(from folder: URL) -> URL? {
        var dir = folder.standardizedFileURL
        let home = Paths.home.standardizedFileURL.path
        while true {
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            if dir.path == home || dir.path == "/" { return nil }
            dir.deleteLastPathComponent()
        }
    }

    /// Where Build / Update should write: the git root above `folder`, else `folder` itself.
    static func projectRoot(for folder: URL) -> URL {
        var dir = folder.standardizedFileURL
        let home = Paths.home.standardizedFileURL.path
        while dir.path != home && dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir }
            dir.deleteLastPathComponent()
        }
        return folder.standardizedFileURL
    }

    static func load(_ url: URL) throws -> PortalFile {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError.invalid(url, "The top level should be an object with a \"snippets\" list.")
        }
        let raw = json["snippets"] as? [[String: Any]] ?? []
        let snippets = raw.compactMap { item -> (String, String)? in
            guard let text = item["text"] as? String, !text.isEmpty else { return nil }
            return (item["name"] as? String ?? "", text)
        }
        return PortalFile(url: url, snippets: snippets, seeded: json["seeded"] as? [String] ?? [])
    }

    /// Adds newly detected commands; never touches existing snippets or re-adds seeded ones.
    /// Returns how many were added.
    @discardableResult
    static func seed(at root: URL, with detected: [(name: String, text: String)]) throws -> Int {
        let url = root.appendingPathComponent(name)
        var json: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LoadError.invalid(url, "The top level should be an object.")
            }
            json = existing
        }
        var snippets = json["snippets"] as? [[String: Any]] ?? []
        var seeded = json["seeded"] as? [String] ?? []
        let present = Set(snippets.compactMap { $0["text"] as? String })
        var added = 0
        for command in detected where !present.contains(command.text) && !seeded.contains(command.text) {
            snippets.append(["name": command.name, "text": command.text])
            seeded.append(command.text)
            added += 1
        }
        json["snippets"] = snippets
        json["seeded"] = seeded
        let data = try JSONSerialization.data(withJSONObject: json,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
        return added
    }
}

// MARK: - Finding commands in a repo

enum CommandDetector {
    /// Commands a project defines, read from well-known files at its root. Nothing is run.
    static func detect(in root: URL) -> [(name: String, text: String)] {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(name).path) }
        func read(_ name: String) -> String? { try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
        var found: [(String, String)] = []

        // package.json scripts, with the runner its lockfile implies.
        if let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
           let pkg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = pkg["scripts"] as? [String: Any] {
            let runner = exists("pnpm-lock.yaml") ? "pnpm" : exists("yarn.lock") ? "yarn"
                : (exists("bun.lockb") || exists("bun.lock")) ? "bun run" : "npm run"
            let order = ["dev", "start", "build", "test", "lint"]
            for key in scripts.keys.sorted(by: { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }) {
                found.append((key, "\(runner) \(key)"))
            }
        }

        // Makefile targets and justfile recipes.
        let target = try! NSRegularExpression(pattern: #"^([A-Za-z0-9][A-Za-z0-9_.-]*)\s*:(?!=)"#, options: .anchorsMatchLines)
        for (file, tool) in [("Makefile", "make"), ("makefile", "make"), ("justfile", "just"), ("Justfile", "just")] {
            guard let text = read(file) else { continue }
            let names = target.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
            for name in names where !name.hasPrefix(".") && !found.contains(where: { $0.1 == "\(tool) \(name)" }) {
                found.append((name, "\(tool) \(name)"))
            }
        }

        // Scripts meant to be run directly.
        for dir in ["scripts", "bin"] {
            let folder = root.appendingPathComponent(dir)
            let files = (try? fm.contentsOfDirectory(atPath: folder.path))?.sorted() ?? []
            for file in files where !file.hasPrefix(".") {
                let path = folder.appendingPathComponent(file).path
                guard file.hasSuffix(".sh") || fm.isExecutableFile(atPath: path) else { continue }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { continue }
                found.append(((file as NSString).deletingPathExtension, "\(dir)/\(file)"))
            }
        }

        // Toolchains with standard commands.
        if exists("Package.swift") { found += [("swift build", "swift build"), ("swift test", "swift test")] }
        if exists("Cargo.toml") { found += [("cargo run", "cargo run"), ("cargo test", "cargo test")] }
        if exists("project.yml") { found.append(("xcodegen", "xcodegen generate")) }
        if exists("docker-compose.yml") || exists("compose.yaml") || exists("compose.yml") {
            found.append(("docker compose up", "docker compose up"))
        }
        return found
    }
}

// MARK: - Pasting

@MainActor
enum SnippetPaster {
    /// Pastes `text` into the front app via the clipboard, then puts the clipboard back (unless
    /// `keepOnClipboard`). Both writes carry Portal's marker so clipboard history ignores them.
    static func paste(_ text: String, keepOnClipboard: Bool = false) {
        let pb = NSPasteboard.general
        let saved = keepOnClipboard ? nil : PasteboardSnapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        if !keepOnClipboard { pb.setData(Data(), forType: .portalMarker) }

        guard Permissions.accessibilityGranted else {
            Permissions.requestAccessibility()
            return   // leave the snippet on the clipboard so ⌘V still works
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Paster.sendPaste()
            if let saved { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { saved.restore(pb) } }
        }
    }

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
