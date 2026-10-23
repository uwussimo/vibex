import AppKit
import SwiftUI

/// One project window for a single folder, laid out like VS Code: activity bar | Source Control
/// sidebar | terminal | tabbed editor area (browser tabs, simulator, diff).
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let session: ProjectSession
    let workspace: WorkspaceSplitViewController
    let toast = ToastModel()
    let sourceControl: SourceControlModel
    private let columns = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem { columns.splitViewItems[0] }
    /// Per-window automation state (element refs survive between tool calls).
    private(set) lazy var simulatorAutomation = SimulatorAutomation(pane: workspace.simulatorPane)
    private(set) lazy var browserAutomation = BrowserAutomation(pane: workspace.browserPane)
    private(set) lazy var runner = Runner(window: self)

    var project: Project { session.project }
    var onClose: (MainWindowController) -> Void = { _ in }
    var onBecomeKey: (MainWindowController) -> Void = { _ in }

    init(session: ProjectSession) {
        self.session = session
        sourceControl = SourceControlModel(folder: session.project.url)
        workspace = WorkspaceSplitViewController(session: session, sourceControl: sourceControl)
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
        window.backgroundColor = .windowBackgroundColor
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
        let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: SourceControlSidebar(
            model: sourceControl,
            window: { [weak window] in window }
        )))
        sidebar.minimumThickness = 240
        sidebar.maximumThickness = 440
        sidebar.canCollapse = true
        sidebar.isCollapsed = session.state.sourceControlVisible != true
        sidebar.holdingPriority = NSLayoutConstraint.Priority(260)
        columns.splitView.autosaveName = "Vibex.SourceControl.\(session.project.id)"
        columns.addSplitViewItem(sidebar)
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
        installTitlebarAccessory(RunButton(runner: runner), width: 220)
        installActivityBar(in: activityBar)
        sourceControl.isSidebarVisible = !sidebar.isCollapsed
        sourceControl.start()
    }

    private func installActivityBar(in container: NSView) {
        let bar = NSHostingView(rootView: ActivityBar(
            sourceControl: sourceControl,
            tabs: workspace.editor.tabs,
            simulator: workspace.simulatorPane.model,
            runner: runner,
            actions: ActivityBarActions(
                toggleSourceControl: { [weak self] in self?.toggleSourceControl(nil) },
                showBrowser: { [weak self] in self?.workspace.focusBrowser(nil) },
                showSimulator: { [weak self] in self?.workspace.focusSimulator(nil) },
                toggleRun: { [weak self] in
                    guard let runner = self?.runner else { return }
                    runner.phase.isActive ? runner.stop() : runner.run()
                },
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

    // MARK: - Source Control

    private(set) var isSourceControlVisible: Bool {
        get { !sidebarItem.isCollapsed }
        set {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.28
                context.allowsImplicitAnimation = true
                sidebarItem.animator().isCollapsed = !newValue
            }
            session.update { $0.sourceControlVisible = newValue }
            sourceControl.isSidebarVisible = newValue
        }
    }

    @objc func toggleSourceControl(_ sender: Any?) {
        isSourceControlVisible.toggle()
        if !isSourceControlVisible { sourceControl.select(nil) }
    }

    // MARK: - Command palette

    private var paletteHost: NSView?
    private weak var responderBeforePalette: NSResponder?

    @objc func showCommandPalette(_ sender: Any?) {
        if paletteHost != nil { closePalette(); return }
        guard let window, let contentView = window.contentView else { return }
        responderBeforePalette = window.firstResponder
        let items = CommandCatalog.items(for: self)
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

    // MARK: - Run (responder chain)

    @objc func runProject(_ sender: Any?) { runner.run() }
    @objc func stopProject(_ sender: Any?) { runner.stop() }

    /// Opens `.vibex.json`, creating it from what was detected (or a template) first.
    @objc func editRunConfiguration(_ sender: Any?) {
        let file = project.url.appendingPathComponent(RunConfig.fileName)
        if !FileManager.default.fileExists(atPath: file.path) {
            let config = RunDetector.detect(in: project.url) ?? RunConfig(kind: .command, command: "echo 'set run.command in .vibex.json'")
            do {
                try config.write(to: project.url)
            } catch {
                toast.show(title: "Could not write \(RunConfig.fileName)", message: error.localizedDescription)
                return
            }
        }
        NSWorkspace.shared.open(file)
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
            host.widthAnchor.constraint(equalToConstant: 400),
            host.heightAnchor.constraint(equalToConstant: 140),
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
