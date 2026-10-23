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

    /// Throws away working-tree changes. Untracked files are deleted.
    @concurrent func discard(_ changes: [GitChange]) async throws {
        let untracked = changes.filter { $0.kind == .untracked }.map(\.path)
        let tracked = changes.filter { $0.kind != .untracked }.map(\.path)
        if !tracked.isEmpty { try run(["restore", "--worktree", "--"] + tracked).check() }
        if !untracked.isEmpty { try run(["clean", "-f", "-q", "--"] + untracked).check() }
    }

    @concurrent func commit(message: String) async throws {
        try run(["commit", "--quiet", "-m", message]).check()
    }

    @concurrent func push() async throws {
        try run(["push", "--quiet"]).check()
    }

    @concurrent func pull() async throws {
        try run(["pull", "--ff-only", "--quiet"]).check()
    }

    // MARK: - Running git

    struct Result: Sendable {
        var output: String
        var errors: String
        var status: Int32
        var truncated: Bool

        func check() throws {
            guard status == 0 else {
                let message = errors.trimmingCharacters(in: .whitespacesAndNewlines)
                throw GitError.failed(message.isEmpty ? "git exited with \(status)" : message)
            }
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
            output: String(decoding: data, as: UTF8.self),
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
