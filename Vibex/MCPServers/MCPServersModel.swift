import Foundation
import Observation
import os

/// An MCP server Claude Code is set up to use.
nonisolated struct InstalledMCPServer: Identifiable, Equatable, Sendable {
    /// Claude Code's scopes: every project (user), this project shared through `.mcp.json` (project),
    /// or this project on this Mac only (local).
    enum Scope: String, Sendable, CaseIterable { case user, project, local }

    var name: String
    var scope: Scope
    /// The command or URL, for the row's second line.
    var detail: String
    /// Where Claude Code gets a server that isn't in its config files ("Plugin", "claude.ai"); Vibex can't remove those.
    var origin: String?
    var id: String { "\(origin ?? scope.rawValue)|\(name)" }
    /// "plugin:figma:figma" → "figma"
    var displayName: String {
        if name.hasPrefix("plugin:") { return name.split(separator: ":").last.map(String.init) ?? name }
        if name.hasPrefix("claude.ai ") { return String(name.dropFirst("claude.ai ".count)) }
        return name
    }
    /// Vibex's own server, which Vibex manages.
    var isVibex: Bool { name == "vibex" }
}

/// Whether Claude Code can actually use a server, from `claude mcp list`.
nonisolated enum MCPHealth: Equatable, Sendable {
    case connected
    /// A remote server that signs in with OAuth: `/mcp` in Claude Code does it.
    case needsSignIn
    /// A `.mcp.json` server Claude Code hasn't been allowed to start in this project yet.
    case waitingForApproval
    case failed

    /// "clickup: https://mcp.clickup.com/mcp (HTTP) - ✔ Connected" → ("clickup", target, .connected)
    static func parse(_ output: String) -> [(name: String, target: String, health: MCPHealth)] {
        output.split(separator: "\n").compactMap { line in
            guard let colon = line.range(of: ": "), let dash = line.range(of: " - ", options: .backwards), colon.upperBound <= dash.lowerBound else { return nil }
            let name = String(line[..<colon.lowerBound])
            let target = String(line[colon.upperBound..<dash.lowerBound]).replacingOccurrences(of: " (HTTP)", with: "").replacingOccurrences(of: " (SSE)", with: "")
            let status = line[dash.upperBound...].lowercased()
            let health: MCPHealth = status.contains("connected") && !status.contains("failed") ? .connected
                : status.contains("auth") ? .needsSignIn
                : status.contains("approval") ? .waitingForApproval
                : .failed
            return (name, target, health)
        }
    }
}

