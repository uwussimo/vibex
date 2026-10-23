import Foundation
import Observation
import os

/// Parallel agents: several Claude Code attempts at once, each on its own branch in its own git
/// worktree, so they never touch each other's files or the project's checkout. Compare them in
/// Source Control, merge the one you like, remove the rest.
@Observable
final class AgentsModel {
    enum State: Equatable { case loading, notRepository, ready }

    struct Agent: Identifiable, Equatable {
        var path: URL
        var branch: String
        var name: String
        var task: String?
        var created: Date?
        var stats = GitChangeStats()
        var id: String { path.path }
    }

    /// What just happened, with the next step.
    enum Notice: Equatable { case merged(name: String, into: String) }

    private(set) var state: State = .loading
    private(set) var agents: [Agent] = []
    /// The branch agents start from and merge into: the project checkout's current branch.
    private(set) var baseBranch: String?
    private(set) var busy: String?
    var problem: GitProblem?
    var notice: Notice?
    /// The New Agent form is open.
    var isComposing = false

    let project: Project
    private var repository: GitRepository?

    /// Branches Vibex creates for agents start with this.
    static let branchPrefix = "vibex/"

    init(project: Project) {
        self.project = project
    }

    // MARK: - Where agents live

    /// `~/Library/Application Support/Vibex/Agents/<project id>/`: worktrees, and what each was asked.
    var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vibex/Agents/\(project.id)", isDirectory: true)
    }

    private var notesURL: URL { root.appendingPathComponent("agents.json") }

    private struct Note: Codable { var name: String; var task: String?; var created: Date }

    private func notes() -> [String: Note] {
        (try? JSONDecoder().decode([String: Note].self, from: Data(contentsOf: notesURL))) ?? [:]
    }

    private func save(notes: [String: Note]) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(notes).write(to: notesURL, options: .atomic)
    }

    // MARK: - Loading

    func refresh() {
        Task { await reload() }
    }

    private func reload() async {
        if repository == nil { repository = await GitRepository.find(containing: project.url) }
        guard let repository else {
            state = .notRepository
            agents = []
            return
        }
        baseBranch = await repository.currentBranch()
        let notes = notes()
        let trees = (try? await repository.worktrees()) ?? []
        let mainPath = repository.root.standardizedFileURL.path
        var list: [Agent] = []
        for tree in trees where tree.path.standardizedFileURL.path != mainPath {
            guard let branch = tree.branch else { continue }
            let note = notes[tree.path.path]
            var agent = Agent(
                path: tree.path,
                branch: branch,
                name: note?.name ?? (branch.hasPrefix(Self.branchPrefix) ? String(branch.dropFirst(Self.branchPrefix.count)) : branch),
                task: note?.task,
                created: note?.created
            )
            if let base = baseBranch {
                agent.stats = await GitRepository(root: tree.path).changes(since: base)
            }
            list.append(agent)
        }
        list.sort { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
        if list != agents { agents = list }
        state = .ready
    }

    // MARK: - Actions

    /// "Add a dark mode toggle" → "add-dark-mode-toggle"
    nonisolated static func slug(_ text: String) -> String {
        let cleaned = String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
        let words = cleaned.split(separator: " ").prefix(5)
        return words.isEmpty ? "agent" : words.joined(separator: "-")
    }

    /// A name no existing agent or branch uses: "dark-mode", then "dark-mode-2"…
    func uniqueName(_ name: String) -> String {
        let taken = Set(agents.map(\.name))
        var candidate = Self.slug(name)
        var number = 2
        while taken.contains(candidate) || FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = "\(Self.slug(name))-\(number)"
            number += 1
        }
        return candidate
    }

    /// Creates the worktree and branch from the base branch's last commit. Returns the new agent's folder.
    func create(name: String, task: String?) async -> URL? {
        guard let repository, busy == nil else { return nil }
        let name = uniqueName(name)
        let path = root.appendingPathComponent(name, isDirectory: true)
        busy = "Creating \(name)…"
        problem = nil
        defer { busy = nil }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await repository.addWorktree(path: path, branch: Self.branchPrefix + name)
        } catch {
            problem = GitProblem.explain(error)
            return nil
        }
        var notes = notes()
        notes[path.path] = Note(name: name, task: task.flatMap { $0.isEmpty ? nil : $0 }, created: Date())
        save(notes: notes)
        Log.app.info("created agent \(name, privacy: .public)")
        await reload()
        return path
    }

    /// Commits whatever the agent left uncommitted, then merges its branch into the base branch.
    func merge(_ agent: Agent) async {
        guard let repository, let base = baseBranch, busy == nil else { return }
        busy = "Merging \(agent.name)…"
        problem = nil
        defer { busy = nil }
        do {
            if agent.stats.uncommitted {
                try await GitRepository(root: agent.path).commitAll(message: agent.task.map { "\($0)\n\nAgent: \(agent.name)" } ?? "Agent: \(agent.name)")
            }
            try await repository.merge(agent.branch)
            notice = .merged(name: agent.name, into: base)
        } catch {
            problem = GitProblem.explain(error)
        }
        await reload()
    }

    /// Deletes the worktree. The branch goes too if it was merged; otherwise it stays, so nothing is lost.
    @discardableResult
    func remove(_ agent: Agent) async -> Bool {
        guard let repository, busy == nil else { return false }
        busy = "Removing \(agent.name)…"
        problem = nil
        defer { busy = nil }
        do {
            try await repository.removeWorktree(path: agent.path)
        } catch {
            problem = GitProblem.explain(error)
            return false
        }
        let branchDeleted = await repository.deleteBranchIfMerged(agent.branch)
        if !branchDeleted {
            problem = GitProblem(message: "Removed \(agent.name). Its branch \(agent.branch) wasn't merged, so Vibex kept it.", detail: nil, fix: nil)
        }
        var notes = notes()
        notes[agent.path.path] = nil
        save(notes: notes)
        if case .merged(agent.name, _) = notice { notice = nil }
        await reload()
        return true
    }

    /// `claude 'Add a dark mode toggle'`, quoted for any POSIX shell.
    nonisolated static func claudeCommand(task: String?) -> String {
        guard let task, !task.isEmpty else { return "claude" }
        return "claude '" + task.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
