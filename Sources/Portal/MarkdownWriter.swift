import AppKit

/// Writes formatted text (read from the clipboard's HTML or RTF) as Markdown: headings, bold,
/// italics, strikethrough, code, links, lists, and tables.
enum MarkdownWriter {
    /// Markdown for `attr`, or nil when it has no formatting worth keeping (plain text, or all code).
    static func markdown(from attr: NSAttributedString) -> String? {
        let paragraphs = Paragraph.split(attr)
        let body = bodySize(attr, paragraphs)
        var writer = Writer(attr: attr)
        var i = 0
        while i < paragraphs.count {
            let p = paragraphs[i]
            switch p.kind(attr, body: body) {
            case .blank:
                writer.blank()
                i += 1
            case .cell(let table):
                var cells: [Paragraph] = []
                while i < paragraphs.count, paragraphs[i].table?.table === table { cells.append(paragraphs[i]); i += 1 }
                writer.table(cells)
            case .code:
                var lines: [Paragraph] = []
                while i < paragraphs.count, paragraphs[i].kind(attr, body: body) == .code { lines.append(paragraphs[i]); i += 1 }
                writer.code(lines)
            case .heading(let level):
                writer.heading(p, level: level)
                i += 1
            case .item(let depth, let marker):
                writer.item(p, depth: depth, marker: marker)
                i += 1
            case .paragraph:
                writer.paragraph(p)
                i += 1
            }
        }
        guard writer.formatted else { return nil }
        return writer.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The most common text size, which headings are measured against.
    private static func bodySize(_ attr: NSAttributedString, _ paragraphs: [Paragraph]) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        for p in paragraphs {
            attr.enumerateAttribute(.font, in: p.range) { value, range, _ in
                if let font = value as? NSFont, !font.isMono { counts[font.pointSize, default: 0] += range.length }
            }
        }
        return counts.max { $0.value < $1.value }?.key ?? 12
    }
}

private extension NSFont {
    var isMono: Bool { fontDescriptor.symbolicTraits.contains(.monoSpace) || isFixedPitch }
}

// MARK: - Paragraphs

private enum Kind: Equatable {
    case blank, paragraph, code
    case heading(Int)
    case item(depth: Int, marker: String)
    case cell(NSTextTable)

    static func == (a: Kind, b: Kind) -> Bool {
        switch (a, b) {
        case (.blank, .blank), (.paragraph, .paragraph), (.code, .code): true
        case let (.heading(x), .heading(y)): x == y
        case let (.item(d1, m1), .item(d2, m2)): d1 == d2 && m1 == m2
        case let (.cell(x), .cell(y)): x === y
        default: false
        }
    }
}

private struct Paragraph {
    /// The text, without its line ending or a list's "\t•\t" marker.
    var range: NSRange
    var style: NSParagraphStyle?
    var table: NSTextTableBlock?

    static func split(_ attr: NSAttributedString) -> [Paragraph] {
        let s = attr.string as NSString
        var out: [Paragraph] = []
        var location = 0
        while location < s.length {
            let full = s.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(full)
            var range = full
            while range.length > 0, let last = UnicodeScalar(s.character(at: NSMaxRange(range) - 1)),
                  CharacterSet.newlines.contains(last) {
                range.length -= 1
            }
            let style = attr.attribute(.paragraphStyle, at: full.location, effectiveRange: nil) as? NSParagraphStyle
            // Imported lists put their marker in the text, between tabs.
            if style?.textLists.isEmpty == false, s.substring(with: range).hasPrefix("\t") {
                let marker = s.range(of: "\t", range: NSRange(location: range.location + 1, length: range.length - 1))
                if marker.location != NSNotFound {
                    let start = NSMaxRange(marker)
                    range = NSRange(location: start, length: NSMaxRange(range) - start)
                }
            }
            let table = style?.textBlocks.lazy.compactMap { $0 as? NSTextTableBlock }.first
            out.append(Paragraph(range: range, style: style, table: table))
        }
        return out
    }

    func text(_ attr: NSAttributedString) -> String { (attr.string as NSString).substring(with: range) }

