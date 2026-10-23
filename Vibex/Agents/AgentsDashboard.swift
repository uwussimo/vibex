import SwiftUI

/// Claude Code and Codex at a glance: plan windows, spending, what is running now, and the trends
/// behind them. Shown in the AI Usage editor tab.
struct AgentsDashboard: View {
    let store: AgentUsageStore

    var body: some View {
        VStack(spacing: 0) {
            header
            if let summary = store.summary {
                ScrollView {
                    content(summary)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                        .frame(maxWidth: 980)
                        .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.automatic)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading Claude Code logs…")
                        .font(.vibex(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .onAppear { store.appear() }
        .onDisappear { store.disappear() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("AI Usage")
                .font(.vibex(size: 20, weight: .semibold))
            Spacer()
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .opacity(store.isRefreshing ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.3), value: store.isRefreshing)
                .help(store.lastUpdated.map { "Updated \($0.formatted(.relative(presentation: .named)))" } ?? "Updating…")
            ToolbarIconButton(icon: .refresh, help: "Refresh", action: store.refresh)
        }
        .padding(.leading, 22)
        .padding(.trailing, 10)
        .frame(height: 50)
    }

    private func content(_ summary: AgentUsageSummary) -> some View {
        VStack(spacing: 12) {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    ClaudeCard(summary: summary, plan: store.plan)
                    CodexCard(limits: store.codex, installed: store.codexInstalled)
                }
                GridRow {
                    SpendingCard(summary: summary, plan: store.plan, periodDays: Binding(get: { store.periodDays }, set: { store.periodDays = $0 }))
                    NowCard(sessions: summary.active)
                }
            }
            TrendCard(days: summary.trend, total: summary.periodCost)
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    SharesCard(title: "Models", icon: .cpu, shares: summary.models, tint: AgentColors.claude)
                    SharesCard(title: "Projects", icon: .folder, shares: summary.projects, tint: Color.primary.opacity(0.75))
                }
            }
            ActivityCard(summary: summary)
        }
    }
}

enum AgentColors {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let codex = Color(red: 0.47, green: 0.55, blue: 1.0)
}

// MARK: - Card chrome

private struct Card<Content: View, Accessory: View>: View {
    let title: String
    let icon: Icon
    var tint: Color = .secondary
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                IconView(icon, size: 15)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(title)
                    .font(.vibex(size: 14, weight: .semibold))
                Spacer(minLength: 6)
                accessory
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(radius: 18)
    }
}

extension Card where Accessory == EmptyView {
    init(title: String, icon: Icon, tint: Color = .secondary, @ViewBuilder content: () -> Content) {
        self.init(title: title, icon: icon, tint: tint, accessory: { EmptyView() }, content: content)
    }
}

private struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.vibex(size: 11.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.16)))
    }
}

private struct Meter: View {
    let value: Double
    let tint: Color
    var marker: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(tint).frame(width: max(8, geometry.size.width * min(1, max(0, value))))
                if let marker {
                    Rectangle().fill(Color.primary.opacity(0.8)).frame(width: 2).offset(x: geometry.size.width * min(1, marker) - 1)
                }
            }
        }
        .frame(height: 8)
        .animation(.spring(response: 0.4, dampingFraction: 1), value: value)
    }
}

enum UsageFormat {
    /// "$9.34", "$588", "$1 980": dollars always (the locale's "US$" is noise here), no cents from $100.
    static func money(_ value: Double) -> String {
        "$" + value.formatted(.number.precision(.fractionLength(value >= 100 ? 0 : 2)))
    }

    static func tokens(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(2)))
    }

    /// "1h 3m", "19d 2h", "42m".
    static func countdown(to date: Date, from now: Date = Date()) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes >= 24 * 60 { return "\(minutes / 1440)d \(minutes % 1440 / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    static func window(_ minutes: Int) -> String {
        if minutes >= 1440 { return "\(minutes / 1440)d" }
        if minutes >= 60 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

private struct ResetLabel: View {
    let title: String
    let resetsAt: Date?

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.vibex(size: 13, weight: .semibold))
            if let resetsAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Label(UsageFormat.countdown(to: resetsAt, from: context.date), systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                        .font(.vibex(size: 12))
                        .foregroundStyle(.secondary)
                        .help("Resets \(resetsAt.formatted(date: .omitted, time: .shortened))")
                }
            }
        }
    }
}

// MARK: - Cards

private struct ClaudeCard: View {
    let summary: AgentUsageSummary
    let plan: ClaudePlan?

