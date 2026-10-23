import AppKit

/// The Vibex icon in the macOS menu bar: what is running across every project at a glance, plus the
/// app-wide actions (open a folder, setup, the vibex command) without switching to a window first.
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
        statusItem.button?.image = Self.icon(active: false)
        statusItem.button?.toolTip = "Vibex"
        observeRuns()
    }

    /// Filled while any project is running, so a glance at the menu bar says something is live.
    private func observeRuns() {
        Task { [weak self] in
            let changes = Observations { WindowManager.shared.windows.contains { $0.runner.phase.isActive } }
            for await active in changes {
                self?.statusItem.button?.image = Self.icon(active: active)
            }
        }
    }

    private static func icon(active: Bool) -> NSImage? {
        let image = NSImage(systemSymbolName: active ? "rectangle.split.3x1.fill" : "rectangle.split.3x1", accessibilityDescription: "Vibex")
        image?.isTemplate = true
        return image?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
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
                let recent = action(project.name, #selector(openRecent(_:)), symbol: "folder")
                recent.representedObject = project.path
                recent.toolTip = project.displayPath
                recent.isEnabled = project.exists
                submenu.addItem(recent)
            }
            item.submenu = submenu
            menu.addItem(item)
        }
        menu.addItem(action("Open Folder…", #selector(openFolder(_:)), symbol: "folder.badge.plus"))

        if !bootedDevices.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header("Simulators"))
            for device in bootedDevices {
                let item = NSMenuItem(title: "\(device.name)", action: nil, keyEquivalent: "")
                item.image = symbol("iphone")
                item.badge = NSMenuItemBadge(string: device.isBooted ? device.runtime : device.state)
                let submenu = NSMenu()
                let shutdown = action("Shut Down", #selector(shutdownSimulator(_:)), symbol: "power")
                shutdown.representedObject = device.udid
                submenu.addItem(shutdown)
                item.submenu = submenu
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        if let version = updater.availableVersion {
            menu.addItem(action("Restart to Update to \(version)", #selector(AppDelegate.restartToUpdate(_:)), symbol: "arrow.down.circle.fill", target: NSApp.delegate))
        } else {
            menu.addItem(action("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)), symbol: "arrow.down.circle", target: NSApp.delegate))
        }
        menu.addItem(action("Setup & Permissions…", #selector(AppDelegate.showSetup(_:)), symbol: "checklist", target: NSApp.delegate))
        if CommandLineTool.installedPath == nil {
            menu.addItem(action("Install 'vibex' Command", #selector(AppDelegate.installCommandLineTool(_:)), symbol: "terminal", target: NSApp.delegate))
        }
        menu.addItem(action("Copy MCP Config", #selector(AppDelegate.copyMCPConfig(_:)), symbol: "doc.on.doc", target: NSApp.delegate))
        menu.addItem(.separator())
        menu.addItem(action("Quit Vibex", #selector(NSApplication.terminate(_:)), symbol: nil, target: NSApp, key: "q"))
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
        let item = action(window.project.name, #selector(showProject(_:)), symbol: runner.phase.isActive ? "play.circle.fill" : "folder")
        item.representedObject = window.project.path
        item.toolTip = window.project.displayPath
        if runner.phase != .idle { item.badge = NSMenuItemBadge(string: runner.phase.label) }

        let submenu = NSMenu()
        let show = action("Show Window", #selector(showProject(_:)), symbol: "macwindow")
        show.representedObject = window.project.path
        submenu.addItem(show)
        let run = runner.phase.isActive
            ? action("Stop", #selector(stopProject(_:)), symbol: "stop.fill")
            : action("Run", #selector(runProject(_:)), symbol: "play.fill")
        run.representedObject = window.project.path
        run.isEnabled = runner.phase.isActive || runner.resolveConfig() != nil
        submenu.addItem(run)
        let reveal = action("Show in Finder", #selector(revealProject(_:)), symbol: "folder")
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

    @objc private func runProject(_ sender: NSMenuItem) {
        window(for: sender)?.runner.run()
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

    private func action(_ title: String, _ selector: Selector, symbol name: String?, target: AnyObject? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = target ?? self
        if let name { item.image = symbol(name) }
        return item
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
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
