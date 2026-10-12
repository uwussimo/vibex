import AppKit
import os
import SwiftTerm
import SwiftUI

/// Tabs of real PTY-backed terminals. Lives on the left, where Claude Code runs.
final class TerminalPaneViewController: NSViewController {
    private final class Tab {
        let id = UUID()
        let terminal: LocalProcessTerminalView
        var title: String
        var directory: String?
        var hasExited = false

        init(terminal: LocalProcessTerminalView, title: String, directory: String?) {
            self.terminal = terminal
            self.title = title
            self.directory = directory
        }
    }

    let session: ProjectSession
    private var tabs: [Tab] = []
    private var selectedID: UUID?
    private let tabBarModel = TerminalTabBarModel()
    private let container = NSView()
    private var hasRestored = false
    private var clickMonitor: Any?

    init(session: ProjectSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = TerminalTheme.background.cgColor

        let actions = TabStripActions(
            select: { [weak self] id in self?.select(id) },
            close: { [weak self] id in self?.close(id) },
            new: { [weak self] in self?.newTab(nil) }
        )
        let tabBar = NSHostingView(rootView: TerminalTabStrip(model: tabBarModel, actions: actions))
        tabBar.sizingOptions = []
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = TerminalTheme.background.cgColor

        root.addSubview(tabBar)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 36),
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // SwiftTerm's mouseDown does not claim first responder, so after a click in the browser
        // keystrokes would keep going to the web view. Claim it on any click inside the pane.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.claimFocusIfClicked(event)
            }
            return event
        }
    }

    // The pane lives as long as the window, so the monitor is never removed.

    private func claimFocusIfClicked(_ event: NSEvent) {
        guard let window = view.window, event.window === window, let terminal = selectedTab?.terminal else { return }
        let point = container.convert(event.locationInWindow, from: nil)
        guard container.bounds.contains(point), window.firstResponder !== terminal else { return }
        window.makeFirstResponder(terminal)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasRestored else { return }
        hasRestored = true
        let directories = session.state.terminalDirectories.filter { FileManager.default.fileExists(atPath: $0) }
        if directories.isEmpty {
            openTab(directory: session.project.path)
        } else {
            for directory in directories { openTab(directory: directory) }
        }
        focusCurrentTerminal()
    }

    // MARK: - Tabs

    private var selectedTab: Tab? { tabs.first { $0.id == selectedID } }

    @discardableResult
    private func openTab(directory: String?) -> Tab {
        let session = TerminalSession.login(
            directory: directory ?? selectedTab?.directory ?? self.session.project.path,
            environment: self.session.terminalEnvironment
        )
        let terminal = LocalProcessTerminalView(frame: container.bounds)
        terminal.autoresizingMask = [.width, .height]
        TerminalTheme.apply(to: terminal)
        terminal.processDelegate = self
        do {
            try terminal.setUseMetal(true)
        } catch {
            Log.terminal.notice("Metal renderer unavailable, using CoreText: \(error.localizedDescription, privacy: .public)")
        }

        let tab = Tab(terminal: terminal, title: Self.title(forDirectory: session.directory), directory: session.directory)
        tabs.append(tab)
        syncTabBar()
        select(tab.id)

        terminal.startProcess(
            executable: session.shell,
            args: session.arguments,
            environment: session.environment,
            execName: session.execName,
            currentDirectory: session.directory
        )
        Log.terminal.info("opened tab in \(session.directory, privacy: .public)")
        return tab
    }

    private func select(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedID = id
        for subview in container.subviews where subview !== tab.terminal {
            subview.removeFromSuperview()
        }
        if tab.terminal.superview == nil {
            tab.terminal.frame = container.bounds
            container.addSubview(tab.terminal)
        }
        syncTabBar()
        focusCurrentTerminal()
    }

    private func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        if !tab.hasExited {
            tab.terminal.terminate()
        }
        tab.terminal.removeFromSuperview()
        tabs.remove(at: index)
        if tabs.isEmpty {
            openTab(directory: tab.directory)
            return
        }
        if selectedID == id {
            select(tabs[min(index, tabs.count - 1)].id)
        } else {
            syncTabBar()
        }
    }

    private func syncTabBar() {
        tabBarModel.tabs = tabs.map { TabStripItem(id: $0.id, title: $0.title) }
        tabBarModel.selectedID = selectedID
    }

    private static func title(forDirectory directory: String?) -> String {
        guard let directory else { return "Terminal" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if directory == home { return "~" }
        return (directory as NSString).lastPathComponent
    }

    /// Opens a tab and types the command once the shell is up, so the user sees exactly what runs.
    @discardableResult
    func runCommandInNewTab(_ command: String, directory: String? = nil) -> UUID {
        let tab = openTab(directory: directory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak tab] in
            tab?.terminal.send(txt: command + "\n")
        }
        return tab.id
    }

    /// Shell process ids of every tab, for finding which window an MCP caller runs in.
    var shellPIDs: [pid_t] { tabs.compactMap { $0.terminal.process?.shellPid } }

    struct TabSummary {
        let id: UUID
        let title: String
        let directory: String?
    }

    func tabSummaries() -> [TabSummary] {
        tabs.map { TabSummary(id: $0.id, title: $0.title, directory: $0.directory) }
    }

    func focusCurrentTerminal() {
        guard let terminal = selectedTab?.terminal else { return }
        view.window?.makeFirstResponder(terminal)
    }

    func persistTabs() {
        let directories = tabs.compactMap(\.directory)
        session.update { $0.terminalDirectories = directories }
    }

    // MARK: - Menu actions

    @objc func newTab(_ sender: Any?) { openTab(directory: nil) }

    @objc func closeTab(_ sender: Any?) {
        guard let selectedID else { return }
        close(selectedID)
    }

    @objc func nextTab(_ sender: Any?) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        select(tabs[(index + 1) % tabs.count].id)
    }

    @objc func previousTab(_ sender: Any?) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        select(tabs[(index - 1 + tabs.count) % tabs.count].id)
    }

    @objc func clearTerminal(_ sender: Any?) {
        // Same as the shell's clear: scroll the screen away and reset the cursor.
        selectedTab?.terminal.send(txt: "\u{1b}[2J\u{1b}[3J\u{1b}[H")
    }
}

extension TerminalPaneViewController: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard let tab = tabs.first(where: { $0.terminal === source }) else { return }
        tab.title = title.isEmpty ? Self.title(forDirectory: tab.directory) : title
        syncTabBar()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let tab = tabs.first(where: { $0.terminal === source }) else { return }
        var path = directory
        if let directory, let url = URL(string: directory), url.scheme == "file" {
            path = url.path
        }
        tab.directory = path
        if tab.title == Self.title(forDirectory: tab.directory) || tab.title == "Terminal" || tab.title == "~" {
            tab.title = Self.title(forDirectory: path)
        }
        syncTabBar()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let tab = tabs.first(where: { $0.terminal === source }) else { return }
        tab.hasExited = true
        Log.terminal.info("shell exited with \(exitCode ?? -1)")
        close(tab.id)
    }
}
