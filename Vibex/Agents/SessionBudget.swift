import Foundation

/// The limit the Claude session bar measures against, and when to warn about it. Claude's plans
/// don't publish their 5-hour limits in dollars, so the default is your largest earlier session;
/// you can set your own in AI Usage.
nonisolated struct SessionBudget: Equatable, Sendable {
    /// Dollars of API value per 5-hour session; nil is automatic.
    var custom: Double?

    static let presets: [Double] = [25, 50, 100, 200, 400]
    /// Warn once at each of these shares of the limit, per session.
    static let thresholds: [Double] = [0.8, 1.0]

    func limit(for summary: AgentUsageSummary) -> Double? {
        if let custom, custom > 0 { return custom }
        return summary.largestPastBlockCost > 0 ? summary.largestPastBlockCost : nil
    }

    /// The highest threshold the current session has crossed.
    static func crossed(cost: Double, limit: Double) -> Double? {
        guard limit > 0 else { return nil }
        return thresholds.last { cost >= limit * $0 }
    }

    /// The key that makes each warning fire once: the session's reset time plus the threshold.
    static func alertKey(resetsAt: Date, threshold: Double) -> String {
        "\(Int(resetsAt.timeIntervalSince1970))-\(Int(threshold * 100))"
    }
}
