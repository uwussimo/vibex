import Foundation
import Testing
@testable import Vibex

@Suite struct GitStatusTests {
    @Test func `branch with upstream and counts`() {
        let status = GitStatus.parse("## main...origin/main [ahead 2, behind 1]\0")
        #expect(status.branch == "main")
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 2)
        #expect(status.behind == 1)
        #expect(status.isClean)
    }

    @Test func `new repository and detached head`() {
        #expect(GitStatus.parse("## No commits yet on main\0").branch == "main")
        #expect(GitStatus.parse("## HEAD (no branch)\0").branch == nil)
    }

    @Test func `a file can be staged and modified again`() {
        let status = GitStatus.parse("## main\0MM App.swift\0")
        #expect(status.staged.map(\.path) == ["App.swift"])
        #expect(status.unstaged.map(\.path) == ["App.swift"])
        #expect(status.changeCount == 1)
    }

    @Test func `untracked, deleted and added files`() {
        let status = GitStatus.parse("## main\0?? new file.txt\0 D Old.swift\0A  Added.swift\0")
        #expect(status.unstaged.map(\.kind) == [.untracked, .deleted])
        #expect(status.unstaged.first?.path == "new file.txt")
        #expect(status.staged.map(\.kind) == [.added])
    }

    @Test func `renames carry the original path`() {
        let status = GitStatus.parse("## main\0R  Sources/New.swift\0Sources/Old.swift\0 M Other.swift\0")
        let rename = try! #require(status.staged.first)
        #expect(rename.kind == .renamed)
        #expect(rename.path == "Sources/New.swift")
        #expect(rename.originalPath == "Sources/Old.swift")
        #expect(rename.fileName == "New.swift")
        #expect(rename.directory == "Sources")
        #expect(status.unstaged.map(\.path) == ["Other.swift"])
    }

    @Test(arguments: ["UU", "AA", "DD", "AU", "UD"])
    func `merge conflicts get their own list`(code: String) {
        let status = GitStatus.parse("## main\0\(code) Conflict.swift\0")
        #expect(status.conflicted.map(\.path) == ["Conflict.swift"])
        #expect(status.staged.isEmpty)
        #expect(status.unstaged.isEmpty)
    }
}

@Suite struct DiffParserTests {
    static let sample = """
    diff --git a/App.swift b/App.swift
    index 1111111..2222222 100644
    --- a/App.swift
    +++ b/App.swift
    @@ -1,4 +1,5 @@ struct App {
     let a = 1
    -let b = 2
    +let b = 3
    +let c = 4
     let d = 5
    @@ -20,2 +21,2 @@ func render()
    -    old()
    +    new()
    \\ No newline at end of file
    """

    @Test func `hunks and line numbers`() throws {
        let diff = DiffParser.parse(Self.sample)
        #expect(diff.hunks.count == 2)
        #expect(diff.additions == 3)
        #expect(diff.deletions == 2)
        let first = try #require(diff.hunks.first)
        #expect(first.context == "struct App {")
        #expect(first.lines.map(\.kind) == [.context, .removed, .added, .added, .context])
        #expect(first.lines[1].oldNumber == 2)
        #expect(first.lines[2].newNumber == 2)
        #expect(first.lines[3].newNumber == 3)
        #expect(first.lines[4].oldNumber == 3)
        #expect(first.lines[4].newNumber == 4)
        #expect(diff.hunks[1].lines.last?.missingNewline == true)
        #expect(diff.hunks[1].lines.first?.oldNumber == 20)
    }

    @Test func `split rows pair removals with additions`() throws {
        let rows = try #require(DiffParser.parse(Self.sample).hunks.first).splitRows
        #expect(rows.count == 4)
        #expect(rows[1].left?.text == "let b = 2")
        #expect(rows[1].right?.text == "let b = 3")
        #expect(rows[2].left == nil)
        #expect(rows[2].right?.text == "let c = 4")
    }

    @Test func `word highlight covers only what changed`() throws {
        let ranges = try #require(DiffParser.changedRanges("let b = 2", "let b = 3"))
        #expect("let b = 2"[ranges.left] == "2")
        #expect("let b = 3"[ranges.right] == "3")
        #expect(DiffParser.changedRanges("abc", "xyz") == nil)
    }

    @Test func `binary files are flagged`() {
        let diff = DiffParser.parse("diff --git a/icon.png b/icon.png\nBinary files a/icon.png and b/icon.png differ\n")
        #expect(diff.isBinary)
        #expect(diff.hunks.isEmpty)
    }

    @Test func `hunk header without counts`() {
        let header = DiffParser.parseHeader("@@ -0,0 +1 @@")
        #expect(header.old == 0)
        #expect(header.new == 1)
        #expect(header.context.isEmpty)
    }
}

@Suite(.serialized) struct GitRepositoryTests {
    @Test func `status, stage, diff and commit in a scratch repository`() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try await GitRepository.initialize(at: folder)
        let repo = try #require(await GitRepository.find(containing: folder))
        try "one\ntwo\n".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        var status = try await repo.status()
        let untracked = try #require(status.unstaged.first)
        #expect(untracked.kind == .untracked)
        let newFile = try await repo.diff(for: untracked)
        #expect(newFile.additions == 2)

        try await repo.stage(["notes.txt"])
        status = try await repo.status()
        #expect(status.staged.map(\.kind) == [.added])

        try await repo.unstage(["notes.txt"])
        #expect(try await repo.status().staged.isEmpty)
        try await repo.stage(["notes.txt"])

        // Commit needs an identity; keep it local to the scratch repository.
        _ = try Shell.run("/usr/bin/git", ["-C", folder.path, "config", "user.email", "test@example.com"])
        _ = try Shell.run("/usr/bin/git", ["-C", folder.path, "config", "user.name", "Test"])
        try await repo.commit(message: "First")
        #expect(try await repo.status().isClean)

        try "one\n2\n".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let modified = try #require(try await repo.status().unstaged.first)
        let diff = try await repo.diff(for: modified)
        #expect(diff.additions == 1)
        #expect(diff.deletions == 1)

        try await repo.discard([modified])
        #expect(try await repo.status().isClean)
    }
}
