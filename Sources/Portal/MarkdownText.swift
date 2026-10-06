import SwiftUI

/// A transformer result's Markdown, drawn the way it pastes as rich text (see `RichText`).
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        let blocks = MarkdownBlock.parse(markdown)
        if blocks.isEmpty {
            Text(markdown)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { row($0) }
            }
        }
    }

    /// Text in a list lines up at 20pt per level; an item's first block hangs its marker in that space.
    private func row(_ b: MarkdownBlock) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let marker = b.marker {
                Text(marker)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14, alignment: .trailing)
            }
            content(b)
        }
        .padding(.leading, CGFloat(b.depth) * 20 - (b.marker == nil ? 0 : 20))
        .padding(.leading, b.quoted ? 12 : 0)
        .overlay(alignment: .leading) {
            if b.quoted { Capsule().fill(Theme.hairline).frame(width: 3) }
        }
    }

    @ViewBuilder private func content(_ b: MarkdownBlock) -> some View {
        switch b.kind {
        case .paragraph:
            Text(b.text)
        case .header(let level):
            Text(b.text).font(level <= 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
        case .code:
            Text(String(b.text.characters).trimmingCharacters(in: .newlines))
                .font(.callout.monospaced())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        case .table(let rows, let header):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, cells in
                    GridRow {
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                            Text(cell).fontWeight(header && i == 0 ? .semibold : nil)
                        }
                    }
                    if header && i == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
        }
    }
}

/// One paragraph, heading, code block, or table of parsed Markdown.
struct MarkdownBlock: Identifiable {
    enum Kind {
        case paragraph, code
        case header(Int)
        case table(rows: [[AttributedString]], header: Bool)
    }

    let id: Int
    var kind: Kind
    var text = AttributedString()
    /// How many lists it's inside.
    var depth = 0
    /// "1." or "•" on the first block of a list item.
    var marker: String?
    var quoted = false

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let attr = try? AttributedString(markdown: hardBreaks(markdown), options: options) else { return [] }
        var blocks: [MarkdownBlock] = []
        var markedItems = Set<Int>()
        var tableRow: Int?
        for (intent, range) in attr.runs[\.presentationIntent] {
            guard let components = intent?.components, let innermost = components.first else { continue }
            let text = AttributedString(attr[range])

            // Table cells come one run each: gather them into rows of the table they belong to.
            if let table = components.first(where: { if case .table = $0.kind { true } else { false } }) {
                let row = components.first { if case .tableRow = $0.kind { true } else { $0.kind == .tableHeaderRow } }?.identity
                if blocks.last?.id == table.identity, case .table(var rows, let header) = blocks.last!.kind {
                    if row == tableRow { rows[rows.count - 1].append(text) } else { rows.append([text]) }
                    blocks[blocks.count - 1].kind = .table(rows: rows, header: header)
                } else {
                    let header = components.contains { $0.kind == .tableHeaderRow }
                    blocks.append(MarkdownBlock(id: table.identity, kind: .table(rows: [[text]], header: header)))
                }
                tableRow = row
                continue
            }

            var block = MarkdownBlock(id: innermost.identity, kind: .paragraph, text: text)
            switch innermost.kind {
            case .header(let level): block.kind = .header(level)
            case .codeBlock: block.kind = .code
            default: break
            }
            block.depth = components.count { $0.kind == .orderedList || $0.kind == .unorderedList }
            block.quoted = components.contains { $0.kind == .blockQuote }
            if let i = components.firstIndex(where: { if case .listItem = $0.kind { true } else { false } }),
               case .listItem(let ordinal) = components[i].kind,
               markedItems.insert(components[i].identity).inserted {
                let ordered = components.indices.contains(i + 1) && components[i + 1].kind == .orderedList
                block.marker = ordered ? "\(ordinal)." : "•"
            }
            blocks.append(block)
        }
        return blocks
    }

    /// Ends each line with a Markdown hard break, outside code fences, so single line breaks
    /// stay line breaks here as they do when pasted.
    static func hardBreaks(_ markdown: String) -> String {
        var inFence = false
        return markdown.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                return String(line)
            }
            return inFence || trimmed.isEmpty ? String(line) : line + "  "
        }.joined(separator: "\n")
    }
}