    func kind(_ attr: NSAttributedString, body: CGFloat) -> Kind {
        let text = text(attr)
        if let table { return .cell(table.table) }
        if text.trimmingCharacters(in: .whitespaces.union(["\u{FFFC}", "\u{00A0}", "\u{2028}"])).isEmpty { return .blank }
        if let lists = style?.textLists, let list = lists.last {
            let unordered: Set<NSTextList.MarkerFormat> = [.disc, .circle, .square, .box, .check, .diamond, .hyphen]
            let marker = unordered.contains(list.markerFormat) ? "-" : "\(attr.itemNumber(in: list, at: range.location))."
            return .item(depth: lists.count, marker: marker)
        }
        var fonts: [NSFont] = []
        attr.enumerateAttribute(.font, in: range) { value, r, _ in
            let part = (attr.string as NSString).substring(with: r)
            if let font = value as? NSFont, !part.trimmingCharacters(in: .whitespaces).isEmpty { fonts.append(font) }
        }
        if !fonts.isEmpty, fonts.allSatisfy(\.isMono) { return .code }
        // A short line in bigger or bold-and-bigger type is a heading.
        if let size = fonts.map(\.pointSize).min(), text.count <= 200, !text.contains("\u{2028}") {
            let ratio = size / body
            let bold = fonts.allSatisfy { $0.fontDescriptor.symbolicTraits.contains(.bold) }
            if ratio >= 1.6 { return .heading(1) }
            if ratio >= 1.3 { return .heading(2) }
            if ratio >= 1.1 && bold { return .heading(3) }
        }
        return .paragraph
    }

    /// Space after it, or before the next: separate paragraphs, not lines of one.
    var spaced: Bool { (style?.paragraphSpacing ?? 0) > 0 }
    var spacedBefore: Bool { (style?.paragraphSpacingBefore ?? 0) > 0 }
}

// MARK: - Writing

private struct Writer {
    let attr: NSAttributedString
    var out = ""
    /// Something only Markdown can say: a heading, list, table, link, or styled text.
    var formatted = false
    private var last: Last = .start

    private enum Last { case start, blank, paragraph(spaced: Bool), block, item }

    init(attr: NSAttributedString) { self.attr = attr }

    mutating func blank() {
        if case .start = last { return }
        last = .blank
    }

    /// The line break or blank line before the next block.
    private mutating func separate(_ p: Paragraph?, item: Bool = false, block: Bool = false) {
        switch last {
        case .start: break
        case .blank, .block: out += "\n\n"
        case .item: out += item ? "\n" : "\n\n"
        case .paragraph(let spaced): out += spaced || block || item || p?.spacedBefore == true ? "\n\n" : "\n"
        }
    }

    mutating func paragraph(_ p: Paragraph) {
        separate(p)
        out += escapeLineStart(inline(p.range))
        last = .paragraph(spaced: p.spaced)
    }

    mutating func heading(_ p: Paragraph, level: Int) {
        separate(p, block: true)
        out += String(repeating: "#", count: level) + " " + inline(p.range, plainWeight: true)
        formatted = true
        last = .block
    }

    mutating func item(_ p: Paragraph, depth: Int, marker: String) {
        separate(p, item: true)
        let indent = String(repeating: "    ", count: depth - 1)
        let text = inline(p.range).replacingOccurrences(of: "\n", with: "\n" + indent + String(repeating: " ", count: marker.count + 1))
        out += indent + marker + " " + text
        formatted = true
        last = .item
    }

    mutating func code(_ lines: [Paragraph]) {
        separate(nil, block: true)
        let text = lines.map { $0.text(attr).replacingOccurrences(of: "\u{2028}", with: "\n") }.joined(separator: "\n")
        let fence = text.contains("```") ? "~~~" : "```"
        out += fence + "\n" + text + "\n" + fence
        last = .block
    }

    mutating func table(_ cells: [Paragraph]) {
        separate(nil, block: true)
        var grid: [[String]] = []
        for cell in cells {
            guard let block = cell.table else { continue }
            let row = block.startingRow, column = block.startingColumn
            while grid.count <= row { grid.append([]) }
            while grid[row].count <= column { grid[row].append("") }
            // The header row is bold already.
            let text = inline(cell.range, plainWeight: row == 0)
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
            grid[row][column] += grid[row][column].isEmpty ? text : " " + text
        }
        grid.removeAll(where: \.isEmpty)
        let columns = grid.map(\.count).max() ?? 0
        guard columns > 0 else { return }
        func line(_ cells: [String]) -> String {
            "| " + (cells + Array(repeating: "", count: columns - cells.count)).joined(separator: " | ") + " |"
        }
        var lines = [line(grid[0]), line(Array(repeating: "---", count: columns))]
        lines += grid.dropFirst().map(line)
        out += lines.joined(separator: "\n")
        formatted = true
        last = .block
    }

