import AppKit
import os
import SwiftTerm
import SwiftUI

/// Tabs of real PTY-backed terminals. Lives on the left, where Claude Code runs.
final class TerminalPaneViewController: NSViewController {
    private final class Tab {
        let id: UUID
        let terminal: LocalProcessTerminalView
        var title: String
        var directory: String?
        var hasExited = false
        /// Set for tabs that run one command (Run): they stay open on exit and report the code.
        var onExit: ((Int32?) -> Void)?
        var fixedTitle: String?

        init(id: UUID = UUID(), terminal: LocalProcessTerminalView, title: String, directory: String?) {
            self.id = id
            self.terminal = terminal
            self.title = title
            self.directory = directory
        }
    }

    let session: ProjectSession
    private var tabs: [Tab] = []
    private var selectedID: UUID?
    var selectedTabID: UUID? { selectedID }
    private let tabBarModel = TerminalTabBarModel()
    private let container = NSView()
    private var hasRestored = false
    private var clickMonitor: Any?
    /// Tabs were opened or closed (the workspace collapses the column when none are left).
    var onTabsChange: () -> Void = {}
    var isEmpty: Bool { tabs.isEmpty }
    /// False until the saved tabs were restored, so an empty pane at launch isn't taken for a closed one.
    var hasLoadedTabs: Bool { hasRestored }
    /// What the "Nothing open" state offers when this and the editor area are both empty.
    var emptyActions = PaneEmptyActions(terminal: {}, simulator: {}, browser: {}) {
        didSet { emptyHost?.rootView = PaneEmptyState(actions: emptyActions) }
    }
    private var emptyHost: NSHostingView<PaneEmptyState>?

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
        let empty = NSHostingView(rootView: PaneEmptyState(actions: emptyActions))
        empty.sizingOptions = []
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.isHidden = true
        root.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.topAnchor.constraint(equalTo: root.topAnchor),
            empty.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            empty.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        emptyHost = empty
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeAttention()
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

