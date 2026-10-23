import Foundation

/// One changed path as `git status` reports it.
nonisolated struct GitChange: Hashable, Sendable, Identifiable {
    enum Kind: Sendable {
        case modified, added, deleted, renamed, copied, typeChanged, untracked, conflicted

        var letter: String {
            switch self {
            case .modified: "M"
            case .added: "A"
            case .deleted: "D"
            case .renamed: "R"
            case .copied: "C"
            case .typeChanged: "T"
            case .untracked: "U"
            case .conflicted: "!"
            }
        }

        var label: String {
            switch self {
            case .modified: "Modified"
            case .added: "Added"
            case .deleted: "Deleted"
            case .renamed: "Renamed"
            case .copied: "Copied"
            case .typeChanged: "Type changed"
            case .untracked: "Untracked"
            case .conflicted: "Conflict"
            }
        }
    }

    enum Area: Sendable { case staged, unstaged, conflicted }

    let path: String
    /// The old path of a rename or copy.
    let originalPath: String?
    let kind: Kind
    let area: Area

    var id: String { "\(area)|\(path)" }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let directory = (path as NSString).deletingLastPathComponent
        return directory.isEmpty ? "" : directory
    }
}

/// What `git status --porcelain=v1 --branch -z` says about a repository.
nonisolated struct GitStatus: Equatable, Sendable {
    var branch: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var staged: [GitChange] = []
    var unstaged: [GitChange] = []
    var conflicted: [GitChange] = []

    var changeCount: Int { Set((staged + unstaged + conflicted).map(\.path)).count }
    var isClean: Bool { staged.isEmpty && unstaged.isEmpty && conflicted.isEmpty }

    /// Parses NUL-separated porcelain v1 output. Renames carry their original path as the next field.
    static func parse(_ output: String) -> GitStatus {
        var status = GitStatus()
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let field = fields.popFirst() {
            if field.hasPrefix("## ") {
                status.parseBranch(String(field.dropFirst(3)))
                continue
            }
            guard field.count > 3 else { continue }
            let x = field[field.startIndex]
            let y = field[field.index(after: field.startIndex)]
            let path = String(field.dropFirst(3))
            let original = (x == "R" || x == "C" || y == "R" || y == "C") ? fields.popFirst() : nil

            if x == "?" && y == "?" {
                status.unstaged.append(GitChange(path: path, originalPath: nil, kind: .untracked, area: .unstaged))
                continue
            }
            if x == "!" { continue }
            if isConflict(x, y) {
                status.conflicted.append(GitChange(path: path, originalPath: nil, kind: .conflicted, area: .conflicted))
                continue
            }
            if x != " ", let kind = kind(for: x) {
                status.staged.append(GitChange(path: path, originalPath: original, kind: kind, area: .staged))
            }
            if y != " ", let kind = kind(for: y) {
                status.unstaged.append(GitChange(path: path, originalPath: original, kind: kind, area: .unstaged))
            }
        }
        return status
    }

    /// `main...origin/main [ahead 1, behind 2]`, `HEAD (no branch)` or `No commits yet on main`.
    private mutating func parseBranch(_ line: String) {
        var head = line
        if let bracket = head.range(of: " [") {
            let counts = head[bracket.upperBound...].dropLast()
            for part in counts.split(separator: ",") {
                let words = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
                guard words.count == 2, let number = Int(words[1]) else { continue }
                if words[0] == "ahead" { ahead = number }
                if words[0] == "behind" { behind = number }
            }
            head = String(head[..<bracket.lowerBound])
        }
        for prefix in ["No commits yet on ", "Initial commit on "] where head.hasPrefix(prefix) {
            head = String(head.dropFirst(prefix.count))
        }
        if let dots = head.range(of: "...") {
            branch = String(head[..<dots.lowerBound])
            upstream = String(head[dots.upperBound...])
        } else {
            branch = head == "HEAD (no branch)" ? nil : head
        }
    }

    private static func isConflict(_ x: Character, _ y: Character) -> Bool {
        x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D")
    }

    private static func kind(for code: Character) -> GitChange.Kind? {
        switch code {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        default: nil
        }
    }
}

nonisolated enum GitError: Error, LocalizedError {
    case notInstalled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "Git is not installed. Install Xcode or its Command Line Tools."
        case let .failed(message): message
        }
    }
}

/// What a discard threw away, so it can be put back.
nonisolated struct DiscardBackup: Sendable {
    enum Entry: Sendable {
        /// A tracked file's contents before the discard, saved as a blob.
        case saved(path: String, blob: String, permissions: Int?)
        /// A tracked file that was already deleted; the discard brought it back.
        case missing(path: String)
        /// An untracked file, now in the Trash.
        case trashed(path: String, location: URL)
    }

    var entries: [Entry] = []
}

