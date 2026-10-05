import Foundation

/// Where something shows: quicklinks, snippets, and transformers all scope the same way.
/// In any of `apps` (bundle IDs) or on any of `sites`; neither = everywhere except the excluded
/// apps and sites. Exclusions only apply while it's global.
protocol Scoped {
    var apps: [String] { get set }
    var sites: [String] { get set }
    var excludedApps: [String] { get set }
    var excludedSites: [String] { get set }
}

extension Scoped {
    var isGlobal: Bool { apps.isEmpty && sites.isEmpty }

    /// True in one of its apps or on one of its sites; for a global one, anywhere it isn't excluded.
    func applies(app: String?, url: URL?) -> Bool {
        if isGlobal { return !isExcluded(app: app, url: url) }
        return matchesApp(app) || matchesSite(url)
    }

    func matchesApp(_ app: String?) -> Bool { app.map(apps.contains) ?? false }

    func matchesSite(_ url: URL?) -> Bool {
        guard let url else { return false }
        return sites.contains { SiteMatcher.matches($0, url) }
    }

    func isExcluded(app: String?, url: URL?) -> Bool {
        guard isGlobal else { return false }
        if let app, excludedApps.contains(app) { return true }
        if let url, excludedSites.contains(where: { SiteMatcher.matches($0, url) }) { return true }
        return false
    }

    /// Whether it could apply with `app` in front. Sites are only known once a browser's tab is
    /// read, so any browser counts for a site-scoped one (and an excluded site doesn't rule one out).
    func couldApply(frontApp app: String?) -> Bool {
        if isGlobal { return !(app.map(excludedApps.contains) ?? false) }
        return matchesApp(app) || (!sites.isEmpty && BrowserContext.isBrowser(app))
    }

    /// Whether both could show in the same place, so one hotkey can't serve both.
    func overlaps(_ other: any Scoped) -> Bool {
        if isGlobal && other.isGlobal { return true }
        if isGlobal { return !other.isInside(exclusionsOf: self) }
        if other.isGlobal { return !isInside(exclusionsOf: other) }
        if !Set(apps).isDisjoint(with: other.apps) { return true }
        // Sites only match in browsers: a browser in one and a site in the other can meet.
        if apps.contains(where: BrowserContext.isBrowser) && !other.sites.isEmpty { return true }
        if other.apps.contains(where: BrowserContext.isBrowser) && !sites.isEmpty { return true }
        return sites.contains { a in other.sites.contains { b in ScopeSites.overlap(a, b) } }
    }

    /// True when every place this scoped one shows is one `global` is hidden from.
    fileprivate func isInside(exclusionsOf global: any Scoped) -> Bool {
        apps.allSatisfy(global.excludedApps.contains)
            && sites.allSatisfy { site in global.excludedSites.contains { ScopeSites.covers($0, site) } }
    }

    /// A scoped one lists where it shows, so leftover exclusions are dropped when it's saved.
    mutating func dropUnusedExclusions() {
        guard !isGlobal else { return }
        excludedApps = []
        excludedSites = []
    }

    /// "Mail, github.com" for a scoped one's card, "Not in Ghostty" for a global one with
    /// exclusions; nil when it shows everywhere.
    @MainActor var scopeLabel: String? {
        func list(_ names: [String]) -> String? {
            guard let first = names.first else { return nil }
            if names.count == 1 { return first }
            if names.count == 2 { return "\(first), \(names[1])" }
            return "\(first) +\(names.count - 1)"
        }
        if !isGlobal { return list(apps.map { SharedSettings.appName(bundleID: $0) } + sites) }
        return list(excludedApps.map { SharedSettings.appName(bundleID: $0) } + excludedSites).map { "Not in \($0)" }
    }
}

enum ScopeSites {
    /// Whether every URL `site` matches is also matched by `pattern`.
    static func covers(_ pattern: String, _ site: String) -> Bool {
        probe(site).map { SiteMatcher.matches(pattern, $0) } ?? false
    }

    /// `github.com` and `gist.github.com/me` overlap; `github.com` and `gitlab.com` don't.
    static func overlap(_ a: String, _ b: String) -> Bool {
        if let u = probe(b), SiteMatcher.matches(a, u) { return true }
        if let u = probe(a), SiteMatcher.matches(b, u) { return true }
        return false
    }

    private static func probe(_ pattern: String) -> URL? {
        var p = pattern.lowercased()
        if p.hasPrefix("*.") { p.removeFirst(2) }
        return URL(string: "https://" + p)
    }
}
