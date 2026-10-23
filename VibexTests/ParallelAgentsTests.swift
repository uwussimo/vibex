import Foundation
import Testing
@testable import Vibex

@Suite struct AgentNamingTests {
    @Test func `tasks become short branch names`() {
        #expect(AgentsModel.slug("Add a dark mode toggle to Settings, please") == "add-a-dark-mode-toggle")
        #expect(AgentsModel.slug("Fix #42: crash!") == "fix-42-crash")
        #expect(AgentsModel.slug("   ") == "agent")
        #expect(AgentsModel.claudeCommand(task: "Don't break the build") == #"claude 'Don'\''t break the build'"#)
        #expect(AgentsModel.claudeCommand(task: nil) == "claude")
    }

    @Test func `worktree list and shortstat parse`() {
        let trees = GitWorktree.parse("worktree /repo\nHEAD abc\nbranch refs/heads/main\n\nworktree /agents/dark\nHEAD def\nbranch refs/heads/vibex/dark\n\nworktree /tmp/x\nHEAD 123\ndetached\n")
        #expect(trees.map(\.branch) == ["main", "vibex/dark", nil])
        let stats = GitChangeStats.parse(shortstat: " 3 files changed, 120 insertions(+), 14 deletions(-)")
        #expect(stats.files == 3 && stats.insertions == 120 && stats.deletions == 14)
        #expect(GitChangeStats.parse(shortstat: " 1 file changed, 2 insertions(+)").deletions == 0)
    }
}

@MainActor @Suite(.serialized) struct ParallelAgentsTests {
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

    @Test func `create, change, review, merge and remove an agent`() async throws {
        let folder = try makeRepo()
        let model = AgentsModel(project: Project(url: folder))
        defer {
            try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: model.root)
        }
        model.refresh()
        await waitUntil { model.state == .ready }
        #expect(model.agents.isEmpty)
        #expect(model.baseBranch == "main")

        let path = try #require(await model.create(name: "Add dark mode", task: "Add dark mode"))
        let agent = try #require(model.agents.first)
        #expect(agent.name == "add-dark-mode")
        #expect(agent.branch == "vibex/add-dark-mode")
        #expect(agent.task == "Add dark mode")
        #expect(agent.stats.isEmpty)

        // The agent works in its own folder; the project's checkout doesn't see it.
        try "one\ntwo\nthree\n".write(to: path.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        try "dark\n".write(to: path.appendingPathComponent("Theme.swift"), atomically: true, encoding: .utf8)
        model.refresh()
        await waitUntil { model.agents.first?.stats.files == 2 }
        let changed = try #require(model.agents.first)
        #expect(changed.stats.insertions == 3) // two lines added to App.swift, one in the new Theme.swift
        #expect(changed.stats.uncommitted)
        #expect(try String(contentsOf: folder.appendingPathComponent("App.swift"), encoding: .utf8) == "one\n")

        // Review: Source Control switches to the agent's checkout, and back.
        let sourceControl = SourceControlModel(folder: folder)
        sourceControl.start()
        sourceControl.show(checkout: path, agent: changed.name)
        await waitUntil { sourceControl.status.unstaged.count == 2 }
        #expect(sourceControl.reviewingAgent == "add-dark-mode")
        #expect(Set(sourceControl.status.unstaged.map(\.path)) == ["App.swift", "Theme.swift"])
        sourceControl.show(checkout: nil)
        await waitUntil { sourceControl.state == .ready && sourceControl.status.isClean }
        #expect(sourceControl.reviewingAgent == nil)
        sourceControl.stop()

        // Merge commits what's left and brings it into main.
        await model.merge(changed)
        #expect(model.problem == nil)
        #expect(model.notice == .merged(name: "add-dark-mode", into: "main"))
        #expect(try String(contentsOf: folder.appendingPathComponent("Theme.swift"), encoding: .utf8) == "dark\n")

        // Removing a merged agent deletes its folder and branch.
        let merged = try #require(model.agents.first)
        #expect(await model.remove(merged))
        #expect(model.agents.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        let branches = try String(decoding: Shell.run("/usr/bin/git", ["-C", folder.path, "branch", "--list", "vibex/*"]), as: UTF8.self)
        #expect(branches.isEmpty)
    }

    @Test func `removing an unmerged agent keeps its branch`() async throws {
        let folder = try makeRepo()
        let model = AgentsModel(project: Project(url: folder))
        defer {
            try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: model.root)
        }
        model.refresh()
        await waitUntil { model.state == .ready }
        let path = try #require(await model.create(name: "risky", task: nil))
        try "x\n".write(to: path.appendingPathComponent("New.swift"), atomically: true, encoding: .utf8)
        _ = try Shell.run("/usr/bin/git", ["-C", path.path, "add", "."])
        _ = try Shell.run("/usr/bin/git", ["-C", path.path, "-c", "user.name=T", "-c", "user.email=t@e.com", "commit", "-qm", "wip"])
        model.refresh()
        await waitUntil { model.agents.first?.stats.commits == 1 }
        let agent = try #require(model.agents.first)
        #expect(await model.remove(agent))
        #expect(model.problem?.message.contains("kept it") == true)
        let branches = try String(decoding: Shell.run("/usr/bin/git", ["-C", folder.path, "branch", "--list", "vibex/*"]), as: UTF8.self)
        #expect(branches.contains("vibex/risky"))
        #expect(model.uniqueName("risky") == "risky")
    }
}
