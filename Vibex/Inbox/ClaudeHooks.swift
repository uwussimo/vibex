import Foundation
import os

/// Claude Code hooks that tell Vibex when a session in one of its terminal tabs is waiting for the
/// user (a permission request or a question) and when it moves on, for the approval inbox. They live
/// in `~/.claude/settings.json` next to the user's own hooks, run asynchronously so Claude never
/// waits on them, and do nothing outside Vibex: the command needs `VIBEX_HOOK_URL`, which only
/// Vibex's terminals set.
nonisolated enum ClaudeHooks {
    /// Every Vibex hook command contains this; it is how they are found again to update or remove.
    static let marker = "VIBEX_HOOK_URL"

    /// The events, and the tool matcher for the ones that take one.
    static let events: [(name: String, matcher: String?)] = [
        ("PermissionRequest", "*"),
        ("Notification", nil),
        ("UserPromptSubmit", nil),
        ("PostToolUse", "*"),
        ("Stop", nil),
        ("SessionEnd", nil),
    ]

    /// Posts the hook's JSON (stdin) to Vibex with the tab and window it came from. Always exits 0.
    static let command = #"[ -n "$VIBEX_HOOK_URL" ] && curl -fsS -m 2 -X POST -H "Authorization: Bearer $VIBEX_MCP_TOKEN" -H "Content-Type: application/json" -H "X-Vibex-Tab: $VIBEX_TAB" -H "X-Vibex-Window: $VIBEX_WINDOW" --data-binary @- "$VIBEX_HOOK_URL" >/dev/null 2>&1; exit 0"#

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    // MARK: - Pure transformations (tested)

    static func isInstalled(in settings: [String: Any]) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return events.allSatisfy { event in
            (hooks[event.name] as? [[String: Any]] ?? []).contains { isVibex($0) && ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String == command }
        }
    }

    /// `settings` with Vibex's hooks added (or refreshed), leaving every other hook as it was.
    static func installed(into settings: [String: Any]) -> [String: Any] {
        var settings = removed(from: settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entries = hooks[event.name] as? [[String: Any]] ?? []
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command, "async": true]]]
            if let matcher = event.matcher { entry["matcher"] = matcher }
            entries.append(entry)
            hooks[event.name] = entries
        }
        settings["hooks"] = hooks
        return settings
    }

    /// `settings` without Vibex's hooks; events left with no hooks are dropped.
    static func removed(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (name, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !isVibex($0) }
            hooks[name] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    private static func isVibex(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    // MARK: - The settings file

    enum Status: Equatable { case installed, missing }

    static var status: Status {
        isInstalled(in: read()) ? .installed : .missing
    }

    static func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// Adds the hooks. The first time it touches the file, the original is kept next to it as
    /// `settings.json.vibex-backup`.
    static func install() throws {
        try write(installed(into: read()))
    }

    static func uninstall() throws {
        try write(removed(from: read()))
    }

    static func installIfNeeded(removedByUser: Bool) {
        guard !removedByUser, status == .missing else { return }
        do {
            try install()
            Log.app.info("added Vibex's approval hooks to Claude Code")
        } catch {
            Log.app.error("could not add Claude Code hooks: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func write(_ settings: [String: Any]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = settingsURL.appendingPathExtension("vibex-backup")
        if fileManager.fileExists(atPath: settingsURL.path), !fileManager.fileExists(atPath: backup.path) {
            try fileManager.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
