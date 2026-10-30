import AppKit
import SwiftUI

/// The Vibex icon in the macOS menu bar. Either click opens the menu: what is open across every
/// project, AI Usage, and the app-wide actions (open a folder, setup, the vibex command).
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let mcp: MCPService
    private let updater: Updater
    private var windows: WindowManager { .shared }
    private var bootedDevices: [SimDevice] = []

    init(mcp: MCPService, updater: Updater) {
        self.mcp = mcp
        self.updater = updater
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.image = Self.icon(dot: nil)
        statusItem.button?.toolTip = "Vibex"
        observeRuns()
    }

    /// Filled while any project is running, so a glance at the menu bar says something is live.
    /// Orange while Claude waits for the user anywhere, green while a project runs.
    private func observeRuns() {
        Task { [weak self] in
            let changes = Observations {
                (WindowManager.shared.windows.contains { $0.runner.phase.isActive }, !AttentionCenter.shared.waiting.isEmpty)
            }
            for await (running, waiting) in changes {
                self?.statusItem.button?.image = Self.icon(dot: waiting ? Theme.NS.orange : (running ? Theme.NS.green : nil))
                self?.statusItem.button?.toolTip = waiting ? "Vibex: Claude is waiting for you" : "Vibex"
            }
        }
    }

    /// The bolt from the app icon, with a dot while a project is running. Without a dot it stays a
    /// template image so macOS tints it for the menu bar; with one, it draws the bolt in the label color.
    static func icon(dot: NSColor?) -> NSImage? {
        guard let bolt = NSImage.icon(.zap, size: 16) else { return nil }
        guard let dot else { return bolt }
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            let glyph = NSRect(x: 1, y: 1, width: 16, height: 16)
            bolt.draw(in: glyph)
            NSColor.labelColor.set()
            glyph.fill(using: .sourceAtop)
            dot.setFill()
            NSBezierPath(ovalIn: NSRect(x: 13, y: 11, width: 6.5, height: 6.5)).fill()
            return true
        }
        image.accessibilityDescription = "Vibex"
        return image
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    func menuWillOpen(_ menu: NSMenu) {
        Task {
            let devices = (try? await Simctl().listDevices()) ?? []
            let booted = devices.filter { $0.isBooted || $0.isTransitioning }
            guard booted != bootedDevices else { return }
            bootedDevices = booted
            rebuild()
        }
    }

    // MARK: - Building

    private func rebuild() {
        menu.removeAllItems()
        menu.addItem(statusRow())
        menu.addItem(.separator())

        let waiting = AttentionCenter.shared.all
        if !waiting.isEmpty {
            menu.addItem(header("Waiting for You"))
            for item in waiting {
                let project = windows.windows.first { $0.session.windowID == item.windowID }?.project.name ?? "Claude"
                let row = action("\(project): \(item.message)", #selector(jumpToWaiting(_:)), icon: item.kind == .permission ? .key : .message)
                row.representedObject = item.tabID.uuidString
                row.toolTip = item.message
                menu.addItem(row)
            }
            menu.addItem(.separator())
        }
        menu.addItem(header("Projects"))
        if windows.windows.isEmpty {
            menu.addItem(disabled("No open projects"))
        }
        for window in windows.windows {
            menu.addItem(projectItem(window))
        }
        let recents = ProjectStore.shared.recents.filter { recent in !windows.windows.contains { $0.project == recent } }.prefix(6)
        if !recents.isEmpty {
            let item = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for project in recents {
                let recent = action(project.name, #selector(openRecent(_:)), icon: .folder)
                recent.representedObject = project.path
                recent.toolTip = project.displayPath
                recent.isEnabled = project.exists
                submenu.addItem(recent)
            }
            item.submenu = submenu
            menu.addItem(item)
        }
        menu.addItem(action("Open Folder…", #selector(openFolder(_:)), icon: .folderPlus))
        let agents = action("AI Usage", #selector(showAgents(_:)), icon: .barChart)
        agents.toolTip = "Claude and Codex usage, in the frontmost project window"
        agents.isEnabled = targetWindow != nil
        menu.addItem(agents)

        if !bootedDevices.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header("Simulators"))
            for device in bootedDevices {
                let item = NSMenuItem(title: "\(device.name)", action: nil, keyEquivalent: "")
                item.image = .icon(.phone)
                item.badge = NSMenuItemBadge(string: device.isBooted ? device.runtime : device.state)
                let submenu = NSMenu()
                let shutdown = action("Shut Down", #selector(shutdownSimulator(_:)), icon: .power)
                shutdown.representedObject = device.udid
                submenu.addItem(shutdown)
                item.submenu = submenu
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        if let version = updater.availableVersion {
            menu.addItem(action("Update to \(version)…", #selector(AppDelegate.showUpdate(_:)), icon: .download, target: NSApp.delegate))
        } else {
            menu.addItem(action("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)), icon: .download, target: NSApp.delegate))
        }
        menu.addItem(action("Setup & Permissions…", #selector(AppDelegate.showSetup(_:)), icon: .checkCircle, target: NSApp.delegate))
        if CommandLineTool.installedPath == nil {
            menu.addItem(action("Install 'vibex' Command", #selector(AppDelegate.installCommandLineTool(_:)), icon: .terminal, target: NSApp.delegate))
        }
        menu.addItem(action("Copy MCP Config", #selector(AppDelegate.copyMCPConfig(_:)), icon: .copy, target: NSApp.delegate))
        menu.addItem(.separator())
        menu.addItem(action("Quit Vibex", #selector(NSApplication.terminate(_:)), icon: nil, target: NSApp, key: "q"))
    }

    private func statusRow() -> NSMenuItem {
        let title: String
        let color: NSColor
        if !mcp.isRunning {
            (title, color) = ("MCP server stopped", .systemRed)
        } else if mcp.isClientActive {
            (title, color) = ("MCP on :\(mcp.port), Claude Code connected", .systemGreen)
        } else {
            (title, color) = ("MCP on :\(mcp.port)", .systemGray)
        }
        let item = disabled(title)
        item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .regular).applying(.init(paletteColors: [color])))
        return item
    }

    private func projectItem(_ window: MainWindowController) -> NSMenuItem {
        let runner = window.runner
        let item = action(window.project.name, #selector(showProject(_:)), icon: runner.phase.isActive ? .play : .folder)
        item.representedObject = window.project.path
        item.toolTip = window.project.displayPath
        if runner.phase != .idle { item.badge = NSMenuItemBadge(string: runner.phase.label) }

        let submenu = NSMenu()
        let show = action("Show Window", #selector(showProject(_:)), icon: .browser)
        show.representedObject = window.project.path
        submenu.addItem(show)
        // Claude starts runs over MCP; stopping one from here is the only control left outside the window.
        if runner.phase.isActive {
            let stop = action("Stop \(runner.config?.summary ?? "Run")", #selector(stopProject(_:)), icon: .stop)
            stop.representedObject = window.project.path
            submenu.addItem(stop)
        }
        let reveal = action("Show in Finder", #selector(revealProject(_:)), icon: .folder)
        reveal.representedObject = window.project.path
        submenu.addItem(reveal)
        item.submenu = submenu
        return item
    }

    // MARK: - Actions

    @objc private func showProject(_ sender: NSMenuItem) {
        guard let window = window(for: sender) else { return }
        NSApp.activate()
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
    }

    /// The project window used last, else any.
    private var targetWindow: MainWindowController? { windows.keyWindow ?? windows.windows.first }

    @objc private func jumpToWaiting(_ sender: NSMenuItem) {
        guard let tab = (sender.representedObject as? String).flatMap(UUID.init(uuidString:)) else { return }
        AttentionCenter.shared.jump(to: tab)
    }

    @objc private func showAgents(_ sender: Any?) {
        guard let window = targetWindow else { return }
        NSApp.activate()
        window.showWindow(nil)
        window.showAgents(nil)
    }

    @objc private func stopProject(_ sender: NSMenuItem) {
        window(for: sender)?.runner.stop()
    }

    @objc private func revealProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSApp.activate()
        windows.open(URL(fileURLWithPath: path))
    }

    @objc private func openFolder(_ sender: Any?) {
        NSApp.activate()
        windows.showOpenPanel()
    }

    @objc private func shutdownSimulator(_ sender: NSMenuItem) {
        guard let udid = sender.representedObject as? String else { return }
        Task { try? await Simctl().shutdown(udid) }
    }

    // MARK: - Helpers

    private func window(for item: NSMenuItem) -> MainWindowController? {
        guard let path = item.representedObject as? String else { return nil }
        return windows.windows.first { $0.project.path == path }
    }

    private func action(_ title: String, _ selector: Selector, icon: Icon?, target: AnyObject? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = target ?? self
        if let icon { item.image = .icon(icon) }
        return item
    }

    private func header(_ title: String) -> NSMenuItem {
        NSMenuItem.sectionHeader(title: title)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
