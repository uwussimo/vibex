import Foundation
import Observation
import os

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

    private let engine = AgentUsageEngine()
    private var timer: Timer?
    /// Views showing the dashboard; the store only polls while someone is looking.
    private var viewers = 0

    var codexInstalled: Bool { CodexLimits.isInstalled }

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
            if codex != self.codex { self.codex = codex }
            lastUpdated = Date()
            isRefreshing = false
            Log.app.debug("usage refresh took \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
        }
    }

    @concurrent private static func readCodex() async -> CodexLimits? { CodexLimits.read() }
}
