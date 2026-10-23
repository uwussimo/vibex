import Foundation

/// Every Claude response Claude Code has logged, folded into hourly totals per model and project.
/// Kept on disk so a launch reads only what the logs gained since the last one.
nonisolated struct ClaudeUsageLedger: Codable, Sendable {
    struct Bucket: Codable, Hashable, Sendable {
        /// Hours since 1970, UTC.
        var hour: Int
        var model: String
        var project: String
    }

    /// Per log file: how far it has been read, and its latest stretch of activity for "Now".
    struct FileState: Codable, Sendable {
        var offset: UInt64 = 0
        var project = ""
        var model = ""
        var runStart: Date?
        var lastActivity: Date?
        var runOutput = 0
        var runCost = 0.0
    }

    static let version = 1
    /// A gap longer than this ends a stretch of activity in one session.
    static let runGap: TimeInterval = 30 * 60

    var version = Self.version
    var files: [String: FileState] = [:]
    var buckets: [Bucket: TokenUsage] = [:]
    /// Hashes of message ids already counted: Claude Code repeats a response's usage on every
    /// content block, and resumed sessions copy earlier messages into a new file.
    var seen: Set<UInt64> = []

    // MARK: - Reading the logs

    static var projectsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// Reads whatever the logs gained since the last call. Returns false when a file shrank, which
    /// means it was rewritten and the ledger must be rebuilt from scratch.
    mutating func update(from folder: URL = projectsFolder) -> Bool {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return true }
        let parser = LineParser()
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { continue }
            var state = files[url.path] ?? FileState()
            if UInt64(size) < state.offset { return false }
            guard UInt64(size) > state.offset, let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            try? handle.seek(toOffset: state.offset)
            guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { continue }
            let complete = data[data.startIndex...lastNewline]
            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let record = parser.parse(line) else { continue }
                record.apply(to: &self, file: &state)
            }
            state.offset += UInt64(complete.count)
            files[url.path] = state
        }
        return true
    }

    // MARK: - Persistence

    static var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("com.yusuf.vibex/claude-usage.plist")
    }

    static func load() -> ClaudeUsageLedger {
        guard let data = try? Data(contentsOf: cacheURL),
              let ledger = try? PropertyListDecoder().decode(ClaudeUsageLedger.self, from: data),
              ledger.version == version else { return ClaudeUsageLedger() }
        return ledger
    }

    func save() {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.cacheURL, options: .atomic)
    }
}

/// One assistant response's usage, pulled from a log line.
nonisolated struct ClaudeUsageRecord {
    var key: UInt64
    var date: Date
    var model: String
    var project: String
    var usage: TokenUsage

    func apply(to ledger: inout ClaudeUsageLedger, file state: inout ClaudeUsageLedger.FileState) {
        guard ledger.seen.insert(key).inserted else { return }
        let bucket = ClaudeUsageLedger.Bucket(hour: Int(date.timeIntervalSince1970 / 3600), model: model, project: project)
        ledger.buckets[bucket, default: TokenUsage()] += usage

        if let last = state.lastActivity, date.timeIntervalSince(last) < ClaudeUsageLedger.runGap, state.runStart != nil {
            state.runOutput += usage.output
            state.runCost += usage.cost
        } else {
            state.runStart = date
            state.runOutput = usage.output
            state.runCost = usage.cost
        }
        state.lastActivity = max(state.lastActivity ?? date, date)
        state.project = project
        state.model = model
    }
}

/// Turns JSONL lines into records, skipping everything that isn't a billed assistant response.
nonisolated final class LineParser {
    private let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let plainDates = ISO8601DateFormatter()
    private static let usageMarker = Data(#""usage""#.utf8)
    private static let assistantMarker = Data(#""assistant""#.utf8)

    func parse(_ line: Data.SubSequence) -> ClaudeUsageRecord? {
        // Most lines are tool output or user turns; skip them without decoding.
        guard line.range(of: Self.usageMarker) != nil, line.range(of: Self.assistantMarker) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let model = message["model"] as? String, AgentPricing.rate(for: model) != nil,
              let usage = message["usage"] as? [String: Any],
              let stamp = object["timestamp"] as? String,
              let date = dates.date(from: stamp) ?? plainDates.date(from: stamp) else { return nil }

        func int(_ dictionary: [String: Any]?, _ key: String) -> Int { (dictionary?[key] as? NSNumber)?.intValue ?? 0 }
        var tokens = TokenUsage()
        tokens.input = int(usage, "input_tokens")
        tokens.output = int(usage, "output_tokens")
        tokens.cacheRead = int(usage, "cache_read_input_tokens")
        let creation = usage["cache_creation"] as? [String: Any]
        if creation != nil {
            tokens.cacheWrite5m = int(creation, "ephemeral_5m_input_tokens")
            tokens.cacheWrite1h = int(creation, "ephemeral_1h_input_tokens")
        } else {
            tokens.cacheWrite5m = int(usage, "cache_creation_input_tokens")
        }
        tokens.cost = AgentPricing.cost(tokens, model: model, fast: usage["speed"] as? String == "fast")

        let id = (message["id"] as? String ?? "") + ":" + (object["requestId"] as? String ?? stamp)
        let cwd = object["cwd"] as? String ?? ""
        return ClaudeUsageRecord(
            key: Self.hash(id),
            date: date,
            model: model,
            project: cwd.isEmpty ? "Other" : (cwd as NSString).lastPathComponent,
            usage: tokens
        )
    }

    /// FNV-1a: stable across launches, unlike `Hasher`.
    static func hash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}
