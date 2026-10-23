import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    let mcp = MCPService()
    let updater = Updater()
    private var windows: WindowManager { .shared }
    private var hasLaunched = false
    /// Folders macOS hands over before launch finishes (`vibex .` on a cold start); opened once MCP is up.
    private var pendingURLs: [URL] = []
    private var setup: SetupWindowController?
    private var menuBar: MenuBarController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Vibex is dark everywhere, like its terminal and its site.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = MainMenu.build()
    }

    /// Unit tests run inside the app; they must not open windows, bind the MCP port or touch Claude Code's config.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        mcp.choosePort()
        TerminalSession.extraEnvironment = mcp.environmentVariables()
        windows.mcp = mcp
        mcp.registry.register(WorkspaceTools.make())
        mcp.registry.register(BrowserTools.make())
        mcp.registry.register(SimulatorTools.make())
        mcp.start()
        menuBar = MenuBarController(mcp: mcp, updater: updater)
        updater.start()
        hasLaunched = true
        if pendingURLs.isEmpty {
            windows.restoreOrWelcome()
        } else {
            openFolders(pendingURLs)
            pendingURLs = []
        }
        if SetupModel.needsSetup { showSetup(nil) }
        NSApp.activate()
        Log.app.info("Vibex launched")
    }

    /// Folders dropped on the Dock icon, passed to `vibex`, or passed with `open -a Vibex <folder>`.
    func application(_ application: NSApplication, open urls: [URL]) {
        if hasLaunched { openFolders(urls) } else { pendingURLs += urls }
    }

    private func openFolders(_ urls: [URL]) {
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                windows.open(url)
            } else {
                windows.open(url.deletingLastPathComponent())
            }
        }
    }

    // MARK: - Menu actions

    @objc func openFolder(_ sender: Any?) { windows.showOpenPanel() }

    @objc func newHomeWindow(_ sender: Any?) { windows.open(FileManager.default.homeDirectoryForCurrentUser) }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        windows.open(URL(fileURLWithPath: path))
    }

    @objc func clearRecents(_ sender: Any?) { ProjectStore.shared.clearRecents() }

    @objc func showWelcome(_ sender: Any?) { windows.showWelcome() }

    @objc func checkForUpdates(_ sender: Any?) {
        guard Updater.isEnabled else {
            windows.keyWindow?.toast.show(title: "Updates are off in development builds", message: "Install a release to get automatic updates.")
            return
        }
        Task { await updater.check(userInitiated: true) }
    }

    @objc func restartToUpdate(_ sender: Any?) { updater.restartToUpdate() }

    @objc func showSetup(_ sender: Any?) {
        let controller = setup ?? SetupWindowController()
        setup = controller
        controller.showWindow(sender)
    }

    @objc func copyMCPConfig(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(mcp.registrar.addCommand + "\n\n" + mcp.registrar.jsonConfig, forType: .string)
        windows.keyWindow?.toast.show(title: "MCP config copied", message: "The claude mcp add command and the JSON config are on the clipboard.")
    }

    @objc func installCommandLineTool(_ sender: Any?) {
        Task {
            do {
                let path = try await CommandLineTool.install()
                windows.keyWindow?.toast.show(title: "Installed vibex", message: "Run vibex . in any folder to open it here (\(path)).")
            } catch {
                windows.keyWindow?.toast.show(title: "Could not install vibex", message: error.localizedDescription)
            }
        }
    }

    @objc func reregisterMCP(_ sender: Any?) {
        Task {
            await mcp.rotateToken()
            TerminalSession.extraEnvironment = mcp.environmentVariables()
            windows.keyWindow?.toast.show(title: "MCP re-registered", message: mcp.registration)
        }
    }

    // MARK: - Lifecycle

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let window = windows.keyWindow { window.showWindow(nil) } else { windows.showWelcome() }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for window in windows.windows {
            let item = menu.addItem(withTitle: window.project.name, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = window.project.path
            item.target = self
        }
        if !windows.windows.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: "Open Folder…", action: #selector(openFolder(_:)), keyEquivalent: "").target = self
        return menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        windows.prepareForTermination()
        updater.installOnQuitIfNeeded()
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Fills File → Open Recent each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recents = ProjectStore.shared.recents
        for project in recents {
            let item = menu.addItem(withTitle: project.name, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = project.path
            item.toolTip = project.displayPath
            item.target = self
            item.isEnabled = project.exists
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        }
        if !recents.isEmpty { menu.addItem(.separator()) }
        let clear = menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecents(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !recents.isEmpty
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Restart to Update appears only once a newer release is waiting.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(restartToUpdate(_:)) else { return true }
        let version = updater.availableVersion
        menuItem.isHidden = version == nil
        menuItem.title = version.map { "Restart to Update to \($0)" } ?? "Restart to Update"
        return version != nil
    }
}
