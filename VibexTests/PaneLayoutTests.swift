import AppKit
import SwiftUI
import Testing
@testable import Vibex

/// Drives a real project window offscreen: closing the last browser or terminal tab closes that
/// column, both closed leaves "Nothing open", and the activity bar's actions bring them back.
@MainActor @Suite(.serialized) struct PaneLayoutTests {
    func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    @Test func closingAndReopeningPanes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-panes-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("habits")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = ProjectStore(directory: root.appendingPathComponent("state"))
        let project = Project(url: folder)
        var state = ProjectState()
        state.browserTabURLs = ["about:blank"]
        state.terminalDirectories = [folder.path]
        store.save(state, for: project)
        let session = ProjectSession(project: project, store: store)
        let controller = MainWindowController(session: session)
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: -6000, y: 200, width: 1500, height: 820), display: false)
        controller.showWindow(nil)
        await wait(1.5)
        let workspace = controller.workspace
        let terminalView = workspace.terminalPane.view, editorView = workspace.editor.view
        func showing(_ view: NSView) -> Bool { view.window != nil && view.frame.width > 100 }
        #expect(showing(terminalView) && showing(editorView))
        #expect(workspace.panes.terminal && workspace.panes.editor)

        // Last browser tab closes the editor column.
        let browserID = try #require(workspace.browserPane.tabs.first?.id)
        workspace.editor.close(.browser(browserID))
        await wait(0.8)
        #expect(!showing(editorView) && terminalView.frame.width > 1400)
        #expect(!workspace.panes.editor)
        #expect(session.state.browserClosed == true)

        // Browser button brings it back with a new tab.
        workspace.focusBrowser(nil)
        await wait(0.8)
        #expect(showing(editorView))
        #expect(workspace.browserPane.tabs.count == 1)
        #expect(session.state.browserClosed == false)
        #expect(terminalView.frame.width > 300)

        // Last terminal tab closes the terminal column.
        while !workspace.terminalPane.isEmpty { workspace.terminalPane.closeTab(nil) }
        await wait(0.8)
        #expect(!showing(terminalView) && editorView.frame.width > 1400)
        #expect(!workspace.panes.terminal)
        #expect(session.state.terminalClosed == true)

        // Both closed: the terminal column returns with "Nothing open".
        workspace.editor.close(.browser(try #require(workspace.browserPane.tabs.first?.id)))
        await wait(0.8)
        #expect(showing(terminalView) && !showing(editorView))

        // Terminal button opens a shell.
        workspace.focusTerminal(nil)
        await wait(1.0)
        #expect(!workspace.terminalPane.isEmpty)
        #expect(workspace.panes.terminal)
        workspace.focusBrowser(nil)
        await wait(1.0)
        #expect(terminalView.frame.width > 300 && editorView.frame.width > 300)

        controller.close()
        await wait(0.3)
        try? FileManager.default.removeItem(at: root)
    }
}
