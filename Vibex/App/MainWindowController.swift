import AppKit
import SwiftUI

/// One project window: terminal | simulator | browser for a single folder.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let session: ProjectSession
    let workspace: WorkspaceSplitViewController
    let toast = ToastModel()
    /// Per-window automation state (element refs survive between tool calls).
    private(set) lazy var simulatorAutomation = SimulatorAutomation(pane: workspace.simulatorPane)
    private(set) lazy var browserAutomation = BrowserAutomation(pane: workspace.browserPane)

    var project: Project { session.project }
    var onClose: (MainWindowController) -> Void = { _ in }
    var onBecomeKey: (MainWindowController) -> Void = { _ in }

    init(session: ProjectSession) {
        self.session = session
        workspace = WorkspaceSplitViewController(session: session)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1880, height: 1040),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Title plus the folder's proxy icon; ⌘-click it to see the path.
        window.title = session.project.name
        window.representedURL = session.project.url
        window.minSize = NSSize(width: 960, height: 600)
        window.backgroundColor = .windowBackgroundColor
        window.tabbingMode = .automatic // follows System Settings › Desktop & Dock › Prefer tabs
        window.tabbingIdentifier = "Vibex.Project"
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = workspace
        let autosave = "Vibex.Project.\(session.project.id)"
        if !window.setFrameUsingName(autosave), !window.setFrameUsingName("Vibex.MainWindow") {
            window.center()
        }
        window.setFrameAutosaveName(autosave)
        installToastOverlay()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func installToastOverlay() {
        guard let contentView = window?.contentView else { return }
        let host = NSHostingView(rootView: ToastView(model: toast))
        host.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(host, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: contentView.topAnchor),
            host.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            host.widthAnchor.constraint(equalToConstant: 400),
            host.heightAnchor.constraint(equalToConstant: 140),
        ])
    }

    func installTitlebarAccessory<Content: View>(_ view: Content, width: CGFloat) {
        let accessory = NSTitlebarAccessoryViewController()
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 24)
        accessory.view = host
        accessory.layoutAttribute = .trailing
        window?.addTitlebarAccessoryViewController(accessory)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        workspace.windowDidBecomeKey()
        onBecomeKey(self)
    }

    func windowWillClose(_ notification: Notification) {
        workspace.prepareForTermination()
        onClose(self)
    }
}
