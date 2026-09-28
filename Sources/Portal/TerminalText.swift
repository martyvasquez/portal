import Foundation

/// Cleans text copied out of a terminal: TUI borders, Claude Code's ⏺ marker,
/// trailing spaces, shared indentation, and (optionally) prose that the app hard-wrapped.
/// Conservative on purpose: anything that looks like code or a command keeps its line breaks.
enum TerminalText {
    static let terminalBundleIDs: Set<String> = [
        "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
    ]

    static func clean(_ text: String, unwrap: Bool) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        lines = stripBoxBorders(lines)
        lines = lines.map { trimTrailing($0) }
        lines = stripLeadingMarker(lines)
        lines = dedent(lines)
        if unwrap { lines = unwrapProse(lines) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        // Keep a single trailing newline if the original had one (e.g. copied whole lines).
        let joined = lines.joined(separator: "\n")
        return text.hasSuffix("\n") && lines.count > 1 ? joined + "\n" : joined
    }

    private static func trimTrailing(_ s: String) -> String {
        var s = s
        while let last = s.last, last == " " || last == "\t" { s.removeLast() }
        return s
    }

    private static func indent(_ s: String) -> Int { s.prefix { $0 == " " }.count }

    /// `╭──╮ │ text │ ╰──╯` → `text`, when most non-empty lines are framed.
    private static func stripBoxBorders(_ lines: [String]) -> [String] {
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonEmpty.isEmpty else { return lines }
        let edges: Set<Character> = ["│", "┃", "║"]
        let framed = nonEmpty.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return (t.first.map(edges.contains) ?? false) || t.first.map("╭╰┌└╔╚".contains) == true
        }
        guard framed.count * 10 >= nonEmpty.count * 8 else { return lines }
        return lines.compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if let f = t.first, "╭╰┌└╔╚".contains(f) { return nil }   // top/bottom rule
            guard let f = t.first, edges.contains(f) else { return line }
            var inner = t.dropFirst()
            if let l = inner.last, edges.contains(l) { inner = inner.dropLast() }
            if inner.first == " " { inner = inner.dropFirst() }
            return String(inner)
        }
    }

    /// Claude Code starts a response with "⏺ " and indents following lines to match.
    private static func stripLeadingMarker(_ lines: [String]) -> [String] {
        guard let first = lines.first else { return lines }
        let t = first.drop { $0 == " " }
        guard t.hasPrefix("⏺ ") || t.hasPrefix("● ") && lines.count > 1 && lines.dropFirst().allSatisfy({ $0.isEmpty || indent($0) >= 2 }) else {
            return lines
        }
        var out = lines
        out[0] = String(repeating: " ", count: indent(first) + 2) + String(t.dropFirst(2))
        return out
    }

    private static func dedent(_ lines: [String]) -> [String] {
        let common = lines.filter { !$0.isEmpty }.map(indent).min() ?? 0
        guard common > 0 else { return lines }
        return lines.map { $0.isEmpty ? $0 : String($0.dropFirst(common)) }
    }

    private struct Line {
        let raw: String
        let indent: Int
        let marker: Int      // width of a list marker ("- ", "1. "), 0 if none
        var hang: Int { indent + marker }
        var content: Substring { raw.dropFirst(hang) }
    }

    private static let markerPattern = try! NSRegularExpression(pattern: #"^([-*•+]|\d{1,3}[.)])\s+"#)

    private static func parse(_ s: String) -> Line {
        let ind = indent(s)
        let rest = String(s.dropFirst(ind))
        let m = markerPattern.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest))
        return Line(raw: s, indent: ind, marker: m?.range.length ?? 0)
    }

    /// Prose: mostly letters and spaces, several words, no code-ish endings.
    private static func isProse(_ s: Substring) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.contains(" ") || t.count < 25 else { return false }
        if t.hasPrefix("$ ") || t.hasPrefix("> ") || t.hasPrefix("#") || t.hasPrefix("```") { return false }
        if let last = t.last, "{};\\".contains(last) { return false }
        let wordy = t.unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " || ",.'’\"-()?!:".unicodeScalars.contains($0) }.count
        return Double(wordy) / Double(t.unicodeScalars.count) >= 0.85
    }

    /// Joins hard-wrapped prose: a line that ran close to the wrap width, followed by a
    /// continuation aligned with its text (same paragraph or the same list item).
    private static func unwrapProse(_ input: [String]) -> [String] {
        guard input.count > 1 else { return input }
        let width = input.map(\.count).max() ?? 0
        guard width >= 30 else { return input }
        var out: [String] = []
        var current: Line?
        var currentLength = 0   // length of the last physical line merged into `current`

        func flush() { if let c = current { out.append(c.raw) }; current = nil }

        for raw in input {
            if raw.isEmpty { flush(); out.append(raw); continue }
            let line = parse(raw)
            if let c = current,
               line.marker == 0,
               line.indent == c.hang,
               currentLength >= Int(Double(width) * 0.6),
               isProse(c.content), isProse(line.content) {
                current = Line(raw: c.raw + " " + line.content, indent: c.indent, marker: c.marker)
                currentLength = raw.count
                continue
            }
            flush()
            current = line
            currentLength = raw.count
        }
        flush()
        return out
    }
}
