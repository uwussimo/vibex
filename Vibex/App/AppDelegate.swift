import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    let mcp = MCPService()
    private var windows: WindowManager { .shared }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        mcp.choosePort()
        TerminalSession.extraEnvironment = mcp.environmentVariables()
        windows.mcp = mcp
        mcp.registry.register(WorkspaceTools.make())
        mcp.registry.register(BrowserTools.make())
        mcp.registry.register(SimulatorTools.make())
        mcp.start()
        if windows.windows.isEmpty { windows.restoreOrWelcome() }
        NSApp.activate()
        Log.app.info("Vibex launched")
    }

    /// Folders dropped on the Dock icon or passed with `open -a Vibex <folder>`.
    func application(_ application: NSApplication, open urls: [URL]) {
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

    @objc func copyMCPConfig(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(mcp.registrar.addCommand + "\n\n" + mcp.registrar.jsonConfig, forType: .string)
        windows.keyWindow?.toast.show(title: "MCP config copied", message: "The claude mcp add command and the JSON config are on the clipboard.")
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
        windows.prepareForTermination()
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
