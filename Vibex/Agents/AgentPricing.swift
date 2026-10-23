import Foundation

/// Tokens from one Claude response, as Claude Code logs them.
nonisolated struct TokenUsage: Codable, Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0
    var cost = 0.0

    var total: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }

    static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheWrite5m += rhs.cacheWrite5m
        lhs.cacheWrite1h += rhs.cacheWrite1h
        lhs.cacheRead += rhs.cacheRead
        lhs.cost += rhs.cost
    }
}

/// What a response would have cost at Anthropic's first-party API rates ("API value"). Subscription
/// users don't pay this; it shows what the plan is worth.
nonisolated enum AgentPricing {
    struct Rate: Equatable {
        /// Dollars per million tokens.
        var input: Double
        var output: Double
        /// Cache reads as a fraction of the input price.
        var cacheRead: Double = 0.1
    }

    /// Longest prefix wins, so "opus-5-5" is matched before "opus-5".
    private static let rates: [(prefix: String, rate: Rate)] = [
        ("fable-5-1", Rate(input: 10, output: 50, cacheRead: 0.025)),
        ("mythos-5-1", Rate(input: 10, output: 50, cacheRead: 0.025)),
        ("fable-5", Rate(input: 10, output: 50)),
        ("mythos-5", Rate(input: 10, output: 50)),
        ("opus-5-5", Rate(input: 4, output: 20, cacheRead: 0.05)),
        ("opus-5", Rate(input: 5, output: 25)),
        ("opus-4-8", Rate(input: 5, output: 25)),
        ("opus-4-7", Rate(input: 5, output: 25)),
        ("opus-4-6", Rate(input: 5, output: 25)),
        ("opus-4-5", Rate(input: 5, output: 25)),
        ("opus-4", Rate(input: 15, output: 75)),
        ("sonnet-5-5", Rate(input: 2, output: 10)),
        ("sonnet-5", Rate(input: 2, output: 10)),
        ("sonnet-4", Rate(input: 3, output: 15)),
        ("sonnet-3", Rate(input: 3, output: 15)),
        ("haiku-5-5", Rate(input: 0.10, output: 0.50)),
        ("haiku-4", Rate(input: 1, output: 5)),
        ("haiku-3-5", Rate(input: 0.80, output: 4)),
    ].sorted { $0.prefix.count > $1.prefix.count }

    /// "claude-opus-5-5" or "claude-opus-4-5-20251101" → "opus-5-5…"; nil for models it doesn't know.
    static func rate(for model: String) -> Rate? {
        let key = model.hasPrefix("claude-") ? String(model.dropFirst(7)) : model
        return rates.first { key.hasPrefix($0.prefix) }?.rate
    }

    static func cost(_ usage: TokenUsage, model: String, fast: Bool = false) -> Double {
        guard var rate = rate(for: model) else { return 0 }
        // Claude Haiku 5.5 charges 5× for prompts over 100K tokens.
        let prompt = usage.input + usage.cacheWrite5m + usage.cacheWrite1h + usage.cacheRead
        if model.contains("haiku-5-5"), prompt > 100_000 {
            rate.input *= 5
            rate.output *= 5
        }
        // Fast mode runs at twice the standard price.
        let multiplier = fast ? 2.0 : 1.0
        let dollars = Double(usage.input) * rate.input
            + Double(usage.output) * rate.output
            + Double(usage.cacheWrite5m) * rate.input * 1.25
            + Double(usage.cacheWrite1h) * rate.input * 2
            + Double(usage.cacheRead) * rate.input * rate.cacheRead
        return dollars * multiplier / 1_000_000
    }

    /// "claude-opus-5-5" → "Opus 5.5", "claude-sonnet-4-5-20250929" → "Sonnet 4.5".
    static func displayName(_ model: String) -> String {
        var key = model.hasPrefix("claude-") ? String(model.dropFirst(7)) : model
        if let date = key.range(of: #"-\d{8}$"#, options: .regularExpression) { key.removeSubrange(date) }
        let parts = key.split(separator: "-")
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " \(version)")
    }
}
