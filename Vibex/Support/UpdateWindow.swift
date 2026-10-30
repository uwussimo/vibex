import AppKit
import SwiftUI

/// The face of `Updater`: what's new, then the download and install as they happen.
final class UpdateWindowController: NSWindowController {
    init(updater: Updater) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "Software Update"
        window.backgroundColor = Theme.NS.background
        super.init(window: window)
        window.contentView = NSHostingView(rootView: UpdateView(updater: updater) { [weak window] in window?.close() })
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate()
        window?.makeKeyAndOrderFront(sender)
    }
}

struct UpdateView: View {
    let updater: Updater
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 34)
                .padding(.bottom, 18)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !isInstalling { footer }
        }
        .frame(width: 520, height: 560)
        .background(Theme.background)
        .animation(.spring(response: 0.35, dampingFraction: 1), value: updater.state)
    }

    private var isInstalling: Bool {
        if case .installing = updater.state { return true }
        return false
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            Text(title)
                .font(.vibex(size: 20, weight: .semibold))
                .foregroundStyle(Theme.text)
                .contentTransition(.opacity)
            if let subtitle {
                Text(subtitle)
                    .font(.vibex(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
        }
    }

    private var title: String {
        switch updater.state {
        case .idle, .checking: "Checking for updates…"
        case .upToDate: "Vibex is up to date"
        case let .available(version): "Vibex \(version) is ready"
        case let .installing(version): "Updating to \(version)…"
        case .failed: "The update didn't finish"
        }
    }

    private var subtitle: String? {
        switch updater.state {
        case .idle, .checking, .installing: nil
        case .upToDate: "You have the latest version, \(updater.currentVersion). Here's what's in it."
        case .available: "You have \(updater.currentVersion)."
        case let .failed(reason): reason
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch updater.state {
        case .installing:
            VStack(spacing: 18) {
                Spacer()
                InstallSteps(progress: updater.progress ?? InstallProgress(step: .downloading))
                Text("Vibex quits and reopens by itself when this is done. Your windows and tabs come back.")
                    .font(.vibex(size: 12))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Spacer()
            }
        case .idle, .checking:
            ProgressView().controlSize(.regular)
        case .upToDate, .available, .failed:
            if let notes = updater.releaseNotes, !notes.isEmpty {
                ScrollView {
                    MarkdownView(document: MarkdownDocument(notes))
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            } else {
                Spacer()
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if case .available = updater.state {
                Text("Running terminal commands stop when Vibex restarts. Later installs it when you quit.")
                    .font(.vibex(size: 11.5))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            buttons
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    @ViewBuilder
    private var buttons: some View {
        switch updater.state {
        case .available:
            Button("Later") {
                updater.postpone()
                close()
            }
            .controlSize(.large)
            Button("Restart to Update", action: updater.restartToUpdate)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        case .failed:
            Button("Open Releases") {
                NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repository)/releases/latest")!)
            }
            .controlSize(.large)
            Button("Try Again") { Task { await updater.check(userInitiated: true) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        case .idle, .checking, .upToDate, .installing:
            Button("Done", action: close)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Download → Verify → Install, with the download's own progress.
private struct InstallSteps: View {
    let progress: InstallProgress

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(InstallProgress.Step.allCases, id: \.rawValue) { step in
                    HStack(spacing: 6) {
                        Group {
                            if step.rawValue < progress.step.rawValue {
                                IconView(.checkCircle, size: 15).foregroundStyle(Theme.green)
                            } else if step == progress.step {
                                ProgressView().controlSize(.mini).frame(width: 15, height: 15)
                            } else {
                                Circle().strokeBorder(Theme.lineStrong, lineWidth: 1.5).frame(width: 13, height: 13).frame(width: 15, height: 15)
                            }
                        }
                        Text(step.title)
                            .font(.vibex(size: 12.5, weight: step == progress.step ? .medium : .regular))
                            .foregroundStyle(step.rawValue <= progress.step.rawValue ? Theme.text : Theme.faint)
                    }
                    if step != InstallProgress.Step.allCases.last {
                        Rectangle().fill(Theme.line).frame(width: 28, height: 1)
                    }
                }
            }
            if progress.step == .downloading, let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .frame(width: 300)
                    .tint(Theme.accent)
            }
        }
    }
}

/// The title bar's right side: an update button when one is waiting, then the MCP status.
struct TitlebarStatusView: View {
    let service: MCPService
    let updater: Updater

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            if let label {
                Button(action: updater.showWindow) {
                    HStack(spacing: 5) {
                        IconView(.download, size: 12)
                        Text(label).font(.vibex(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 9)
                    .frame(height: 20)
                    .background(Capsule().fill(Theme.accent))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressFeedbackButtonStyle())
                .help("See what's new and update")
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            MCPStatusView(service: service)
        }
        .animation(.spring(response: 0.3, dampingFraction: 1), value: label)
    }

    private var label: String? {
        switch updater.state {
        case let .available(version): "Update to \(version)"
        case .installing: "Updating…"
        default: nil
        }
    }
}
