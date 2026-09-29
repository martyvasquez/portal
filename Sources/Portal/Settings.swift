import Foundation
import AppKit
import Combine
import Carbon.HIToolbox
import SystemConfiguration

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static let appSupport: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Portal", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let iCloudDrive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    static let defaultSyncFolder = iCloudDrive.appendingPathComponent("Portal", isDirectory: true)

    static var iCloudDriveAvailable: Bool {
        FileManager.default.fileExists(atPath: iCloudDrive.path)
    }

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier mask
    var display: String

    static let launcherDefault = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey), display: "⌘Space")
    static let clipboardDefault = KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), display: "⇧⌘V")
}

/// A named link to a folder or URL that opens in a chosen app (like Raycast Quicklinks).
struct Quicklink: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var link: String            // folder path (stored with ~) or URL; may contain {query}
    var appPath: String?        // nil = system default app
    var hotKey: KeyCombo?

    static let placeholder = "{query}"

    var needsQuery: Bool { link.contains(Self.placeholder) }

    var isFolder: Bool {
        let t = link.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("/") || t.hasPrefix("~")
    }

    var appURL: URL? { appPath.map { URL(fileURLWithPath: $0) } }

    static let finderPath = "/System/Library/CoreServices/Finder.app"

    /// The app that opens this link by default: Finder for folders, the default browser for URLs.
    var defaultAppPath: String? {
        if isFolder { return Self.finderPath }
        guard let probe = URL(string: "https://example.com") else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)?.standardizedFileURL.path
    }

    /// The app that will actually open this link: the chosen one, else the default.
    var resolvedAppPath: String? {
        appPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? defaultAppPath
    }

    /// Whether "open with the default app" (⌘↩) would do something different.
    var hasAlternateApp: Bool { resolvedAppPath != defaultAppPath }

    var appName: String {
        guard let appPath else { return isFolder ? "Finder" : "Default Browser" }
        let n = FileManager.default.displayName(atPath: appPath)
        return n.hasSuffix(".app") ? String(n.dropLast(4)) : n
    }

    /// Resolves the link, substituting `{query}` (URL-encoded for URLs).
    func resolvedURL(query: String = "") -> URL? {
        let t = link.trimmingCharacters(in: .whitespaces)
        if isFolder {
            return Paths.expand(t.replacingOccurrences(of: Self.placeholder, with: query))
        }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))) ?? query
        var s = t.replacingOccurrences(of: Self.placeholder, with: encoded)
        if !s.contains("://") { s = "https://" + s }
        return URL(string: s)
    }
}

/// Settings that sync between Macs (stored as settings.json in the sync folder when sync is on).
struct SharedSettings: Codable, Equatable {
    var launcherHotKey = KeyCombo.launcherDefault
    var clipboardHotKey = KeyCombo.clipboardDefault

