import Testing
import Foundation
import CryptoKit
import AppKit
@testable import Portal

@Suite struct FuzzyTests {
    private func rank(_ q: String, _ names: [String]) -> [String] {
        let items = names.map { LaunchItem(id: "/tmp/\($0)", name: $0, path: "/tmp/\($0)", kind: .app) }
        return Ranker.rank(query: Array(q.utf8), items: items, usage: [:], limit: 10).map(\.name)
    }

    @Test func prefixBeatsScattered() {
        #expect(rank("appl", ["some-apple-thing", "app-launcher", "maple"]).first == "app-launcher")
    }

    @Test func exactBeatsLonger() {
        #expect(rank("portal", ["portal-web", "portal"]).first == "portal")
    }

    @Test func noMatchIsExcluded() {
        #expect(rank("xyz", ["app-launcher"]).isEmpty)
    }

    @Test func frecencyBreaksTies() {
        let a = LaunchItem(id: "/x/api", name: "api", path: "/x/api", kind: .app)
        let b = LaunchItem(id: "/y/api", name: "api", path: "/y/api", kind: .app)
        let usage = ["/y/api": UsageEntry(count: 5, last: Date())]
        #expect(Ranker.rank(query: Array("api".utf8), items: [a, b], usage: usage, limit: 5).first?.path == "/y/api")
    }

    @Test func nameMatchBeatsFrequentKeywordMatch() {
        let polish = LaunchItem(id: "transform:polish", name: "Polish", subtitle: "Polish and refine {selection}",
                                path: "", kind: .transform, keywords: "transform transformer ai")
        let custom = LaunchItem(id: "transform:custom", name: "Transform with Prompt…", path: "", kind: .transform)
        let usage = ["transform:polish": UsageEntry(count: 200, last: Date())]
        #expect(Ranker.rank(query: Array("trans".utf8), items: [polish, custom], usage: usage, limit: 5).first?.id == "transform:custom")
    }
}

@Suite struct SecretTests {
    // Split so the fake keys don't trip GitHub's secret scanning.
    static let fakeSecrets: [String] = [
        "sk-" + "ant-api03-abcdefghijklmnopqrstuvwxyz0123456789",
        "gh" + "p_abcdefghijklmnopqrstuvwxyz0123456789AB",
        "AKIA" + "IOSFODNN7EXAMPLE",
        "sk_" + "live_51HabcdefghijklmnopQRST",
        "xo" + "xb-1234567890-abcdefghij",
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
        "q8Vd7mX2pL9wK4zR1tY6uN3bC5hJ0gF8sA7eD2",
    ]

    @Test(arguments: fakeSecrets)
    func detectsSecrets(_ s: String) { #expect(SecretDetector.looksSecret(s)) }

    @Test(arguments: [
        "hello world this is a sentence",
        "https://github.com/anthropics/claude-code/pull/1234",
        "/Users/martyvasquez/Development/app-launcher",
        "4b825dc642cb6eb9a060e54bf8d69288fbee4904",   // git sha: no uppercase
        "const x = someFunctionCall(argument)",
    ])
    func ignoresNormalText(_ s: String) { #expect(!SecretDetector.looksSecret(s)) }

    @Test func masking() {
        #expect(SecretDetector.mask("sk-abcdefghijklmnop1234") == "sk-a••••••••1234")
    }
}

@Suite struct StorageTests {
    @Test func fileNameRoundTrip() throws {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_790_000_000.123)
        let name = ClipFileName.make(created: date, id: id, secret: true)
        let parsed = try #require(ClipFileName.parse(name))
        #expect(parsed.id == id && parsed.secret)
        #expect(abs(parsed.created.timeIntervalSince(date)) < 0.002)
        #expect(ClipFileName.parse(ClipFileName.make(created: date, id: id, secret: false))?.secret == false)
        // Clips pinned by older versions still read.
        #expect(ClipFileName.parse("1790000000123_\(id.uuidString)_ps.clip")?.secret == true)
        #expect(ClipFileName.parse("settings.json") == nil)
    }

    @Test func encryptionRoundTripAndWrongKey() throws {
        let salt = Crypto.randomBytes(16)
        let key = Crypto.deriveKey(passphrase: "correct horse", salt: salt, iterations: 1000)
        let same = Crypto.deriveKey(passphrase: "correct horse", salt: salt, iterations: 1000)
        let wrong = Crypto.deriveKey(passphrase: "wrong horse", salt: salt, iterations: 1000)
        let sealed = try Crypto.seal(Data("secret".utf8), key: key)
        #expect(try Crypto.open(sealed, key: same) == Data("secret".utf8))
        #expect(throws: (any Error).self) { try Crypto.open(sealed, key: wrong) }
    }
}

@Suite struct QuicklinkTests {
    @Test func folderLinkExpandsTilde() {
        let link = Quicklink(name: "Dev", link: "~/Development")
        #expect(link.isFolder)
        #expect(link.resolvedURL()?.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Development").path)
        #expect(link.appName == "Finder")
    }

