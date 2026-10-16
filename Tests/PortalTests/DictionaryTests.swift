import Testing
@testable import Portal

@Suite struct DictionaryTests {
    private func fix(_ text: String, _ entries: DictionaryEntry...) -> String {
        DictionaryCorrector(entries).apply(to: text)
    }

    @Test func replacesPhrase() {
        #expect(fix("I use cloud code every day.", .correction(hear: "cloud code", write: "Claude Code"))
                == "I use Claude Code every day.")
    }

    @Test func ignoresCase() {
        #expect(fix("Cloud Code is great", .correction(hear: "cloud code", write: "Claude Code")) == "Claude Code is great")
    }

    @Test func matchesRunTogetherAndHyphenated() {
        let rule = DictionaryEntry.correction(hear: "cloud code", write: "Claude Code")
        #expect(fix("try CloudCode now", rule) == "try Claude Code now")
        #expect(fix("try cloud-code now", rule) == "try Claude Code now")
    }

    @Test func onlyWholeWords() {
        let rule = DictionaryEntry.correction(hear: "cloud", write: "Claude")
        #expect(fix("Cloudflare and the cloud", rule) == "Cloudflare and the Claude")
        #expect(fix("cloud's edge", rule) == "Claude's edge")
    }

    @Test func longestFirst() {
        #expect(fix("cloud code and cloud",
                    .correction(hear: "cloud", write: "Claude"),
                    .correction(hear: "cloud code", write: "Claude Code")) == "Claude Code and Claude")
    }

    @Test func offEntriesDoNothing() {
        var rule = DictionaryEntry.correction(hear: "cloud code", write: "Claude Code")
        rule.isEnabled = false
        #expect(fix("cloud code", rule) == "cloud code")
    }

    @Test func replacementIsLiteral() {
        #expect(fix("price tag", .correction(hear: "price tag", write: "$1 \\o/")) == "$1 \\o/")
    }

    @Test func accentsMatchInEitherForm() {
        let decomposed = "cafe\u{301} au lait"
        #expect(fix(decomposed, .correction(hear: "café au lait", write: "latte")) == "latte")
    }

    @Test func hintsAreRightSpellingsDedupedAndCapped() {
        let entries: [DictionaryEntry] = [.term("Anthropic"), .correction(hear: "cloud code", write: "Claude Code"),
                                          .term("anthropic")] + (0..<60).map { .term("word\($0)") }
        let hints = DictionaryCorrector.hints(from: entries)
        #expect(hints.prefix(2) == ["Anthropic", "Claude Code"])
        #expect(hints.count == DictionaryCorrector.hintLimit)
    }

    @Test func warnsAboutRisky() {
        #expect(DictionaryEntry.correction(hear: "code", write: "Claude").warning != nil)
        #expect(DictionaryEntry.correction(hear: "gpt", write: "GPT").warning != nil)
        #expect(DictionaryEntry.correction(hear: "Portal", write: "portal").warning != nil)
        #expect(DictionaryEntry.correction(hear: "port all", write: "Portal").warning == nil)
        #expect(DictionaryEntry.term("the").warning == nil)
    }

    @Test func tidyJoinsPieces() {
        #expect(DictationModel.tidy("  Hello  there . How are you ?") == "Hello there. How are you?")
    }
}
