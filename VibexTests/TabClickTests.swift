import AppKit
import Testing
@testable import Vibex

/// Hit-tests a real window, so anything floating over the tab strips shows up. A toast's empty
/// overlay used to take every click across the top middle of the window.
@MainActor @Suite(.serialized) struct TabClickTests {
    private func hit(_ point: NSPoint, in content: NSView) -> NSView? {
        content.superview?.hitTest(content.convert(point, to: content.superview))
    }

    private func isInside(_ view: NSView?, _ ancestor: NSView) -> Bool {
        var view = view
        while let current = view {
            if current === ancestor { return true }
            view = current.superview
        }
        return false
    }

    @Test func `clicks reach both tab strips, and a toast only takes its own`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-clicks-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("habits")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(directory: root.appendingPathComponent("state"))
        let project = Project(url: folder)
        var state = ProjectState()
        state.browserTabURLs = ["about:blank"]
        state.terminalDirectories = [folder.path]
        store.save(state, for: project)
        let controller = MainWindowController(session: ProjectSession(project: project, store: store))
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: -6000, y: 200, width: 1500, height: 820), display: false)
        controller.showWindow(nil)
        defer { controller.close() }
        try await Task.sleep(for: .seconds(1.5))
        let content = try #require(window.contentView)
        let workspace = controller.workspace

        for pane in [workspace.editor.view, workspace.terminalPane.view] {
            let frame = pane.convert(pane.bounds, to: content)
            let blocked = stride(from: frame.minX + 4, to: frame.maxX - 4, by: 20).filter { !isInside(hit(NSPoint(x: $0, y: frame.maxY - 18), in: content), pane) }
            #expect(blocked.isEmpty, "\(blocked)")
        }

        // A toast takes clicks on its card only.
        controller.toast.show(title: "Hello", message: nil)
        try await Task.sleep(for: .seconds(0.6))
        let middle = content.bounds.midX
        let frame = workspace.editor.view.convert(workspace.editor.view.bounds, to: content)
        #expect(!isInside(hit(NSPoint(x: middle, y: frame.maxY - 25), in: content), workspace.view))
        #expect(isInside(hit(NSPoint(x: middle, y: frame.maxY - 120), in: content), workspace.view))
    }

    @Test func `Claude opens as a tab in the left column and comes back after closing`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-chat-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("habits")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(directory: root.appendingPathComponent("state"))
        let project = Project(url: folder)
        var state = ProjectState()
        state.browserTabURLs = ["about:blank"]
        state.terminalDirectories = [folder.path]
        state.claudeSessions = ["restored-session"]
        store.save(state, for: project)
        let session = ProjectSession(project: project, store: store)
        let controller = MainWindowController(session: session)
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: -6000, y: 200, width: 1500, height: 820), display: false)
        controller.showWindow(nil)
        defer { controller.close() }
        try await Task.sleep(for: .seconds(1.5))
        let pane = controller.workspace.terminalPane

        // A saved chat comes back beside the saved terminal, and both stay saved.
        #expect(pane.tabBarModel.tabs.map(\.isClaude) == [false, true])
        pane.persistTabs()
        #expect(session.state.claudeSessions == ["restored-session"])
        #expect(session.state.terminalDirectories.count == 1)

        pane.selectTab(pane.tabBarModel.tabs[0].id)
        #expect(!pane.tabBarModel.isClaudeSelected)
        controller.showClaude()
        #expect(pane.tabBarModel.isClaudeSelected)
        // Closing everything still leaves Claude one click away.
        while !pane.isEmpty { pane.closeTab(nil) }
        try await Task.sleep(for: .seconds(0.5))
        controller.showClaude()
        try await Task.sleep(for: .seconds(0.5))
        #expect(pane.tabBarModel.isClaudeSelected)
        #expect(controller.workspace.panes.terminal)
    }
}
