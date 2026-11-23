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
    let windowID: String
    let actions: ActivityBarActions

    static let width: CGFloat = 56

    var body: some View {
        VStack(spacing: 2) {
            ActivityButton(
                icon: .terminal,
                label: "Terminal",
                help: waiting > 0
                    ? "Claude is waiting in \(waiting) tab\(waiting == 1 ? "" : "s") (⌘1)"
                    : (panes.terminal ? "Terminal (⌘1). Double-click for a new tab (⌘T)" : "Open Terminal (⌘1)"),
                isSelected: panes.terminal,
                attention: waiting,
                action: actions.showTerminal,
                doubleAction: actions.newTerminal
            )
            ActivityButton(
                icon: .phone,
                label: "Simulator",
                help: simulator.bootedDevice.map { "Simulator: \($0.name) (⌘2)" } ?? "Simulator (⌘2)",
                isSelected: isEditorShowing(.simulator),
                dot: simulator.bootedDevice != nil ? Theme.green : nil,
                action: actions.showSimulator
            )
            ActivityButton(
                icon: .globe,
                label: "Browser",
                help: "Browser (⌘3)",
                isSelected: isBrowserShowing,
                action: actions.showBrowser
            )
            ActivityButton(
                icon: .feather,
                label: "Design",
                help: "Vibex Design: Claude draws apps and sites on a canvas (⌘4)",
                isSelected: isEditorShowing(.design),
                attention: tabs.designNeedsAttention ? 1 : 0,
                action: actions.showDesign
            )
            ActivityButton(
                icon: .beaker,
                label: "QA",
                help: "QA: Claude tests the app on several simulators at once (⌘5)",
                isSelected: isEditorShowing(.qa),
                attention: tabs.qaNeedsAttention ? 1 : 0,
                action: actions.showQA
            )
            groupDivider
            ActivityButton(
                icon: .files,
                label: "Files",
                help: "Explorer (⇧⌘E)",
                isSelected: sidebar.isShowing(.explorer),
                action: actions.toggleExplorer
            )
            ActivityButton(
                icon: .branch,
                label: "Git",
                help: "Source Control (⌃⇧G)",
                isSelected: sidebar.isShowing(.sourceControl),
                badge: sourceControl.status.changeCount,
                action: actions.toggleSourceControl
            )
            ActivityButton(
                icon: .skills,
                label: "Skills",
                help: "Skills (⌃⇧K)",
                isSelected: sidebar.isShowing(.skills),
                action: actions.toggleSkills
            )
            ActivityButton(
                icon: .server,
                label: "MCP",
                help: "MCP Servers: tools for Claude Code (⌃⇧M)",
                isSelected: sidebar.isShowing(.mcp),
                action: actions.toggleMCP
            )
            ActivityButton(
                icon: .hardDrive,
                label: "Servers",
                help: "Servers: your saved SSH connections (⌃⇧S)",
                isSelected: sidebar.isShowing(.servers),
                action: actions.toggleServers
            )
            Spacer()
            ActivityButton(
                icon: .barChart,
                label: "Usage",
                help: "AI Usage: Claude and Codex (⌃⇧A)",
                isSelected: isEditorShowing(.agents),
                action: actions.showAgents
            )
            ActivityButton(icon: .settings, label: "Setup", help: "Setup & Permissions", isSelected: false, action: actions.showSetup)
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

    /// Terminal tabs waiting on the user.
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
    /// A double-click on Terminal opens another tab.
    var newTerminal: () -> Void
    var showSimulator: () -> Void
    var showBrowser: () -> Void
    var showDesign: () -> Void
    var showQA: () -> Void
    var toggleSourceControl: () -> Void
    var toggleSkills: () -> Void
    var toggleExplorer: () -> Void
    var toggleMCP: () -> Void
    var toggleServers: () -> Void
    var showAgents: () -> Void
    var showSetup: () -> Void
}

struct ActivityButton: View {
    let icon: Icon
    /// A tool's own logo, shown instead of the icon.
    var logo: BrandLogo?
    /// A word under the icon, so each section says what it is without a tooltip.
    let label: String
    let help: String
    let isSelected: Bool
    var badge = 0
    /// Orange badge for things waiting on the user (approvals); wins over `badge`.
    var attention = 0
    var dot: Color?
    let action: () -> Void
    /// Runs on the second click of a double-click, after `action` ran for the first.
    var doubleAction: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                if let logo {
                    BrandLogoView(logo, size: 18)
                } else if let glyph = icon.activityGlyph {
                    // Line when idle, solid when it's the section you're in.
                    Image(isSelected ? glyph + ".fill" : glyph)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 20, height: 20)
                        .frame(width: 18, height: 18)
                        .contentTransition(.opacity)
                        .accessibilityHidden(true)
                } else {
                    IconView(icon, size: 18)
                }
                Text(label)
                    .font(.vibex(size: 9.5, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
                .foregroundStyle(isSelected ? Theme.text : (isHovering ? Theme.text.opacity(0.85) : Theme.muted))
                .frame(width: 48, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.wash(isSelected ? 0.08 : (isHovering ? 0.045 : 0)))
                )
                .overlay(alignment: .topTrailing) { indicator }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { doubleAction?() }, including: doubleAction == nil ? .subviews : .all)
        .frame(width: ActivityBar.width, height: 46)
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

private extension Icon {
    /// The activity bar's own glyphs: Phosphor (MIT, Vibex/Resources/Activity.xcassets), which draws
    /// every icon in a matching line and solid weight.
    var activityGlyph: String? {
        let name: String? = switch self {
        case .terminal: "terminal-window"
        case .phone: "device-mobile"
        case .globe: "globe"
        case .feather: "pen-nib"
        case .beaker: "flask"
        case .files: "folder-simple"
        case .branch: "git-branch"
        case .skills: "graduation-cap"
        case .server: "plugs"
        case .hardDrive: "hard-drives"
        case .barChart: "chart-bar"
        case .settings: "gear-six"
        default: nil
        }
        return name.map { "ph." + $0 }
    }
}
