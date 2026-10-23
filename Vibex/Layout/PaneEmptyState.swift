import SwiftUI

struct PaneEmptyActions {
    var terminal: () -> Void
    var simulator: () -> Void
    var browser: () -> Void
}

/// Shown when every terminal and editor tab is closed, so the window never goes blank: the three
/// panes, each with the shortcut that brings it back.
struct PaneEmptyState: View {
    let actions: PaneEmptyActions

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Nothing open")
                    .font(.vibex(size: 17, weight: .semibold))
                Text("Open a terminal to start, or bring back the simulator or browser.")
                    .font(.vibex(size: 12.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 8) {
                EmptyStateRow(symbol: "terminal", title: "New Terminal", shortcut: "⌘1", isPrimary: true, action: actions.terminal)
                EmptyStateRow(symbol: "iphone", title: "Simulator", shortcut: "⌘2", action: actions.simulator)
                EmptyStateRow(symbol: "globe", title: "Browser", shortcut: "⌘3", action: actions.browser)
            }
            .frame(width: 260)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: TerminalTheme.background))
    }
}

private struct EmptyStateRow: View {
    let symbol: String
    let title: String
    let shortcut: String
    var isPrimary = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.vibex(size: 13, weight: .medium))
                Spacer()
                Text(shortcut)
                    .font(.vibex(size: 12))
                    .foregroundStyle(isPrimary ? .white.opacity(0.75) : .white.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isPrimary ? Color.accentColor : Color.white.opacity(isHovering ? 0.12 : 0.07))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .onHover { isHovering = $0 }
    }
}
