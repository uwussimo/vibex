import Foundation

/// The Claude plan, from Claude Code's account file, so spending can be compared with what it costs.
nonisolated struct ClaudePlan: Equatable, Sendable {
    var name: String
    /// Dollars per month.
    var price: Double

    static func detect() -> ClaudePlan? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any] else { return nil }
        let tier = (account["organizationRateLimitTier"] as? String ?? account["organizationType"] as? String ?? "").lowercased()
        if tier.contains("max_20x") { return ClaudePlan(name: "Max 20×", price: 200) }
        if tier.contains("max_5x") || tier.contains("claude_max") { return ClaudePlan(name: "Max 5×", price: 100) }
        if tier.contains("pro") { return ClaudePlan(name: "Pro", price: 20) }
        if tier.contains("team") { return ClaudePlan(name: "Team", price: 30) }
        return nil
    }
}

/// Codex's own rate-limit report, from the newest `token_count` event in its session logs.
nonisolated struct CodexLimits: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        var usedPercent: Double
        var minutes: Int
        var resetsAt: Date?
    }

    var plan: String?
    var primary: Window?
    var secondary: Window?
    var updated: Date

    static var sessionsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: sessionsFolder.deletingLastPathComponent().path)
    }

    /// Looks through the most recently written session files, newest first.
    static func read() -> CodexLimits? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: sessionsFolder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate { files.append((url, date)) }
        }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for (url, modified) in files.sorted(by: { $0.1 > $1.1 }).prefix(8) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
            guard let data = try? handle.readToEnd() else { continue }
            for line in data.split(separator: 0x0A).reversed() where line.range(of: Data("rate_limits".utf8)) != nil {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let payload = object["payload"] as? [String: Any],
                      let limits = payload["rate_limits"] as? [String: Any] else { continue }
                func window(_ key: String) -> Window? {
                    guard let value = limits[key] as? [String: Any], let used = value["used_percent"] as? NSNumber else { return nil }
                    let resets = (value["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                    return Window(usedPercent: used.doubleValue, minutes: (value["window_minutes"] as? NSNumber)?.intValue ?? 0, resetsAt: resets)
                }
                let stamp = (object["timestamp"] as? String).flatMap { dates.date(from: $0) } ?? modified
                return CodexLimits(
                    plan: (limits["plan_type"] as? String)?.capitalized,
                    primary: window("primary"),
                    secondary: window("secondary"),
                    updated: stamp
                )
            }
        }
        return nil
    }
}

