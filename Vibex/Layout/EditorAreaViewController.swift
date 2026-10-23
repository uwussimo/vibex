import AppKit
import Observation
import SwiftUI

/// The tabs shown above the editor area, VS Code style: every browser tab, the simulator once a
/// device is running, the diff of the file selected in Source Control, and AI Agents and the skills
/// marketplace when opened.
@Observable
final class EditorTabsModel {
    enum Tab: Hashable {
        case browser(UUID)
        case simulator
        case diff
        case agents
        case skills

        var kind: String {
            switch self {
            case .browser: "browser"
            case .simulator: "simulator"
            case .diff: "diff"
            case .agents: "agents"
            case .skills: "skills"
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let tab: Tab
        var title: String
        var symbol: String
        var isLoading = false
        var tint: Color?
        /// The diff tab is a preview (like VS Code's italic tab): it follows the sidebar's selection.
        var isPreview = false
        var id: Tab { tab }
    }

    var items: [Item] = []
    var selected: Tab?
}

/// Hosts the browser, the simulator, the diff, AI Agents and the skills marketplace as tabs of one
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
    private var simulatorPreferredWidth: CGFloat = 0
    private var lastNonDiffTab: EditorTabsModel.Tab?
    /// Created when opened and removed when closed, so their views stop updating with the tab.
    private var agentsHost: NSView?
    private var skillsHost: NSView?

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
        default: break
        }
        if tabs.selected == nil, let id = browserPane.selectedID ?? browserPane.tabs.first?.id { select(.browser(id)) }
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
        session.update { $0.editorTab = tab.kind }
        reportPreferredWidth()
    }

    private func isBrowser(_ tab: EditorTabsModel.Tab?) -> Bool {
        if case .browser = tab { return true }
        return false
    }

    func showBrowser() {
        if let id = browserPane.selectedID ?? browserPane.tabs.first?.id { select(.browser(id)) }
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
            agentsHost = host(AgentsDashboard(store: .shared, style: .tab))
            rebuildItems()
        }
        select(.agents)
    }

    func openSkillsMarketplace() {
        if skillsHost == nil {
            skillsHost = host(SkillsMarketplaceView(model: skills))
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
            if tabs.selected == .simulator { showBrowser() }
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
            EditorTabsModel.Item(tab: .browser(tab.id), title: tab.title, symbol: "globe", isLoading: tab.isLoading)
        }
        if isSimulatorOpen {
            let model = simulatorPane.model
            items.append(EditorTabsModel.Item(
                tab: .simulator,
                title: model.selectedDevice?.name ?? "Simulator",
                symbol: "iphone",
                tint: model.selectedDevice?.isBooted == true ? Color(nsColor: .systemGreen) : nil
            ))
        }
        if agentsHost != nil {
            items.append(EditorTabsModel.Item(tab: .agents, title: "AI Agents", symbol: "gauge.with.dots.needle.67percent"))
        }
        if skillsHost != nil {
            items.append(EditorTabsModel.Item(tab: .skills, title: "Skills", symbol: "sparkles"))
        }
        if let change = sourceControl.selection {
            items.append(EditorTabsModel.Item(tab: .diff, title: change.fileName, symbol: "plus.forwardslash.minus", tint: change.kind.color, isPreview: true))
        }
        if items != tabs.items { tabs.items = items }
        if let selected = tabs.selected, !items.contains(where: { $0.tab == selected }) {
            if let fallback = lastNonDiffTab, items.contains(where: { $0.tab == fallback }) { select(fallback) } else { showBrowser() }
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
            Button(action: newTab) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressFeedbackButtonStyle())
            .help("New Browser Tab (⌘T)")
            .padding(.trailing, 6)
        }
        .frame(height: 36)
        .background(Rectangle().fill(.bar))
        .overlay(alignment: .bottom) { Divider() }
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
                    Image(systemName: item.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(item.tint ?? Color.primary.opacity(isSelected ? 0.75 : 0.5))
                }
            }
            .frame(width: 14)
            Text(item.title)
                .font(.vibex(size: 12, weight: isSelected ? .medium : .regular))
                .italic(item.isPreview)
                .foregroundStyle(Color.primary.opacity(isSelected ? 0.95 : 0.6))
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.primary.opacity(isHovering ? 0.1 : 0)))
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
                .fill(Color.primary.opacity(isSelected ? 0.1 : (isHovering ? 0.05 : 0)))
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.2, dampingFraction: 1), value: isHovering)
        .animation(.spring(response: 0.2, dampingFraction: 1), value: isSelected)
    }
}
