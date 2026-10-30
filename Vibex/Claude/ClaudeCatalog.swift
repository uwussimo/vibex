import Foundation
import Observation
import os

/// A slash command: Claude Code's own, or a skill.
nonisolated struct ClaudeCommand: Equatable, Sendable, Identifiable {
    var name: String
    var summary: String
    var argumentHint = ""
    var id: String { name }
}

/// A model Claude Code offers, as it names it: "Opus 5.5".
nonisolated struct ClaudeModelOption: Equatable, Sendable, Identifiable {
    /// What `--model` takes; "default" is whatever Claude Code recommends.
    var value: String
    var title: String
    var summary: String
    var effortLevels: [String] = []
    var id: String { value }

    /// The aliases come first, and always mean the latest version. Full ids are older versions.
    var isOlderVersion: Bool { value.hasPrefix("claude-") }
}

/// What Claude Code says it can do in a folder, from its `initialize` reply.
nonisolated struct ClaudeCapabilities: Equatable, Sendable {
    var commands: [ClaudeCommand] = []
    var models: [ClaudeModelOption] = []

    init(commands: [ClaudeCommand] = [], models: [ClaudeModelOption] = []) {
        self.commands = commands
        self.models = models
    }

    init(reply: [String: Any]) {
        commands = Self.commands(reply["commands"])
        models = (reply["models"] as? [[String: Any]] ?? []).compactMap { model in
            guard let value = model["value"] as? String, let title = model["displayName"] as? String else { return nil }
            return ClaudeModelOption(value: value, title: title, summary: model["description"] as? String ?? "", effortLevels: model["supportedEffortLevels"] as? [String] ?? [])
        }
    }

    static func commands(_ list: Any?) -> [ClaudeCommand] {
        (list as? [[String: Any]] ?? []).compactMap { command in
            guard let name = command["name"] as? String, !name.hasPrefix("__") else { return nil }
            return ClaudeCommand(name: name, summary: summary(command["description"] as? String ?? ""), argumentHint: command["argumentHint"] as? String ?? "")
        }
    }

    /// The first sentence, without the "(user)" Claude Code adds to say where a skill lives.
    private static func summary(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\([^)]*\)\s*"#, with: "", options: .regularExpression)
        return cleaned.prefix(while: { !$0.isNewline }).split(separator: ". ").first.map(String.init) ?? cleaned
    }
}

/// Asks Claude Code once per folder what it offers, so the commands and models are there before the
/// first message. Nothing is sent to a model and no session is saved.
@Observable
final class ClaudeCatalog {
    static let shared = ClaudeCatalog()

    private(set) var byFolder: [String: ClaudeCapabilities] = [:]
    @ObservationIgnored private var requested = Set<String>()

    /// The models don't depend on the folder, so a new agent's worktree can name them right away.
    func capabilities(folder: String) -> ClaudeCapabilities {
        var capabilities = byFolder[folder] ?? ClaudeCapabilities()
        if capabilities.models.isEmpty { capabilities.models = byFolder.values.first { !$0.models.isEmpty }?.models ?? [] }
        return capabilities
    }

    func update(folder: String, commands: [ClaudeCommand]) { byFolder[folder, default: ClaudeCapabilities()].commands = commands }

    func load(folder: String, environment: [String: String]) {
        guard requested.insert(folder).inserted else { return }
        Task {
            let binary = ClaudeCodeRegistrar.findClaude() ?? "claude"
            let command = ClaudeChatModel.commandLine(binary: binary, resume: nil, mode: .ask, model: "")
            guard let reply = await Self.ask(ClaudeChatModel.process(folder: folder, environment: environment, command: command)) else {
                requested.remove(folder)
                return
            }
            byFolder[folder] = reply
        }
    }

