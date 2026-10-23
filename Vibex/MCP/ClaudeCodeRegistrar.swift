import Foundation
import os

/// Registers the Vibex MCP server with the Claude Code CLI (`claude mcp add`) so every Claude Code
/// session, including the ones in Vibex's own terminal, has the tools without manual setup.
nonisolated struct ClaudeCodeRegistrar: Sendable {
    let url: String
    let token: String

    static let serverName = "vibex"

    enum Outcome: Sendable {
        case alreadyRegistered
        case registered
        case claudeNotFound
        case failed(String)
    }

    /// Everything `claude mcp add` needs, for the "Copy MCP Config" menu item.
    var addCommand: String {
        "claude mcp add --transport http --scope user \(Self.serverName) \(url) --header \"Authorization: Bearer \(token)\""
    }

    var jsonConfig: String {
        """
        {
          "mcpServers": {
            "\(Self.serverName)": {
              "type": "http",
              "url": "\(url)",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }

    @concurrent
    func ensureRegistered(force: Bool = false) async -> Outcome {
        guard let claude = Self.findClaude() else { return .claudeNotFound }
        let environment = Self.environment(forBinary: claude)
        if !force, let existing = try? Shell.run(claude, ["mcp", "get", Self.serverName], environment: environment),
           let text = String(data: existing, encoding: .utf8), text.contains(url), text.contains(token) {
            return .alreadyRegistered
        }
        _ = try? Shell.run(claude, ["mcp", "remove", "--scope", "user", Self.serverName], environment: environment)
        do {
            _ = try Shell.run(claude, ["mcp", "add", "--transport", "http", "--scope", "user", Self.serverName, url, "--header", "Authorization: Bearer \(token)"], environment: environment)
            return .registered
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The `claude` executable: the login shell's PATH first, then the usual install locations.
    static func findClaude() -> String? {
        if let data = try? Shell.run("/bin/zsh", ["-lc", "command -v claude"], environment: nil),
           let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node") {
            for version in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                candidates.append("\(home)/.nvm/versions/node/\(version)/bin/claude")
            }
        }
        return Shell.find(candidates)
    }

    /// `claude` is often a Node script; make sure its directory is on PATH so `node` resolves.
    static func environment(forBinary path: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let dir = (path as NSString).deletingLastPathComponent
        env["PATH"] = "\(dir):/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        return env
    }
}
