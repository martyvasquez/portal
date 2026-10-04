import SwiftUI

struct LauncherView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            Divider()
            if let run = model.run {
                TransformRunView(run: run, model: model)
            } else {
                listContent
            }
        }
    }

    @ViewBuilder private var listContent: some View {
        if model.pending != nil {
            argumentHelp
        } else if model.promptMode {
            promptHelp
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

    private var searchRow: some View {
        HStack(spacing: 10) {
            if let pending = model.pending {
                QuicklinkIcon(link: pending).frame(width: 20, height: 20)
                breadcrumb(pending.name)
            } else if let run = model.run {
                Image(systemName: "wand.and.sparkles").font(.title3).foregroundStyle(Theme.accent)
                breadcrumb(run.transformer.name)
            } else if model.promptMode {
                Image(systemName: "text.bubble").font(.title3).foregroundStyle(Theme.accent)
                breadcrumb("Transform")
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            SearchField(text: $model.query, placeholder: placeholder, fontSize: 17)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var placeholder: String {
        if model.pending != nil { return "Type your query" }
        if model.run != nil { return "Ask for changes" }
        if model.promptMode { return "What should happen to the \(model.transformInput?.source == .clipboard ? "clip" : "selection")?" }
        return model.transformInput != nil ? "Transform the selection, or search" : "Snippets, quicklinks, and apps"
    }

    private func breadcrumb(_ title: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.title3.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: 260, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var promptHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Press Return to run your prompt on:")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let input = model.transformInput {
                Text(input.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                            SectionTitle(text: header(for: item))
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
        index == 0 || header(for: model.results[index - 1]) != header(for: model.results[index])
    }

    private func header(for item: LaunchItem) -> String {
        if let section = item.section { return section }
        switch item.kind {
        case .transform: return "Transform Selection"
        case .finder: return "Finder Selection"
        case .snippet, .folderAction: return "Snippets"
        case .quicklink: return "Quicklinks"
        case .app: return model.query.isEmpty ? "Recent Apps" : "Apps"
        case .command: return "Portal"
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
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
            if let badge = item.badge { Pill(text: badge) }
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

/// The icon of the app the link opens in (Finder for plain folder links), so the same
/// app always looks the same whether it was picked explicitly or is the default.
struct QuicklinkIcon: View {
    let link: Quicklink
    var body: some View {
        if let app = link.resolvedAppPath {
            Image(nsImage: IconCache.icon(forPath: app)).resizable().interpolation(.high)
        } else {
            Image(systemName: "link").foregroundStyle(Theme.accent)
        }
    }
}

/// A transformer's reply as it streams in, then the keys to use it or ask for changes.
private struct TransformRunView: View {
    @ObservedObject var run: TransformRun
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(run.followUps.enumerated()), id: \.offset) { _, followUp in
                        Label(followUp, systemImage: "arrow.turn.down.right")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let error = run.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else if run.output.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Working on it…").foregroundStyle(.secondary)
                        }
                    } else {
                        Text(run.output)
                            .font(looksLikeCode ? .callout.monospaced() : .body)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.automatic)
            Divider()
            HStack(spacing: 14) {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                ForEach(hints, id: \.0) { KeyHint(keys: $0.0, label: $0.1) }
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
        }
    }

    private var looksLikeCode: Bool {
        let start = run.output.drop { $0.isWhitespace }.first
        return start == "{" || start == "[" || run.output.contains("```")
    }

    private var status: String {
        let chars = run.input.text.count.formatted()
        if run.isRunning { return "\(run.modelName) · \(chars) characters" }
        if run.error != nil { return run.modelName }
        return "\(run.modelName) · \(chars) → \(run.output.count.formatted()) characters"
    }

    private var hints: [(String, String)] {
        if run.isRunning { return [("⎋", "Cancel")] }
        if run.error != nil { return [("⌘R", "Try Again"), ("⎋", "Back")] }
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty { return [("↩", "Ask"), ("⎋", "Back")] }
        var hints = [("↩", model.actionLabel(.replace))]
        if model.actionLabel(.replace) != "Copy" { hints.append(("⌥↩", "Copy")) }
        hints.append(("⌘R", "Retry"))
        hints.append(("⎋", "Back"))
        return hints
    }
}
