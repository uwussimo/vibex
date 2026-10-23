import AppKit
import SwiftUI

/// First-launch setup: every permission and tool Vibex relies on, each with a live status and one
/// button that grants or installs it. Reopen it from Vibex → Setup & Permissions….
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    private let model = SetupModel()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 720),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "Set up Vibex"
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SetupView(model: model) { [weak self] in
            self?.close()
        })
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        model.refresh()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_ notification: Notification) { model.markSeen() }
}

struct SetupView: View {
    let model: SetupModel
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 22)
                .padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Permissions", [.fullDiskAccess, .folders, .notifications])
                    section("Tools", [.xcode, .claude, .commandLine])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
            footer
        }
        .frame(width: 580, height: 720)
        .background(.background)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Set up Vibex")
                .font(.vibex(size: 22, weight: .semibold))
            Text("Grant these once so commands in the terminal, the simulator and Claude Code just work.")
                .font(.vibex(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
    }

    private func section(_ title: String, _ ids: [SetupItem.ID]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.vibex(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    if index > 0 { Divider().padding(.leading, 58) }
                    SetupRow(id: id, model: model)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.readyCount) of \(model.totalCount) ready")
                    .font(.vibex(size: 12, weight: .medium))
                    .contentTransition(.numericText())
                Text(model.isComplete ? "You're all set." : "Optional items can wait. Reopen this from the Vibex menu.")
                    .font(.vibex(size: 11.5))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            Button(action: done) {
                Text(model.isComplete ? "Start Using Vibex" : "Continue")
                    .font(.vibex(size: 13, weight: .medium))
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.spring(response: 0.3, dampingFraction: 1), value: model.isComplete)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: model.readyCount)
    }
}

private struct SetupRow: View {
    let id: SetupItem.ID
    let model: SetupModel

    private var status: SetupItem.Status { model.status(id) }
    /// Folders don't need asking about once Full Disk Access covers them.
    private var isCovered: Bool { id == .folders && model.status(.fullDiskAccess) == .ready }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: content.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(content.tint.gradient))
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
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
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
        case .claude, .commandLine: return "Install"
        }
    }

    private var content: (symbol: String, tint: Color, title: String, detail: String, optional: Bool) {
        switch id {
        case .fullDiskAccess:
            ("lock.open.fill", .blue, "Full Disk Access",
             "Recommended. Lets terminal commands reach every project. Turn on Vibex, then come back.", false)
        case .folders:
            ("folder.fill", .cyan, "Desktop, Documents and Downloads",
             "Without Full Disk Access, macOS asks once for each folder.", false)
        case .notifications:
            ("bell.badge.fill", .red, "Notifications",
             "Claude Code and Run can tell you when a long task finishes.", true)
        case .xcode:
            ("hammer.fill", .indigo, "Xcode and an iOS simulator",
             "The simulator pane and Run for iOS projects use Xcode 26 and an iOS runtime.", false)
        case .claude:
            ("sparkles", .orange, "Claude Code",
             "Vibex registers its MCP tools with Claude Code so it can drive the simulator and browser.", false)
        case .commandLine:
            ("terminal.fill", .gray, "vibex command",
             "Run “vibex .” in any terminal to open that folder here.", true)
        }
    }
}