    // MARK: Inline

    private struct Style: Equatable {
        var bold = false, italic = false, code = false, strike = false
    }

    /// The text in `range` with its bold, italics, code, strikethrough, and links as Markdown.
    /// `plainWeight` leaves out bold, for headings, which are bold already.
    private mutating func inline(_ range: NSRange, plainWeight: Bool = false) -> String {
        let s = attr.string as NSString
        let whole = s.substring(with: range)
        // Escape only what could pair up into formatting: "5*3" stays as it is.
        let escaped = Set("*~`".filter { c in whole.filter { $0 == c }.count >= 2 })

        var runs: [(text: String, style: Style, link: String?)] = []
        attr.enumerateAttributes(in: range) { attrs, r, _ in
            var style = Style()
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                style.bold = traits.contains(.bold) && !plainWeight
                style.italic = traits.contains(.italic)
                style.code = font.isMono
            }
            if (attrs[.obliqueness] as? NSNumber)?.doubleValue ?? 0 > 0 { style.italic = true }
            if (attrs[.strikethroughStyle] as? NSNumber)?.intValue ?? 0 != 0 { style.strike = true }
            let link = (attrs[.link] as? URL)?.absoluteString ?? attrs[.link] as? String
            let text = s.substring(with: r)
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "\u{2028}", with: "\n")
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            runs.append((text, style, link))
        }

        var result = ""
        var i = 0
        while i < runs.count {
            let link = runs[i].link
            var group = ""
            var plainGroup = ""
            // Runs in one link, then runs with one style.
            while i < runs.count, runs[i].link == link {
                let style = runs[i].style
                var text = ""
                while i < runs.count, runs[i].link == link, runs[i].style == style { text += runs[i].text; i += 1 }
                group += styled(text, style, escaping: escaped, inLink: link != nil)
                plainGroup += text
            }
            if let link, !link.isEmpty {
                formatted = true
                let label = group.trimmingCharacters(in: .whitespaces)
                if plainGroup.trimmingCharacters(in: .whitespaces) == link || "mailto:" + plainGroup == link {
                    result += plainGroup
                } else {
                    let target = link.contains(where: { $0 == " " || $0 == "(" || $0 == ")" }) ? "<\(link)>" : link
                    let lead = String(group.prefix { $0 == " " }), trail = String(group.reversed().prefix { $0 == " " })
                    result += lead + "[\(label)](\(target))" + trail
                }
            } else {
                result += group
            }
        }
        return result
    }

    private mutating func styled(_ text: String, _ style: Style, escaping: Set<Character>, inLink: Bool) -> String {
        if style.code {
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return text }
            formatted = true
            let tick = text.contains("`") ? "``" : "`"
            return tick + text + tick
        }
        var body = ""
        for c in text {
            if escaping.contains(c) || (inLink && (c == "[" || c == "]")) { body.append("\\") }
            body.append(c)
        }
        // "<b>" in the text would read as HTML.
        body = body.replacingOccurrences(of: #"<(?=[A-Za-z/!?])"#, with: "\\\\<", options: .regularExpression)
        let open = (style.strike ? "~~" : "") + (style.bold ? "**" : "") + (style.italic ? "*" : "")
        guard !open.isEmpty else { return body }
        formatted = true
        let close = String(open.reversed())
        // Markers hug the words: "**bold** text", never "**bold **text". Each line is wrapped on its own.
        return body.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let core = line.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { return String(line) }
            let lead = String(line.prefix { $0 == " " }), trail = String(line.reversed().prefix { $0 == " " })
            return lead + open + core + close + trail
        }.joined(separator: "\n")
    }

    /// "# not a heading", "- not a list", "1. not a list": text that would turn into Markdown at a line's start.
    private func escapeLineStart(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var l = String(line)
            if l.range(of: #"^\s*(#{1,6}\s|[-+]\s|>|\d+[.)]\s)"#, options: .regularExpression) != nil {
                if let i = l.firstIndex(where: { !$0.isWhitespace }) {
                    if l[i].isNumber, let dot = l[i...].firstIndex(where: { $0 == "." || $0 == ")" }) {
                        l.insert("\\", at: dot)
                    } else {
                        l.insert("\\", at: i)
                    }
                }
            }
            return l
        }.joined(separator: "\n")
    }
}
