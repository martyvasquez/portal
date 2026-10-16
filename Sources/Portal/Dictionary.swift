import Foundation

/// One thing the dictation dictionary knows. A term is a word the recognizer should expect
/// ("Anthropic"); a correction rewrites what it heard ("cloud code" → "Claude Code").
struct DictionaryEntry: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case term, correction }

    var id = UUID()
    var kind: Kind
    /// The right spelling: the term itself, or what a correction writes.
    var write: String
    /// What a correction replaces. Empty for terms.
    var hear = ""
    /// Off entries stay in the list but change nothing, to test whether one is helping.
    var isEnabled = true

    static func term(_ word: String) -> DictionaryEntry { DictionaryEntry(kind: .term, write: word) }
    static func correction(hear: String, write: String) -> DictionaryEntry {
        DictionaryEntry(kind: .correction, write: write, hear: hear)
    }

    /// Why this entry might fire on text you didn't mean, or nil if it looks safe.
    var warning: String? {
        guard kind == .correction else { return nil }
        let trigger = hear.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty else { return nil }
        if write.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trigger) == .orderedSame {
            return "This replaces “\(trigger)” with itself, so it never changes anything."
        }
        let words = DictionaryCorrector.words(of: trigger.lowercased())
        guard words.count == 1, let only = words.first else { return nil }
        if Self.commonWords.contains(only) {
            return "“\(trigger)” is an everyday word, so every one you say gets replaced. Try a longer phrase."
        }
        if only.count <= 3 { return "“\(trigger)” is short and will match often. Try a longer phrase." }
        return nil
    }

    private static let commonWords: Set<String> = [
        "a", "about", "all", "also", "and", "any", "are", "as", "at", "back", "be", "because", "but", "by",
        "call", "can", "case", "check", "class", "close", "cloud", "code", "come", "could", "data", "day",
        "did", "do", "does", "down", "each", "even", "file", "find", "first", "for", "from", "get", "give",
        "go", "good", "great", "group", "had", "has", "have", "he", "her", "here", "him", "his", "how", "if",
        "in", "into", "is", "it", "its", "just", "key", "know", "like", "line", "list", "look", "make", "man",
        "many", "may", "me", "more", "most", "my", "need", "new", "no", "not", "now", "number", "of", "off",
        "on", "one", "only", "open", "or", "other", "our", "out", "over", "page", "part", "people", "point",
        "put", "read", "right", "run", "said", "same", "say", "see", "set", "she", "should", "show", "side",
        "so", "some", "state", "still", "such", "take", "team", "test", "than", "that", "the", "their",
        "them", "then", "there", "these", "they", "thing", "think", "this", "time", "to", "two", "type", "up",
        "us", "use", "user", "very", "want", "was", "way", "we", "well", "were", "what", "when", "where",
        "which", "who", "will", "with", "word", "work", "would", "year", "you", "your",
    ]
}

/// Applies the dictionary's corrections to finished text. Recognizer hints only make a word
/// likelier; this is what guarantees the spelling.
///
/// Longer triggers run first, so "Claude Code" wins over "Claude". Triggers only match whole
/// words, so "cloud code" never touches "Cloudflare". Case doesn't matter, and the parts of a
/// phrase may be run together or hyphenated ("CloudCode", "cloud-code").
struct DictionaryCorrector {
    private let rules: [(regex: NSRegularExpression, template: String)]

    init(_ entries: [DictionaryEntry]) {
        rules = entries
            .filter { $0.isEnabled && $0.kind == .correction }
            .compactMap { entry -> (Int, NSRegularExpression, String)? in
                let parts = Self.words(of: entry.hear.precomposedStringWithCanonicalMapping)
                guard !parts.isEmpty else { return nil }
                let body = parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "[\\s\\-]*")
                // Lookarounds rather than \b, which treats a hyphen or apostrophe as a word edge.
                guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\(body)(?![\\p{L}\\p{N}])",
                                                           options: .caseInsensitive) else { return nil }
                return (parts.joined().count, regex, NSRegularExpression.escapedTemplate(for: entry.write))
            }
            .sorted { $0.0 > $1.0 }
            .map { ($0.1, $0.2) }
    }

    func apply(to text: String) -> String {
        // macOS hands back decomposed accents in places; match in one normal form.
        var result = text.precomposedStringWithCanonicalMapping
        for rule in rules {
            result = rule.regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                         withTemplate: rule.template)
        }
        return result
    }

    static func words(of s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init)
    }

    /// At most this many words go to the recognizer. Long hint lists make it "hear" them in
    /// quiet or unclear audio, which is worse than the misspelling they prevent.
    static let hintLimit = 40

    /// Right spellings for the recognizer to expect: terms and what corrections write, in list order.
    static func hints(from entries: [DictionaryEntry]) -> [String] {
        var seen = Set<String>()
        var hints: [String] = []
        for entry in entries where entry.isEnabled {
            let phrase = entry.write.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty, seen.insert(phrase.lowercased()).inserted else { continue }
            hints.append(phrase)
            if hints.count == hintLimit { break }
        }
        return hints
    }
}