/// Everything the AI Usage dashboard shows, computed from the ledger in one pass.
nonisolated struct AgentUsageSummary: Equatable, Sendable {
    struct Day: Equatable, Sendable, Identifiable {
        var date: Date
        var cost: Double
        var tokens: Int
        var id: Date { date }
    }

    struct Share: Equatable, Sendable, Identifiable {
        var name: String
        var cost: Double
        var id: String { name }
    }

    struct Session: Equatable, Sendable, Identifiable {
        var id: String
        var project: String
        var model: String
        var started: Date
        var output: Int
        var cost: Double
    }

    /// Claude's usage resets in 5-hour windows that start with the first message after the last one ended.
    struct Block: Equatable, Sendable {
        var cost: Double
        var resetsAt: Date
    }

    var periodDays: Int
    var periodCost = 0.0
    var periodTokens = 0
    var cacheShare = 0.0
    var trend: [Day] = []
    var models: [Share] = []
    var projects: [Share] = []
    var currentBlock: Block?
    var largestBlockCost = 0.0
    /// The largest session before the current one: the automatic limit, so a record session
    /// in progress isn't always at 100%.
    var largestPastBlockCost = 0.0
    var active: [Session] = []
    /// 13 weeks of days, oldest first, starting on the first day of a week.
    var activity: [Day] = []
    var activityCost = 0.0
    var activeDays = 0
    var busiestDay: Day?
    var streak = 0
    var isEmpty: Bool { periodCost == 0 && activity.allSatisfy { $0.cost == 0 } }

    static let blockLength: TimeInterval = 5 * 3600

    static func make(from ledger: ClaudeUsageLedger, periodDays: Int, now: Date = Date(), calendar: Calendar = .current) -> AgentUsageSummary {
        var summary = AgentUsageSummary(periodDays: periodDays)
        let today = calendar.startOfDay(for: now)
        let periodStart = calendar.date(byAdding: .day, value: -(periodDays - 1), to: today)!

        var byDay: [Date: Day] = [:]
        var byModel: [String: Double] = [:]
        var byProject: [String: Double] = [:]
        var byHour: [Int: Double] = [:]
        var cacheRead = 0
        for (bucket, usage) in ledger.buckets {
            let date = Date(timeIntervalSince1970: Double(bucket.hour) * 3600)
            let day = calendar.startOfDay(for: date)
            byDay[day, default: Day(date: day, cost: 0, tokens: 0)].cost += usage.cost
            byDay[day]!.tokens += usage.total
            byHour[bucket.hour, default: 0] += usage.cost
            guard day >= periodStart else { continue }
            summary.periodCost += usage.cost
            summary.periodTokens += usage.total
            cacheRead += usage.cacheRead
            byModel[AgentPricing.displayName(bucket.model), default: 0] += usage.cost
            byProject[bucket.project, default: 0] += usage.cost
        }
        summary.cacheShare = summary.periodTokens > 0 ? Double(cacheRead) / Double(summary.periodTokens) : 0
        summary.trend = (0..<periodDays).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: periodStart)!
            return byDay[day] ?? Day(date: day, cost: 0, tokens: 0)
        }
        summary.models = byModel.map { Share(name: $0.key, cost: $0.value) }.sorted { $0.cost > $1.cost }.filter { $0.cost > 0.005 }
        summary.projects = byProject.map { Share(name: $0.key, cost: $0.value) }.sorted { $0.cost > $1.cost }.filter { $0.cost > 0.005 }

        // 5-hour blocks, starting at the hour of the first message after the previous block ended.
        var blockStart: Int?
        var blockCost = 0.0
        for hour in byHour.keys.sorted() {
            if let start = blockStart, hour < start + 5 {
                blockCost += byHour[hour]!
            } else {
                summary.largestBlockCost = max(summary.largestBlockCost, blockCost)
                blockStart = hour
                blockCost = byHour[hour]!
            }
        }
        summary.largestPastBlockCost = summary.largestBlockCost
        summary.largestBlockCost = max(summary.largestBlockCost, blockCost)
        if let start = blockStart {
            let resets = Date(timeIntervalSince1970: Double(start) * 3600 + blockLength)
            if resets > now {
                summary.currentBlock = Block(cost: blockCost, resetsAt: resets)
            } else {
                summary.largestPastBlockCost = summary.largestBlockCost
            }
        }

        summary.active = ledger.files.compactMap { path, state in
            guard let last = state.lastActivity, now.timeIntervalSince(last) < 5 * 60, let started = state.runStart else { return nil }
            return Session(id: path, project: state.project, model: AgentPricing.displayName(state.model), started: started, output: state.runOutput, cost: state.runCost)
        }
        .sorted { $0.started < $1.started }

        // Activity: whole weeks, so the grid's rows line up with weekdays.
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let gridStart = calendar.date(byAdding: .day, value: -12 * 7, to: weekStart)!
        let days = (calendar.dateComponents([.day], from: gridStart, to: today).day ?? 0) + 1
        summary.activity = (0..<days).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: gridStart)!
            return byDay[day] ?? Day(date: day, cost: 0, tokens: 0)
        }
        summary.activityCost = summary.activity.reduce(0) { $0 + $1.cost }
        summary.activeDays = summary.activity.filter { $0.cost > 0 }.count
        summary.busiestDay = summary.activity.max { $0.cost < $1.cost }.flatMap { $0.cost > 0 ? $0 : nil }

        // Consecutive active days up to today (or yesterday, before today's first message).
        var day = byDay[today]?.cost ?? 0 > 0 ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        while byDay[day]?.cost ?? 0 > 0 {
            summary.streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return summary
    }
}
