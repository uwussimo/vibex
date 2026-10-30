import AppKit
import Observation
import SwiftUI

/// The tabs shown above the editor area, VS Code style: every browser tab, the simulator once a
/// device is running, the diff of the file selected in Source Control, and AI Usage and the skills
/// marketplace when opened.
@Observable
final class EditorTabsModel {
    enum Tab: Hashable {
        case browser(UUID)
        case simulator
        case diff
        case agents
        case skills
        case compare
        case devices
        case mcp
        case design
        /// A file (or a skill's SKILL.md), by OpenDocument.id.
        case file(String)

        var kind: String {
            switch self {
            case .browser: "browser"
            case .simulator: "simulator"
            case .diff: "diff"
            case .agents: "agents"
            case .skills: "skills"
            case .compare: "compare"
            case .devices: "devices"
            case .mcp: "mcp"
            case .design: "design"
            case .file: "file"
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let tab: Tab
        var title: String
        var icon: Icon
        var isLoading = false
        var tint: Color?
        /// The diff tab is a preview (like VS Code's italic tab): it follows the sidebar's selection.
        var isPreview = false
        var id: Tab { tab }
    }

    var items: [Item] = []
    var selected: Tab?
    /// The Design chat is waiting on the user.
    var designNeedsAttention = false
    /// No tabs at all: the workspace collapses the editor column.
    var isEmpty: Bool { items.isEmpty }
}

/// Hosts the browser, the simulator, the diff, AI Usage and the skills marketplace as tabs of one
/// area beside the terminal. Hidden tabs stay alive: the browser keeps playing and the simulator
/// pauses its display only.
final class EditorAreaViewController: NSViewController {
    let browserPane: BrowserPaneViewController
    let simulatorPane: SimulatorPaneViewController
    let sourceControl: SourceControlModel
    let skills: SkillsModel
    let tabs = EditorTabsModel()
    private let session: ProjectSession

    /// The simulator tab exists from the moment a device is running (or the user asks for it).
    private(set) var isSimulatorOpen = false
    /// What Build mode should size the area to: the simulator's natural width while it is showing.
    var onPreferredWidthChange: (CGFloat) -> Void = { _ in }
    /// Tabs opened or closed; the workspace collapses the column when none are left.
    var onTabsChange: () -> Void = {}
    private var simulatorPreferredWidth: CGFloat = 0
    private var lastNonDiffTab: EditorTabsModel.Tab?
    /// Created when opened and removed when closed, so their views stop updating with the tab.
    private var agentsHost: NSView?
    private var skillsHost: NSView?
    private var compareHost: NSView?
    private var devicesController: DeviceMatrixViewController?
    private var mcpHost: NSView?
    private var designHost: NSView?
    private var designModel: DesignModel?
    /// Reopens the Design tab that was showing when the project closed.
    var restoreDesign: () -> Void = {}
    /// The Design chat's process, for finding which window an MCP caller runs in.
    var designPID: pid_t? { designModel?.chat.processID }
    /// File tabs in the order they opened; the preview one is replaced by the next single click.
    private var fileHosts: [String: NSView] = [:]
    private var fileDocuments: [String: OpenDocument] = [:]
    private var fileOrder: [String] = []
    private var previewFile: String?
    /// The file in front changed (nil when it's not a file), for the Explorer's highlight.
    var onFileShown: (URL?) -> Void = { _ in }

    private let container = NSView()
    private lazy var diffHost: NSHostingView<DiffView> = {
        let host = NSHostingView(rootView: DiffView(model: sourceControl) { [weak self] in
            self?.sourceControl.select(nil)
        })
        // The split decides the width; a SwiftUI ideal size must not hug the column narrower.
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        return host
    }()

