import AppKit
import SwiftUI

/// One project window: terminal | simulator | browser for a single folder.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let session: ProjectSession
    let workspace: WorkspaceSplitViewController
    let toast = ToastModel()
    let sourceControl: SourceControlModel
    private let columns = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem { columns.splitViewItems[0] }
    private var diffHost: NSView?
    /// Per-window automation state (element refs survive between tool calls).
    private(set) lazy var simulatorAutomation = SimulatorAutomation(pane: workspace.simulatorPane)
    private(set) lazy var browserAutomation = BrowserAutomation(pane: workspace.browserPane)
    private(set) lazy var runner = Runner(window: self)

    var project: Project { session.project }
    var onClose: (MainWindowController) -> Void = { _ in }
    var onBecomeKey: (MainWindowController) -> Void = { _ in }

    init(session: ProjectSession) {
        self.session = session
        workspace = WorkspaceSplitViewController(session: session)
        sourceControl = SourceControlModel(folder: session.project.url)
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
        // A plain container holds the split views, so overlays (toast, palette, diff) float above
        // them instead of becoming extra split panes. The Source Control sidebar wraps the workspace
        // rather than joining its three spring-driven columns.
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
        NSLayoutConstraint.activate([
            columns.view.topAnchor.constraint(equalTo: root.view.topAnchor),
            columns.view.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
            columns.view.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
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
        installTitlebarAccessory(SourceControlButton(model: sourceControl) { [weak self] in
            self?.toggleSourceControl(nil)
        }, width: 150)
        sourceControl.isSidebarVisible = !sidebar.isCollapsed
        sourceControl.start()
        observeDiffSelection()
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

    /// Shows the diff over the simulator and browser while a file is selected.
    private func observeDiffSelection() {
        Task { [weak self] in
            guard let model = self?.sourceControl else { return }
            for await selected in Observations({ model.selection != nil }) {
                self?.setDiffVisible(selected)
            }
        }
    }

    private func setDiffVisible(_ visible: Bool) {
        guard let contentView = window?.contentView else { return }
        if visible, diffHost == nil {
            let host = NSHostingView(rootView: DiffView(model: sourceControl) { [weak self] in
                self?.sourceControl.select(nil)
            })
            host.translatesAutoresizingMaskIntoConstraints = false
            host.wantsLayer = true
            host.shadow = {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
                shadow.shadowBlurRadius = 18
                shadow.shadowOffset = NSSize(width: -2, height: 0)
                return shadow
            }()
            contentView.addSubview(host, positioned: .below, relativeTo: toastHost)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: contentView.topAnchor),
                host.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                host.leadingAnchor.constraint(equalTo: workspace.terminalPane.view.trailingAnchor),
                host.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
            diffHost = host
            contentView.layoutSubtreeIfNeeded()
            Self.slide(host, in: true)
        } else if !visible, let host = diffHost {
            diffHost = nil
            Self.slide(host, in: false) { host.removeFromSuperview() }
        }
    }

    /// Enters and leaves along the same path: from and back to the right edge, critically damped.
    private static func slide(_ view: NSView, in entering: Bool, completion: (() -> Void)? = nil) {
        guard let layer = view.layer else { completion?(); return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = entering ? 0 : 1
        fade.toValue = entering ? 1 : 0
        fade.duration = entering ? 0.18 : 0.14
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "fade")
        if !reduceMotion {
            let slide = CASpringAnimation(keyPath: "transform.translation.x")
            slide.fromValue = entering ? 48 : 0
            slide.toValue = entering ? 0 : 48
            // Response 0.35 s, damping ratio 1 (Apple's default for UI that wasn't flicked).
            slide.mass = 1
            slide.stiffness = pow(2 * .pi / 0.35, 2)
            slide.damping = 2 * sqrt(slide.stiffness)
            slide.duration = entering ? slide.settlingDuration : 0.16
            slide.fillMode = .forwards
            slide.isRemovedOnCompletion = false
            layer.add(slide, forKey: "slide")
        }
        CATransaction.commit()
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

    private weak var toastHost: NSView?

    private func installToastOverlay() {
        guard let contentView = window?.contentView else { return }
        let host = NSHostingView(rootView: ToastView(model: toast))
        toastHost = host
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
