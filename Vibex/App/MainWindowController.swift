import AppKit
import SwiftUI

/// One project window for a single folder, laid out like VS Code: activity bar | sidebar (Source
/// Control or Skills) | terminal | tabbed editor area (browser tabs, simulator, diff, AI Usage, Skills).
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let session: ProjectSession
    let workspace: WorkspaceSplitViewController
    let toast = ToastModel()
    let sourceControl: SourceControlModel
    let skills: SkillsModel
    let agents: AgentsModel
    let sidebar = SidebarModel()
    private let columns = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem { columns.splitViewItems[0] }
    /// Per-window automation state (element refs survive between tool calls).
    private(set) lazy var simulatorAutomation = SimulatorAutomation(pane: workspace.simulatorPane)
    private(set) lazy var browserAutomation = BrowserAutomation(pane: workspace.browserPane)
    private(set) lazy var runner = Runner(window: self)
    private(set) lazy var deviceMatrix = DeviceMatrixModel(session: session)
    private(set) lazy var mcpServers = MCPServersModel(folder: session.project.url)
    private(set) lazy var explorer = ExplorerModel(root: session.project.url)

    var project: Project { session.project }
    var onClose: (MainWindowController) -> Void = { _ in }
    var onBecomeKey: (MainWindowController) -> Void = { _ in }

    init(session: ProjectSession) {
        self.session = session
        sourceControl = SourceControlModel(folder: session.project.url)
        skills = SkillsModel(folder: session.project.url)
        agents = AgentsModel(project: session.project)
        workspace = WorkspaceSplitViewController(session: session, sourceControl: sourceControl, skills: skills)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1880, height: 1040),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Title plus the folder's proxy icon; ⌘-click it to see the path.
        window.title = session.project.name
        window.representedURL = session.project.url
        window.minSize = NSSize(width: 960, height: 600)
        window.backgroundColor = Theme.NS.background
        window.tabbingMode = .automatic // follows System Settings › Desktop & Dock › Prefer tabs
        window.tabbingIdentifier = "Vibex.Project"
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        // A plain container holds the activity bar and the split views, so overlays (toast, palette)
        // float above them instead of becoming extra split panes.
        let root = NSViewController()
        root.view = NSView()
        let workspace = workspace
        // A plain item rather than a glass sidebar: Vibex's surfaces are solid, like its site.
        let sidebarItem = NSSplitViewItem(viewController: NSHostingController(rootView: SidebarView(
            sidebar: sidebar,
            sourceControl: sourceControl,
            skills: skills,
            mcpServers: mcpServers,
            explorer: explorer,
            openFile: { [weak self] url, keep in self?.openFile(url, keep: keep) },
            viewSkill: { [weak self] skill in self?.openFile(skill.skillFile, keep: true) },
            window: { [weak window] in window },
            browseSkills: { [weak workspace] in workspace?.editor.openSkillsMarketplace() },
            browseMCP: { [weak self] in self?.browseMCPServers(nil) },
            openClaude: { [weak self] in self?.openClaudeCode() }
        )))
        sidebarItem.minimumThickness = 240
        sidebarItem.maximumThickness = 440
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = session.state.sourceControlVisible != true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        sidebar.panel = session.state.sidebarPanel.flatMap(SidebarModel.Panel.init(rawValue:)) ?? .sourceControl
        columns.splitView.autosaveName = "Vibex.SourceControl.\(session.project.id)"
        columns.addSplitViewItem(sidebarItem)
        columns.addSplitViewItem(NSSplitViewItem(viewController: workspace))
        root.addChild(columns)
        columns.view.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(columns.view)
        let activityBar = NSView()
        activityBar.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(activityBar)
        NSLayoutConstraint.activate([
            activityBar.topAnchor.constraint(equalTo: root.view.topAnchor),
            activityBar.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
            activityBar.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            activityBar.widthAnchor.constraint(equalToConstant: ActivityBar.width),
            columns.view.topAnchor.constraint(equalTo: root.view.topAnchor),
            columns.view.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
            columns.view.leadingAnchor.constraint(equalTo: activityBar.trailingAnchor),
            columns.view.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
        ])
        window.contentViewController = root
        window.setContentSize(NSSize(width: 1880, height: 1040))
        let autosave = "Vibex.Project.\(session.project.id)"
        if !window.setFrameUsingName(autosave), !window.setFrameUsingName("Vibex.MainWindow") {
            window.center()
        }
        window.setFrameAutosaveName(autosave)
        installToastOverlay()
        installActivityBar(in: activityBar)
        sidebar.isVisible = !sidebarItem.isCollapsed
        sourceControl.start()
        agents.refresh()
        workspace.simulatorPane.openDevices = { [weak self] in self?.showDevices(nil) }
        workspace.terminalPane.openFile = { [weak self] url in self?.openFile(url, keep: true) }
        workspace.terminalPane.agents = ClaudeAgentsContext(model: agents, actions: agentActions())
        workspace.editor.restoreDesign = { [weak self] in self?.openDesignTab() }
        workspace.terminalPane.showSkills = { [weak self] in self?.showSidebar(.skills) }
        workspace.terminalPane.showMCP = { [weak self] in self?.showSidebar(.mcp) }
        workspace.editor.onFileShown = { [weak self] url in if let url { self?.explorer.selection = url.standardizedFileURL } }
    }

    private func installActivityBar(in container: NSView) {
        let bar = NSHostingView(rootView: ActivityBar(
            sidebar: sidebar,
            sourceControl: sourceControl,
            tabs: workspace.editor.tabs,
            panes: workspace.panes,
            leftTabs: workspace.terminalPane.tabBarModel,
            simulator: workspace.simulatorPane.model,
            attention: .shared,
            agents: agents,
            windowID: session.windowID,
            actions: ActivityBarActions(
                showClaude: { [weak self] in self?.showClaude() },
                showTerminal: { [weak self] in self?.showTerminalOrWaiting() },
                showSimulator: { [weak self] in self?.workspace.focusSimulator(nil) },
                showBrowser: { [weak self] in self?.workspace.focusBrowser(nil) },
                showDesign: { [weak self] in self?.showDesign(nil) },
                toggleSourceControl: { [weak self] in self?.toggleSourceControl(nil) },
                toggleSkills: { [weak self] in self?.toggleSkills(nil) },
                toggleExplorer: { [weak self] in self?.toggleExplorer(nil) },
                toggleMCP: { [weak self] in self?.toggleMCPServers(nil) },
                showAgents: { [weak self] in self?.showAgents(nil) },
                showSetup: { NSApp.sendAction(#selector(AppDelegate.showSetup(_:)), to: nil, from: nil) }
            )
        ))
        bar.sizingOptions = []
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    // MARK: - Sidebar

    private var isSidebarVisible: Bool {
        get { !sidebarItem.isCollapsed }
        set {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.28
                context.allowsImplicitAnimation = true
                sidebarItem.animator().isCollapsed = !newValue
            }
            session.update { $0.sourceControlVisible = newValue }
            sidebar.isVisible = newValue
        }
    }

    /// Opens `panel` in the sidebar, or hides the sidebar when it is already showing it.
    private func toggleSidebar(_ panel: SidebarModel.Panel) {
        if sidebar.isShowing(panel) {
            isSidebarVisible = false
            // Hiding Source Control closes the diff it opened.
            if panel == .sourceControl { sourceControl.select(nil) }
        } else {
            showSidebar(panel)
        }
    }

    private func showSidebar(_ panel: SidebarModel.Panel) {
        sidebar.panel = panel
        session.update { $0.sidebarPanel = panel.rawValue }
        if !isSidebarVisible { isSidebarVisible = true }
    }

    /// The Terminal button jumps to the first tab waiting on the user, if any.
    private func showTerminalOrWaiting() {
        if let item = AttentionCenter.shared.all.first(where: { $0.windowID == session.windowID }) {
            workspace.showTerminalTab(item.tabID)
        } else {
            workspace.focusTerminal(nil)
        }
    }

    /// ⌘T with focus outside the terminal and browser (the sidebar, or nothing open) still opens a
    /// terminal tab: the responder chain ends here after the panes.
    @objc func newTab(_ sender: Any?) {
        if workspace.terminalPane.isEmpty { workspace.focusTerminal(nil) } else { workspace.terminalPane.newTab(nil) }
    }

    @objc func toggleSourceControl(_ sender: Any?) { toggleSidebar(.sourceControl) }
    @objc func showDevices(_ sender: Any?) { workspace.editor.openDevices(model: deviceMatrix, runner: runner) }

    /// File › New Agent: Claude's composer, ready to start one.
    @objc func newAgent(_ sender: Any?) {
        showClaude()
        agents.isComposing = true
    }

    // MARK: - Design

    private var designModel: DesignModel?

    /// A canvas needs the room, so the design gets the wide side of the window.
    @objc func showDesign(_ sender: Any?) {
        // In this order, because the wide layout brings the browser forward.
        workspace.apply(mode: .watch, animated: true)
        openDesignTab()
    }

    private func openDesignTab() {
        // Closing the tab ends its chat, so each opening starts from a live model.
        let model = workspace.editor.tabs.items.contains { $0.tab == .design } ? designModel : nil
        let design = model ?? makeDesignModel()
        designModel = design
        workspace.editor.openDesign(model: design)
    }

    private func makeDesignModel() -> DesignModel {
        let design = DesignModel(project: project.url, environment: session.terminalEnvironment, resuming: session.state.designSession)
        design.chat.actions = ClaudeChatActions(
            openFile: { [weak self] url in self?.openFile(url, keep: true) },
            runInTerminal: { [weak self] command in
                guard let self else { return }
                workspace.showTerminalTab(workspace.terminalPane.runCommandInNewTab(command, directory: project.path))
            }
        )
        design.onSessionChange = { [weak self] id in self?.session.update { $0.designSession = id } }
        design.build = { [weak self] prompt, asAgent in
            guard let self else { return }
            if asAgent {
                agents.isComposing = false
                agentActions().create("build-design", prompt, [])
            } else {
                workspace.apply(mode: .balanced, animated: true)
                workspace.terminalPane.sendToClaude(prompt)
                workspace.updatePanesAfterTabChange()
            }
        }
        return design
    }

    // MARK: - Agents

    private func agentActions() -> AgentActions {
        AgentActions(
            create: { [weak self] name, task, attachments in
                guard let self else { return }
                Task {
                    guard let folder = await self.agents.create(name: name, task: task) else { return }
                    self.workspace.showTerminalTab(self.workspace.terminalPane.openAgentChat(in: folder, name: name, task: task, attachments: attachments))
                }
            },
            open: { [weak self] agent in
                guard let self else { return }
                if let id = workspace.terminalPane.tabIDs(inside: agent.path).first {
                    workspace.showTerminalTab(id)
                } else {
                    Task {
                        let session = await ClaudeTranscript.latestSession(folder: agent.path.path)
                        self.workspace.showTerminalTab(self.workspace.terminalPane.openAgentChat(in: agent.path, name: agent.name, task: nil, resuming: session))
                    }
                }
            },
            review: { [weak self] agent in
                guard let self else { return }
                sourceControl.show(checkout: agent.path, agent: agent.name)
                showSidebar(.sourceControl)
            },
            merge: { [weak self] agent in self?.confirmMerge(agent) },
            remove: { [weak self] agent in self?.confirmRemove(agent) },
            reveal: { agent in NSWorkspace.shared.activateFileViewerSelecting([agent.path]) },
            waiting: { [weak self] agent in
                guard let self else { return nil }
                let tabs = workspace.terminalPane.tabIDs(inside: agent.path)
                return tabs.lazy.compactMap { AttentionCenter.shared.waiting[$0]?.message }.first
            },
            isOpen: { [weak self] agent in !(self?.workspace.terminalPane.tabIDs(inside: agent.path).isEmpty ?? true) },
            isWorking: { [weak self] agent in self?.workspace.terminalPane.chat(inside: agent.path)?.isBusy == true }
        )
    }

    private func confirmMerge(_ agent: AgentsModel.Agent) {
        guard let window else { return }
        let alert = NSAlert()
        let base = agents.baseBranch ?? "the current branch"
        alert.messageText = "Merge \(agent.name) into \(base)?"
        alert.informativeText = agent.stats.uncommitted
            ? "Its uncommitted changes are committed first, then \(agent.branch) is merged into \(base) in this project."
            : "\(agent.branch) is merged into \(base) in this project."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task {
                await self.agents.merge(agent)
                self.sourceControl.refresh()
            }
        }
    }

    private func confirmRemove(_ agent: AgentsModel.Agent) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(agent.name)?"
        alert.informativeText = "Its folder, chat and terminal tabs close. The branch \(agent.branch) is deleted only if it was merged; otherwise Vibex keeps it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            workspace.terminalPane.closeTabs(inside: agent.path)
            if sourceControl.folder.standardizedFileURL == agent.path.standardizedFileURL { sourceControl.show(checkout: nil) }
            Task { await self.agents.remove(agent) }
        }
    }
    @objc func toggleSkills(_ sender: Any?) { toggleSidebar(.skills) }
    @objc func toggleExplorer(_ sender: Any?) { toggleSidebar(.explorer) }

    /// A file in a tab: a preview tab from a single click, a kept one from a double click.
    func openFile(_ url: URL, keep: Bool) {
        workspace.editor.openDocument(.file(url), keep: keep)
    }
    @objc func toggleMCPServers(_ sender: Any?) { toggleSidebar(.mcp) }

    /// A terminal tab running Claude Code in the project, e.g. to sign in to MCP servers with /mcp.
    func showClaude() {
        workspace.terminalPane.showClaude()
        workspace.updatePanesAfterTabChange()
    }

    func openClaudeCode() {
        let id = workspace.terminalPane.runCommandInNewTab("claude", directory: session.project.path)
        workspace.showTerminalTab(id)
    }

    @objc func browseMCPServers(_ sender: Any?) {
        showSidebar(.mcp)
        workspace.editor.openMCPMarketplace(model: mcpServers)
    }
    @objc func showAgents(_ sender: Any?) { workspace.editor.openAgents() }
    @objc func browseSkills(_ sender: Any?) {
        showSidebar(.skills)
        workspace.editor.openSkillsMarketplace()
    }

    /// Steps through the changed files' diffs, opening the sidebar so the list shows where you are.
    @objc func nextChange(_ sender: Any?) { stepChange(1) }
    @objc func previousChange(_ sender: Any?) { stepChange(-1) }

    private func stepChange(_ offset: Int) {
        guard !sourceControl.orderedChanges.isEmpty else { NSSound.beep(); return }
        if !sidebar.isShowing(.sourceControl) { showSidebar(.sourceControl) }
        sourceControl.selectAdjacent(offset)
    }

    // MARK: - Command palette

    private var paletteHost: NSView?
    private weak var responderBeforePalette: NSResponder?

    @objc func showCommandPalette(_ sender: Any?) {
        if paletteHost != nil { closePalette(); return }
        guard let window, let contentView = window.contentView else { return }
        responderBeforePalette = window.firstResponder
        let items = CommandCatalog.items(for: self)
        explorer.refreshFileIndex()
        let model = PaletteModel(items: items) { [weak self] query in
            guard let self else { return [] }
            return CommandCatalog.dynamicItems(for: query, window: self)
        }
        let host = NSHostingView(rootView: CommandPaletteView(
            model: model,
            run: { [weak self] item in
                self?.closePalette()
                // Let the restored first responder settle so responder-chain commands hit the right pane.
                DispatchQueue.main.async { item.perform() }
            },
            dismiss: { [weak self] in self?.closePalette() }
        ))
        host.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(host, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: contentView.topAnchor),
            host.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        paletteHost = host
        // The hosting view must hold first responder before SwiftUI can focus the search field.
        window.makeFirstResponder(host)
        // Then hand focus straight to the field's NSTextField so the first keystroke lands in it.
        DispatchQueue.main.async { [weak self, weak host] in
            guard let host, let field = Self.firstTextField(in: host) else { return }
            self?.window?.makeFirstResponder(field)
        }
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) { return field }
        }
        return nil
    }

    private func closePalette() {
        paletteHost?.removeFromSuperview()
        paletteHost = nil
        if let responder = responderBeforePalette { window?.makeFirstResponder(responder) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func installToastOverlay() {
        guard let contentView = window?.contentView else { return }
        let host = NSHostingView(rootView: ToastView(model: toast))
        host.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(host, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: contentView.topAnchor),
            host.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            host.widthAnchor.constraint(equalToConstant: 360),
        ])
    }

    func installTitlebarAccessory<Content: View>(_ view: Content, width: CGFloat) {
        let accessory = NSTitlebarAccessoryViewController()
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 24)
        accessory.view = host
        accessory.layoutAttribute = .trailing
        window?.addTitlebarAccessoryViewController(accessory)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        workspace.windowDidBecomeKey()
        onBecomeKey(self)
    }

    func windowWillClose(_ notification: Notification) {
        sourceControl.stop()
        workspace.prepareForTermination()
        onClose(self)
    }
}
