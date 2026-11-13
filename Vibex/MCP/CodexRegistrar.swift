import Foundation
import os

/// Registers the Vibex MCP server with Codex, so Codex sessions get the same tools as Claude Code.
/// Codex reads `~/.codex/config.toml`, and Vibex keeps one block of it, `[mcp_servers.vibex]`,
/// pointed at the current address and token. Everything else in the file is left as it was.
nonisolated struct CodexRegistrar: Sendable {
    let url: String
    let token: String

    enum Outcome: Sendable, Equatable {
        case alreadyRegistered
        case registered
        case codexNotFound
        case failed(String)
    }

    static let header = "[mcp_servers.\(ClaudeCodeRegistrar.serverName)]"
    private static let note = "# Kept current by Vibex: its address and token. Edit the rest of this file freely."

    /// `$CODEX_HOME`, or `~/.codex`.
    static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static var configURL: URL { home.appendingPathComponent("config.toml") }

    /// Codex has run on this Mac at least once.
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: home.path) }

    var block: String {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return """
        \(Self.note)
        \(Self.header)
        url = \(quoted(url))
        http_headers = { Authorization = \(quoted("Bearer \(token)")) }
        """
    }

    @concurrent
    func ensureRegistered() async -> Outcome {
        guard Self.isInstalled else { return .codexNotFound }
        let url = Self.configURL
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = Self.updating(existing, with: block)
        guard updated != existing else { return .alreadyRegistered }
        do {
            let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
            try updated.write(to: url, atomically: true, encoding: .utf8)
            if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
            return .registered
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The config with Vibex's block in place of the old one, or added at the end.
    static func updating(_ config: String, with block: String) -> String {
        var lines = config.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
            let body = lines.joined(separator: "\n")
            return (body.isEmpty ? "" : body + "\n\n") + block + "\n"
        }
        // The block ends at the next table, even one of its own such as a tool's settings: those are the user's.
        var end = start + 1
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
        // Blank lines before the next table stay with it.
        while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        var first = start
        if first > 0, lines[first - 1] == note { first -= 1 }
        // Settings the user added to the block, such as how its tools are approved, stay under it.
        let owned: Set<String> = ["url", "http_headers"]
        let kept = lines[(start + 1)..<end].filter { line in
            let key = line.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
            return !owned.contains(key)
        }
        lines.replaceSubrange(first..<end, with: block.components(separatedBy: "\n") + kept)
        return lines.joined(separator: "\n") + "\n"
    }
}
