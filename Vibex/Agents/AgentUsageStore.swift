import Foundation
import Observation
import os
import UserNotifications

/// Owns the ledger off the main actor: one scan at a time, saved after each pass that read anything.
actor AgentUsageEngine {
    private var ledger: ClaudeUsageLedger?

    func refresh(periodDays: Int) -> AgentUsageSummary {
        var ledger = ledger ?? ClaudeUsageLedger.load()
        let before = ledger.files.mapValues(\.offset)
        if !ledger.update() {
            // A log was rewritten; its old contributions can't be subtracted, so start over.
            ledger = ClaudeUsageLedger()
            _ = ledger.update()
        }
        if ledger.files.mapValues(\.offset) != before { ledger.save() }
        self.ledger = ledger
        return AgentUsageSummary.make(from: ledger, periodDays: periodDays)
    }

    func summary(periodDays: Int) -> AgentUsageSummary? {
        ledger.map { AgentUsageSummary.make(from: $0, periodDays: periodDays) }
    }
}

/// Claude Code and Codex usage for the AI Usage dashboard, shared by the menu bar and every window.
@Observable
final class AgentUsageStore {
    static let shared = AgentUsageStore()

    private(set) var summary: AgentUsageSummary?
    private(set) var codex: CodexLimits?
    private(set) var plan: ClaudePlan?
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    var periodDays: Int = Defaults.agentsPeriodDays {
        didSet {
            Defaults.agentsPeriodDays = periodDays
            Task { if let summary = await engine.summary(periodDays: periodDays) { self.summary = summary } }
        }
    }

    /// The session limit and its alerts, set in AI Usage.
    var budget = SessionBudget(custom: Defaults.sessionLimit > 0 ? Defaults.sessionLimit : nil) {
        didSet { Defaults.sessionLimit = budget.custom ?? 0 }
    }
    var budgetAlerts = Defaults.budgetAlerts {
        didSet { Defaults.budgetAlerts = budgetAlerts }
    }

    private let engine = AgentUsageEngine()
    private var timer: Timer?
    private var backgroundTimer: Timer?
    /// Views showing the dashboard; the store only polls while someone is looking.
    private var viewers = 0

    var codexInstalled: Bool { CodexLimits.isInstalled }

    /// A slow refresh while nobody looks at the dashboard, so budget alerts still go out.
    func startBackground() {
        guard backgroundTimer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        backgroundTimer = timer
        refresh()
    }

    func appear() {
        viewers += 1
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func disappear() {
        viewers = max(0, viewers - 1)
        if viewers == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let days = periodDays
        Task {
            let started = Date()
            let summary = await engine.refresh(periodDays: days)
            let codex = await Self.readCodex()
            plan = ClaudePlan.detect()
            if summary != self.summary { self.summary = summary }
            checkBudget(summary)
            if codex != self.codex { self.codex = codex }
            lastUpdated = Date()
            isRefreshing = false
            Log.app.debug("usage refresh took \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
        }
    }

    @concurrent private static func readCodex() async -> CodexLimits? { CodexLimits.read() }

    // MARK: - Budget alerts

    private func checkBudget(_ summary: AgentUsageSummary) {
        guard budgetAlerts, let block = summary.currentBlock, let limit = budget.limit(for: summary),
              let threshold = SessionBudget.crossed(cost: block.cost, limit: limit) else { return }
        let key = SessionBudget.alertKey(resetsAt: block.resetsAt, threshold: threshold)
        guard !Defaults.budgetAlertsSent.contains(key) else { return }
        Defaults.budgetAlertsSent.append(key)
        let content = UNMutableNotificationContent()
        content.title = threshold >= 1 ? "Claude session limit reached" : "Claude session at \(Int(threshold * 100))%"
        content.body = "\(UsageFormat.money(block.cost)) of \(UsageFormat.money(limit)) · resets in \(UsageFormat.countdown(to: block.resetsAt))"
        content.sound = .default
        content.threadIdentifier = "vibex.budget"
        Task { try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil)) }
    }
}
