import AppKit
import os

/// Which columns are showing, for the activity bar.
@Observable
final class PaneVisibility {
    var terminal = true
    var editor = true
}

/// Two columns: the terminal and the tabbed editor area (browser tabs, simulator, diff). Owns the
/// layout modes and the spring that moves the divider between them. A column whose last tab closed
/// collapses, and comes back from the activity bar.
final class WorkspaceSplitViewController: NSSplitViewController, NSMenuItemValidation {
    let session: ProjectSession
    let terminalPane: TerminalPaneViewController
    let editor: EditorAreaViewController
    var simulatorPane: SimulatorPaneViewController { editor.simulatorPane }
    var browserPane: BrowserPaneViewController { editor.browserPane }
    let panes = PaneVisibility()

    private(set) var mode: LayoutMode = .balanced
    private var manualWidths: ColumnWidths?
    private var editorPreferredWidth: CGFloat = 0
    private var isSettingPosition = false
    private var lastLayoutWidth: CGFloat = 0
    private var hasAppliedInitialLayout = false
    private lazy var animator = SpringAnimator(view: splitView)

    private var terminalItem: NSSplitViewItem!
    private var editorItem: NSSplitViewItem!

    init(session: ProjectSession, sourceControl: SourceControlModel, skills: SkillsModel) {
        self.session = session
        terminalPane = TerminalPaneViewController(session: session)
        editor = EditorAreaViewController(session: session, sourceControl: sourceControl, skills: skills)
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
        view.frame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        terminalItem = NSSplitViewItem(viewController: terminalPane)
        terminalItem.minimumThickness = LayoutPlan.minTerminal
        terminalItem.holdingPriority = NSLayoutConstraint.Priority(250)

        editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = LayoutPlan.minEditor
        editorItem.holdingPriority = NSLayoutConstraint.Priority(300)

        addSplitViewItem(terminalItem)
        addSplitViewItem(editorItem)

        animator.onFrame = { [weak self] positions in self?.setDividerPosition(positions[0]) }
        animator.onSettle = { [weak self] in self?.captureManualWidthsIfBalanced() }

        editor.onPreferredWidthChange = { [weak self] width in self?.editorPreferredWidthChanged(width) }
        simulatorPane.runInTerminal = { [weak self] command in
            guard let self else { return }
            terminalPane.runCommandInNewTab(command)
            view.window?.makeKeyAndOrderFront(nil)
        }
        terminalPane.emptyActions = PaneEmptyActions(
            terminal: { [weak self] in self?.focusTerminal(nil) },
            simulator: { [weak self] in self?.focusSimulator(nil) },
            browser: { [weak self] in self?.focusBrowser(nil) }
        )
        terminalPane.onTabsChange = { [weak self] in self?.updatePanes() }
        editor.onTabsChange = { [weak self] in self?.updatePanes() }
    }

    // MARK: - Closing and reopening columns

