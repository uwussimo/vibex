import AppKit
import Observation
import os
import SwiftUI

/// Opens, tracks and restores project windows, and tells MCP tools which window a call is for.
@Observable
final class WindowManager {
    static let shared = WindowManager()

    private(set) var windows: [MainWindowController] = []
    /// Most recently focused first.
    private var focusOrder: [ObjectIdentifier] = []
    private var welcome: WelcomeWindowController?
    private var isTerminating = false
    var mcp: MCPService?

    var keyWindow: MainWindowController? {
        if let key = windows.first(where: { $0.window?.isKeyWindow == true }) { return key }
        for id in focusOrder {
            if let window = windows.first(where: { ObjectIdentifier($0) == id }) { return window }
        }
        return windows.first
    }

    // MARK: - Opening

    @discardableResult
    func open(_ url: URL) -> MainWindowController? {
        let project = Project(url: url)
        guard project.exists else {
            Log.app.error("not a folder: \(url.path, privacy: .public)")
            return nil
        }
        if let existing = windows.first(where: { $0.project == project }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            // Key-window notifications do not fire while Vibex is in the background.
            noteFocus(existing)
            return existing
        }
        let controller = MainWindowController(session: ProjectSession(project: project))
        controller.onClose = { [weak self] closed in self?.windowClosed(closed) }
        controller.onBecomeKey = { [weak self] focused in self?.noteFocus(focused) }
        if let mcp { controller.installTitlebarAccessory(MCPStatusView(service: mcp), width: 140) }
        windows.append(controller)
        noteFocus(controller)
        ProjectStore.shared.noteOpened(project)
        NSDocumentController.shared.noteNewRecentDocumentURL(project.url)
        rememberOpenSet()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        welcome?.close()
        welcome = nil
        Log.app.info("opened project \(project.path, privacy: .public)")
        return controller
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose a project folder"
        if panel.runModal() == .OK {
            panel.urls.forEach { open($0) }
        }
    }

    /// Restores last session's windows; falls back to the welcome window.
    func restoreOrWelcome() {
        let previous = ProjectStore.shared.lastOpen.filter(\.exists)
        previous.forEach { open($0.url) }
        if windows.isEmpty { showWelcome() }
    }

    func showWelcome() {
        if let welcome {
            welcome.showWindow(nil)
            return
        }
        let controller = WelcomeWindowController(manager: self)
        welcome = controller
        controller.showWindow(nil)
        controller.window?.center()
        NSApp.activate()
    }

    // MARK: - Lifecycle

    func prepareForTermination() {
        isTerminating = true
        rememberOpenSet()
        windows.forEach { $0.workspace.prepareForTermination() }
    }

    private func windowClosed(_ controller: MainWindowController) {
        windows.removeAll { $0 === controller }
        focusOrder.removeAll { $0 == ObjectIdentifier(controller) }
        guard !isTerminating else { return }
        rememberOpenSet()
        if windows.isEmpty { showWelcome() }
    }

    private func noteFocus(_ controller: MainWindowController) {
        let id = ObjectIdentifier(controller)
        focusOrder.removeAll { $0 == id }
        focusOrder.insert(id, at: 0)
    }

    private func rememberOpenSet() {
        ProjectStore.shared.lastOpen = windows.map(\.project)
    }

    // MARK: - Tool routing

    /// The window an MCP call should act on: the caller's own window when known, else the most recently focused.
    func toolTarget(callerWindowID: String? = ToolCall.callerWindowID) throws -> MainWindowController {
        if let callerWindowID, let window = windows.first(where: { $0.session.windowID == callerWindowID }) {
            return window
        }
        guard let window = keyWindow else { throw ToolError("no project window is open in Vibex") }
        return window
    }
}

/// Per-call context for MCP tools, set by the server while a tool runs.
enum ToolCall {
    @TaskLocal static var callerWindowID: String?
}