/// A git failure in words people can act on, with the one action that usually fixes it.
nonisolated struct GitProblem: Equatable, Sendable {
    enum Fix: Sendable { case pull, publish }

    var message: String
    /// git's own output, when `message` rephrases it.
    var detail: String?
    var fix: Fix?

    static func explain(_ error: Error) -> GitProblem {
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = raw.lowercased()
        func problem(_ message: String, _ fix: Fix? = nil) -> GitProblem {
            GitProblem(message: message, detail: raw, fix: fix)
        }
        if text.contains("has no upstream branch") {
            return problem("This branch isn't on the remote yet.", .publish)
        }
        if text.contains("[rejected]") || text.contains("fetch first") || text.contains("non-fast-forward") {
            return problem("The remote has commits you don't have yet. Pull, then push again.", .pull)
        }
        if text.contains("not possible to fast-forward") || text.contains("divergent branches") || text.contains("diverging branches") {
            return problem("Your branch and the remote have both moved on. Merge or rebase in the terminal.")
        }
        if text.contains("would be overwritten by merge") {
            return problem("Pulling would overwrite files you've changed. Commit or discard them first.")
        }
        if text.contains("could not read username") || text.contains("authentication failed")
            || text.contains("permission denied (publickey)") || text.contains("terminal prompts disabled") {
            return problem("Git couldn't sign in to the remote. Run git push once in the terminal to save your credentials.")
        }
        if text.contains("please tell me who you are") || text.contains("unable to auto-detect email") {
            return problem("Git doesn't know your name yet. Set user.name and user.email with git config --global.")
        }
        if text.contains("could not resolve host") || text.contains("could not connect") || text.contains("network is unreachable") {
            return problem("Can't reach the remote. Check your connection and try again.")
        }
        if text.contains("index.lock") {
            return problem("Another git command is running in this repository. Try again when it finishes.")
        }
        // Anything else: git's first real line, without its "fatal:" or "error:" prefix.
        let lines = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var message = lines.first { !$0.isEmpty && !$0.hasPrefix("hint:") } ?? raw
        for prefix in ["fatal: ", "error: "] where message.hasPrefix(prefix) {
            message = String(message.dropFirst(prefix.count))
        }
        message = message.prefix(1).uppercased() + message.dropFirst()
        return GitProblem(message: message, detail: message == raw ? nil : raw, fix: nil)
    }
}

