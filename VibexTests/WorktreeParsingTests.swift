import Foundation
import Testing
@testable import Vibex

@Suite struct AgentNamingTests {
    @Test func `worktree list and shortstat parse`() {
        let trees = GitWorktree.parse("worktree /repo\nHEAD abc\nbranch refs/heads/main\n\nworktree /agents/dark\nHEAD def\nbranch refs/heads/vibex/dark\n\nworktree /tmp/x\nHEAD 123\ndetached\n")
        #expect(trees.map(\.branch) == ["main", "vibex/dark", nil])
        let stats = GitChangeStats.parse(shortstat: " 3 files changed, 120 insertions(+), 14 deletions(-)")
        #expect(stats.files == 3 && stats.insertions == 120 && stats.deletions == 14)
        #expect(GitChangeStats.parse(shortstat: " 1 file changed, 2 insertions(+)").deletions == 0)
    }
}

@MainActor @Suite(.serialized) struct WorktreeParsingTests {
    func makeRepo() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-agents-\(UUID().uuidString)/habits")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func git(_ args: [String]) throws { _ = try Shell.run("/usr/bin/git", ["-C", folder.path] + args) }
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "Test"])
        try git(["config", "user.email", "test@example.com"])
        try "one\n".write(to: folder.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-qm", "first"])
        return folder
    }

    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<50 where !condition() { try? await Task.sleep(for: .milliseconds(100)) }
    }
}