    /// Redraws the tab dots whenever a session starts or stops waiting.
    private func observeAttention() {
        withObservationTracking {
            _ = AttentionCenter.shared.waiting
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncTabBar()
                self?.observeAttention()
            }
        }
    }

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
            if session.state.terminalClosed != true { openTab(directory: session.project.path) }
        } else {
            for directory in directories { openTab(directory: directory) }
        }
        syncTabBar()
        focusCurrentTerminal()
    }

    // MARK: - Tabs

    private var selectedTab: Tab? { tabs.first { $0.id == selectedID } }

    /// Brings the pane back after its last tab was closed: one shell in the project folder.
    func reopen() {
        hasRestored = true
        if tabs.isEmpty { openTab(directory: session.project.path) }
        focusCurrentTerminal()
    }

    @discardableResult
    private func openTab(directory: String?) -> Tab {
        hasRestored = true
        if self.session.state.terminalClosed == true { self.session.update { $0.terminalClosed = false } }
        // The tab's id travels in its environment, so Claude Code's hooks can say which tab is waiting.
        let id = UUID()
        let session = TerminalSession.login(
            directory: directory ?? selectedTab?.directory ?? self.session.project.path,
            environment: self.session.terminalEnvironment.merging(["VIBEX_TAB": id.uuidString]) { $1 }
        )
        let terminal = makeTerminalView()

        let tab = Tab(id: id, terminal: terminal, title: Self.title(forDirectory: session.directory), directory: session.directory)
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

    private func makeTerminalView() -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: container.bounds)
        terminal.autoresizingMask = [.width, .height]
        TerminalTheme.apply(to: terminal)
        terminal.processDelegate = self
        do {
            try terminal.setUseMetal(true)
        } catch {
            Log.terminal.notice("Metal renderer unavailable, using CoreText: \(error.localizedDescription, privacy: .public)")
        }
        return terminal
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
            // Closing the last tab closes the terminal; the activity bar brings it back.
            selectedID = nil
            session.update { $0.terminalClosed = true }
            syncTabBar()
            return
        }
        if selectedID == id {
            select(tabs[min(index, tabs.count - 1)].id)
        } else {
            syncTabBar()
        }
    }

    private func syncTabBar() {
        let attention = AttentionCenter.shared
        tabBarModel.tabs = tabs.map { TabStripItem(id: $0.id, title: $0.title, needsAttention: attention.isWaiting(tab: $0.id)) }
        attention.forget(tabs: Set(tabs.map(\.id)), inWindow: session.windowID)
        tabBarModel.selectedID = selectedID
        emptyHost?.isHidden = !tabs.isEmpty
        onTabsChange()
    }

    /// Shells title tabs with an abbreviated working directory ("~/D/e/vibex", or "claude ~/D/e/vibex"
    /// while a command runs). Show the folder's name instead, keeping the command.
    nonisolated static func displayTitle(_ title: String) -> String {
        var words = title.split(separator: " ").map(String.init)
        guard let last = words.last, last.hasPrefix("/") || last.hasPrefix("~") else { return title }
        let folder = last == "~" || last == "/" ? last : (last as NSString).lastPathComponent
        words.removeLast()
        return words.isEmpty ? folder : words.joined(separator: " ") + " · " + folder
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

    func selectTab(_ id: UUID) { select(id) }

    /// A shell in `directory` (an agent's worktree), optionally typing `command` once it's ready.
    @discardableResult
    func openTab(in directory: URL, command: String? = nil) -> UUID {
        guard let command else { return openTab(directory: directory.path).id }
        return runCommandInNewTab(command, directory: directory.path)
    }

    /// Tabs whose shell is inside `folder`, for an agent's status and for closing them with it.
    func tabIDs(inside folder: URL) -> [UUID] {
        let prefix = folder.standardizedFileURL.path
        return tabs.filter { tab in
            guard let directory = tab.directory else { return false }
            let path = URL(fileURLWithPath: directory).standardizedFileURL.path
            return path == prefix || path.hasPrefix(prefix + "/")
        }.map(\.id)
    }

    func closeTabs(inside folder: URL) {
        for id in tabIDs(inside: folder) { close(id) }
    }
    func hasTab(_ id: UUID) -> Bool { tabs.contains { $0.id == id } }

    /// Shell process ids of every tab, for finding which window an MCP caller runs in.
    var shellPIDs: [pid_t] { tabs.compactMap { $0.terminal.process?.shellPid } }

    // MARK: - Process tabs

    /// Opens a tab that runs one command (not a shell) and stays open when it ends, so its output can be read.
    /// The command runs in the user's login shell for its PATH, under `script` so a transcript lands in `logURL`.
    @discardableResult
    func runProcessTab(
        title: String,
        command: String,
        directory: String,
        logURL: URL,
        replacing previous: UUID?,
        onExit: @escaping (Int32?) -> Void
    ) -> UUID {
        if let previous { terminate(previous, close: true) }
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID()
        let login = TerminalSession.login(directory: directory, environment: session.terminalEnvironment.merging(["VIBEX_TAB": id.uuidString]) { $1 })
        let terminal = makeTerminalView()
        let tab = Tab(id: id, terminal: terminal, title: title, directory: directory)
        tab.fixedTitle = title
        tab.onExit = onExit
        tabs.append(tab)
        select(tab.id)
        terminal.feed(text: "\u{1b}[2m$ \(command)\u{1b}[0m\r\n")
        terminal.startProcess(
            executable: "/usr/bin/script",
            args: ["-q", "-F", logURL.path, login.shell, "-l", "-c", command],
            environment: login.environment,
            execName: nil,
            currentDirectory: directory
        )
        Log.terminal.info("run tab: \(command, privacy: .public)")
        return tab.id
    }

    /// Stops a tab's process; optionally closes the tab too.
    func terminate(_ id: UUID, close shouldClose: Bool = false) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if !tab.hasExited {
            tab.onExit = shouldClose ? nil : tab.onExit
            tab.terminal.terminate()
        }
        if shouldClose { close(id) }
    }

    func isRunning(_ id: UUID) -> Bool {
        tabs.first { $0.id == id }.map { !$0.hasExited } ?? false
    }

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
        let directories = tabs.filter { $0.fixedTitle == nil }.compactMap(\.directory)
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
        guard let tab = tabs.first(where: { $0.terminal === source }), tab.fixedTitle == nil else { return }
        tab.title = title.isEmpty ? Self.title(forDirectory: tab.directory) : Self.displayTitle(title)
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
        Log.terminal.info("process exited with \(exitCode ?? -1)")
        if let onExit = tab.onExit {
            tab.onExit = nil
            let code = exitCode ?? -1
            let color = code == 0 ? "32" : "31"
            tab.terminal.feed(text: "\r\n\u{1b}[\(color)m● exited with code \(code)\u{1b}[0m — ⌘W closes this tab\r\n")
            tab.title = "\(tab.fixedTitle ?? "Run") \(code == 0 ? "✓" : "✗")"
            syncTabBar()
            onExit(exitCode)
            return
        }
        guard tab.fixedTitle == nil else { return }
        close(tab.id)
    }
}