/// The `git` command line for one working tree. Every call runs off the main actor.
nonisolated struct GitRepository: Sendable {
    let root: URL

    static let executable = "/usr/bin/git"
    /// Diffs larger than this are cut off; nobody reads a 40 MB diff in a sidebar.
    static let diffLimit = 2_000_000

    /// The top of the working tree containing `folder`, or nil when it is not in a repository.
    @concurrent static func find(containing folder: URL) async -> GitRepository? {
        guard let output = try? run(["rev-parse", "--show-toplevel"], in: folder).output else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : GitRepository(root: URL(fileURLWithPath: path))
    }

    @concurrent static func initialize(at folder: URL) async throws {
        try run(["init"], in: folder).check()
    }

    @concurrent func status() async throws -> GitStatus {
        let result = try run(["status", "--porcelain=v1", "--branch", "-z", "--untracked-files=all"])
        try result.check()
        return GitStatus.parse(result.output)
    }

    @concurrent func diff(for change: GitChange) async throws -> FileDiff {
        let result: Result
        switch change.kind {
        case .untracked:
            // Exit status 1 just means "there are differences".
            result = try run(["diff", "--no-index", "--no-color", "--no-ext-diff", "--", "/dev/null", change.path], limit: Self.diffLimit)
        default:
            var arguments = ["diff", "--no-color", "--no-ext-diff", "-M"]
            if change.area == .staged { arguments.append("--cached") }
            arguments.append("--")
            if let original = change.originalPath { arguments.append(original) }
            arguments.append(change.path)
            result = try run(arguments, limit: Self.diffLimit)
        }
        guard result.status == 0 || result.status == 1 else { throw GitError.failed(result.errors) }
        var diff = DiffParser.parse(result.output)
        diff.isTruncated = result.truncated
        return diff
    }

    @concurrent func stage(_ paths: [String]) async throws {
        try run(["add", "--all", "--"] + paths).check()
    }

    @concurrent func unstage(_ paths: [String]) async throws {
        // `restore --staged` fails before the first commit; `rm --cached` covers that case.
        let result = try run(["restore", "--staged", "--"] + paths)
        if result.status != 0 { try run(["rm", "--cached", "-r", "--quiet", "--"] + paths).check() }
    }

    /// Throws away working-tree changes, keeping enough to undo it: tracked files' current contents
    /// go into git's object store first, and untracked files move to the Trash instead of being deleted.
    @concurrent func discard(_ changes: [GitChange]) async throws -> DiscardBackup {
        let fileManager = FileManager.default
        var backup = DiscardBackup()
        let tracked = changes.filter { $0.kind != .untracked }.map(\.path)
        for path in tracked {
            let url = root.appendingPathComponent(path)
            if fileManager.fileExists(atPath: url.path) {
                let blob = try run(["hash-object", "-w", "--no-filters", "--", path]).checkedOutput()
                let permissions = (try? fileManager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
                backup.entries.append(.saved(path: path, blob: blob, permissions: permissions))
            } else {
                backup.entries.append(.missing(path: path))
            }
        }
        if !tracked.isEmpty { try run(["restore", "--worktree", "--"] + tracked).check() }
        for change in changes where change.kind == .untracked {
            var trashed: NSURL?
            try fileManager.trashItem(at: root.appendingPathComponent(change.path), resultingItemURL: &trashed)
            if let trashed { backup.entries.append(.trashed(path: change.path, location: trashed as URL)) }
        }
        return backup
    }

    /// Puts back what `discard` threw away. A file recreated since then is left alone.
    @concurrent func restore(_ backup: DiscardBackup) async throws {
        let fileManager = FileManager.default
        for entry in backup.entries {
            switch entry {
            case let .saved(path, blob, permissions):
                let url = root.appendingPathComponent(path)
                let contents = try run(["cat-file", "blob", blob])
                try contents.check()
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.data.write(to: url, options: .atomic)
                if let permissions { try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
            case let .missing(path):
                try? fileManager.removeItem(at: root.appendingPathComponent(path))
            case let .trashed(path, location):
                let url = root.appendingPathComponent(path)
                guard !fileManager.fileExists(atPath: url.path) else { continue }
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: location, to: url)
            }
        }
    }

    /// Commits what is staged and returns the new commit's short hash.
    @concurrent func commit(message: String) async throws -> String {
        try run(["commit", "--quiet", "-m", message]).check()
        return (try? run(["rev-parse", "--short", "HEAD"]).checkedOutput()) ?? ""
    }

    @concurrent func push() async throws {
        try run(["push", "--quiet"]).check()
    }

    /// Pushes a branch that has no upstream yet and tracks it (origin when there is one). Returns the remote.
    @concurrent func publish() async throws -> String {
        let remotes = await remotes()
        guard let remote = remotes.contains("origin") ? "origin" : remotes.first else {
            throw GitError.failed("This repository has no remote to push to.")
        }
        try run(["push", "--quiet", "--set-upstream", remote, "HEAD"]).check()
        return remote
    }

    @concurrent func remotes() async -> [String] {
        guard let output = try? run(["remote"]).checkedOutput() else { return [] }
        return output.split(separator: "\n").map(String.init)
    }

    @concurrent func pull() async throws {
        try run(["pull", "--ff-only", "--quiet"]).check()
    }

    // MARK: - Running git

    struct Result: Sendable {
        var data: Data
        var errors: String
        var status: Int32
        var truncated: Bool

        func check() throws {
            guard status == 0 else {
                let message = errors.trimmingCharacters(in: .whitespacesAndNewlines)
                throw GitError.failed(message.isEmpty ? "git exited with \(status)" : message)
            }
        }

        var output: String { String(decoding: data, as: UTF8.self) }

        /// The output without its trailing newline, after checking the command succeeded.
        func checkedOutput() throws -> String {
            try check()
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @discardableResult
    private func run(_ arguments: [String], limit: Int? = nil) throws -> Result {
        try Self.run(arguments, in: root, limit: limit)
    }

    @discardableResult
    private static func run(_ arguments: [String], in directory: URL, limit: Int? = nil) throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw GitError.notInstalled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-c", "core.quotepath=off", "-c", "color.ui=false"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"   // never hang waiting for a password
        environment["GIT_OPTIONAL_LOCKS"] = "0"    // status must not fight the user's own git commands
        environment["LC_ALL"] = "C"
        environment["PATH"] = Toolchain.path(appending: environment["PATH"])
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Read stderr concurrently so a chatty command can't fill its pipe and deadlock.
        let errorData = ErrorBuffer()
        let errorReader = Thread { errorData.set(errors.fileHandleForReading.readDataToEndOfFile()) }
        errorReader.start()

        var data = Data()
        var truncated = false
        let handle = output.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if let limit, data.count > limit {
                truncated = true
                process.terminate()
                break
            }
        }
        process.waitUntilExit()
        errorData.wait()
        return Result(
            data: data,
            errors: String(decoding: errorData.data, as: UTF8.self),
            status: truncated ? 0 : process.terminationStatus,
            truncated: truncated
        )
    }

    private final class ErrorBuffer: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private(set) var data = Data()

        func set(_ data: Data) {
            self.data = data
            done.signal()
        }

        func wait() { done.wait() }
    }
}
