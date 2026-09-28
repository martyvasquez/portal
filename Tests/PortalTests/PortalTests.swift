import Testing
import Foundation
import CryptoKit
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
        let name = ClipFileName.make(created: date, id: id, pinned: true, secret: true)
        let parsed = try #require(ClipFileName.parse(name))
        #expect(parsed.id == id && parsed.pinned && parsed.secret)
        #expect(abs(parsed.created.timeIntervalSince(date)) < 0.002)
        #expect(ClipFileName.parse(ClipFileName.make(created: date, id: id, pinned: false, secret: false))?.pinned == false)
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
