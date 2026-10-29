import Foundation
import Testing
@testable import Vibex

@MainActor @Suite struct ExplorerTests {
    private func project() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("explorer-\(UUID().uuidString)").standardizedFileURL
        let files = ["Sources/App.swift", "Sources/Views/Home.swift", "README.md", "build/out.o", ".gitignore", ".DS_Store", "a.txt"]
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((file == ".gitignore" ? "build/\n" : "x").utf8).write(to: url)
        }
        _ = try Shell.run("/usr/bin/git", ["-C", root.path, "init", "-q"])
        return root
    }

    @Test func `the tree lists folders first and opens folder by folder`() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ExplorerModel(root: root)
        model.start()
        defer { model.stop() }
        #expect(model.rows.map(\.node.name) == ["build", "Sources", ".gitignore", "a.txt", "README.md"])
        let sources = try #require(model.rows.first { $0.node.name == "Sources" }?.node)
        model.toggle(sources)
        #expect(model.rows.map(\.node.name) == ["build", "Sources", "Views", "App.swift", ".gitignore", "a.txt", "README.md"])
        #expect(model.rows.first { $0.node.name == "App.swift" }?.depth == 1)
        model.collapseAll()
        #expect(model.rows.count == 5)
        model.reveal(root.appendingPathComponent("Sources/Views/Home.swift"))
        #expect(model.rows.map(\.node.name).contains("Home.swift"))
        #expect(model.selection == root.appendingPathComponent("Sources/Views/Home.swift").standardizedFileURL)
    }

    @Test func `git-ignored files are marked and new files appear`() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ExplorerModel(root: root)
        model.start()
        defer { model.stop() }
        try await Task.sleep(for: .milliseconds(800))
        let build = try #require(model.rows.first { $0.node.name == "build" }?.node)
        let sources = try #require(model.rows.first { $0.node.name == "Sources" }?.node)
        #expect(model.isIgnored(build))
        #expect(!model.isIgnored(sources))
        try Data("new".utf8).write(to: root.appendingPathComponent("New.swift"))
        try await Task.sleep(for: .seconds(1.5))
        #expect(model.rows.map(\.node.name).contains("New.swift"))
    }

    @Test func `files are read as text, binary or too large`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appendingPathComponent("a.swift"), binary = folder.appendingPathComponent("b.bin")
        try Data("let x = 1".utf8).write(to: text)
        try Data([0x01, 0x00, 0x02]).write(to: binary)
        #expect(FileContent.read(text) == .text("let x = 1"))
        #expect(FileContent.read(binary) == .binary(3))
        #expect(FileContent.read(folder.appendingPathComponent("gone.txt")) == .missing("This file no longer exists."))
        #expect(FileIcon.logo(for: "App.swift") == .swift)
        #expect(FileIcon.logo(for: "package.json") == .nodejs)
    }
}

@Suite struct MarkdownTests {
    @Test func `a skill reads as front matter and blocks`() {
        let source = """
        ---
        name: write-swift
        description: How to write modern Swift well.
        license: MIT
        ---

        # Write Swift

        Use **value types** and `struct`s
        by default.

        - First
          continued
        - Second
          - Nested
        1. One
        2) Two
        - [x] Done
        - [ ] Todo

        ```swift
        let x = 1
        ```

        > A quote
        > goes on

        | Name | Kind |
        |------|:----:|
        | a | b |

        ---
        """
        let doc = MarkdownDocument(source)
        #expect(doc.frontMatter.map(\.key) == ["name", "description", "license"])
        #expect(doc.frontMatter[1].value == "How to write modern Swift well.")
        #expect(doc.blocks == [
            .heading(level: 1, text: "Write Swift"),
            .paragraph("Use **value types** and `struct`s by default."),
            .list([
                .init(depth: 0, marker: "•", text: "First continued"),
                .init(depth: 0, marker: "•", text: "Second"),
                .init(depth: 1, marker: "•", text: "Nested"),
                .init(depth: 0, marker: "1.", text: "One"),
                .init(depth: 0, marker: "2.", text: "Two"),
                .init(depth: 0, marker: "☑", text: "Done"),
                .init(depth: 0, marker: "☐", text: "Todo"),
            ]),
            .code(language: "swift", text: "let x = 1"),
            .quote("A quote goes on"),
            .table(header: ["Name", "Kind"], rows: [["a", "b"]]),
            .rule,
        ])
    }

    @Test func `folded front matter and no front matter`() {
        let folded = MarkdownDocument("---\nname: x\ndescription: >\n  Line one\n  line two\n---\nBody")
        #expect(folded.frontMatter.last?.value == "Line one line two")
        #expect(folded.blocks == [.paragraph("Body")])
        let plain = MarkdownDocument("## Hi\n\nText")
        #expect(plain.frontMatter.isEmpty)
        #expect(plain.blocks == [.heading(level: 2, text: "Hi"), .paragraph("Text")])
    }
}