    @concurrent private static func ask(_ process: Process) async -> ClaudeCapabilities? {
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        defer { process.terminate() }
        // A broken install shouldn't leave a process behind for good.
        let watchdog = Task.detached { [process] in
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { process.terminate() }
        }
        defer { watchdog.cancel() }
        try? stdin.fileHandleForWriting.write(contentsOf: Data((ClaudeMessage.control("initialize") + "\n").utf8))
        do {
            for try await line in stdout.fileHandleForReading.bytes.lines {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], object["type"] as? String == "control_response",
                      let response = (object["response"] as? [String: Any])?["response"] as? [String: Any] else { continue }
                return ClaudeCapabilities(reply: response)
            }
        } catch {
            Log.app.error("claude catalog: \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }
}

/// One row of the menu above the composer.
nonisolated struct ClaudeSuggestion: Equatable, Sendable, Identifiable {
    enum Action: Equatable, Sendable {
        /// Replace the composer's text and keep typing.
        case insert(String)
        /// Send this now.
        case run(String)
    }

    var id: String
    var title: String
    var detail: String = ""
    var isCode = true
    /// What Return does.
    var action: Action
    /// What Tab does: always finishes the text, never sends.
    var completion: String
}

/// An earlier conversation in this folder.
nonisolated struct ClaudeSessionSummary: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var date: Date
}

/// Decides what the menu above the composer offers for what's typed so far.
nonisolated enum ClaudeCompleter {
    /// What Vibex does itself, because a terminal-less Claude Code can't.
    static let localCommands = [
        ClaudeCommand(name: "plan", summary: "Plan mode: Claude proposes before changing anything", argumentHint: "[task]"),
        ClaudeCommand(name: "auto", summary: "Auto mode: Claude only stops for risky actions", argumentHint: "[task]"),
        ClaudeCommand(name: "ask", summary: "Ask mode: Claude asks before edits and commands"),
        ClaudeCommand(name: "accept-edits", summary: "Accept edits: file changes go ahead, commands ask"),
        ClaudeCommand(name: "new", summary: "Start a new chat"),
        ClaudeCommand(name: "agent", summary: "Start a parallel agent on its own branch", argumentHint: "<task>"),
        ClaudeCommand(name: "resume", summary: "Pick up an earlier conversation", argumentHint: "<conversation>"),
        ClaudeCommand(name: "skills", summary: "Open the Skills panel"),
        ClaudeCommand(name: "mcp", summary: "Open the MCP Servers panel"),
        ClaudeCommand(name: "help", summary: "How commands work here"),
    ]

    /// Shown first when nothing is typed yet: what people reach for most.
    private static let common = ["plan", "auto", "agent", "model", "compact", "clear", "context", "usage", "resume", "effort", "init"]
    private static let effortLevels = ["low", "medium", "high", "xhigh", "max"]
    /// Commands whose argument has its own menu, so picking the command opens that.
    private static let opensMenu: Set = ["model", "effort", "resume"]

    static func suggestions(for text: String, commands: [ClaudeCommand], models: [ClaudeModelOption], sessions: [ClaudeSessionSummary], files: [String]) -> [ClaudeSuggestion] {
        if text.hasPrefix("/") {
            let parts = text.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if parts.count == 1 { return commandRows(query: parts[0], commands: commands) }
            let query = parts[1].lowercased()
            switch parts[0] {
            case "model": return modelRows(query: query, models: models)
            case "effort": return effortLevels.filter { query.isEmpty || $0.hasPrefix(query) }.map { row("/effort \($0)", title: $0) }
            case "resume": return sessionRows(query: query, sessions: sessions)
            default: return []
            }
        }
        // A file: the word being typed starts with @.
        guard let last = text.split(separator: " ", omittingEmptySubsequences: false).last?.split(separator: "\n", omittingEmptySubsequences: false).last,
              last.hasPrefix("@") else { return [] }
        let query = String(last.dropFirst())
        let head = String(text.dropLast(last.count))
        return FuzzyMatch.rank(files, query: query, text: { $0 }).prefix(30).map(\.item).map { file in
            ClaudeSuggestion(id: "@\(file)", title: file, action: .insert("\(head)@\(file) "), completion: "\(head)@\(file) ")
        }
    }

    private static func merged(_ commands: [ClaudeCommand]) -> [ClaudeCommand] {
        let local = Set(localCommands.map(\.name))
        return localCommands + commands.filter { !local.contains($0.name) }
    }

    private static func commandRows(query: String, commands: [ClaudeCommand]) -> [ClaudeSuggestion] {
        let all = merged(commands)
        let query = query.lowercased()
        let ranked: [ClaudeCommand]
        if query.isEmpty {
            let first = common.compactMap { name in all.first { $0.name == name } }
            ranked = first + all.filter { !common.contains($0.name) }.sorted { $0.name < $1.name }
        } else {
            // What people reach for most beats alphabetical luck: /co means /compact before /color.
            let starts = all.filter { $0.name.lowercased().hasPrefix(query) }.sorted { a, b in
                let ranks = [a, b].map { command in common.firstIndex(of: command.name) ?? common.count }
                return ranks[0] != ranks[1] ? ranks[0] < ranks[1] : a.name.count < b.name.count
            }
            let inName = all.filter { !$0.name.lowercased().hasPrefix(query) && $0.name.lowercased().contains(query) }
            let inSummary = query.count < 3 ? [] : all.filter { !$0.name.lowercased().contains(query) && $0.summary.lowercased().contains(query) }
            ranked = starts + inName + inSummary
        }
        return ranked.map { command in
            // An optional argument can still run bare; a required one, or its own menu, can't.
            let mustContinue = opensMenu.contains(command.name) || command.argumentHint.hasPrefix("<")
            return ClaudeSuggestion(
                id: command.name,
                title: "/\(command.name)",
                // Some hints list every value; those are too long to help in one row.
                detail: [command.argumentHint.count <= 16 ? command.argumentHint : "", command.summary].filter { !$0.isEmpty }.joined(separator: "  "),
                action: mustContinue ? .insert("/\(command.name) ") : .run("/\(command.name)"),
                completion: "/\(command.name) "
            )
        }
    }

    private static func modelRows(query: String, models: [ClaudeModelOption]) -> [ClaudeSuggestion] {
        models.filter { query.isEmpty || $0.value.lowercased().contains(query) || $0.title.lowercased().contains(query) }
            .map { row("/model \($0.value)", title: $0.title, detail: $0.summary) }
    }

    private static func sessionRows(query: String, sessions: [ClaudeSessionSummary]) -> [ClaudeSuggestion] {
        sessions.filter { query.isEmpty || $0.title.lowercased().contains(query) }.map { session in
            var row = row("/resume \(session.id)", title: session.title, detail: session.date.formatted(.relative(presentation: .named)))
            row.isCode = false
            return row
        }
    }

    private static func row(_ command: String, title: String, detail: String = "") -> ClaudeSuggestion {
        ClaudeSuggestion(id: command, title: title, detail: detail, action: .run(command), completion: command)
    }
}
