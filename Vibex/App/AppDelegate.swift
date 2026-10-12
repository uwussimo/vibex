import AppKit
import os


final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    let mcp = MCPService()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        mcp.choosePort()
        TerminalSession.extraEnvironment = mcp.environmentVariables()
        let controller = MainWindowController()
        controller.showWindow(nil)
        mainWindowController = controller
        mcp.registry.register(WorkspaceTools.make(workspace: controller.workspace, toast: controller.toast))
        mcp.registry.register(BrowserTools.make(browser: controller.workspace.browserPane))
        mcp.registry.register(SimulatorTools.make(simulator: controller.workspace.simulatorPane))
        mcp.start()
        controller.installMCPStatus(mcp)
        NSApp.activate()
        Log.app.info("Vibex launched")
    }

    @objc func copyMCPConfig(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(mcp.registrar.addCommand + "\n\n" + mcp.registrar.jsonConfig, forType: .string)
        mainWindowController?.toast.show(title: "MCP config copied", message: "The claude mcp add command and the JSON config are on the clipboard.")
    }

    @objc func reregisterMCP(_ sender: Any?) {
        Task {
            await mcp.rotateToken()
            TerminalSession.extraEnvironment = mcp.environmentVariables()
            mainWindowController?.toast.show(title: "MCP re-registered", message: mcp.registration)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindowController?.showWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.workspace.prepareForTermination()
    }
}