    @Test func urlQueryIsEncoded() {
        let link = Quicklink(name: "GH", link: "https://github.com/search?q={query}", appPath: "/Applications/Google Chrome.app")
        #expect(link.needsQuery && !link.isFolder)
        #expect(link.resolvedURL(query: "swift & rust")?.absoluteString == "https://github.com/search?q=swift%20%26%20rust")
        #expect(link.appName == "Google Chrome")
    }

    @Test func quicklinksSavedBeforeScopesLoadAsGlobal() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Dev","link":"~/Development","appPath":"/Applications/Ghostty.app"}"#
        let link = try JSONDecoder().decode(Quicklink.self, from: Data(json.utf8))
        #expect(link.name == "Dev" && link.appPath == "/Applications/Ghostty.app" && link.isGlobal && link.excludedApps.isEmpty)
    }

    @Test func quicklinkScopeRoundTrips() throws {
        var link = Quicklink(name: "Ticket", link: "https://bytelaunch.atlassian.net/browse/{query}")
        link.sites = ["*.atlassian.net"]
        link.hotKey = KeyCombo.clipboardDefault
        let back = try JSONDecoder().decode(Quicklink.self, from: JSONEncoder().encode(link))
        #expect(back == link)
        #expect(back.applies(app: "com.google.Chrome", url: URL(string: "https://bytelaunch.atlassian.net/jira")))
        #expect(!back.applies(app: "com.apple.mail", url: nil))
    }

    @Test func bareDomainGetsScheme() {
        #expect(Quicklink(name: "x", link: "news.ycombinator.com").resolvedURL()?.absoluteString == "https://news.ycombinator.com")
    }

    @Test func quicklinksOutrankApps() {
        let app = LaunchItem(id: "/Applications/Dev.app", name: "Developer", path: "/Applications/Dev.app", kind: .app)
        let link = LaunchItem(id: "q1", name: "Development", subtitle: "~/Development", path: "", kind: .quicklink)
        #expect(Ranker.rank(query: Array("dev".utf8), items: [app, link], usage: [:], limit: 5).first?.id == "q1")
    }

    @Test func oldSettingsFileStillDecodes() throws {
        let json = #"{"folderRoots":["~"],"clipboardRetentionDays":3}"#
        let s = try JSONDecoder().decode(SharedSettings.self, from: Data(json.utf8))
        #expect(s.clipboardRetentionDays == 3)
        #expect(!s.quicklinks.isEmpty)
        #expect(s.pinned.isEmpty && s.recentLimit == 8 && s.recentLimitWithMatches == 3)
    }