    init(session: ProjectSession, sourceControl: SourceControlModel, skills: SkillsModel) {
        self.session = session
        self.sourceControl = sourceControl
        self.skills = skills
        browserPane = BrowserPaneViewController(session: session)
        simulatorPane = SimulatorPaneViewController(session: session)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        let strip = NSHostingView(rootView: EditorTabStrip(
            model: tabs,
            select: { [weak self] tab in self?.select(tab) },
            close: { [weak self] tab in self?.close(tab) },
            newTab: { [weak self] in self?.browserPane.newTab(nil) }
        ))
        strip.sizingOptions = []
        strip.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(strip)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: root.topAnchor),
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: 36),
            container.topAnchor.constraint(equalTo: strip.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for child in [browserPane as NSViewController, simulatorPane] {
            addChild(child)
            embed(child.view)
        }
        embed(diffHost)

        browserPane.onTabsChange = { [weak self] in self?.rebuildItems() }
        browserPane.onSelect = { [weak self] id in self?.select(.browser(id)) }
        simulatorPane.openCompare = { [weak self] in self?.openCompare() }
        simulatorPane.onPreferredWidthChange = { [weak self] width in
            self?.simulatorPreferredWidth = width
            self?.reportPreferredWidth()
        }
        // Build the browser (and restore its tabs) before choosing what to show.
        _ = browserPane.view
        simulatorPane.start()
        observeSimulator()
        observeDiff()
        rebuildItems()
        switch session.state.editorTab {
        case "agents": openAgents()
        case "skills": openSkillsMarketplace()
        case "design": restoreDesign()
        default: break
        }
        if tabs.selected == nil {
            if let id = browserPane.selectedID ?? browserPane.tabs.first?.id { select(.browser(id)) } else if let first = tabs.items.first { select(first.tab) }
        }
    }

    private func embed(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        child.isHidden = true
        container.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: container.topAnchor),
            child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Selecting

    func select(_ tab: EditorTabsModel.Tab) {
        if case let .browser(id) = tab, browserPane.selectedID != id {
            browserPane.select(id) // calls back into select(_:) through onSelect
            return
        }
        if tab == .simulator, !isSimulatorOpen { openSimulator(select: false) }
        guard tabs.selected != tab || browserPane.view.isHidden == isBrowser(tab) else { return }
        tabs.selected = tab
        if tab != .diff { lastNonDiffTab = tab }
        browserPane.view.isHidden = !isBrowser(tab)
        simulatorPane.view.isHidden = tab != .simulator
        simulatorPane.setVisible(tab == .simulator)
        diffHost.isHidden = tab != .diff
        agentsHost?.isHidden = tab != .agents
        skillsHost?.isHidden = tab != .skills
        compareHost?.isHidden = tab != .compare
        devicesController?.view.isHidden = tab != .devices
        mcpHost?.isHidden = tab != .mcp
        designHost?.isHidden = tab != .design
        for (id, host) in fileHosts { host.isHidden = tab != .file(id) }
        if case let .file(id) = tab { onFileShown(fileDocuments[id]?.file) } else { onFileShown(nil) }
        session.update { $0.editorTab = tab.kind }
        reportPreferredWidth()
    }

    /// Gives keyboard focus to the selected tab's content.
    func focusSelected() {
        switch tabs.selected {
        case .browser: browserPane.focusWebView()
        case .simulator: simulatorPane.focus()
        default: break
        }
    }

    private func showNothing() {
        tabs.selected = nil
        for view in [browserPane.view, simulatorPane.view, diffHost, agentsHost, skillsHost, compareHost, devicesController?.view, mcpHost, designHost] + fileHosts.values.map(Optional.some) { view?.isHidden = true }
        simulatorPane.setVisible(false)
        reportPreferredWidth()
    }

    private func isBrowser(_ tab: EditorTabsModel.Tab?) -> Bool {
        if case .browser = tab { return true }
        return false
    }

    /// Shows the browser, opening a tab on the start page when every tab was closed.
    func showBrowser() {
        if let id = browserPane.selectedID ?? browserPane.tabs.first?.id {
            select(.browser(id))
        } else {
            browserPane.openTab(url: nil) // selects itself through onSelect
        }
    }

    func openSimulator(select shouldSelect: Bool) {
        if !isSimulatorOpen {
            isSimulatorOpen = true
            rebuildItems()
        }
        if shouldSelect { select(.simulator) }
    }

    func openAgents() {
        if agentsHost == nil {
            agentsHost = host(AgentsDashboard(store: .shared))
            rebuildItems()
        }
        select(.agents)
    }

    /// Opens a file tab, or brings it forward. `keep: false` is a preview tab: the next preview
    /// replaces it, like a single click in VS Code's explorer.
    func openDocument(_ document: OpenDocument, keep: Bool) {
        if fileHosts[document.id] == nil {
            if !keep, let preview = previewFile, preview != document.id { close(.file(preview)) }
            fileDocuments[document.id] = document
            fileHosts[document.id] = host(FileTabView(
                document: document,
                projectRoot: session.project.url,
                open: { [weak self] url in self?.openDocument(.file(url), keep: true) }
            ))
            fileOrder.append(document.id)
            if !keep { previewFile = document.id }
        } else if keep, previewFile == document.id {
            previewFile = nil
        }
        rebuildItems()
        select(.file(document.id))
    }

