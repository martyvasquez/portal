import SwiftUI

// MARK: - Scope rows

/// "Show in" and "Except in" rows for a quicklink, snippet, or transformer editor's grid.
/// The editor owns the half-typed site fields so Save can keep what's in them (`commit`).
struct ScopeRows<Item: Scoped>: View {
    @Binding var item: Item
    @Binding var newSite: String
    @Binding var newExcludedSite: String
    /// Help under "Show in": while it's everywhere, then once it's scoped.
    let globalHelp: String
    let scopedHelp: String
    var excludedHelp = "Hidden in these apps and on these sites."

    var body: some View {
        GridRow {
            Text("Show in").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                PlaceChips(apps: $item.apps, sites: $item.sites, newSite: $newSite,
                           leading: item.isGlobal ? "Everywhere" : nil)
                Text(item.isGlobal ? globalHelp : scopedHelp)
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if item.isGlobal {
            GridRow {
                Text("Except in").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    PlaceChips(apps: $item.excludedApps, sites: $item.excludedSites,
                               newSite: $newExcludedSite, leading: nil)
                    Text(excludedHelp)
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Adds sites still in the text fields and drops exclusions a scoped item doesn't use.
    static func commit(_ item: inout Item, newSite: inout String, newExcludedSite: inout String) {
        PlaceChips.add(&newSite, to: &item.sites)
        PlaceChips.add(&newExcludedSite, to: &item.excludedSites)
        item.dropUnusedExclusions()
    }
}

/// App and website chips with buttons to add more: where something shows, or where it's hidden.
struct PlaceChips: View {
    @Binding var apps: [String]
    @Binding var sites: [String]
    @Binding var newSite: String
    let leading: String?

    var body: some View {
        FlowLayout(spacing: 6) {
            if let leading {
                Text(leading)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4).padding(.vertical, 3)
            }
            ForEach(apps, id: \.self) { id in
                Chip(label: SharedSettings.appName(bundleID: id), icon: IconCache.appIcon(bundleID: id)) {
                    apps.removeAll { $0 == id }
                }
            }
            ForEach(sites, id: \.self) { site in
                Chip(label: site, icon: NSImage(systemSymbolName: "globe", accessibilityDescription: nil)) {
                    sites.removeAll { $0 == site }
                }
            }
            Button("Add App…", action: addApp)
            TextField("Add website", text: $newSite)
                .textFieldStyle(.plain)
                .font(.callout)
                .frame(width: 130)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .onSubmit { Self.add(&newSite, to: &sites) }
                .help("Press Return to add. github.com includes its subdomains; *.atlassian.net matches any; github.com/martyvasquez limits to that path.")
        }
    }

    /// Adds a typed site ("github.com", "*.atlassian.net", "github.com/martyvasquez") and clears the field.
    static func add(_ typed: inout String, to sites: inout [String]) {
        var site = typed.trimmingCharacters(in: .whitespaces).lowercased()
        if let scheme = site.range(of: "://") { site = String(site[scheme.upperBound...]) }
        while site.hasSuffix("/") { site.removeLast() }
        typed = ""
        guard !site.isEmpty, !sites.contains(site) else { return }
        sites.append(site)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !apps.contains(id) { apps.append(id) }
        }
    }
}
