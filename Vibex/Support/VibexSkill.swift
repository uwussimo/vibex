import Foundation
import os

/// Keeps the `vibex` skill in `~/.claude/skills/vibex`, so Claude Code in any project knows what Vibex
/// is and how to use its MCP tools. Installed at launch and refreshed when Vibex updates. A skill the
/// user wrote themselves (no Vibex marker), or one they removed in the Skills sidebar, is left alone.
nonisolated enum VibexSkill {
    enum Status: Equatable { case current, outdated, missing, userOwned }

    static let name = "vibex"
    static let marker = "<!-- Installed by Vibex "

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/\(name)")
    }
    static var file: URL { folder.appendingPathComponent("SKILL.md") }

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// The skill as this build of Vibex ships it.
    static func bundledText(version: String = version) -> String? {
        guard let url = Bundle.main.url(forResource: "VibexSkill", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.replacingOccurrences(of: "{{VERSION}}", with: version)
    }

    static func status(of installed: String?, bundled: String?) -> Status {
        guard let installed else { return .missing }
        guard installed.contains(marker) else { return .userOwned }
        return installed == bundled ? .current : .outdated
    }

    static var status: Status { status(in: folder) }

    static func status(in folder: URL) -> Status {
        // A symlink means it came from somewhere else (skills.sh, a dotfiles repo).
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: folder.path)) != nil { return .userOwned }
        let file = folder.appendingPathComponent("SKILL.md")
        return status(of: try? String(contentsOf: file, encoding: .utf8), bundled: bundledText())
    }

    /// At launch: install or update, unless the user removed it.
    static func installIfNeeded(removedByUser: Bool) {
        guard !removedByUser else { return }
        switch status {
        case .missing, .outdated:
            do {
                try install()
                Log.app.info("installed the vibex skill for Claude Code")
            } catch {
                Log.app.error("could not install the vibex skill: \(error.localizedDescription, privacy: .public)")
            }
        case .current, .userOwned:
            break
        }
    }

    static func install(into folder: URL = folder) throws {
        guard let text = bundledText() else { throw CocoaError(.fileReadNoSuchFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }
}
