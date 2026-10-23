import Foundation
import Testing
@testable import Vibex

@Suite struct AgentPricingTests {
    @Test func `models match their own price, not a shorter prefix`() {
        #expect(AgentPricing.rate(for: "claude-opus-5-5")?.input == 4)
        #expect(AgentPricing.rate(for: "claude-opus-5")?.input == 5)
        #expect(AgentPricing.rate(for: "claude-opus-4-1-20250805")?.input == 15)
        #expect(AgentPricing.rate(for: "claude-fable-5-1")?.cacheRead == 0.025)
        #expect(AgentPricing.rate(for: "<synthetic>") == nil)
    }

    @Test func `cost counts cache writes and reads at their multipliers`() {
        var usage = TokenUsage()
        usage.input = 1_000_000
        usage.output = 1_000_000
        usage.cacheWrite5m = 1_000_000
        usage.cacheWrite1h = 1_000_000
        usage.cacheRead = 1_000_000
        // Opus 5.5: 4 + 20 + 5 + 8 + 0.2
        #expect(abs(AgentPricing.cost(usage, model: "claude-opus-5-5") - 37.2) < 0.0001)
        #expect(abs(AgentPricing.cost(usage, model: "claude-opus-5-5", fast: true) - 74.4) < 0.0001)
    }

    @Test func `display names`() {
        #expect(AgentPricing.displayName("claude-opus-5-5") == "Opus 5.5")
        #expect(AgentPricing.displayName("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        #expect(AgentPricing.displayName("claude-fable-5-1") == "Fable 5.1")
    }
}

@Suite struct ClaudeUsageLedgerTests {
    private func line(id: String, time: String, output: Int = 100, model: String = "claude-opus-5-5", cwd: String = "/x/vibex") -> String {
        #"{"type":"assistant","requestId":"r-\#(id)","timestamp":"\#(time)","cwd":"\#(cwd)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":10,"output_tokens":\#(output),"cache_read_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":500}}}}"#
    }

    @Test func `repeated messages count once and appended lines are read incrementally`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("session.jsonl")
        let first = [line(id: "a", time: "2026-10-23T10:00:00.000Z"), line(id: "a", time: "2026-10-23T10:00:00.000Z"), #"{"type":"user"}"#]
        try (first.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        var ledger = ClaudeUsageLedger()
        let firstPass = ledger.update(from: folder)
        #expect(firstPass)
        #expect(ledger.buckets.values.reduce(0) { $0 + $1.output } == 100)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        // A half-written line is left for the next pass.
        try handle.write(contentsOf: Data((line(id: "b", time: "2026-10-23T11:00:00.000Z", output: 50) + "\n" + #"{"type":"assis"#).utf8))
        try handle.close()
        let secondPass = ledger.update(from: folder)
        #expect(secondPass)
        #expect(ledger.buckets.values.reduce(0) { $0 + $1.output } == 150)
        #expect(ledger.buckets.keys.allSatisfy { $0.project == "vibex" })
    }

    @Test func `sessions are 5-hour blocks from the first message`() {
        var ledger = ClaudeUsageLedger()
        let now = Date()
        let hour = Int(now.timeIntervalSince1970 / 3600)
        func add(_ hoursAgo: Int, cost: Double) {
            var usage = TokenUsage()
            usage.cost = cost
            ledger.buckets[.init(hour: hour - hoursAgo, model: "claude-opus-5-5", project: "p")] = usage
        }
        add(12, cost: 10)  // an older block
        add(11, cost: 30)
        add(2, cost: 5)    // the current block started 2 hours ago
        add(1, cost: 2)
        let summary = AgentUsageSummary.make(from: ledger, periodDays: 30, now: now)
        #expect(summary.largestBlockCost == 40)
        #expect(summary.currentBlock?.cost == 7)
        #expect(summary.periodCost == 47)
        #expect(summary.streak >= 1)
    }
}

@Suite struct SkillsLibraryTests {
    @Test func `front matter reads quoted and folded values`() {
        let text = "---\nname: \"ux-laws\"\ndescription: >\n  Apply the laws\n  while building.\nlicense: MIT\n---\n# Body"
        let values = SkillsLibrary.frontmatter(text)
        #expect(values["name"] == "ux-laws")
        #expect(values["description"] == "Apply the laws while building.")
        #expect(values["license"] == "MIT")
    }

    @Test func `install layout links .claude to .agents and removal can be undone`() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-skills-\(UUID().uuidString)")
        let files = project.appendingPathComponent(".agents/skills/demo")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: A demo skill.\n---\n".write(to: files.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let links = project.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: links.appendingPathComponent("demo").path, withDestinationPath: "../../.agents/skills/demo")
        defer { try? FileManager.default.removeItem(at: project) }

        let skill = try #require(SkillsLibrary.list(.project, project: project).first)
        #expect(skill.name == "demo")
        #expect(skill.summary == "A demo skill.")

        let removed = try SkillsLibrary.remove(skill, project: project)
        #expect(SkillsLibrary.list(.project, project: project).isEmpty)
        try SkillsLibrary.restore(removed)
        #expect(SkillsLibrary.list(.project, project: project).map(\.name) == ["demo"])
    }

    @Test func `locate prefers the folder named after the skill`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-repo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (folder, name) in [("repo-abc/skills/other", "target"), ("repo-abc/skills/target", "target")] {
            let url = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try "---\nname: \(name)\n---\n".write(to: url.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        #expect(SkillsLibrary.locate("target", in: root)?.lastPathComponent == "target")
        #expect(SkillsLibrary.locate("missing", in: root) == nil)
    }
}

@Suite struct AgentsFocusTests {
    @Test func `focus reports the current session`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var summary = AgentUsageSummary(periodDays: 30)
        summary.currentBlock = .init(cost: 36.43, resetsAt: now.addingTimeInterval(63 * 60))
        summary.largestBlockCost = 60
        #expect(WorkspaceTools.sessionSummary(summary, now: now) == "Opened AI Usage. Session $36.43 · resets in 1h 3m · 61% of your largest session.")
        #expect(WorkspaceTools.sessionSummary(AgentUsageSummary(periodDays: 30), now: now).contains("No Claude session"))
    }
}
