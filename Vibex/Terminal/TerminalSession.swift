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

    /// The user's own login shell (System Settings › Users & Groups, or `chsh`), so tabs have the
    /// same PATH, node version manager and aliases as their regular terminal.
    static func preferredShell() -> String {
        let candidates = [
            getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } },
            ProcessInfo.processInfo.environment["SHELL"],
        ]
        return candidates.compactMap { $0 }.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) } ?? "/bin/zsh"
    }

    /// argv[0] with a leading dash, which is how shells learn they are login shells.
    var execName: String { "-" + (shell as NSString).lastPathComponent }
}