    /// A column with no tabs closes. When both are empty the terminal column stays, showing a
    /// "Nothing open" state, so the window is never blank. Closing removes the column's split item
    /// (it has nothing left to keep alive), which takes effect at once, unlike collapsing.
    private func updatePanes() {
        guard isViewLoaded, terminalItem != nil else { return }
        let editorEmpty = editor.tabs.isEmpty
        let terminalEmpty = terminalPane.isEmpty && terminalPane.hasLoadedTabs
        let showTerminal = !terminalEmpty || editorEmpty
        let showEditor = !editorEmpty
        let reopening = (showTerminal && !isShowing(terminalItem)) || (showEditor && !isShowing(editorItem))
        guard showTerminal != isShowing(terminalItem) || showEditor != isShowing(editorItem) else {
            syncPanes()
            return
        }
        animator.cancel()
        if showTerminal, !isShowing(terminalItem) { insertSplitViewItem(terminalItem, at: 0) }
        if showEditor, !isShowing(editorItem) { addSplitViewItem(editorItem) }
        if !showTerminal, isShowing(terminalItem) { removeSplitViewItem(terminalItem) }
        if !showEditor, isShowing(editorItem) { removeSplitViewItem(editorItem) }
        view.layoutSubtreeIfNeeded()
        syncPanes()
        // Keystrokes follow whichever column is still showing.
        if !showEditor { terminalPane.focusCurrentTerminal() } else if !showTerminal { editor.focusSelected() }
        // Both columns are back: put the divider where the layout mode wants it.
        if reopening, isBothShowing {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                apply(mode: mode, animated: false)
            }
        }
    }

    private func isShowing(_ item: NSSplitViewItem) -> Bool { splitViewItems.contains(item) }

    private func syncPanes() {
        let terminal = isShowing(terminalItem) && !terminalPane.isEmpty
        let editor = isShowing(editorItem)
        if panes.terminal != terminal { panes.terminal = terminal }
        if panes.editor != editor { panes.editor = editor }
    }

    private var isBothShowing: Bool { splitViewItems.count == 2 }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasAppliedInitialLayout else { return }
        hasAppliedInitialLayout = true
        mode = session.state.layout
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            apply(mode: mode, animated: false)
        }
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
        if mode == .balanced, newMode != .balanced, hasAppliedInitialLayout {
            captureManualWidths()
        }
        mode = newMode
        session.update { $0.layout = newMode }
        Log.layout.info("layout mode → \(newMode.rawValue, privacy: .public)")
        // Watch is for the browser (Netflix); Build is for the app being built.
        switch newMode {
        case .watch: editor.showBrowser()
        case .build: if editor.isSimulatorOpen { editor.select(.simulator) }
        case .balanced: break
        }

        // With one column closed there is no divider to place.
        guard isBothShowing else { return }
        let target = Double(LayoutPlan.widths(mode: newMode, available: available, editorPreferred: editorPreferredWidth, manual: manualWidths).terminal)
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            animator.animate(from: [currentPosition], to: [target])
        } else {
            animator.cancel()
            setDividerPosition(target)
        }
    }

    private var available: CGFloat { splitView.bounds.width - splitView.dividerThickness }
    private var currentPosition: Double { Double(terminalItem.viewController.view.frame.width) }

    private func setDividerPosition(_ position: Double) {
        isSettingPosition = true
        splitView.setPosition(CGFloat(position), ofDividerAt: 0)
        isSettingPosition = false
    }

    private func captureManualWidths() {
        guard isBothShowing else { return }
        let widths = ColumnWidths(terminal: terminalItem.viewController.view.frame.width, editor: editorItem.viewController.view.frame.width)
        guard widths.total > 0 else { return }
        manualWidths = widths
        session.update { $0.columnWidths = widths }
    }

    private func captureManualWidthsIfBalanced() {
        if mode == .balanced { captureManualWidths() }
    }

    private func editorPreferredWidthChanged(_ width: CGFloat) {
        guard abs(width - editorPreferredWidth) > 0.5 else { return }
        editorPreferredWidth = width
        if hasAppliedInitialLayout, mode == .build { apply(mode: .build, animated: true) }
    }

    // MARK: - Resizing

    /// When the window (or the sidebar) changes the width, re-apply the mode so Balanced keeps the
    /// user's ratio, rather than letting the lower holding priority hand every point to the terminal.
    override func viewDidLayout() {
        super.viewDidLayout()
        let width = splitView.bounds.width
        defer { lastLayoutWidth = width }
        guard hasAppliedInitialLayout, lastLayoutWidth > 0, abs(width - lastLayoutWidth) > 0.5, !animator.isAnimating else { return }
        // Positioning inside the split view's own layout pass gets overridden; do it right after.
        DispatchQueue.main.async { [weak self] in
            guard let self, !animator.isAnimating, isBothShowing else { return }
            let target = LayoutPlan.widths(mode: mode, available: available, editorPreferred: editorPreferredWidth, manual: manualWidths).terminal
            setDividerPosition(Double(target))
        }
    }

    // MARK: - NSSplitViewDelegate

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        // Only the user dragging the divider (mouse down, same overall width) changes the
        // remembered ratio; layout passes that squeeze a column for a moment must not.
        guard !isSettingPosition, !animator.isAnimating, hasAppliedInitialLayout, isBothShowing,
              NSEvent.pressedMouseButtons & 1 == 1,
              abs(splitView.bounds.width - lastLayoutWidth) <= 0.5 else { return }
        captureManualWidthsIfBalanced()
    }

    // MARK: - Focus

    @objc func focusTerminal(_ sender: Any?) {
        view.window?.makeKeyAndOrderFront(nil)
        // Opens a shell when every tab was closed; the column expands through onTabsChange.
        terminalPane.reopen()
    }

    @objc func focusSimulator(_ sender: Any?) {
        view.window?.makeKeyAndOrderFront(nil)
        editor.openSimulator(select: true)
        simulatorPane.focus()
    }

    @objc func focusBrowser(_ sender: Any?) {
        view.window?.makeKeyAndOrderFront(nil)
        editor.showBrowser()
        // A freshly opened tab joins the window on the next pass.
        DispatchQueue.main.async { [weak self] in self?.browserPane.focusWebView() }
    }

    func windowDidBecomeKey() {
        if view.window?.firstResponder === view.window {
            terminalPane.focusCurrentTerminal()
        }
    }

    func prepareForTermination() {
        captureManualWidthsIfBalanced()
        terminalPane.persistTabs()
        editor.prepareForTermination()
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