    var snippets: [Snippet] = []
    var quicklinks: [Quicklink] = [
        Quicklink(name: "Development", link: "~/Development", appPath: "/Applications/Ghostty.app"),
        Quicklink(name: "Development in Finder", link: "~/Development"),
        Quicklink(name: "Search GitHub", link: "https://github.com/search?q={query}",
                  appPath: "/Applications/Google Chrome.app"),
    ]
    var includeApps = true
    var showMenuBarIcon = true
    /// Apps offered for what's selected in Finder, in order; the first is the default.
    var folderOpenWith: [String] = SharedSettings.installed([
        "/Applications/Ghostty.app", "/System/Applications/Utilities/Terminal.app", "/Applications/Sublime Text.app",
    ])
    var fileOpenWith: [String] = SharedSettings.installed([
        "/Applications/Sublime Text.app", "/System/Applications/TextEdit.app",
    ])
    /// Files of these types get their folder's apps instead of the file apps.
    var excludedFileTypes: [String] = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "pdf", "mov", "mp4", "mp3", "wav", "zip", "dmg", "pkg", "app",
    ]
    var finderSelectionHotKey: KeyCombo?

    var clipboardRetentionDays = 7
    var secretRetentionDays = 7
    var recordSecrets = true
    var maxImageMB = 5
    var maxClipsPerMac = 2000
    var pasteOnSelect = true
    var cleanTerminalCopies = true
    var unwrapTerminalLines = true
    var ignoredBundleIDs: [String] = []

    init() {}

    private enum LegacyKeys: String, CodingKey { case finderSelectionAppPath }

    static func installed(_ paths: [String]) -> [String] {
        paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func appName(_ path: String) -> String {
        let n = FileManager.default.displayName(atPath: path)
        return n.hasSuffix(".app") ? String(n.dropLast(4)) : n
    }

    // Tolerate missing keys so older settings files keep working as fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SharedSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        launcherHotKey = v(.launcherHotKey, d.launcherHotKey)
        clipboardHotKey = v(.clipboardHotKey, d.clipboardHotKey)
        snippets = v(.snippets, d.snippets)
        quicklinks = v(.quicklinks, d.quicklinks)
        includeApps = v(.includeApps, d.includeApps)
        showMenuBarIcon = v(.showMenuBarIcon, d.showMenuBarIcon)
        folderOpenWith = v(.folderOpenWith, d.folderOpenWith)
        fileOpenWith = v(.fileOpenWith, d.fileOpenWith)
        excludedFileTypes = v(.excludedFileTypes, d.excludedFileTypes)
        finderSelectionHotKey = v(.finderSelectionHotKey, d.finderSelectionHotKey)

        // Earlier versions had one app for the Finder selection; keep it as the default folder app.
        if !c.contains(.folderOpenWith),
           let legacy = try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(String.self, forKey: .finderSelectionAppPath) {
            folderOpenWith = [legacy] + folderOpenWith.filter { $0 != legacy }
        }
        clipboardRetentionDays = v(.clipboardRetentionDays, d.clipboardRetentionDays)
        secretRetentionDays = v(.secretRetentionDays, d.secretRetentionDays)
        recordSecrets = v(.recordSecrets, d.recordSecrets)
        maxImageMB = v(.maxImageMB, d.maxImageMB)
        maxClipsPerMac = v(.maxClipsPerMac, d.maxClipsPerMac)
        pasteOnSelect = v(.pasteOnSelect, d.pasteOnSelect)
        cleanTerminalCopies = v(.cleanTerminalCopies, d.cleanTerminalCopies)
        unwrapTerminalLines = v(.unwrapTerminalLines, d.unwrapTerminalLines)
        ignoredBundleIDs = v(.ignoredBundleIDs, d.ignoredBundleIDs)
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var values = SharedSettings() {
        didSet { if !isLoading && values != oldValue { scheduleSave() } }
    }

    /// Per-Mac settings (UserDefaults).
    @Published var syncEnabled: Bool {
        didSet {
            guard syncEnabled != oldValue else { return }
            UserDefaults.standard.set(syncEnabled, forKey: "syncEnabled")
            adoptSettingsFileAfterLocationChange()
        }
    }
    @Published var syncFolderPath: String {
        didSet {
            guard syncFolderPath != oldValue else { return }
            UserDefaults.standard.set(syncFolderPath, forKey: "syncFolderPath")
            if syncEnabled { adoptSettingsFileAfterLocationChange() }
        }
    }

    let machineID: String
    let machineName: String

    private var isLoading = false
    private var saveWork: DispatchWorkItem?
    private var lastSeenModDate: Date?
    private var pollTimer: Timer?

    private init() {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "machineID") {
            machineID = id
        } else {
            machineID = UUID().uuidString
            d.set(machineID, forKey: "machineID")
        }
        machineName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
        syncEnabled = d.object(forKey: "syncEnabled") as? Bool ?? Paths.iCloudDriveAvailable
        syncFolderPath = d.string(forKey: "syncFolderPath") ?? Paths.abbreviate(Paths.defaultSyncFolder.path)
    }

    var syncFolderURL: URL { Paths.expand(syncFolderPath) }

    var settingsFileURL: URL {
        syncEnabled ? syncFolderURL.appendingPathComponent("settings.json") : Paths.appSupport.appendingPathComponent("settings.json")
    }

    func load() {
        if FileManager.default.fileExists(atPath: settingsFileURL.path) { readSettingsFile() } else { saveNow() }
        pollTimer?.invalidate()
        // Pick up edits made on the other Mac.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfChangedOnDisk() }
        }
    }

    private func readSettingsFile() {
        let url = settingsFileURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(SharedSettings.self, from: data) else { return }
        lastSeenModDate = modDate(url)
        isLoading = true
        values = decoded
        isLoading = false
    }

    private func reloadIfChangedOnDisk() {
        guard syncEnabled, saveWork == nil else { return }
        let date = modDate(settingsFileURL)
        if let date, date != lastSeenModDate { readSettingsFile() }
    }

    private func adoptSettingsFileAfterLocationChange() {
        if FileManager.default.fileExists(atPath: settingsFileURL.path) {
            readSettingsFile()
        } else {
            saveNow()
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.saveWork = nil
                self?.saveNow()
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        let url = settingsFileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(values).write(to: url, options: .atomic)
            lastSeenModDate = modDate(url)
        } catch {
            NSLog("Portal: failed to save settings: \(error)")
        }
    }

    private func modDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
