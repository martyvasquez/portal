import SwiftUI

struct LauncherView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            Divider()
            if model.pending != nil {
                argumentHelp
            } else if model.results.isEmpty {
                ContentUnavailableView(model.query.isEmpty ? "No Quicklinks Yet" : "No Matches",
                                       systemImage: model.query.isEmpty ? "link" : "magnifyingglass",
                                       description: Text(model.query.isEmpty ? "Add quicklinks in Settings." : ""))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultsList
            }
            Divider()
            footer
        }
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            if let pending = model.pending {
                QuicklinkIcon(link: pending).frame(width: 20, height: 20)
                Text(pending.name)
                    .font(.title3.weight(.medium))
                    .fixedSize()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            SearchField(text: $model.query,
                        placeholder: model.pending == nil ? "Quicklinks and apps" : "Type your query",
                        fontSize: 17)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var argumentHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pending = model.pending {
                Text(pending.link)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("Press Return to open in \(pending.appName).")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        if showsHeader(at: index) {
                            SectionTitle(text: header(for: item.kind))
                                .padding(.top, index == 0 ? 2 : 12)
                        }
                        LaunchRow(item: item, link: model.quicklink(for: item), index: index,
                                  selected: index == model.selection)
                            .id(item.id)
                            .onTapGesture {
                                model.selection = index
                                model.perform(.primary)
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selection) { _, new in
                if model.results.indices.contains(new) { proxy.scrollTo(model.results[new].id) }
            }
        }
    }

    private func showsHeader(at index: Int) -> Bool {
        index == 0 || model.results[index - 1].kind != model.results[index].kind
    }

    private func header(for kind: LaunchKind) -> String {
        switch kind {
        case .finder: model.finderFolders.count > 1 ? "Finder Selection" : "Finder"
        case .quicklink: "Quicklinks"
        case .app: model.query.isEmpty ? "Recent Apps" : "Apps"
        case .command: "Portal"
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Spacer()
            ForEach(model.hints(for: model.selectedItem), id: \.0) { KeyHint(keys: $0.0, label: $0.1) }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }
}

private struct LaunchRow: View {
    let item: LaunchItem
    let link: Quicklink?
    let index: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let link {
                if link.needsQuery { Pill(text: "Query") }
                Pill(text: link.appName)
            }
            if let hotKey = item.hotKey { KeyCap(text: hotKey) }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background { if selected { SelectionFill() } }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        if let link {
            QuicklinkIcon(link: link)
        } else if item.kind == .finder, let app = item.openWith {
            Image(nsImage: IconCache.icon(forPath: app)).resizable().interpolation(.high)
        } else if let symbol = item.symbol {
            Image(systemName: symbol)
                .foregroundStyle(Theme.accent)
                .font(.body.weight(.medium))
        } else {
            Image(nsImage: IconCache.icon(forPath: item.path)).resizable().interpolation(.high)
        }
    }
}

/// Folder icon for folder links; the "open with" app's icon for URLs.
struct QuicklinkIcon: View {
    let link: Quicklink
    var body: some View {
        if link.isFolder && link.appPath == nil {
            Image(nsImage: IconCache.icon(forPath: Paths.expand(link.link).path)).resizable().interpolation(.high)
        } else if let app = link.appPath {
            Image(nsImage: IconCache.icon(forPath: app)).resizable().interpolation(.high)
        } else if let browser = IconCache.defaultBrowserIcon() {
            Image(nsImage: browser).resizable().interpolation(.high)
        } else {
            Image(systemName: "link").foregroundStyle(Theme.accent)
        }
    }
}
