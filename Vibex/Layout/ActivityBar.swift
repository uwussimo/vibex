import SwiftUI

/// The thin icon column on the far left, as in VS Code, in groups by what each button opens:
/// the panes (Terminal, Simulator, Browser, in ⌘1–⌘3 order), then the sidebar views (Source Control,
/// Skills), with AI Usage and Setup at the bottom.
struct ActivityBar: View {
    let sidebar: SidebarModel
    let sourceControl: SourceControlModel
    let tabs: EditorTabsModel
    let panes: PaneVisibility
    let simulator: SimulatorModel
    let attention: AttentionCenter
    let agents: AgentsModel
    let windowID: String
    let actions: ActivityBarActions

    static let width: CGFloat = 52

    var body: some View {
        VStack(spacing: 2) {
            ActivityButton(
                icon: .terminal,
                help: waiting > 0
                    ? "Claude is waiting in \(waiting) tab\(waiting == 1 ? "" : "s") (⌘1)"
                    : (panes.terminal ? "Terminal (⌘1)" : "Open Terminal (⌘1)"),
                isSelected: panes.terminal,
                attention: waiting,
                action: actions.showTerminal
            )
            ActivityButton(
                icon: .phone,
                help: simulator.bootedDevice.map { "Simulator: \($0.name) (⌘2)" } ?? "Simulator (⌘2)",
                isSelected: isEditorShowing(.simulator),
                dot: simulator.bootedDevice != nil ? Theme.green : nil,
                action: actions.showSimulator
            )
            ActivityButton(
                icon: .globe,
                help: "Browser (⌘3)",
                isSelected: isBrowserShowing,
                action: actions.showBrowser
            )
            groupDivider
            ActivityButton(
                icon: .branch,
                help: "Source Control (⌃⇧G)",
                isSelected: sidebar.isShowing(.sourceControl),
                badge: sourceControl.status.changeCount,
                action: actions.toggleSourceControl
            )
            ActivityButton(
                icon: .dataflow,
                help: "Agents: parallel Claude attempts in their own branches (⌃⇧N)",
                isSelected: sidebar.isShowing(.agents),
                badge: agents.agents.count,
                action: actions.toggleAgents
            )
            ActivityButton(
                icon: .sparkles,
                help: "Skills (⌃⇧K)",
                isSelected: sidebar.isShowing(.skills),
                action: actions.toggleSkills
            )
            ActivityButton(
                icon: .puzzle,
                help: "MCP Servers: tools for Claude Code (⌃⇧M)",
                isSelected: sidebar.isShowing(.mcp),
                action: actions.toggleMCP
            )
            Spacer()
            ActivityButton(
                icon: .agents,
                help: "AI Usage: Claude and Codex (⌃⇧A)",
                isSelected: isEditorShowing(.agents),
                action: actions.showAgents
            )
            ActivityButton(icon: .settings, help: "Setup & Permissions", isSelected: false, action: actions.showSetup)
                .padding(.bottom, 10)
        }
        .padding(.top, 8)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Theme.background)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.line).frame(width: 1)
        }
    }

    private var waiting: Int { attention.count(windowID: windowID) }

    /// Space plus a hairline: the panes above, the sidebar views below.
    private var groupDivider: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(width: 22, height: 1)
            .padding(.vertical, 7)
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
    var toggleAgents: () -> Void
    var toggleSkills: () -> Void
    var toggleMCP: () -> Void
    var showAgents: () -> Void
    var showSetup: () -> Void
}

struct ActivityButton: View {
    let icon: Icon
    let help: String
    let isSelected: Bool
    var badge = 0
    /// Orange badge for things waiting on the user (approvals); wins over `badge`.
    var attention = 0
    var dot: Color?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            IconView(icon, size: 19)
                .foregroundStyle(isSelected ? Theme.text : (isHovering ? Theme.text.opacity(0.85) : Theme.muted))
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(isSelected ? 0.08 : (isHovering ? 0.045 : 0)))
                )
                .overlay(alignment: .topTrailing) { indicator }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .frame(width: ActivityBar.width, height: 44)
        .overlay(alignment: .leading) {
            // Grows from the middle when selected, like the indicator in VS Code and Xcode's navigator.
            Capsule()
                .fill(Theme.accent)
                .frame(width: 3, height: isSelected ? 20 : 0)
                .opacity(isSelected ? 1 : 0)
        }
        .help(help)
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 1), value: isSelected)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: badge)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: attention)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    @ViewBuilder
    private var indicator: some View {
        if attention > 0 {
            count(attention, fill: Theme.orange)
        } else if badge > 0 {
            count(badge, fill: Theme.accent)
        } else if let dot {
            Circle()
                .fill(dot)
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(Theme.background, lineWidth: 1.5))
                .offset(x: -7, y: 8)
                .transition(.scale.combined(with: .opacity))
        }
    }

    private func count(_ value: Int, fill: Color) -> some View {
        Text(value > 99 ? "99+" : "\(value)")
            .font(.vibex(size: 9.5, weight: .bold))
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(Theme.background, lineWidth: 1.5))
            .offset(x: -1, y: 2)
            .contentTransition(.numericText())
            .transition(.scale(scale: 0.5).combined(with: .opacity))
    }
}
