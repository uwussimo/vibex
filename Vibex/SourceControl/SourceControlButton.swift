import SwiftUI

/// Title-bar control: the branch and how many files changed. Opens and closes the sidebar (⌃⇧G).
struct SourceControlButton: View {
    let model: SourceControlModel
    let toggle: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                if model.state == .ready {
                    Text(model.branchLabel)
                        .font(.vibex(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 90)
                    if model.status.changeCount > 0 {
                        Text("\(model.status.changeCount)")
                            .font(.vibex(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(Color.accentColor))
                            .contentTransition(.numericText())
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                } else {
                    Text("Git").font(.vibex(size: 11.5, weight: .medium))
                }
            }
            .foregroundStyle(model.isSidebarVisible ? Color.accentColor : .primary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(model.isSidebarVisible ? 0.1 : (isHovering ? 0.08 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .onHover { isHovering = $0 }
        .help("Source Control (⌃⇧G)")
        .fixedSize()
        .padding(.trailing, 6)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: model.status.changeCount)
        .animation(.spring(response: 0.25, dampingFraction: 1), value: model.isSidebarVisible)
    }
}
