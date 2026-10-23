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
    var id: String { "\(scope.rawValue)|\(name)" }
    /// Vibex's own server, which Vibex manages.
    var isVibex: Bool { name == "vibex" }
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
            return InstalledMCPServer(name: name, scope: scope, detail: detail)
        }
        .sorted { $0.name < $1.name }
    }

    /// Runs `claude <arguments>` in the project folder (project scope writes `.mcp.json` there).
    @concurrent static func claude(_ arguments: [String], in folder: URL) async throws {
        guard let binary = ClaudeCodeRegistrar.findClaude() else {
            throw GitError.failed("Claude Code isn't installed. Install it from Setup & Permissions.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = ClaudeCodeRegistrar.environment(forBinary: binary)
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.failed(message.isEmpty ? "claude exited with \(process.terminationStatus)" : message)
        }
    }
}

/// The MCP sidebar and marketplace: what's installed, featured servers, and registry search.
@Observable
final class MCPServersModel {
    private(set) var installed: [InstalledMCPServer] = []
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
        }
    }

    @concurrent private static func read(_ folder: URL) async -> [InstalledMCPServer] {
        MCPServersStore.installed(project: folder)
    }

    func isInstalled(_ spec: MCPServerSpec) -> Bool { installed.contains { $0.name == spec.name } }

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