    var body: some View {
        Card(title: "Claude", icon: .sparkles, tint: AgentColors.claude) {
            HStack(spacing: 6) {
                if let plan { Badge(text: plan.name, tint: AgentColors.claude) }
                if !summary.active.isEmpty {
                    Circle().fill(AgentColors.claude).frame(width: 8, height: 8).help("Claude Code is running")
                }
            }
        } content: {
            if let block = summary.currentBlock {
                HStack(alignment: .firstTextBaseline) {
                    ResetLabel(title: "Session", resetsAt: block.resetsAt)
                    Spacer()
                    Text(UsageFormat.money(block.cost)).font(.vibex(size: 15, weight: .semibold)).monospacedDigit()
                }
                Meter(value: summary.largestBlockCost > 0 ? block.cost / summary.largestBlockCost : 0, tint: AgentColors.claude.opacity(0.75))
                Text("Your largest 5-hour session: \(UsageFormat.money(summary.largestBlockCost))")
                    .font(.vibex(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                Text("No session running")
                    .font(.vibex(size: 13, weight: .semibold))
                Text("A 5-hour window starts with your next message.")
                    .font(.vibex(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CodexCard: View {
    let limits: CodexLimits?
    let installed: Bool

    var body: some View {
        Card(title: "Codex", icon: .codeBrowser, tint: AgentColors.codex) {
            if let plan = limits?.plan { Badge(text: plan, tint: AgentColors.codex) }
        } content: {
            if let limits, let window = limits.primary {
                // Codex only reports usage when it runs; once the window has reset with nothing newer, it's 0%.
                let hasReset = window.resetsAt.map { $0 < Date() } ?? false
                let used = hasReset ? 0 : window.usedPercent
                HStack(alignment: .firstTextBaseline) {
                    ResetLabel(title: UsageFormat.window(window.minutes), resetsAt: hasReset ? nil : window.resetsAt)
                    Spacer()
                    Text("\(Int(used.rounded()))%").font(.vibex(size: 15, weight: .semibold)).monospacedDigit()
                }
                Meter(value: used / 100, tint: AgentColors.codex)
                Text(hasReset
                    ? "Reset \(window.resetsAt!.formatted(.dateTime.month(.abbreviated).day())); not used since"
                    : "Updated \(limits.updated.formatted(.relative(presentation: .named)))")
                    .font(.vibex(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                Text(installed ? "No usage reported yet" : "Needs the Codex app or CLI")
                    .font(.vibex(size: 12.5))
                    .foregroundStyle(.secondary)
                if !installed {
                    Link("Get Codex", destination: URL(string: "https://openai.com/codex")!)
                        .font(.vibex(size: 12, weight: .medium))
                }
            }
        }
    }
}

private struct SpendingCard: View {
    let summary: AgentUsageSummary
    let plan: ClaudePlan?
    @Binding var periodDays: Int

    var body: some View {
        Card(title: "Spending", icon: .dollar) {
            Menu {
                Picker("Period", selection: $periodDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.inline)
            } label: {
                Text("\(periodDays) days").font(.vibex(size: 12.5))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(UsageFormat.money(summary.periodCost))
                    .font(.vibex(size: 30, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .layoutPriority(1)
                    .contentTransition(.numericText())
                Text("API value").font(.vibex(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let multiple {
                    Badge(text: "\(multiple)×", tint: AgentColors.claude)
                        .help("What these tokens would cost at API prices, against \(plan?.name ?? "your plan")'s price for \(periodDays) days")
                }
            }
            Text("\(UsageFormat.tokens(summary.periodTokens)) tokens · \(Int((summary.cacheShare * 100).rounded()))% from cache")
                .font(.vibex(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var multiple: Int? {
        guard let plan, plan.price > 0 else { return nil }
        let value = summary.periodCost / (plan.price * Double(periodDays) / 30)
        return value >= 1.5 ? Int(value.rounded()) : nil
    }
}

private struct NowCard: View {
    let sessions: [AgentUsageSummary.Session]

    var body: some View {
        Card(title: "Now", icon: .activity, tint: AgentColors.claude) {
            if !sessions.isEmpty {
                Circle().fill(AgentColors.claude).frame(width: 8, height: 8)
            }
        } content: {
            if sessions.isEmpty {
                Text("Nothing running")
                    .font(.vibex(size: 12.5))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sessions.prefix(3)) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                IconView(.sparkles, size: 12.5).foregroundStyle(AgentColors.claude)
                                Text(session.project).font(.vibex(size: 13.5, weight: .semibold)).lineLimit(1)
                                Spacer()
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text(Self.elapsed(from: session.started, to: context.date))
                                        .font(.vibex(size: 13.5, weight: .medium))
                                        .monospacedDigit()
                                        .foregroundStyle(AgentColors.claude)
                                }
                            }
                            Text("\(session.model) · \(UsageFormat.tokens(session.output)) written · \(UsageFormat.money(session.cost))")
                                .font(.vibex(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let hours = seconds / 3600, minutes = seconds % 3600 / 60, rest = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

private struct TrendCard: View {
    let days: [AgentUsageSummary.Day]
    let total: Double
    @State private var hovered: Date?

    var body: some View {
        Card(title: "Trend", icon: .barChart) {
            Text(caption)
                .font(.vibex(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
        } content: {
            let peak = max(days.map(\.cost).max() ?? 0, 0.01)
            HStack(alignment: .bottom, spacing: days.count > 45 ? 2 : 4) {
                ForEach(days) { day in
                    let isToday = day.id == days.last?.id
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(fill(day, isToday: isToday))
                        .frame(height: max(3, 104 * day.cost / peak))
                        .frame(maxWidth: .infinity, maxHeight: 104, alignment: .bottom)
                        .contentShape(Rectangle())
                        .onHover { inside in hovered = inside ? day.id : (hovered == day.id ? nil : hovered) }
                }
            }
            .frame(height: 104)
            .animation(.spring(response: 0.4, dampingFraction: 1), value: days)
            HStack {
                Text(label(days.first))
                Spacer()
                Text(label(days.count > 2 ? days[days.count / 2] : nil))
                Spacer()
                Text(label(days.last))
            }
            .font(.vibex(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
        }
    }

    private func fill(_ day: AgentUsageSummary.Day, isToday: Bool) -> Color {
        if day.cost == 0 { return Color.primary.opacity(0.08) }
        if day.id == hovered || isToday { return AgentColors.claude }
        return AgentColors.claude.opacity(0.55)
    }

    private var caption: String {
        if let hovered, let day = days.first(where: { $0.id == hovered }) {
            return "\(day.date.formatted(.dateTime.month(.abbreviated).day())) · \(UsageFormat.money(day.cost)) · \(UsageFormat.tokens(day.tokens)) tokens"
        }
        return "\(days.count) days · \(UsageFormat.money(total))"
    }

    private func label(_ day: AgentUsageSummary.Day?) -> String {
        day?.date.formatted(.dateTime.month(.abbreviated).day()) ?? ""
    }
}

private struct SharesCard: View {
    let title: String
    let icon: Icon
    let shares: [AgentUsageSummary.Share]
    let tint: Color

    var body: some View {
        Card(title: title, icon: icon) {
            if shares.isEmpty {
                Text("No usage in this period").font(.vibex(size: 12.5)).foregroundStyle(.secondary)
            } else {
                let top = shares.first?.cost ?? 1
                VStack(spacing: 9) {
                    ForEach(shares.prefix(3)) { share in
                        HStack(spacing: 10) {
                            Text(share.name)
                                .font(.vibex(size: 13.5, weight: .medium))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Capsule()
                                .fill(tint)
                                .frame(width: max(6, 64 * share.cost / top), height: 6)
                                .frame(width: 64, alignment: .leading)
                            Text(UsageFormat.money(share.cost))
                                .font(.vibex(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                                .frame(minWidth: 44, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}

private struct ActivityCard: View {
    let summary: AgentUsageSummary

    var body: some View {
        Card(title: "Activity", icon: .grid) {
            if summary.streak > 0 {
                Label("\(summary.streak)", systemImage: "flame.fill")
                    .font(.vibex(size: 12.5, weight: .semibold))
                    .foregroundStyle(.orange)
                    .help("\(summary.streak)-day streak")
            }
        } content: {
            HStack(alignment: .top, spacing: 22) {
                heatmap
                VStack(alignment: .leading, spacing: 4) {
                    Text(UsageFormat.money(summary.activityCost))
                        .font(.vibex(size: 22, weight: .semibold))
                        .monospacedDigit()
                    Text("13 weeks").font(.vibex(size: 12)).foregroundStyle(.secondary)
                    Spacer().frame(height: 10)
                    stat("Active days", "\(summary.activeDays)")
                    if let busiest = summary.busiestDay {
                        stat("Busiest day", "\(busiest.date.formatted(.dateTime.month(.abbreviated).day())) · \(UsageFormat.money(busiest.cost))")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var heatmap: some View {
        let weeks = stride(from: 0, to: summary.activity.count, by: 7).map { Array(summary.activity[$0..<min($0 + 7, summary.activity.count)]) }
        let levels = Self.thresholds(summary.activity.map(\.cost).filter { $0 > 0 })
        return HStack(alignment: .top, spacing: 3) {
            ForEach(weeks.indices, id: \.self) { column in
                VStack(spacing: 3) {
                    ForEach(weeks[column]) { day in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.primary.opacity(Self.opacity(day.cost, levels)))
                            .frame(width: 12, height: 12)
                            .help("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(UsageFormat.money(day.cost))")
                    }
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.vibex(size: 12.5, weight: .medium))
    }

    /// Quartiles of the active days, so one huge day doesn't wash out the rest.
    static func thresholds(_ costs: [Double]) -> [Double] {
        let sorted = costs.sorted()
        guard !sorted.isEmpty else { return [] }
        return [0.25, 0.5, 0.75].map { sorted[min(sorted.count - 1, Int(Double(sorted.count) * $0))] }
    }

    static func opacity(_ cost: Double, _ levels: [Double]) -> Double {
        guard cost > 0 else { return 0.08 }
        let level = levels.filter { cost >= $0 }.count
        return [0.25, 0.45, 0.68, 0.92][min(level, 3)]
    }
}
