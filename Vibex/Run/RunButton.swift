import SwiftUI

/// Title-bar Run control. A labeled button says what it does: "Run Habits" when idle (naming what
/// would run), "Stop" while running, with the current step beside it.
struct RunButton: View {
    let runner: Runner
    @State private var isHovering = false
    /// What Run would start, re-read whenever the pointer comes near so a new .vibex.json shows up.
    @State private var target: RunConfig?

    var body: some View {
        HStack(spacing: 8) {
            if runner.phase != .idle {
                HStack(spacing: 5) {
                    if runner.phase.showsProgress { ProgressView().controlSize(.mini) }
                    Text(runner.phase.label)
                        .font(.vibex(size: 11.5, weight: .medium))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
                .transition(.opacity)
            }
            Button {
                runner.phase.isActive ? runner.stop() : runner.run()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: runner.phase.isActive ? "stop.fill" : "play.fill")
                        .font(.system(size: 9.5, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                    Text(title)
                        .font(.vibex(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(runner.phase.isActive ? Color(nsColor: .systemRed) : Color.primary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.12 : 0.07))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(PressFeedbackButtonStyle())
            .onHover { hovering in
                isHovering = hovering
                if hovering { target = runner.resolveConfig() }
            }
            .help(help)
        }
        .fixedSize()
        .padding(.trailing, 8)
        // The accessory is wider than the control; keep it against the window's trailing edge.
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.spring(response: 0.25, dampingFraction: 1), value: runner.phase)
        .onAppear { target = runner.resolveConfig() }
    }

    private var title: String {
        if runner.phase.isActive { return "Stop" }
        guard let target else { return "Run" }
        switch target.kind {
        case .ios, .macos: return "Run \(target.scheme ?? "")".trimmingCharacters(in: .whitespaces)
        case .web, .command: return "Run"
        }
    }

    private var help: String {
        if runner.phase.isActive { return "Stop (⌘.)" }
        guard let target else { return "Run (⇧⌘R). Vibex hasn't found anything to run yet; add a .vibex.json or use Run → Edit Run Configuration." }
        return "Run \(target.summary) (⇧⌘R)"
    }

    private var statusColor: Color {
        switch runner.phase {
        case .failed: .red
        case .succeeded, .serving: .green
        default: .secondary
        }
    }
}
