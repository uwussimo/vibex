import AppKit
import SwiftUI

/// One permission or tool, with its live status and the button that grants or installs it. Used on
/// Settings › Get Started and Settings › Claude Code & MCP.
struct SetupRow: View {
    let id: SetupItem.ID
    let model: SetupModel

    private var status: SetupItem.Status { model.status(id) }
    /// Folders don't need asking about once Full Disk Access covers them.
    private var isCovered: Bool { id == .folders && model.status(.fullDiskAccess) == .ready }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Group {
                if let logo {
                    BrandLogoView(logo, size: 20)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.raised))
                } else {
                    IconView(content.icon, size: 16)
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(content.tint.gradient))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(content.title)
                        .font(.vibex(size: 13, weight: .medium))
                    if content.optional {
                        Text("Optional")
                            .font(.vibex(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                Text(detail)
                    .font(.vibex(size: 11.5))
                    .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 12)
            trailing
                .frame(minWidth: 90, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .opacity(isCovered ? 0.55 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 1), value: status)
        .animation(.spring(response: 0.35, dampingFraction: 1), value: isCovered)
    }

    @ViewBuilder
    private var trailing: some View {
        switch isCovered ? .ready : status {
        case .checking:
            ProgressView().controlSize(.small)
        case .ready:
            IconView(.checkCircle, size: 20.5)
                .foregroundStyle(.green)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        case .working:
            ProgressView().controlSize(.small)
        case .needed, .failed:
            Button { model.perform(id) } label: {
                Text(actionTitle).font(.vibex(size: 12, weight: .medium))
            }
            .controlSize(.regular)
            .transition(.opacity)
        }
    }

    private var isFailure: Bool {
        if case .failed = status { return true }
        return false
    }

    private var detail: String {
        if isCovered { return "Covered by Full Disk Access." }
        switch status {
        case let .working(activity): return activity
        case let .failed(message): return message
        default: return content.detail
        }
    }

    private var actionTitle: String {
        if isFailure { return "Try Again" }
        switch id {
        case .fullDiskAccess: return "Open Settings"
        case .folders: return "Allow"
        case .notifications: return Defaults.notificationsRequested ? "Open Settings" : "Allow"
        case .xcode: return FileManager.default.fileExists(atPath: Toolchain.developerDir) ? "Download iOS" : "Get Xcode"
        case .claude, .vibexSkill, .commandLine: return "Install"
        case .approvalHooks: return "Turn On"
        }
    }

    /// The tool's own logo, for rows about a tool rather than a permission.
    private var logo: BrandLogo? {
        switch id {
        case .xcode: .xcode
        case .claude, .vibexSkill, .approvalHooks: .claude
        default: nil
        }
    }

    private var content: (icon: Icon, tint: Color, title: String, detail: String, optional: Bool) {
        switch id {
        case .fullDiskAccess:
            (.unlock, .blue, "Full Disk Access",
             "Recommended. Lets terminal commands reach every project. Turn on Vibex, then come back.", false)
        case .folders:
            (.folder, .cyan, "Desktop, Documents and Downloads",
             "Without Full Disk Access, macOS asks once for each folder.", false)
        case .notifications:
            (.bell, .red, "Notifications",
             "Claude Code can tell you when a long task finishes.", true)
        case .xcode:
            (.codeBrowser, .indigo, "Xcode and an iOS simulator",
             "The simulator pane and iOS builds use Xcode 26 and an iOS runtime.", false)
        case .claude:
            (.sparkles, .orange, "Claude Code",
             "Vibex registers its MCP tools with Claude Code so it can drive the simulator and browser.", false)
        case .vibexSkill:
            (.book, .purple, "Vibex skill for Claude Code",
             "Teaches Claude Code in every project how to use Vibex's simulator, browser and terminal tools.", false)
        case .approvalHooks:
            (.bellRinging, .orange, "Approval alerts",
             "Claude Code tells Vibex when a session needs your approval, so the tab, the menu bar and a notification show it.", true)
        case .commandLine:
            (.terminal, .gray, "vibex command",
             "Run “vibex .” in any terminal to open that folder here.", true)
        }
    }
}
