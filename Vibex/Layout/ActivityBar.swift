import SwiftUI

/// The thin icon column on the far left, as in VS Code, in groups by what each button opens:
/// the panes (Terminal, Simulator, Browser, in ⌘1–⌘3 order), then the sidebar views (Source Control,
/// Skills), with AI Agents and Setup at the bottom. Running lives in the title bar, where it has a label.
struct ActivityBar: View {
    let sidebar: SidebarModel
    let sourceControl: SourceControlModel
    let tabs: EditorTabsModel
    let panes: PaneVisibility
    let simulator: SimulatorModel
    let actions: ActivityBarActions

    static let width: CGFloat = 48

    var body: some View {
        VStack(spacing: 4) {
            ActivityButton(
                symbol: "terminal",
                help: panes.terminal ? "Terminal (⌘1)" : "Open Terminal (⌘1)",
                isSelected: panes.terminal,
                action: actions.showTerminal
            )
            ActivityButton(
                symbol: "iphone",
                help: simulator.bootedDevice.map { "Simulator: \($0.name) (⌘2)" } ?? "Simulator (⌘2)",
                isSelected: isEditorShowing(.simulator),
                dot: simulator.bootedDevice != nil ? Color(nsColor: .systemGreen) : nil,
                action: actions.showSimulator
            )
            ActivityButton(
                symbol: "globe",
                help: "Browser (⌘3)",
                isSelected: isBrowserShowing,
                action: actions.showBrowser
            )
            groupDivider
            ActivityButton(
                symbol: "arrow.triangle.branch",
                help: "Source Control (⌃⇧G)",
                isSelected: sidebar.isShowing(.sourceControl),
                badge: sourceControl.status.changeCount,
                action: actions.toggleSourceControl
            )
            ActivityButton(
                symbol: "sparkles",
                help: "Skills (⌃⇧K)",
                isSelected: sidebar.isShowing(.skills),
                action: actions.toggleSkills
            )
            Spacer()
            ActivityButton(
                symbol: "gauge.with.dots.needle.67percent",
                help: "AI Agents: Claude and Codex usage (⌃⇧A)",
                isSelected: isEditorShowing(.agents),
                action: actions.showAgents
            )
            ActivityButton(symbol: "gearshape", help: "Setup & Permissions", isSelected: false, action: actions.showSetup)
                .padding(.bottom, 8)
        }
        .padding(.top, 6)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(.bar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
        }
    }

    /// Space plus a hairline: the panes above, the sidebar views below.
    private var groupDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 20, height: 1)
            .padding(.vertical, 6)
    }

    private func isEditorShowing(_ tab: EditorTabsModel.Tab) -> Bool {
        panes.editor && tabs.selected == tab
    }

    private var isBrowserShowing: Bool {
        guard panes.editor, case .browser = tabs.selected else { return false }
        return true
    }
}

struct ActivityBarActions {
    var showTerminal: () -> Void
    var showSimulator: () -> Void
    var showBrowser: () -> Void
    var toggleSourceControl: () -> Void
    var toggleSkills: () -> Void
    var showAgents: () -> Void
    var showSetup: () -> Void
}

private struct ActivityButton: View {
    let symbol: String
    let help: String
    let isSelected: Bool
    var badge = 0
    var dot: Color?
    var tint: Color?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(tint ?? (isSelected || isHovering ? Color.primary : Color.secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(isSelected ? 0.09 : (isHovering ? 0.05 : 0)))
                )
                .overlay(alignment: .topTrailing) { indicator }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .frame(width: ActivityBar.width, height: 42)
        .overlay(alignment: .leading) {
            // Grows from the middle when selected, like the indicator in VS Code and Xcode's navigator.
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 3, height: isSelected ? 22 : 0)
                .opacity(isSelected ? 1 : 0)
        }
        .help(help)
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 1), value: isSelected)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: badge)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    @ViewBuilder
    private var indicator: some View {
        if badge > 0 {
            Text(badge > 99 ? "99+" : "\(badge)")
                .font(.vibex(size: 9.5, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(Color.accentColor))
                .offset(x: -2, y: 3)
                .contentTransition(.numericText())
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        } else if let dot {
            Circle()
                .fill(dot)
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                .offset(x: -7, y: 8)
                .transition(.scale.combined(with: .opacity))
        }
    }
}