/// Reads Claude Code's MCP config and changes it with the `claude` CLI, so installs land exactly
/// where Claude Code expects them.
nonisolated enum MCPServersStore {
    static var claudeJSON: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json") }

    static func installed(project: URL, claudeJSON: URL = claudeJSON) -> [InstalledMCPServer] {
        var servers: [InstalledMCPServer] = []
        let config = (try? Data(contentsOf: claudeJSON)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        servers += list(config["mcpServers"], scope: .user)
        let projects = config["projects"] as? [String: Any] ?? [:]
        servers += list((projects[project.path] as? [String: Any])?["mcpServers"], scope: .local)
        let shared = (try? Data(contentsOf: project.appendingPathComponent(".mcp.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        servers += list(shared?["mcpServers"], scope: .project)
        return servers
    }

    private static func list(_ value: Any?, scope: InstalledMCPServer.Scope) -> [InstalledMCPServer] {
        guard let servers = value as? [String: Any] else { return [] }
        return servers.compactMap { name, raw in
            let entry = raw as? [String: Any] ?? [:]
            let detail: String
            if let url = entry["url"] as? String {
                detail = url
            } else {
                let command = entry["command"] as? String ?? ""
                let arguments = (entry["args"] as? [String] ?? []).joined(separator: " ")
                detail = [command, arguments].filter { !$0.isEmpty }.joined(separator: " ")
            }
            return InstalledMCPServer(name: name, scope: scope, detail: detail, origin: nil)
        }
        .sorted { $0.name < $1.name }
    }

    /// `claude mcp list` in the project folder: every server Claude Code would load there, including
    /// plugins' and claude.ai's, with whether it connects. Takes a few seconds; it starts each one.
    @concurrent static func health(in folder: URL) async -> [(name: String, target: String, health: MCPHealth)] {
        guard let output = try? await claudeOutput(["mcp", "list"], in: folder) else { return [] }
        return MCPHealth.parse(output)
    }

    /// Runs `claude <arguments>` in the project folder (project scope writes `.mcp.json` there).
    @concurrent static func claude(_ arguments: [String], in folder: URL) async throws {
        _ = try await claudeOutput(arguments, in: folder)
    }

    @concurrent private static func claudeOutput(_ arguments: [String], in folder: URL) async throws -> String {
        guard let binary = ClaudeCodeRegistrar.findClaude() else {
            throw GitError.failed("Claude Code isn't installed. Install it from Setup & Permissions.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = ClaudeCodeRegistrar.environment(forBinary: binary)
        let errors = Pipe()
        let output = Pipe()
        process.standardError = errors
        process.standardOutput = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read before waiting, so a full pipe can't stall the process.
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.failed(message.isEmpty ? "claude exited with \(process.terminationStatus)" : message)
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// The MCP sidebar and marketplace: what's installed, featured servers, and registry search.
@Observable
final class MCPServersModel {
    private(set) var installed: [InstalledMCPServer] = []
    /// From `claude mcp list`, by server name; empty until the first check finishes.
    private(set) var health: [String: MCPHealth] = [:]
    /// Servers Claude Code gets from plugins and claude.ai rather than its config files.
    private(set) var external: [InstalledMCPServer] = []
    private(set) var isCheckingHealth = false
    private(set) var results: [MCPServerSpec] = []
    private(set) var isSearching = false
    private(set) var installing: Set<String> = []
    var query = "" {
        didSet { scheduleSearch() }
    }
    var problem: String?
    /// The server waiting on API keys or tokens before it can be installed.
    var pendingInstall: (spec: MCPServerSpec, scope: InstalledMCPServer.Scope)?
    let featured = MCPFeatured.servers
    let folder: URL
    private var searchTask: Task<Void, Never>?

    init(folder: URL) {
        self.folder = folder
    }

    func refresh() {
        let folder = folder
        Task {
            let list = await Self.read(folder)
            if list != installed { installed = list }
            await checkHealth()
        }
    }

    private func checkHealth() async {
        guard !isCheckingHealth else { return }
        isCheckingHealth = true
        defer { isCheckingHealth = false }
        let results = await MCPServersStore.health(in: folder)
        guard !results.isEmpty else { return }
        health = Dictionary(results.map { ($0.name, $0.health) }, uniquingKeysWith: { first, _ in first })
        let configured = Set(installed.map(\.name))
        external = results.filter { !configured.contains($0.name) }.map {
            InstalledMCPServer(name: $0.name, scope: .user, detail: $0.target, origin: $0.name.hasPrefix("plugin:") ? "Plugin" : $0.name.hasPrefix("claude.ai") ? "claude.ai" : "Claude Code")
        }
    }

    @concurrent private static func read(_ folder: URL) async -> [InstalledMCPServer] {
        MCPServersStore.installed(project: folder)
    }

    func isInstalled(_ spec: MCPServerSpec) -> Bool { installedScope(of: spec) != nil }

    /// Where it's installed, preferring the global install when it's in both.
    func installedScope(of spec: MCPServerSpec) -> InstalledMCPServer.Scope? {
        let scopes = installed.filter { $0.name == spec.name }.map(\.scope)
        return scopes.contains(.user) ? .user : scopes.first
    }

    /// Installs straight away, or asks for the fields it needs first.
    func install(_ spec: MCPServerSpec, scope: InstalledMCPServer.Scope) {
        if spec.inputs.contains(where: \.isRequired) {
            pendingInstall = (spec, scope)
        } else {
            install(spec, scope: scope, values: [:])
        }
    }

    func install(_ spec: MCPServerSpec, scope: InstalledMCPServer.Scope, values: [String: String]) {
        pendingInstall = nil
        installing.insert(spec.name)
        problem = nil
        let folder = folder
        Task {
            do {
                try await MCPServersStore.claude(spec.addArguments(scope: scope.rawValue, values: values), in: folder)
                Log.app.info("installed MCP server \(spec.name, privacy: .public) (\(scope.rawValue, privacy: .public))")
            } catch {
                problem = error.localizedDescription
            }
            installing.remove(spec.name)
            refresh()
        }
    }

    func remove(_ server: InstalledMCPServer) {
        guard !server.isVibex else { return }
        problem = nil
        let folder = folder
        Task {
            do {
                try await MCPServersStore.claude(["mcp", "remove", server.name, "--scope", server.scope.rawValue], in: folder)
            } catch {
                problem = error.localizedDescription
            }
            refresh()
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                let found = try await MCPRegistry.search(text)
                guard !Task.isCancelled else { return }
                results = found
                problem = nil
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                problem = error.localizedDescription
            }
            isSearching = false
        }
    }

    func retrySearch() { scheduleSearch() }
}
