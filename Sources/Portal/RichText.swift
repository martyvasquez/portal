import AppKit
import cmark_gfm
import cmark_gfm_extensions

/// The formatted versions of copied text that apps put on the clipboard beside the plain text:
/// HTML from browsers and Gmail, RTF from apps built on Apple's text system (Notes, TextEdit, Pages).
struct RichContent: Codable, Equatable, Sendable {
    var html: String?
    var rtf: Data?

    /// Bigger versions (a whole document's styles) aren't kept.
    static let maxBytes = 1_000_000

    /// The formatted versions on the clipboard, or nil when it only has plain text.
    static func read(from pb: NSPasteboard) -> RichContent? {
        var rich = RichContent()
        if let html = pb.string(forType: .html), html.utf8.count <= maxBytes { rich.html = html }
        if let rtf = pb.data(forType: .rtf), rtf.count <= maxBytes { rich.rtf = rtf }
        return rich.html == nil && rich.rtf == nil ? nil : rich
    }

    func write(to pb: NSPasteboard) {
        if let html { pb.setString(html, forType: .html) }
        if let rtf { pb.setData(rtf, forType: .rtf) }
    }
}

/// Text for the clipboard: the plain version every app takes, and formatted versions for apps that show formatting.
struct PasteContent: Equatable {
    var text: String
    var rich: RichContent?

    func write(to pb: NSPasteboard) {
        pb.setString(text, forType: .string)
        rich?.write(to: pb)
    }
}

/// Moves text between Markdown and the clipboard's formatted versions. Transformers work in
/// Markdown: formatted selections are turned into it, and results are turned back into whatever
/// the transformer's output asks for, the way ChatGPT's copy button works.
@MainActor
enum RichText {
    // MARK: Markdown → clipboard

    /// What a transformer's Markdown result puts on the clipboard. Original (a plain selection's
    /// format, once resolved by the run) is the text as written.
    static func content(_ markdown: String, as output: TransformOutput) -> PasteContent {
        switch output {
        case .markdown, .original:
            return PasteContent(text: markdown)
        case .plain:
            return PasteContent(text: plainText(fromMarkdown: markdown))
        case .formatted:
            guard let body = formattedBody(markdown) else {
                // Nothing to format. Text converted from a formatted selection can still carry escapes like \*.
                return PasteContent(text: hasEscapes(markdown) ? plainText(fromMarkdown: markdown) : markdown)
            }
            return PasteContent(text: plainText(fromMarkdown: markdown),
                                rich: RichContent(html: htmlPrefix + body, rtf: rtf(fromHTMLBody: body)))
        }
    }

    /// HTML for `markdown`, or nil when it has no formatting to keep (just paragraphs and line breaks).
    nonisolated static func html(fromMarkdown markdown: String) -> String? {
        formattedBody(markdown).map { htmlPrefix + $0 }
    }

    nonisolated private static let htmlPrefix = "<meta charset=\"utf-8\">"

    /// The rendered HTML, when it has formatting. No font is set, so Gmail and other web apps use their own.
    nonisolated private static func formattedBody(_ markdown: String) -> String? {
        guard let body = renderHTML(markdown),
              // Raw HTML in the text is dropped from the rendering; the plain text is better than losing it.
              !body.contains("<!-- raw HTML omitted -->"),
              hasFormatting(body) else { return nil }
        return body
    }

