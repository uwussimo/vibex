import AppKit
import SwiftUI

/// The single Vibex window.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let workspace = WorkspaceSplitViewController()
    let toast = ToastModel()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1880, height: 1040),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vibex"
        window.minSize = NSSize(width: 960, height: 600)
        window.backgroundColor = .windowBackgroundColor
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        window.contentViewController = workspace
        if !window.setFrameUsingName("Vibex.MainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("Vibex.MainWindow")
        installToastOverlay()
    }

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

    func installMCPStatus(_ service: MCPService) {
        let accessory = NSTitlebarAccessoryViewController()
        let host = NSHostingView(rootView: MCPStatusView(service: service))
        host.frame = NSRect(x: 0, y: 0, width: 140, height: 24)
        accessory.view = host
        accessory.layoutAttribute = .trailing
        window?.addTitlebarAccessoryViewController(accessory)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        workspace.windowDidBecomeKey()
    }
}
