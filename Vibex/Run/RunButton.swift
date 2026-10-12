import SwiftUI

/// Title-bar Run control: ▶ starts, ■ stops, with the current step beside it.
struct RunButton: View {
    let runner: Runner
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                runner.phase.isActive ? runner.stop() : runner.run()
            } label: {
                Image(systemName: runner.phase.isActive ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(runner.phase.isActive ? Color.red : Color.primary)
                    .frame(width: 24, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(isHovering ? 0.1 : 0))
                    )
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressFeedbackButtonStyle())
            .onHover { isHovering = $0 }
            .help(runner.phase.isActive ? "Stop (⌘.)" : "Run (⇧⌘R)\(runner.config.map { " · \($0.summary)" } ?? "")")

            if runner.phase != .idle {
                HStack(spacing: 5) {
                    if case .building = runner.phase { ProgressView().controlSize(.mini) }
                    if case .launching = runner.phase { ProgressView().controlSize(.mini) }
                    if case .preparing = runner.phase { ProgressView().controlSize(.mini) }
                    Text(runner.phase.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
                .transition(.opacity)
            }
        }
        .fixedSize()
        .padding(.trailing, 8)
        .animation(.spring(response: 0.25, dampingFraction: 1), value: runner.phase)
    }

    private var statusColor: Color {
        switch runner.phase {
        case .failed: .red
        case .succeeded, .serving: .green
        default: .secondary
        }
    }
}
