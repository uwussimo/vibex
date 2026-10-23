import AppKit

/// The main menu, built in code. Every item targets the responder chain so the focused pane decides
/// what ⌘W, ⌘R or ⌘L mean.
enum MainMenu {
    static func build() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(appMenu())
        menu.addItem(fileMenu())
        menu.addItem(editMenu())
        menu.addItem(viewMenu())
        menu.addItem(browserMenu())
        menu.addItem(simulatorMenu())
        menu.addItem(windowMenu())
        return menu
    }

    private static func appMenu() -> NSMenuItem {
        let menu = NSMenu(title: "Vibex")
        menu.addItem(withTitle: "About Vibex", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Restart to Update", action: #selector(AppDelegate.restartToUpdate(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Setup & Permissions…", action: #selector(AppDelegate.showSetup(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy MCP Config", action: #selector(AppDelegate.copyMCPConfig(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Re-register MCP with Claude Code", action: #selector(AppDelegate.reregisterMCP(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Install 'vibex' Command", action: #selector(AppDelegate.installCommandLineTool(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Vibex", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Vibex", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return item(menu)
    }

    private static func fileMenu() -> NSMenuItem {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "Open Folder…", action: #selector(AppDelegate.openFolder(_:)), keyEquivalent: "o")
        let recent = menu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = NSApp.delegate as? NSMenuDelegate
        recent.submenu = recentMenu
        menu.addItem(withTitle: "New Window in Home Folder", action: #selector(AppDelegate.newHomeWindow(_:)), keyEquivalent: "n")
        let newAgent = menu.addItem(withTitle: "New Agent…", action: #selector(MainWindowController.newAgent(_:)), keyEquivalent: "n")
        newAgent.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Welcome", action: #selector(AppDelegate.showWelcome(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "New Tab", action: #selector(TerminalPaneViewController.newTab(_:)), keyEquivalent: "t")
        menu.addItem(withTitle: "Close Tab", action: #selector(TerminalPaneViewController.closeTab(_:)), keyEquivalent: "w")
        menu.addItem(.separator())
        let next = menu.addItem(withTitle: "Next Tab", action: #selector(TerminalPaneViewController.nextTab(_:)), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .shift]
        let previous = menu.addItem(withTitle: "Previous Tab", action: #selector(TerminalPaneViewController.previousTab(_:)), keyEquivalent: "[")
        previous.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Terminal", action: #selector(TerminalPaneViewController.clearTerminal(_:)), keyEquivalent: "k")
        menu.addItem(.separator())
        let closeWindow = menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        return item(menu)
    }

    private static func editMenu() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return item(menu)
    }

    private static func viewMenu() -> NSMenuItem {
        let menu = NSMenu(title: "View")
        let palette = menu.addItem(withTitle: "Command Palette…", action: #selector(MainWindowController.showCommandPalette(_:)), keyEquivalent: "p")
        palette.keyEquivalentModifierMask = [.command, .shift]
        let sourceControl = menu.addItem(withTitle: "Source Control", action: #selector(MainWindowController.toggleSourceControl(_:)), keyEquivalent: "g")
        sourceControl.keyEquivalentModifierMask = [.control, .shift]
        menu.addItem(withTitle: "Devices", action: #selector(MainWindowController.showDevices(_:)), keyEquivalent: "")
        let agentsPanel = menu.addItem(withTitle: "Agents", action: #selector(MainWindowController.toggleAgents(_:)), keyEquivalent: "n")
        agentsPanel.keyEquivalentModifierMask = [.control, .shift]
        let skills = menu.addItem(withTitle: "Skills", action: #selector(MainWindowController.toggleSkills(_:)), keyEquivalent: "k")
        skills.keyEquivalentModifierMask = [.control, .shift]
        menu.addItem(withTitle: "Browse Skills…", action: #selector(MainWindowController.browseSkills(_:)), keyEquivalent: "")
        let mcp = menu.addItem(withTitle: "MCP Servers", action: #selector(MainWindowController.toggleMCPServers(_:)), keyEquivalent: "m")
        mcp.keyEquivalentModifierMask = [.control, .shift]
        menu.addItem(withTitle: "Browse MCP Servers…", action: #selector(MainWindowController.browseMCPServers(_:)), keyEquivalent: "")
        let agents = menu.addItem(withTitle: "AI Usage", action: #selector(MainWindowController.showAgents(_:)), keyEquivalent: "a")
        agents.keyEquivalentModifierMask = [.control, .shift]
        let nextChange = menu.addItem(withTitle: "Next Change", action: #selector(MainWindowController.nextChange(_:)), keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!))
        nextChange.keyEquivalentModifierMask = [.command, .option]
        let previousChange = menu.addItem(withTitle: "Previous Change", action: #selector(MainWindowController.previousChange(_:)), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        previousChange.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        let build = menu.addItem(withTitle: "Build Mode", action: #selector(WorkspaceSplitViewController.toggleBuildMode(_:)), keyEquivalent: "b")
        build.keyEquivalentModifierMask = [.command, .shift]
        let watch = menu.addItem(withTitle: "Watch Mode", action: #selector(WorkspaceSplitViewController.toggleWatchMode(_:)), keyEquivalent: "w")
        watch.keyEquivalentModifierMask = [.command, .option]
        let balanced = menu.addItem(withTitle: "Balanced Layout", action: #selector(WorkspaceSplitViewController.balancedMode(_:)), keyEquivalent: "0")
        balanced.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Focus Terminal", action: #selector(WorkspaceSplitViewController.focusTerminal(_:)), keyEquivalent: "1")
        menu.addItem(withTitle: "Focus Simulator", action: #selector(WorkspaceSplitViewController.focusSimulator(_:)), keyEquivalent: "2")
        menu.addItem(withTitle: "Focus Browser", action: #selector(WorkspaceSplitViewController.focusBrowser(_:)), keyEquivalent: "3")
        menu.addItem(.separator())
        let fullScreen = menu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        return item(menu)
    }

    private static func browserMenu() -> NSMenuItem {
        let menu = NSMenu(title: "Browser")
        menu.addItem(withTitle: "Open Location…", action: #selector(BrowserPaneViewController.openLocation(_:)), keyEquivalent: "l")
        menu.addItem(withTitle: "Reload Page", action: #selector(BrowserPaneViewController.reloadPage(_:)), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Back", action: #selector(BrowserPaneViewController.goBack(_:)), keyEquivalent: "[")
        menu.addItem(withTitle: "Forward", action: #selector(BrowserPaneViewController.goForward(_:)), keyEquivalent: "]")
        menu.addItem(.separator())
        let home = menu.addItem(withTitle: "Go to Netflix", action: #selector(BrowserPaneViewController.goHome(_:)), keyEquivalent: "n")
        home.keyEquivalentModifierMask = [.command, .shift]
        return item(menu)
    }

    private static func simulatorMenu() -> NSMenuItem {
        let menu = NSMenu(title: "Simulator")
        menu.addItem(withTitle: "Boot Device", action: #selector(SimulatorPaneViewController.bootDevice(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Shut Down Device", action: #selector(SimulatorPaneViewController.shutdownDevice(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let home = menu.addItem(withTitle: "Home", action: #selector(SimulatorPaneViewController.pressHome(_:)), keyEquivalent: "h")
        home.keyEquivalentModifierMask = [.command, .shift]
        let lock = menu.addItem(withTitle: "Lock", action: #selector(SimulatorPaneViewController.pressLock(_:)), keyEquivalent: "l")
        lock.keyEquivalentModifierMask = [.command, .shift]
        let shot = menu.addItem(withTitle: "Copy Screenshot", action: #selector(SimulatorPaneViewController.copyScreenshot(_:)), keyEquivalent: "s")
        shot.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Boot Slim (simslim)", action: #selector(SimulatorPaneViewController.toggleSlimPreference(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Slim Simulator Now", action: #selector(SimulatorPaneViewController.toggleSlimNow(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Install simslim…", action: #selector(SimulatorPaneViewController.installSimslim(_:)), keyEquivalent: "")
        return item(menu)
    }

    private static func windowMenu() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = menu
        return item(menu)
    }

    private static func item(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}