    /// The MCP server marketplace.
    func openMCPMarketplace(model: MCPServersModel) {
        if mcpHost == nil {
            mcpHost = host(MCPMarketplaceView(model: model))
            rebuildItems()
        }
        select(.mcp)
    }

    /// Vibex Design: a chat and a canvas.
    func openDesign(model: DesignModel) {
        if designHost == nil {
            designModel = model
            designHost = host(DesignTabView(model: model))
            rebuildItems()
        }
        select(.design)
    }

    /// Several simulators side by side.
    func openDevices(model: DeviceMatrixModel, runner: Runner) {
        if devicesController == nil {
            let controller = DeviceMatrixViewController(model: model, runner: runner)
            addChild(controller)
            embed(controller.view)
            devicesController = controller
            rebuildItems()
        }
        select(.devices)
    }

    /// Before and after: the simulator's screenshot history.
    func openCompare() {
        if compareHost == nil {
            compareHost = host(CompareView(history: simulatorPane.snapshots))
            rebuildItems()
        }
        select(.compare)
    }

    func openSkillsMarketplace() {
        if skillsHost == nil {
            skillsHost = host(SkillsMarketplaceView(model: skills, preview: { [weak self] skill in
                self?.openDocument(skill.document, keep: false)
            }))
            rebuildItems()
        }
        select(.skills)
    }

    private func host(_ content: some View) -> NSView {
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        embed(host)
        return host
    }

    func close(_ tab: EditorTabsModel.Tab) {
        switch tab {
        case let .browser(id):
            browserPane.close(id)
        case .simulator:
            isSimulatorOpen = false
            rebuildItems()
        case .diff:
            sourceControl.select(nil)
        case .agents:
            agentsHost?.removeFromSuperview()
            agentsHost = nil
            rebuildItems()
        case .skills:
            skillsHost?.removeFromSuperview()
            skillsHost = nil
            rebuildItems()
        case .compare:
            compareHost?.removeFromSuperview()
            compareHost = nil
            rebuildItems()
        case let .file(id):
            fileHosts.removeValue(forKey: id)?.removeFromSuperview()
            fileDocuments[id] = nil
            fileOrder.removeAll { $0 == id }
            if previewFile == id { previewFile = nil }
            rebuildItems()
        case .design:
            designModel?.stop()
            designModel = nil
            designHost?.removeFromSuperview()
            designHost = nil
            rebuildItems()
        case .mcp:
            mcpHost?.removeFromSuperview()
            mcpHost = nil
            rebuildItems()
        case .devices:
            devicesController?.prepareForTermination()
            devicesController?.view.removeFromSuperview()
            devicesController?.removeFromParent()
            devicesController = nil
            rebuildItems()
        }
    }

    /// ⌘W while the simulator or a diff has focus closes that tab (the browser handles its own).
    @objc func closeTab(_ sender: Any?) {
        if let selected = tabs.selected { close(selected) }
    }

    var selectedTab: EditorTabsModel.Tab? { tabs.selected }

    // MARK: - Items

    private func rebuildItems() {
        var items = browserPane.tabs.map { tab in
            EditorTabsModel.Item(tab: .browser(tab.id), title: tab.title, icon: .globe, isLoading: tab.isLoading)
        }
        if isSimulatorOpen {
            let model = simulatorPane.model
            items.append(EditorTabsModel.Item(
                tab: .simulator,
                title: model.selectedDevice?.name ?? "Simulator",
                icon: .phone,
                tint: model.selectedDevice?.isBooted == true ? Color(nsColor: .systemGreen) : nil
            ))
        }
        if agentsHost != nil {
            items.append(EditorTabsModel.Item(tab: .agents, title: "AI Usage", icon: .barChart))
        }
        if skillsHost != nil {
            items.append(EditorTabsModel.Item(tab: .skills, title: "Skills", icon: .skills))
        }
        if compareHost != nil {
            items.append(EditorTabsModel.Item(tab: .compare, title: "Compare", icon: .compare))
        }
        if devicesController != nil {
            items.append(EditorTabsModel.Item(tab: .devices, title: "Devices", icon: .grid))
        }
        if designHost != nil {
            items.append(EditorTabsModel.Item(tab: .design, title: "Design", icon: .feather))
        }
        if mcpHost != nil {
            items.append(EditorTabsModel.Item(tab: .mcp, title: "MCP Servers", icon: .server))
        }
        for id in fileOrder {
            guard let document = fileDocuments[id] else { continue }
            items.append(EditorTabsModel.Item(tab: .file(id), title: document.title, icon: .fileCode, isPreview: previewFile == id))
        }
        if let change = sourceControl.selection {
            items.append(EditorTabsModel.Item(tab: .diff, title: change.fileName, icon: .fileCode, tint: change.kind.color, isPreview: true))
        }
        let wasEmpty = tabs.isEmpty
        if items != tabs.items { tabs.items = items }
        defer { if tabs.isEmpty != wasEmpty { onTabsChange() } }
        if let selected = tabs.selected, !items.contains(where: { $0.tab == selected }) {
            // The selected tab closed: show the one used before it, or any that is left.
            if let fallback = lastNonDiffTab, items.contains(where: { $0.tab == fallback }) {
                select(fallback)
            } else if let first = items.first(where: { $0.tab != .diff }) ?? items.first {
                select(first.tab)
            } else {
                showNothing()
            }
        }
    }

