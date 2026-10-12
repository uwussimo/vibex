import AppKit
import os

/// Three columns: terminal | simulator slot | browser. Owns layout modes and the spring that moves
/// the dividers between them.
final class WorkspaceSplitViewController: NSSplitViewController, NSMenuItemValidation {
    let session: ProjectSession
    let terminalPane: TerminalPaneViewController
    let simulatorPane: SimulatorPaneViewController
    let browserPane: BrowserPaneViewController

    private(set) var mode: LayoutMode = .balanced
    private var manualWidths: ColumnWidths?
    private var simulatorWidth: CGFloat = 0
    private var isSettingPositions = false
    private var hasAppliedInitialLayout = false
    private lazy var animator = SpringAnimator(view: splitView)

    private var terminalItem: NSSplitViewItem { splitViewItems[0] }
    private var simulatorItem: NSSplitViewItem { splitViewItems[1] }
    private var browserItem: NSSplitViewItem { splitViewItems[2] }

    init(session: ProjectSession) {
        self.session = session
        terminalPane = TerminalPaneViewController(session: session)
        simulatorPane = SimulatorPaneViewController(session: session)
        browserPane = BrowserPaneViewController(session: session)
        manualWidths = session.state.columnWidths
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let split = WorkspaceSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        splitView = split
        super.loadView()
        view.frame = NSRect(x: 0, y: 0, width: 1880, height: 1000)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let terminal = NSSplitViewItem(viewController: terminalPane)
        terminal.minimumThickness = LayoutPlan.minTerminal
        terminal.holdingPriority = NSLayoutConstraint.Priority(250)

        let simulator = NSSplitViewItem(viewController: simulatorPane)
        simulator.minimumThickness = 0
        simulator.canCollapse = true
        simulator.holdingPriority = NSLayoutConstraint.Priority(400)

        let browser = NSSplitViewItem(viewController: browserPane)
        browser.minimumThickness = LayoutPlan.minBrowser
        browser.holdingPriority = NSLayoutConstraint.Priority(300)

        addSplitViewItem(terminal)
        addSplitViewItem(simulator)
        addSplitViewItem(browser)

        animator.onFrame = { [weak self] positions in self?.setDividerPositions(positions) }
        animator.onSettle = { [weak self] in self?.animationDidSettle() }

        simulatorPane.onPreferredWidthChange = { [weak self] width in
            self?.simulatorPreferredWidthChanged(width)
        }
        simulatorPane.runInTerminal = { [weak self] command in
            guard let self else { return }
            terminalPane.runCommandInNewTab(command)
            view.window?.makeKeyAndOrderFront(nil)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasAppliedInitialLayout else { return }
        hasAppliedInitialLayout = true
        mode = session.state.layout
        apply(mode: mode, animated: false)
        simulatorPane.start()
    }

    // MARK: - Modes

    @objc func toggleBuildMode(_ sender: Any?) {
        apply(mode: mode == .build ? .balanced : .build, animated: true)
    }

    @objc func toggleWatchMode(_ sender: Any?) {
        apply(mode: mode == .watch ? .balanced : .watch, animated: true)
    }

    @objc func balancedMode(_ sender: Any?) {
        apply(mode: .balanced, animated: true)
    }

    func apply(mode newMode: LayoutMode, animated: Bool) {
        if mode == .balanced, newMode != .balanced {
            captureManualWidths()
        }
        mode = newMode
        session.update { $0.layout = newMode }
        Log.layout.info("layout mode → \(newMode.rawValue, privacy: .public)")

        let target = targetWidths()
        let positions = dividerPositions(for: target)
        Log.layout.debug("apply \(newMode.rawValue, privacy: .public): terminal \(Int(target.terminal)) sim \(Int(target.simulator)) browser \(Int(target.browser)) from \(self.currentPositions().map { Int($0) }, privacy: .public)")

        if target.simulator > 0, simulatorItem.isCollapsed {
            simulatorItem.isCollapsed = false
            setDividerPositions([currentPositions()[0], currentPositions()[0] + splitView.dividerThickness])
        }
        simulatorPane.setVisible(target.simulator > 0)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated, !reduceMotion {
            animator.animate(from: currentPositions(), to: positions)
        } else {
            animator.cancel()
            setDividerPositions(positions)
            animationDidSettle()
        }
    }

    private func targetWidths() -> ColumnWidths {
        let available = splitView.bounds.width - splitView.dividerThickness * 2
        return LayoutPlan.widths(mode: mode, available: available, simulatorWidth: simulatorWidth, manual: manualWidths)
    }

    private func dividerPositions(for widths: ColumnWidths) -> [Double] {
        let first = Double(widths.terminal)
        let second = first + Double(splitView.dividerThickness) + Double(widths.simulator)
        return [first, second]
    }

    private func currentPositions() -> [Double] {
        let terminal = terminalItem.viewController.view.frame
        let simulator = simulatorItem.viewController.view.frame
        let first = Double(terminal.maxX)
        let second = simulatorItem.isCollapsed ? first : Double(simulator.maxX)
        return [first, second]
    }

    /// The simulator item holds its size harder than the terminal, so a plain `setPosition` on the first
    /// divider gets absorbed by the terminal. Pinning the simulator's thickness while positioning makes the
    /// split view honour both dividers; `animationDidSettle` releases the pin.
    private func setDividerPositions(_ positions: [Double]) {
        guard positions.count == 2 else { return }
        isSettingPositions = true
        let simulatorWidth = max(0, CGFloat(positions[1] - positions[0]) - splitView.dividerThickness)
        simulatorItem.minimumThickness = simulatorWidth
        simulatorItem.maximumThickness = simulatorWidth
        splitView.setPosition(CGFloat(positions[1]), ofDividerAt: 1)
        splitView.setPosition(CGFloat(positions[0]), ofDividerAt: 0)
        isSettingPositions = false
    }

    private func animationDidSettle() {
        let widths = targetWidths()
        let actual = splitViewItems.map { Int($0.viewController.view.frame.width) }
        Log.layout.debug("settled: actual \(actual, privacy: .public) target \(Int(widths.terminal))/\(Int(widths.simulator))/\(Int(widths.browser))")
        if widths.simulator == 0, !simulatorItem.isCollapsed {
            simulatorItem.isCollapsed = true
        }
        simulatorItem.minimumThickness = widths.simulator > 0 ? LayoutPlan.minSimulator : 0
        simulatorItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
    }

    private func captureManualWidths() {
        let widths = ColumnWidths(
            terminal: terminalItem.viewController.view.frame.width,
            simulator: simulatorItem.isCollapsed ? 0 : simulatorItem.viewController.view.frame.width,
            browser: browserItem.viewController.view.frame.width
        )
        manualWidths = widths
        session.update { $0.columnWidths = widths }
    }

    private func simulatorPreferredWidthChanged(_ width: CGFloat) {
        guard abs(width - simulatorWidth) > 0.5 else { return }
        simulatorWidth = width
        Log.layout.debug("simulator width → \(Int(width)) initial=\(self.hasAppliedInitialLayout) mode=\(self.mode.rawValue, privacy: .public)")
        guard hasAppliedInitialLayout else { return }
        if mode == .watch { return }
        simulatorItem.minimumThickness = 0
        apply(mode: mode, animated: true)
    }

    // MARK: - NSSplitViewDelegate

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard !isSettingPositions, !animator.isAnimating, hasAppliedInitialLayout else { return }
        if mode == .balanced {
            captureManualWidths()
        }
    }

    // MARK: - Focus

    @objc func focusTerminal(_ sender: Any?) {
        view.window?.makeKeyAndOrderFront(nil)
        terminalPane.focusCurrentTerminal()
    }

    @objc func focusSimulator(_ sender: Any?) {
        view.window?.makeKeyAndOrderFront(nil)
        simulatorPane.focus()
    }

    @objc func focusBrowser(_ sender: Any?) {
        view.window?.makeKeyAndOrderFront(nil)
        browserPane.focusWebView()
    }

    func windowDidBecomeKey() {
        if view.window?.firstResponder === view.window {
            terminalPane.focusCurrentTerminal()
        }
    }

    func prepareForTermination() {
        if mode == .balanced { captureManualWidths() }
        terminalPane.persistTabs()
        browserPane.prepareForTermination()
        simulatorPane.prepareForTermination()
        session.saveNow()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleBuildMode(_:)):
            menuItem.state = mode == .build ? .on : .off
        case #selector(toggleWatchMode(_:)):
            menuItem.state = mode == .watch ? .on : .off
        case #selector(balancedMode(_:)):
            menuItem.state = mode == .balanced ? .on : .off
        default:
            break
        }
        return true
    }
}