    /// RTF for apps built on Apple's text system, which read it before HTML. Without a font they'd use Times.
    private static func rtf(fromHTMLBody body: String) -> Data? {
        let html = htmlPrefix + "<body style=\"font-family: 'Helvetica Neue', Helvetica, sans-serif; font-size: 13px\">\(body)</body>"
        guard let attr = attributed(html: html) else { return nil }
        let text = NSMutableAttributedString(attributedString: attr)
        while text.string.hasSuffix("\n") { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
        return try? text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    /// Markdown without its markup: headings and bold become plain lines, lists keep "•" and "1.",
    /// table cells are separated by tabs, and links show their address after the text.
    nonisolated static func plainText(fromMarkdown markdown: String) -> String {
        let blocks = MarkdownBlock.parse(markdown)
        guard !blocks.isEmpty else { return markdown }
        var out = ""
        var previous: MarkdownBlock?
        for block in blocks {
            if let previous { out += previous.depth > 0 && block.depth > 0 ? "\n" : "\n\n" }
            out += plain(block)
            previous = block
        }
        return out
    }

    nonisolated private static func plain(_ b: MarkdownBlock) -> String {
        switch b.kind {
        case .table(let rows, _):
            return rows.map { $0.map(linked).joined(separator: "\t") }.joined(separator: "\n")
        case .code:
            return String(b.text.characters).trimmingCharacters(in: .newlines)
        case .paragraph, .header:
            let indent = String(repeating: "    ", count: max(b.depth - 1, 0))
            // An item's later paragraphs line up under its text.
            let prefix = b.marker.map { $0 + " " } ?? (b.depth > 0 ? "  " : "")
            let hang = "\n" + indent + String(repeating: " ", count: prefix.count)
            return indent + prefix + linked(b.text).replacingOccurrences(of: "\n", with: hang)
        }
    }

    /// The text, with each link's address after it when the two differ: "the docs (https://…)".
    nonisolated private static func linked(_ text: AttributedString) -> String {
        text.runs[\.link].map { link, range in
            let s = String(text[range].characters)
            guard let url = link?.absoluteString, url != s, url != "mailto:" + s else { return s }
            return "\(s) (\(url))"
        }.joined()
    }

    nonisolated private static func hasEscapes(_ markdown: String) -> Bool {
        markdown.contains(#/\\[\\`*_{}\[\]()#+\-.!<>|~]/#)
    }

    // MARK: Clipboard → Markdown

    /// Formatted text as Markdown, or nil when it has no formatting worth keeping: it's plain, or
    /// it's all code (a code editor copies its colors as HTML).
    static func markdown(from rich: RichContent) -> String? {
        let attr: NSAttributedString?
        if let html = rich.html {
            attr = attributed(html: html)
        } else if let rtf = rich.rtf {
            attr = NSAttributedString(rtf: rtf, documentAttributes: nil)
        } else {
            attr = nil
        }
        return attr.flatMap(MarkdownWriter.markdown(from:))
    }

    /// Reads HTML with Apple's importer. Images and other remote content are taken out first, so
    /// reading a copied web page never goes to the network.
    private static func attributed(html: String) -> NSAttributedString? {
        var html = html
        for pattern in [#"(?is)<(script|style|iframe|video|audio|object)\b.*?</\1\s*>"#, #"(?i)<(img|link|source|embed|input)\b[^>]*>"#] {
            html = html.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return try? NSAttributedString(data: Data(html.utf8),
                                       options: [.documentType: NSAttributedString.DocumentType.html,
                                                 .characterEncoding: String.Encoding.utf8.rawValue,
                                                 .timeout: 2],
                                       documentAttributes: nil)
    }

    // MARK: cmark

    nonisolated private static let extensions: [String] = {
        cmark_gfm_core_extensions_ensure_registered()
        return ["table", "strikethrough", "autolink", "tasklist"]
    }()

    nonisolated private static func renderHTML(_ markdown: String) -> String? {
        // Hard breaks: single line breaks (an email's sign-off, an address) stay line breaks.
        let options = CMARK_OPT_HARDBREAKS
        guard let parser = cmark_parser_new(options) else { return nil }
        defer { cmark_parser_free(parser) }
        for name in extensions {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        let utf8 = Array(markdown.utf8)
        utf8.withUnsafeBufferPointer { buf in
            buf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                cmark_parser_feed(parser, $0, buf.count)
            }
        }
        guard let doc = cmark_parser_finish(parser) else { return nil }
        defer { cmark_node_free(doc) }
        guard let html = cmark_render_html(doc, options, cmark_parser_get_syntax_extensions(parser)) else { return nil }
        defer { free(html) }
        return String(cString: html)
    }

    /// True when the HTML has any tag besides paragraphs and line breaks.
    nonisolated private static func hasFormatting(_ html: String) -> Bool {
        html.matches(of: #/<\/?([a-zA-Z][a-zA-Z0-9]*)/#).contains { !["p", "br"].contains($0.1.lowercased()) }
    }
}
