import Foundation

enum CommandLineToolError: Error, LocalizedError {
    case missingFromBundle
    case occupied(String)

    var errorDescription: String? {
        switch self {
        case .missingFromBundle: "This build of Vibex does not include the vibex command."
        case let .occupied(path): "\(path) already exists and is not a Vibex link. Remove it and try again."
        }
    }
}

/// Installs the `vibex` shell command (`vibex .` opens a folder) as a symlink into the bundle, like VS Code's `code`.
nonisolated enum CommandLineTool {
    static let name = "vibex"

    static var bundled: String? { Bundle.main.path(forResource: name, ofType: nil) }

    /// Homebrew's bin first (writable without a password), then /usr/local/bin, which is on the default PATH.
    static let directories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Where a working `vibex` link already is, if anywhere (the curl installer may also use ~/.local/bin or ~/bin).
    static var installedPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (directories + ["\(home)/.local/bin", "\(home)/bin"]).map { "\($0)/\(name)" }.first { path in
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return false }
            return destination.hasSuffix(".app/Contents/Resources/\(name)") && FileManager.default.isExecutableFile(atPath: path)
        }
    }

    /// Links the command and returns where it went. Asks for an administrator password only when no directory is writable.
    @concurrent static func install() async throws -> String {
        guard let source = bundled else { throw CommandLineToolError.missingFromBundle }
        let fileManager = FileManager.default
        if let directory = directories.first(where: { fileManager.isWritableFile(atPath: $0) }) {
            let link = "\(directory)/\(name)"
            try removeOldLink(at: link)
            try fileManager.createSymbolicLink(atPath: link, withDestinationPath: source)
            return link
        }
        let link = "/usr/local/bin/\(name)"
        try removeOldLink(at: link, dryRun: true)
        let command = "mkdir -p /usr/local/bin && ln -sf \(quoted(source)) \(quoted(link))"
        let script = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        _ = try Shell.run("/usr/bin/osascript", ["-e", script])
        return link
    }

    /// Replaces only a previous Vibex link, never somebody else's file.
    private static func removeOldLink(at path: String, dryRun: Bool = false) throws {
        let fileManager = FileManager.default
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: path) else {
            if fileManager.fileExists(atPath: path) { throw CommandLineToolError.occupied(path) }
            return
        }
        guard destination.hasSuffix(".app/Contents/Resources/\(name)") else { throw CommandLineToolError.occupied(path) }
        if !dryRun { try fileManager.removeItem(atPath: path) }
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