    @Test func onlyMatchingTransformersBecomesNoRecentsBelowMatches() throws {
        let only = try JSONDecoder().decode(SharedSettings.self, from: Data(#"{"transformerListing":"onlyMatches"}"#.utf8))
        #expect(only.recentLimitWithMatches == 0)
        let first = try JSONDecoder().decode(SharedSettings.self, from: Data(#"{"transformerListing":"matchesFirst"}"#.utf8))
        #expect(first.recentLimitWithMatches == 3)
        let set = try JSONDecoder().decode(SharedSettings.self,
                                           from: Data(#"{"transformerListing":"onlyMatches","recentLimitWithMatches":5}"#.utf8))
        #expect(set.recentLimitWithMatches == 5)
    }
}

@Suite struct TerminalTextTests {
    @Test func claudeCodeResponseIsUnwrapped() {
        let copied = """
        ⏺ The launcher now reads the Finder selection when Finder is the front app, and the
          first row opens that folder in Ghostty.

          - Selected files open their parent folder, and with nothing selected the front
            window's folder is used.
          - Multiple folders each get a row.
        """
        let expected = """
        The launcher now reads the Finder selection when Finder is the front app, and the first row opens that folder in Ghostty.

        - Selected files open their parent folder, and with nothing selected the front window's folder is used.
        - Multiple folders each get a row.
        """
        #expect(TerminalText.clean(copied, unwrap: true) == expected)
    }

    @Test func codeKeepsLineBreaks() {
        let code = """
            func hello() {
                print("hi")
            }
        """
        #expect(TerminalText.clean(code, unwrap: true) == "func hello() {\n    print(\"hi\")\n}")
    }

    @Test func commandsStaySeparate() {
        let cmds = "$ swift build -c release --arch arm64 --show-bin-path   \n$ scripts/build.sh --install"
        #expect(TerminalText.clean(cmds, unwrap: true) == "$ swift build -c release --arch arm64 --show-bin-path\n$ scripts/build.sh --install")
    }

    @Test func boxBordersRemoved() {
        let box = """
        ╭────────────────────────╮
        │ npm install portal     │
        │ npm run dev            │
        ╰────────────────────────╯
        """
        #expect(TerminalText.clean(box, unwrap: true) == "npm install portal\nnpm run dev")
    }

    @Test func shortLinesNotJoined() {
        let list = "apples\noranges\npears"
        #expect(TerminalText.clean(list, unwrap: true) == list)
    }
}

@Suite struct OpenWithTests {
    @Test func legacyFinderAppBecomesDefaultFolderApp() throws {
        let json = #"{"finderSelectionAppPath":"/Applications/Sublime Text.app"}"#
        let s = try JSONDecoder().decode(SharedSettings.self, from: Data(json.utf8))
        #expect(s.folderOpenWith.first == "/Applications/Sublime Text.app")
        #expect(s.folderOpenWith.filter { $0 == "/Applications/Sublime Text.app" }.count == 1)
    }

    @Test func savedListsWinOverLegacy() throws {
        let json = #"{"finderSelectionAppPath":"/x/Old.app","folderOpenWith":["/x/New.app"]}"#
        let s = try JSONDecoder().decode(SharedSettings.self, from: Data(json.utf8))
        #expect(s.folderOpenWith == ["/x/New.app"])
    }
}

@Suite struct FinderClassifyTests {
    @Test func foldersFilesAndExcludedTypes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portal-classify-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("project")
        let app = root.appendingPathComponent("Thing.app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let readme = folder.appendingPathComponent("README.md")
        let png = folder.appendingPathComponent("shot.PNG")
        try Data().write(to: readme)
        try Data().write(to: png)
        defer { try? FileManager.default.removeItem(at: root) }

        let (folders, files) = FinderSelection.classify(
            [folder.path, readme.path, png.path, app.path], excludedTypes: [".png", "app"])
        // The png is excluded → its folder, which is already listed, so no duplicate.
        #expect(folders.map(\.lastPathComponent) == ["project", root.lastPathComponent])
        #expect(files.map(\.lastPathComponent) == ["README.md"])
    }
}

@Suite struct FolderSnippetTests {
    private func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portal-repo-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try #"{"scripts":{"lint":"eslint .","dev":"vite","build":"vite build"}}"#.write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try Data().write(to: root.appendingPathComponent("pnpm-lock.yaml"))
        try "build:\n\tswift build\n.PHONY: build\ndeploy: build\n\t./deploy\nVAR := 1\n".write(to: root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(to: root.appendingPathComponent("scripts/build.sh"), atomically: true, encoding: .utf8)
        try Data().write(to: root.appendingPathComponent("Package.swift"))
        return root
    }

    @Test func detectsCommonCommands() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let texts = CommandDetector.detect(in: root).map(\.text)
        #expect(texts == ["pnpm dev", "pnpm build", "pnpm lint", "make build", "make deploy",
                          "scripts/build.sh", "swift build", "swift test"])
    }

    @Test func seedAddsOnlyNewAndRespectsEditsAndDeletions() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try PortalFile.seed(at: root, with: CommandDetector.detect(in: root))
        #expect(first == 8)

        // Hand edits: rename one, delete another, add a custom command.
        let url = root.appendingPathComponent(PortalFile.name)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var snippets = json["snippets"] as! [[String: Any]]
        snippets[0]["name"] = "Dev server"
        snippets.removeAll { $0["text"] as? String == "make deploy" }
        snippets.append(["name": "Demo", "text": "open -n build/Debug/App.app --args -demo"])
        json["snippets"] = snippets
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        // A new script appears, then Update runs.
        try #"{"scripts":{"lint":"eslint .","dev":"vite","build":"vite build","e2e":"playwright"}}"#
            .write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let second = try PortalFile.seed(at: root, with: CommandDetector.detect(in: root))
        #expect(second == 1)

        let file = try PortalFile.load(url)
        let texts = file.snippets.map(\.text)
        #expect(texts.contains("pnpm e2e"))
        #expect(!texts.contains("make deploy"))                       // deleted stays deleted
        #expect(file.snippets.first?.name == "Dev server")             // edit kept
        #expect(texts.contains("open -n build/Debug/App.app --args -demo"))
    }

    @Test func findsFileFromSubfolderAndRootFromGit() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("Sources/App")
        #expect(PortalFile.projectRoot(for: sub).standardizedFileURL == root.standardizedFileURL)
        try PortalFile.seed(at: root, with: [("x", "echo x")])
        #expect(PortalFile.find(from: sub)?.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
    }

    @Test func brokenFileIsReportedNotOverwritten() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(PortalFile.name)
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try PortalFile.load(url) }
        #expect(throws: (any Error).self) { try PortalFile.seed(at: root, with: [("x", "echo x")]) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }
}