    private func observeSimulator() {
        let model = simulatorPane.model
        var wasBooted = model.bootedDevice != nil
        Task { [weak self] in
            for await state in Observations({ (model.bootedDevice?.udid, model.selectedDevice?.name, model.selectedDevice?.isBooted) }) {
                guard let self else { return }
                let booted = state.0 != nil
                // A device starting (from the header, Run or MCP) brings its tab forward.
                if booted, !wasBooted { openSimulator(select: true) } else if booted, !isSimulatorOpen { openSimulator(select: session.state.editorTab == "simulator") }
                wasBooted = booted
                rebuildItems()
            }
        }
    }

    private func observeDiff() {
        let model = sourceControl
        Task { [weak self] in
            for await id in Observations({ model.selection?.id }) {
                guard let self else { return }
                rebuildItems()
                if id != nil { select(.diff) }
            }
        }
    }

    private func reportPreferredWidth() {
        onPreferredWidthChange(tabs.selected == .simulator ? simulatorPreferredWidth : 0)
    }

    func prepareForTermination() {
        devicesController?.prepareForTermination()
        browserPane.prepareForTermination()
        simulatorPane.prepareForTermination()
    }
}

// MARK: - Tab strip

struct EditorTabStrip: View {
    let model: EditorTabsModel
    let select: (EditorTabsModel.Tab) -> Void
    let close: (EditorTabsModel.Tab) -> Void
    let newTab: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(model.items) { item in
                            EditorTabCell(
                                item: item,
                                isSelected: item.tab == model.selected,
                                select: { select(item.tab) },
                                close: { close(item.tab) }
                            )
                            .id(item.tab)
                            .contextMenu {
                                TabCloseCommands(id: item.tab, all: model.items.map(\.tab), close: close)
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                        }
                    }
                    .padding(.leading, 6)
                }
                .onChange(of: model.selected) { _, tab in
                    guard let tab else { return }
                    withAnimation(.spring(response: 0.3, dampingFraction: 1)) { proxy.scrollTo(tab) }
                }
            }
            if model.items.count > tabListThreshold {
                TabListMenu(tabs: model.items.map { ($0.tab, $0.title, $0.tab == model.selected) }, select: select)
            }
            Button(action: newTab) {
                IconView(.plus, size: 15)
                    .frame(width: 26, height: 26)
                    .foregroundStyle(Theme.muted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressFeedbackButtonStyle())
            .help("New Browser Tab (⌘T)")
            .padding(.trailing, 6)
        }
        .frame(height: 38)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .animation(.spring(response: 0.3, dampingFraction: 1), value: model.items.map(\.tab))
    }
}

private struct EditorTabCell: View {
    let item: EditorTabsModel.Item
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if item.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    IconView(item.icon, size: 13)
                        .foregroundStyle(item.tint ?? (isSelected ? Theme.text.opacity(0.8) : Theme.faint))
                }
            }
            .frame(width: 14)
            Text(item.title)
                .font(.vibex(size: 12, weight: isSelected ? .medium : .regular))
                .italic(item.isPreview)
                .foregroundStyle(isSelected ? Theme.text : Theme.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: close) {
                IconView(.close, size: 11)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.white.opacity(isHovering ? 0.1 : 0)))
                    // A 24pt hit area around the 16pt circle.
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("Close Tab (⌘W)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 3)
        .frame(height: 26)
        .frame(minWidth: 90, maxWidth: 210)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(isSelected ? 0.08 : (isHovering ? 0.04 : 0)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? Theme.line : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.2, dampingFraction: 1), value: isHovering)
        .animation(.spring(response: 0.2, dampingFraction: 1), value: isSelected)
    }
}
