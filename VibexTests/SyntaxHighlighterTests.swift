import Foundation
import Testing
@testable import Vibex

@Suite struct SyntaxHighlighterTests {
    /// The tokens found in a line, as (text, token) pairs.
    static func tokens(_ line: String, _ language: Language, state: inout SyntaxHighlighter.State) -> [(String, SyntaxToken)] {
        let units = Array(line.utf16)
        return SyntaxHighlighter(language: language).spans(for: line, state: &state).map { span in
            (String(utf16CodeUnits: Array(units[span.start..<span.start + span.length]), count: span.length), span.token)
        }
    }

    static func tokens(_ line: String, _ language: Language) -> [(String, SyntaxToken)] {
        var state = SyntaxHighlighter.State()
        return tokens(line, language, state: &state)
    }

    @Test func `swift keywords, types, strings, numbers and attributes`() {
        let found = Self.tokens(#"@MainActor final class View: NSView { let n = 42; let s = "hi \(n)" } // done"#, .swift)
        #expect(found.contains { $0 == ("@MainActor", .attribute) })
        #expect(found.contains { $0 == ("final", .keyword) })
        #expect(found.contains { $0 == ("NSView", .type) })
        #expect(found.contains { $0 == ("42", .number) })
        #expect(found.contains { $0.0.hasPrefix("\"hi") && $0.1 == .string })
        #expect(found.last.map { $0 == ("// done", .comment) } == true)
    }

    @Test func `block comments carry across lines`() {
        var state = SyntaxHighlighter.State()
        let first = Self.tokens("let a = 1 /* starts", .swift, state: &state)
        #expect(first.last?.1 == .comment)
        #expect(state.inBlockComment)
        let second = Self.tokens("still a comment */ let b", .swift, state: &state)
        #expect(second.first.map { $0 == ("still a comment */", .comment) } == true)
        #expect(second.contains { $0 == ("let", .keyword) })
        #expect(!state.inBlockComment)
    }

    @Test func `multi-line strings carry across lines`() {
        var state = SyntaxHighlighter.State()
        _ = Self.tokens(#"let text = """"#, .swift, state: &state)
        #expect(state.openString != nil)
        let inside = Self.tokens("let not = keyword here", .swift, state: &state)
        #expect(inside.count == 1 && inside[0].1 == .string)
        _ = Self.tokens(#"""""#, .swift, state: &state)
        #expect(state.openString == nil)
    }

    @Test func `escaped quotes do not end a string`() {
        let found = Self.tokens(#"x = "a \" b" + y"#, .javaScript)
        #expect(found.contains { $0 == (#""a \" b""#, .string) })
    }

    @Test func `json keys differ from values`() {
        let found = Self.tokens(#"  "name": "vibex", "count": 3, "ok": true"#, .json)
        #expect(found.contains { $0 == (#""name""#, .key) })
        #expect(found.contains { $0 == (#""vibex""#, .string) })
        #expect(found.contains { $0 == ("3", .number) })
        #expect(found.contains { $0 == ("true", .literal) })
    }

    @Test func `yaml keys and comments`() {
        let found = Self.tokens("  - name: build # first", .yaml)
        #expect(found.contains { $0 == ("name", .key) })
        #expect(found.last.map { $0 == ("# first", .comment) } == true)
    }

    @Test func `markup tags and attributes`() {
        let found = Self.tokens(#"<key name="value">text</key>"#, .markup)
        #expect(found.filter { $0.1 == .tag }.map(\.0) == ["key", "key"])
        #expect(found.contains { $0 == ("name", .attribute) })
        #expect(found.contains { $0 == (#""value""#, .string) })
    }

    @Test func `shell variables and comments`() {
        let found = Self.tokens(#"echo "$HOME" ${PATH} # note"#, .shell)
        #expect(found.contains { $0 == ("echo", .keyword) })
        #expect(found.contains { $0 == ("${PATH}", .attribute) })
        #expect(found.last.map { $0 == ("# note", .comment) } == true)
    }

    @Test func `identifiers that contain digits are not numbers`() {
        let found = Self.tokens("let utf8 = value2", .swift)
        #expect(!found.contains { $0.1 == .number })
    }

    @Test(arguments: [
        ("App.swift", "Swift"), ("index.tsx", "JavaScript"), ("main.py", "Python"), ("Makefile", "Shell"),
        ("Package.resolved", "JSON"), ("ci.yml", "YAML"), ("Info.plist", "Markup"), ("README.md", "Markdown"),
    ])
    func `languages come from file names`(path: String, language: String) {
        #expect(Language.forPath(path)?.name == language)
    }

    @Test func `unknown files are left plain`() {
        #expect(Language.forPath("photo.png") == nil)
        let diff = DiffParser.parse("@@ -1 +1 @@\n-a\n+b\n")
        #expect(DiffHighlighter.highlight(diff, path: "data.bin").isEmpty)
    }

    @Test func `removed and added lines keep separate state`() {
        let diff = DiffParser.parse("@@ -1,2 +1,2 @@\n-/* old comment\n+let fresh = 1\n */\n")
        let spans = DiffHighlighter.highlight(diff, path: "A.swift")
        let added = try! #require(diff.hunks.first?.lines.first { $0.kind == .added })
        #expect(spans[added.id]?.contains { $0.token == .keyword } == true)
    }
}
