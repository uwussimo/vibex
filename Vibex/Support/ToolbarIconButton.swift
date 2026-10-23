import SwiftUI

/// A 28pt icon button for pane headers. Feedback lands on press, not release.
struct ToolbarIconButton: View {
    let icon: Icon
    var help: String
    var isEnabled: Bool = true
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            IconView(icon, size: 15)
                .frame(width: 28, height: 28)
                .foregroundStyle(isActive ? Theme.accent : (isHovering && isEnabled ? Theme.text : Theme.muted))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering && isEnabled ? Color.white.opacity(0.08) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .help(help)
        .onHover { isHovering = $0 }
    }
}

/// Scales down immediately on pointer-down and springs back on release.
struct PressFeedbackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 1), value: configuration.isPressed)
    }
}