@Suite struct SiteSnippetTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test func hostIncludesSubdomainsAndWww() {
        #expect(SiteMatcher.matches("github.com", url("https://github.com/martyvasquez/portal")))
        #expect(SiteMatcher.matches("github.com", url("https://gist.github.com/x")))
        #expect(SiteMatcher.matches("www.github.com", url("https://github.com/")))
        #expect(!SiteMatcher.matches("github.com", url("https://notgithub.com/")))
        #expect(!SiteMatcher.matches("github.com", url("https://github.company.com/")))
    }

    @Test func wildcardAndScheme() {
        #expect(SiteMatcher.matches("*.atlassian.net", url("https://bytelaunch.atlassian.net/jira/")))
        #expect(SiteMatcher.matches("https://docs.google.com/", url("https://docs.google.com/document/d/1")))
    }

    @Test func pathPrefixIsWholeSegments() {
        #expect(SiteMatcher.matches("github.com/martyvasquez", url("https://github.com/martyvasquez/portal")))
        #expect(SiteMatcher.matches("github.com/martyvasquez", url("https://github.com/MartyVasquez")))
        #expect(!SiteMatcher.matches("github.com/martyvasquez", url("https://github.com/martyvasquezz")))
        #expect(!SiteMatcher.matches("github.com/martyvasquez", url("https://github.com/anthropics")))
    }

    @Test func labelDropsWww() {
        #expect(SiteMatcher.label(url("https://www.google.com/search?q=x")) == "google.com")
    }

    @Test func globalSnippetHidesWhereExcluded() throws {
        var s = Snippet(name: "Sig", text: "— Marty")
        s.excludedApps = ["com.mitchellh.ghostty"]
        #expect(!s.applies(app: "com.mitchellh.ghostty", url: nil))
        #expect(s.applies(app: "com.apple.mail", url: nil))
        let back = try JSONDecoder().decode(Snippet.self, from: JSONEncoder().encode(s))
        #expect(back.excludedApps == ["com.mitchellh.ghostty"])
        s.apps = ["com.apple.mail"]
        s.dropUnusedExclusions()
        #expect(s.excludedApps.isEmpty)
    }

    @Test func oldSnippetsWithoutSitesStillLoad() throws {
        let json = #"{"snippets":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Email","text":"a@b.co","apps":[]}]}"#
        let s = try JSONDecoder().decode(SharedSettings.self, from: Data(json.utf8))
        #expect(s.snippets.count == 1)
        #expect(s.snippets[0].sites.isEmpty && s.snippets[0].isGlobal)
    }
}

@Suite struct QuicklinkAppTests {
    @Test func defaultAndExplicitFinderAreTheSame() {
        let implicit = Quicklink(name: "a", link: "~/Downloads")
        let explicit = Quicklink(name: "b", link: "~/Development", appPath: Quicklink.finderPath)
        #expect(implicit.resolvedAppPath == Quicklink.finderPath)
        #expect(explicit.resolvedAppPath == Quicklink.finderPath)
        #expect(!implicit.hasAlternateApp && !explicit.hasAlternateApp)   // ⌘↩ would just reopen Finder
    }

    @Test func otherAppHasFinderAsAlternate() {
        let ghostty = Quicklink(name: "c", link: "~/Development/lsc-brain", appPath: "/Applications/Ghostty.app")
        #expect(ghostty.resolvedAppPath == "/Applications/Ghostty.app")
        #expect(ghostty.hasAlternateApp)
    }
}

@Suite struct TransformerTests {
    let context = TransformPrompt.Context(app: "Mail", url: URL(string: "https://example.com/a"), clipboard: "clip")

    @Test func fillsVariables() {
        let p = TransformPrompt.render("Polish {selection} for {app} on {url} with {clipboard}", text: "hi there", context: context)
        #expect(p == "Polish hi there for Mail on https://example.com/a with clip")
    }

    @Test func appendsTextWhenPromptDoesNotUseIt() {
        #expect(TransformPrompt.render("Make this shorter.\n", text: "long text", context: context) == "Make this shorter.\n\nlong text")
    }

    @Test func selectionIsInsertedLiterally() {
        // Braces in the selected text aren't treated as variables.
        let p = TransformPrompt.render("Fix: {selection}", text: "use {app} and {url}", context: context)
        #expect(p == "Fix: use {app} and {url}")
    }

