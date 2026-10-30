import AppKit
import SwiftUI
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
        state.claudeChats = [ClaudeChatState(session: "restored-session", folder: folder.path, name: nil)]
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
        #expect(session.state.claudeChats?.map(\.session) == ["restored-session"])
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

    /// Goes through the app's event queue like a real click, so `clickCount` is what the views read.
    private func click(_ point: NSPoint, in window: NSWindow, count: Int) async throws {
        for (type, number) in [(NSEvent.EventType.leftMouseDown, count), (.leftMouseUp, count)] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: number, pressure: 1
            ))
            NSApp.postEvent(event, atStart: false)
        }
        try await Task.sleep(for: .milliseconds(200))
    }

    @Test func `double-clicking a tab opens another like it`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-dup-\(UUID().uuidString)")
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
        let pane = controller.workspace.terminalPane
        let frame = pane.view.convert(pane.view.bounds, to: nil)
        let firstTab = NSPoint(x: frame.minX + 50, y: frame.maxY - 18)

        // One click only selects.
        try await click(firstTab, in: window, count: 1)
        #expect(pane.tabBarModel.tabs.count == 1)
        // The second click of a double-click opens another, in the same folder.
        try await click(firstTab, in: window, count: 2)
        #expect(pane.tabBarModel.tabs.count == 2)
        #expect(Set(pane.tabSummaries().map(\.directory)) == [folder.path])

        // A Claude chat gives another chat, not a terminal.
        pane.newClaudeChat(nil)
        let chat = try #require(pane.tabBarModel.selectedID)
        pane.duplicate(chat)
        #expect(pane.tabBarModel.tabs.filter(\.isClaude).count == 2)
        #expect(pane.tabBarModel.tabs.count == 4)

        // A browser tab reopens its page; single-view tabs stay single.
        let editor = controller.workspace.editor
        let browser = editor.browserPane
        #expect(browser.tabs.count == 1)
        let editorFrame = editor.view.convert(editor.view.bounds, to: nil)
        let browserTab = NSPoint(x: editorFrame.minX + 50, y: editorFrame.maxY - 18)
        try await click(browserTab, in: window, count: 1)
        try await click(browserTab, in: window, count: 2)
        #expect(browser.tabs.count == 2)
    }

    @Test func `a server's tab and its row answer double-clicks`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-srv-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("habits")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(directory: root.appendingPathComponent("state"))
        let project = Project(url: folder)
        var state = ProjectState()
        state.terminalClosed = true
        store.save(state, for: project)
        let controller = MainWindowController(session: ProjectSession(project: project, store: store))
        controller.showWindow(nil)
        defer { controller.close() }
        try await Task.sleep(for: .seconds(1))
        let model = ServersModel(
            file: root.appendingPathComponent("servers.json"),
            store: KeychainCredentialStore(service: "srv", backend: InMemoryKeychain(), defaults: try #require(UserDefaults(suiteName: UUID().uuidString))),
            authenticator: FakeDeviceAuthenticator()
        )
        var draft = ServerDraft()
        draft.name = "Prod"
        draft.host = "127.0.0.1"
        draft.username = "me"
        let server = model.save(draft, editing: nil)

        // A server's tab asks to connect again, rather than opening a local terminal.
        let pane = controller.workspace.terminalPane
        var asked: [UUID] = []
        pane.connectServer = { asked.append($0) }
        #expect(pane.liveTab(forServer: server.id) == nil)
        let (id, _) = pane.openSSHTab(profile: SSHConnectionProfile(profile: server), credentials: model.credentials, isGrantAuthorized: model.isGrantAuthorized)
        #expect(pane.liveTab(forServer: server.id) == id)
        pane.duplicate(id)
        #expect(asked == [server.id])
        #expect(pane.tabBarModel.tabs.count == 1)

        // The row reports how many clicks it got.
        var counts: [Int] = []
        let window = NSWindow(contentRect: NSRect(x: -6000, y: 200, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ServersSidebar(model: model, click: { _, count in counts.append(count) }, connect: { _ in }))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .seconds(0.5))
        // The middle of the first row, below the sidebar's header. Window coordinates start at the bottom.
        let row = NSPoint(x: 120, y: 400 - 70)
        try await click(row, in: window, count: 1)
        try await click(row, in: window, count: 2)
        #expect(counts == [1, 2])
    }
}
