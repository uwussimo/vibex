import Foundation

/// How a shell is launched inside a tab.
struct TerminalSession {
    let shell: String
    let arguments: [String]
    let environment: [String]
    let directory: String

    /// Environment every new shell gets app-wide (the MCP server address, for Claude Code).
    nonisolated(unsafe) static var extraEnvironment: [String: String] = [:]

    static func login(directory: String? = nil, environment windowEnvironment: [String: String] = [:]) -> TerminalSession {
        let shell = preferredShell()
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Vibex"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["PATH"] = Toolchain.path(appending: env["PATH"])
        for (key, value) in extraEnvironment { env[key] = value }
        for (key, value) in windowEnvironment { env[key] = value }
        env.removeValue(forKey: "TERM_SESSION_ID")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cwd = directory.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? home
        return TerminalSession(
            shell: shell,
            arguments: ["-l"],
            environment: env.map { "\($0.key)=\($0.value)" },
            directory: cwd
        )
    }

    /// fish when it is installed, otherwise the user's login shell.
    static func preferredShell() -> String {
        let fishCandidates = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
        if let fish = fishCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return fish
        }
        return ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    /// argv[0] with a leading dash, which is how shells learn they are login shells.
    var execName: String { "-" + (shell as NSString).lastPathComponent }
}