    @Test func olderSettingsGetStarterTransformers() throws {
        let v = try JSONDecoder().decode(SharedSettings.self, from: Data(#"{"includeApps": false}"#.utf8))
        #expect(v.transformers.map(\.name) == Transformer.starters.map(\.name))
        #expect(v.customPromptAction == .preview)
        #expect(v.aiModel == nil)
    }

    @Test func deletedStartersStayDeleted() throws {
        var v = SharedSettings()
        v.transformers = []
        let round = try JSONDecoder().decode(SharedSettings.self, from: JSONEncoder().encode(v))
        #expect(round.transformers.isEmpty)
    }

    @Test func transformerToleratesMissingFields() throws {
        let t = try JSONDecoder().decode(Transformer.self, from: Data(#"{"name": "X", "prompt": "Do {selection}", "action": "teleport"}"#.utf8))
        #expect(t.name == "X" && t.action == .preview && t.hotKey == nil && t.model == nil)
    }

    @Test func scopedTransformerShowsOnlyInItsAppsOrSites() {
        var t = Transformer(name: "Reply", prompt: "x")
        #expect(t.applies(app: "com.apple.finder", url: nil))
        t.apps = ["com.apple.mail"]
        t.sites = ["github.com"]
        #expect(t.applies(app: "com.apple.mail", url: nil))
        #expect(t.applies(app: "com.google.Chrome", url: URL(string: "https://gist.github.com/x")))
        #expect(!t.applies(app: "com.google.Chrome", url: URL(string: "https://gitlab.com")))
        #expect(!t.applies(app: "com.sublimetext.4", url: nil))
    }

    @Test func scopesThatCanMeetOverlap() {
        let global = Transformer(name: "A", prompt: "x")
        var mail = Transformer(name: "B", prompt: "x"); mail.apps = ["com.apple.mail"]
        var sublime = Transformer(name: "C", prompt: "x"); sublime.apps = ["com.sublimetext.4"]
        var github = Transformer(name: "D", prompt: "x"); github.sites = ["github.com"]
        var gist = Transformer(name: "E", prompt: "x"); gist.sites = ["gist.github.com/me"]
        var chrome = Transformer(name: "F", prompt: "x"); chrome.apps = ["com.google.Chrome"]
        #expect(global.overlaps(mail))
        #expect(!mail.overlaps(sublime))
        #expect(!mail.overlaps(github))
        #expect(github.overlaps(gist))
        #expect(chrome.overlaps(github))
        var gitlab = Transformer(name: "G", prompt: "x"); gitlab.sites = ["gitlab.com"]
        #expect(!github.overlaps(gitlab))
    }

    @Test func scopesOverlapAcrossKinds() {
        var github = Quicklink(name: "PRs", link: "https://github.com/pulls"); github.sites = ["github.com"]
        var mail = Transformer(name: "Reply", prompt: "x"); mail.apps = ["com.apple.mail"]
        var gist = Transformer(name: "Gist", prompt: "x"); gist.sites = ["gist.github.com"]
        #expect(!github.overlaps(mail))
        #expect(github.overlaps(gist))
        #expect(Quicklink(name: "Dev", link: "~/Development").overlaps(mail))
    }

    @Test func hotKeyIsHeldWhereItCouldApply() {
        var site = Quicklink(name: "PRs", link: "https://github.com/pulls"); site.sites = ["github.com"]
        #expect(site.couldApply(frontApp: "com.google.Chrome"))   // the tab is only read on press
        #expect(!site.couldApply(frontApp: "com.apple.mail"))
        var global = Quicklink(name: "Dev", link: "~/Development"); global.excludedApps = ["com.mitchellh.ghostty"]
        #expect(!global.couldApply(frontApp: "com.mitchellh.ghostty"))
        #expect(global.couldApply(frontApp: nil))
    }

    @MainActor @Test func rowSubtitleDropsTheSelectionPlaceholder() {
        #expect(LauncherModel.promptSummary("Polish and refine {selection}\n\nFix grammar.") == "Polish and refine. Fix grammar.")
        #expect(LauncherModel.promptSummary("Convert this into clean Markdown:\n\n{selection}") == "Convert this into clean Markdown")
        #expect(LauncherModel.promptSummary("Make it less formal: {selection}") == "Make it less formal")
        #expect(LauncherModel.promptSummary("Summarize {selection} in one line") == "Summarize in one line")
    }

    @Test func globalTransformerHidesWhereExcluded() {
        var t = Transformer(name: "Less Formal", prompt: "x")
        t.excludedApps = ["com.mitchellh.ghostty"]
        t.excludedSites = ["github.com"]
        #expect(!t.applies(app: "com.mitchellh.ghostty", url: nil))
        #expect(!t.applies(app: "com.google.Chrome", url: URL(string: "https://gist.github.com/x")))
        #expect(t.applies(app: "com.google.Chrome", url: URL(string: "https://mail.google.com")))
        #expect(t.applies(app: "com.apple.mail", url: nil))
        // Once scoped, exclusions don't apply.
        t.apps = ["com.mitchellh.ghostty"]
        #expect(t.applies(app: "com.mitchellh.ghostty", url: nil))
    }

    @Test func exclusionsLetAScopedTransformerShareTheKey() {
        var global = Transformer(name: "Polish", prompt: "x")
        global.excludedApps = ["com.sublimetext.4"]
        global.excludedSites = ["github.com"]
        var sublime = Transformer(name: "JSON", prompt: "x"); sublime.apps = ["com.sublimetext.4"]
        var gist = Transformer(name: "Gist", prompt: "x"); gist.sites = ["gist.github.com"]
        var mail = Transformer(name: "Mail", prompt: "x"); mail.apps = ["com.apple.mail"]
        #expect(!global.overlaps(sublime))
        #expect(!gist.overlaps(global))
        #expect(global.overlaps(mail))
    }

    @Test func transformerScopeRoundTrips() throws {
        var t = Transformer(name: "A", prompt: "x")
        t.apps = ["com.apple.mail"]; t.sites = ["github.com"]
        let back = try JSONDecoder().decode(Transformer.self, from: JSONEncoder().encode(t))
        #expect(back.apps == ["com.apple.mail"] && back.sites == ["github.com"])
        let old = try JSONDecoder().decode(Transformer.self, from: Data(#"{"name":"A","prompt":"x"}"#.utf8))
        #expect(old.isGlobal)
    }

    @MainActor @Test func editorLineCopyIsNotASelection() {
        #expect(SelectionReader.isWholeLine("let x = 1\n"))
        #expect(SelectionReader.isWholeLine("let x = 1\r\n"))
        #expect(!SelectionReader.isWholeLine("let x = 1"))
        #expect(!SelectionReader.isWholeLine("one\ntwo\n"))
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("let x = 1\n", forType: .string)
        #expect(SelectionReader.isLineCopy(pb, text: "let x = 1\n", app: "com.sublimetext.4"))
        #expect(!SelectionReader.isLineCopy(pb, text: "let x = 1\n", app: "com.google.Chrome"))
        pb.setData(Data(#"{"isFromEmptySelection":false}"#.utf8), forType: .init("vscode-editor-data"))
        #expect(!SelectionReader.isLineCopy(pb, text: "let x = 1\n", app: "com.microsoft.VSCode"))
    }

    @Test func requestBodyCarriesTheConversation() throws {
        let body = try ChatGPTClient.body(model: "gpt-5.6-luna", effort: nil, instructions: TransformPrompt.instructions,
                                          messages: [ChatMessage(role: .user, content: "Polish x")])
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "gpt-5.6-luna")
        #expect(json["reasoning"] == nil)
        #expect((json["input"] as? [[String: String]])?.first?["content"] == "Polish x")
    }
}

@Suite struct CalculatorTests {
    private func calc(_ s: String) -> String? { Calculator.evaluate(s)?.plain }

    @Test func basics() {
        #expect(calc("8*8") == "64")
        #expect(calc("10/2") == "5")
        #expect(calc("10/4") == "2.5")
        #expect(calc("2 + 3 * 4") == "14")
        #expect(calc("(2+3)*4") == "20")
        #expect(calc("2^3^2") == "512")
        #expect(calc("-2^2") == "-4")
        #expect(calc("3 × 4 ÷ 2 − 1") == "5")
        #expect(calc("8x8") == "64")
        #expect(calc("2(3+4)") == "14")
    }

    @Test func unfinishedInputShowsSoFar() {
        #expect(calc("4+4+5+") == "13")
        #expect(calc("(2+3") == "5")
        #expect(calc("8*(") == nil)   // just "8"
    }

    @Test func percent() {
        #expect(calc("200 + 15%") == "230")
        #expect(calc("200 - 10%") == "180")
        #expect(calc("50% * 80") == "40")
    }

    @Test func formatting() {
        #expect(calc("0.1+0.2") == "0.3")
        #expect(calc("1,000 * 2") == "2000")
        #expect(Calculator.evaluate("1000*1000")?.display == "1,000,000")
        #expect(calc("1/3") == "0.333333333333")
    }

    @Test func notMath() {
        for s in ["", "8", "-5", "(5)", "safari", "xcode", "x264", "10/0", "1,2+3", "4++", "transform 2+2"] {
            #expect(calc(s) == nil, "\(s)")
        }
    }
}

@Suite struct LauncherGroupingTests {
    private func item(_ id: String, _ kind: LaunchKind, section: String? = nil) -> LaunchItem {
        var i = LaunchItem(id: id, name: id, path: "", kind: kind)
        i.section = section
        return i
    }

    @Test func eachHeadingShowsOnce() {
        let ranked = [item("api", .quicklink), item("docs", .quicklink), item("dev", .snippet, section: "Snippets · acme-web"),
                      item("repo", .quicklink), item("deploy", .snippet, section: "Snippets · acme-web")]
        let grouped = LauncherModel.grouped(ranked)
        #expect(grouped.map(\.id) == ["api", "docs", "repo", "dev", "deploy"])
        let headings = grouped.map(\.heading)
        #expect(zip(headings, headings.dropFirst()).filter { $0 != $1 }.count == 1)
    }

    @Test func bestMatchStaysFirst() {
        let grouped = LauncherModel.grouped([item("calc", .calculator), item("x", .app), item("y", .quicklink), item("z", .app)])
        #expect(grouped.map(\.id) == ["calc", "x", "z", "y"])
    }
}

@Suite struct ClipAgeTests {
    @Test func newClipsSayJustNow() {
        let now = Date()
        #expect(ClipAge.label(now, now: now) == "Just now")
        #expect(ClipAge.label(now.addingTimeInterval(-59), now: now) == "Just now")
        // A clip stamped a hair after the clock read must not read "in 0 sec."
        #expect(ClipAge.label(now.addingTimeInterval(0.2), now: now) == "Just now")
    }

    @Test func olderClipsSayHowLongAgo() {
        let now = Date()
        let label = ClipAge.label(now.addingTimeInterval(-5 * 60), now: now)
        #expect(label.contains("5") && label.contains("ago"))
    }
}

@Suite struct RichTextTests {
    @Test func plainTextHasNoHTML() {
        #expect(RichText.html(fromMarkdown: "Hi Sam,\n\nThanks for the notes.\n\nMarty") == nil)
        #expect(RichText.html(fromMarkdown: "{\n  \"a\": 1\n}") == nil)
    }

    @Test func markdownBecomesHTML() throws {
        let html = try #require(RichText.html(fromMarkdown: "## Next steps\n\n- **Ship** it\n- Read [the docs](https://example.com)"))
        #expect(html.hasPrefix("<meta charset=\"utf-8\">"))
        #expect(html.contains("<h2>Next steps</h2>"))
        #expect(html.contains("<li><strong>Ship</strong> it</li>"))
        #expect(html.contains("<a href=\"https://example.com\">the docs</a>"))
    }

    @Test func keepsLineBreaksAndTables() throws {
        let html = try #require(RichText.html(fromMarkdown: "**Thanks,**\nMarty\n\n| A | B |\n|---|---|\n| 1 | 2 |"))
        #expect(html.contains("<strong>Thanks,</strong><br />"))
        #expect(html.contains("<table>"))
    }

    @Test func rawHTMLFallsBackToText() {
        #expect(RichText.html(fromMarkdown: "Use **bold** or <div>a div</div>") == nil)
    }
}

@Suite struct MarkdownBlockTests {
    @Test func listItemsGetMarkersAndKeepLineBreaks() {
        let md = "## Contradictions\n\nPlease tell us.\n\n1. **Wiring (safety)**\n   The manual contradicts itself.\n   - Which end?\n   - Is it fixed?\n2. Warranty"
        let blocks = MarkdownBlock.parse(md)
        #expect(blocks.map(\.marker) == [nil, nil, "1.", "•", "•", "2."])
        #expect(blocks.map(\.depth) == [0, 0, 1, 2, 2, 1])
        #expect(String(blocks[2].text.characters) == "Wiring (safety)\nThe manual contradicts itself.")
        if case .header(2) = blocks[0].kind {} else { Issue.record("expected a level 2 heading") }
    }

    @Test func tablesGatherIntoRows() throws {
        let blocks = MarkdownBlock.parse("| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\nAfter")
        #expect(blocks.count == 2)
        guard case .table(let rows, let header) = blocks[0].kind else { Issue.record("expected a table"); return }
        #expect(header)
        #expect(rows.map { $0.map { String($0.characters) } } == [["A", "B"], ["1", "2"], ["3", "4"]])
    }

    @Test func codeFencesKeepTheirLines() {
        let blocks = MarkdownBlock.parse("```\nlet x = 1\nlet y = 2\n```")
        #expect(String(blocks[0].text.characters) == "let x = 1\nlet y = 2\n")
    }
}

@Suite @MainActor struct FormattingConversionTests {
    private func markdown(_ html: String) -> String? { RichText.markdown(from: RichContent(html: html)) }

    @Test func gmailMessageBecomesMarkdown() throws {
        let html = #"<div dir="ltr"><div>Hi Sam,</div><div><br></div><div>Here is <b>the plan</b> and <a href="https://x.com/plan">a link</a>.</div><div>Second line</div><ul><li>One</li><li>Two<ul><li>Nested</li></ul></li></ul><ol><li>First</li><li>Second</li></ol><div><br></div><div>Thanks,</div><div>Marty</div></div>"#
        let md = try #require(markdown(html))
        #expect(md == """
            Hi Sam,

            Here is **the plan** and [a link](https://x.com/plan).
            Second line

            - One
            - Two
                - Nested
            1. First
            2. Second

            Thanks,
            Marty
            """)
    }

    @Test func webPageHeadingsTablesAndCode() throws {
        let html = #"<h1>Title</h1><p>Para one with <i>italic</i> and <code>code</code>.</p><p>Para two&nbsp;here.</p><h3>Sub</h3><table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table><pre>let x = 1</pre>"#
        let md = try #require(markdown(html))
        #expect(md == """
            # Title

            Para one with *italic* and `code`.

            Para two here.

            ### Sub

            | A | B |
            | --- | --- |
            | 1 | 2 |

            ```
            let x = 1
            ```
            """)
    }

    @Test func plainOrAllCodeHasNoMarkdown() {
        #expect(markdown("<div>Just text</div><div>and more</div>") == nil)
        #expect(markdown(#"<div style="font-family: Menlo"><div>let x = 1</div><div>let y = 2</div></div>"#) == nil)
    }

    @Test func escapesOnlyWhatWouldFormat() throws {
        let md = try #require(markdown("<div><b>Math</b></div><div>5*3</div><div>a *star* pair</div><div># not a heading</div><div>1. not a list</div>"))
        #expect(md == "**Math**\n5*3\na \\*star\\* pair\n\\# not a heading\n1\\. not a list")
    }

    @Test func outputsPutTheRightVersionsOnTheClipboard() throws {
        let md = "## Plan\n\n- **Ship** it\n- Read [the docs](https://example.com)"
        let formatted = RichText.content(md, as: .formatted)
        #expect(formatted.text == "Plan\n\n• Ship it\n• Read the docs (https://example.com)")
        #expect(formatted.rich?.html?.contains("<h2>Plan</h2>") == true)
        let rtf = try #require(formatted.rich?.rtf)
        let attr = try #require(NSAttributedString(rtf: rtf, documentAttributes: nil))
        #expect((attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.familyName == "Helvetica Neue")

        #expect(RichText.content(md, as: .markdown) == PasteContent(text: md))
        #expect(RichText.content(md, as: .plain) == PasteContent(text: formatted.text))
        // Nothing to format: the text goes as it is.
        #expect(RichText.content("{\n  \"a\": 1\n}", as: .formatted) == PasteContent(text: "{\n  \"a\": 1\n}"))
    }

    @Test func originalPastesTheWayTheSelectionWas() {
        let polish = Transformer(name: "Polish", prompt: "Polish {selection}")
        #expect(polish.output == .original)
        let formatted = TransformInput(text: "Hi there", source: .clipboard, rich: RichContent(html: "<div>Hi <b>there</b></div>"))
        let plain = TransformInput(text: "Hi there", source: .clipboard)
        #expect(TransformRun(transformer: polish, input: formatted, context: .init(), ai: .shared).pasteFormat == .formatted)
        #expect(TransformRun(transformer: polish, input: plain, context: .init(), ai: .shared).pasteFormat == .markdown)
        let reddit = Transformer(name: "Reddit", prompt: "Format for Reddit", output: .markdown)
        #expect(TransformRun(transformer: reddit, input: formatted, context: .init(), ai: .shared).pasteFormat == .markdown)
    }

    @Test func clipsOfferOnlyFormatsThatChangeSomething() {
        func clip(_ text: String, rich: RichContent? = nil, secret: Bool = false) -> ClipPayload {
            var p = ClipPayload(machineID: "m", machineName: "Mac", kind: .text, hash: "h")
            p.text = text
            p.rich = rich
            p.isSecret = secret
            return p
        }
        let plain = clip("Just a note")
        #expect(![ClipFormat.formatted, .markdown, .plain].contains(where: plain.offers))
        #expect(plain.formatName == "Plain text")

        let markdown = clip("## Plan\n\n- **Ship** it")
        #expect(markdown.offers(.formatted) && markdown.offers(.plain) && !markdown.offers(.markdown))
        #expect(markdown.content(as: .formatted).rich?.html?.contains("<h2>Plan</h2>") == true)
        #expect(markdown.content(as: .plain) == PasteContent(text: "Plan\n\n• Ship it"))

        let gmail = clip("Hi there", rich: RichContent(html: "<div>Hi <b>there</b></div>"))
        #expect(gmail.offers(.markdown) && gmail.offers(.plain) && !gmail.offers(.formatted))
        #expect(gmail.content(as: .markdown) == PasteContent(text: "Hi **there**"))
        #expect(gmail.content(as: .plain) == PasteContent(text: "Hi there"))
        #expect(gmail.formatName == "Formatted")

        #expect(!clip("## Key", secret: true).offers(.formatted))
    }

    @Test func oldTransformersAndClipsStillDecode() throws {
        let t = try JSONDecoder().decode(Transformer.self, from: Data(#"{"name":"Polish","prompt":"Polish {selection}"}"#.utf8))
        #expect(t.output == .original)
        let clip = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","created":0,"machineID":"m","machineName":"Mac","kind":"text","text":"hi","isSecret":false,"hash":"h"}"#
        #expect(try JSONDecoder().decode(ClipPayload.self, from: Data(clip.utf8)).rich == nil)
    }

    @Test func sameTextIgnoresWhitespace() {
        #expect(SelectionReader.sameText("Hi  there\n", "Hi there"))
        #expect(!SelectionReader.sameText("Hi there", "Bye there"))
    }
}
