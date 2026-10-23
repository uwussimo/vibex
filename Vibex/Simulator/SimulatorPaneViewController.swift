import AppKit
import IOSurface
import os
import SwiftUI

/// The simulator column: a header with device controls above the device's live screen, rendered
/// straight from CoreSimulator's framebuffer. No Simulator.app window is involved.
final class SimulatorPaneViewController: NSViewController, NSMenuItemValidation {
    enum DisplayState: Equatable {
        case noDevices
        case shutdown
        case connecting
        case live
        case failed(String)
    }

    let model = SimulatorModel()
    let session: ProjectSession
    /// Screenshots kept for before/after comparisons.
    let snapshots: SnapshotHistory
    /// Opens the Compare tab.
    var openCompare: () -> Void = {}
    /// Opens the Devices tab.
    var openDevices: () -> Void = {}

    var onPreferredWidthChange: (CGFloat) -> Void = { _ in }
    /// Runs a shell command in a new terminal tab (used to install simslim in plain sight).
    var runInTerminal: (String) -> Void = { _ in }

    private(set) var displayState: DisplayState = .noDevices
    private let displayView = SimulatorDisplayView(frame: .zero)
    private var emptyStateHost: NSHostingView<SimulatorEmptyState>?
    private var framebuffer: SimulatorFramebuffer?
    private var input: SimulatorInput?
    private var attachedUDID: String?
    private(set) var attachedDevice: CoreSimulatorBridge.Device?

    /// For automation: the live surface and input channel, when attached.
    var automationSurface: IOSurface? { framebuffer?.surface }
    var automationInput: SimulatorInput? { input }
    private var attachRetry: DispatchWorkItem?
    private var stateTimer: Timer?
    private var lastPreferredWidth: CGFloat = 0
    private var hasStarted = false

    static let gutter: CGFloat = 8

    init(session: ProjectSession) {
        self.session = session
        snapshots = SnapshotHistory(projectID: session.project.id)
        super.init(nibName: nil, bundle: nil)
        model.selectedUDID = session.state.deviceUDID
        model.onSelectionChange = { [weak session] udid in session?.update { $0.deviceUDID = udid } }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        let actions = SimulatorHeaderActions(
            boot: { [weak self] in self?.boot() },
            shutdown: { [weak self] in self?.shutdown() },
            screenshot: { [weak self] in self?.screenshot() },
            home: { [weak self] in self?.input?.press(.home) },
            lock: { [weak self] in self?.input?.press(.lock) },
            toggleSlim: { [weak self] in self?.toggleSlim() },
            installSimslim: { [weak self] in self?.installSimslim(nil) },
            compare: { [weak self] in self?.openCompare() },
            devices: { [weak self] in self?.openDevices() }
        )
        let header = NSHostingView(rootView: SimulatorHeader(model: model, snapshots: snapshots, isLive: { [weak self] in self?.displayState == .live }, actions: actions))
        header.sizingOptions = []
        header.translatesAutoresizingMaskIntoConstraints = false
        displayView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(displayView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
            displayView.topAnchor.constraint(equalTo: header.bottomAnchor),
            displayView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            displayView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            displayView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateEmptyState()
        startObservingModel()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        start()
    }

    /// Idempotent. Called by the workspace too, because a collapsed column never "appears".
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        Task { await model.refresh(); reconcile() }
        let timer = Timer(timeInterval: 3, target: self, selector: #selector(pollDeviceState), userInfo: nil, repeats: true)
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        stateTimer = timer
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        reportPreferredWidth()
    }

    func setVisible(_ visible: Bool) {
        displayView.isPaused = !visible
    }

    func focus() {
        view.window?.makeFirstResponder(displayView)
    }

    func prepareForTermination() {
        detach()
    }

    // MARK: - Attaching to the device

    /// Attach to the selected device when it is booted, detach when it is not.
    private func reconcile() {
        guard let device = model.selectedDevice else {
            detach()
            set(state: .noDevices)
            return
        }
        if device.isBooted {
            if attachedUDID != device.udid { attach(udid: device.udid) }
        } else {
            detach()
            set(state: .shutdown)
        }
    }

    private func attach(udid: String) {
        detach()
        attachedUDID = udid
        set(state: .connecting)
        tryAttach()
    }

    private func tryAttach() {
        attachRetry?.cancel()
        guard let udid = attachedUDID else { return }
        do {
            let bridge = try CoreSimulatorBridge.shared()
            let device = try bridge.device(udid: udid)
            guard device.isBooted else {
                set(state: .connecting)
                scheduleAttachRetry()
                return
            }
            let renderable = try bridge.mainDisplay(of: device)
            let framebuffer = SimulatorFramebuffer(renderable: renderable)
            guard framebuffer.surface != nil else {
                // Display exists but has not rendered yet; the surface callback will not retrigger us, so retry.
                framebuffer.stop()
                scheduleAttachRetry()
                return
            }
            let input = try SimulatorInput(bridge: bridge, device: device)
            self.framebuffer = framebuffer
            self.input = input
            attachedDevice = device
            displayView.input = input
            displayView.screenSize = device.screenSize
            displayView.setSurface(framebuffer.surface)
            framebuffer.onSurfaceChange = { [weak self] surface in self?.displayView.setSurface(surface) }
            framebuffer.onFrame = { [weak self] in self?.displayView.frameDidRender() }
            set(state: .live)
            reportPreferredWidth()
            Log.simulator.info("attached to \(device.name, privacy: .public) \(Int(device.screenSize.width))x\(Int(device.screenSize.height))")
        } catch CoreSimulatorError.noMainDisplay {
            set(state: .connecting)
            scheduleAttachRetry()
        } catch {
            set(state: .failed(error.localizedDescription))
            Log.simulator.error("attach failed: \(error.localizedDescription, privacy: .public)")
            scheduleAttachRetry(after: 3)
        }
    }

    private func scheduleAttachRetry(after seconds: Double = 1) {
        let work = DispatchWorkItem { [weak self] in self?.tryAttach() }
        attachRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func detach() {
        attachRetry?.cancel()
        attachRetry = nil
        framebuffer?.stop()
        framebuffer = nil
        input = nil
        displayView.input = nil
        displayView.setSurface(nil)
        attachedUDID = nil
        attachedDevice = nil
    }

    @objc private func pollDeviceState() {
        guard let udid = attachedUDID, displayState == .live else { return }
        if let device = try? CoreSimulatorBridge.shared().device(udid: udid), !device.isBooted {
            Log.simulator.info("device shut down; detaching")
            detach()
            set(state: .shutdown)
            Task { await model.refresh(); reconcile() }
        }
    }

    private func set(state: DisplayState) {
        guard state != displayState else { return }
        displayState = state
        updateEmptyState()
    }

    private func reportPreferredWidth() {
        let height = displayView.bounds.height - 16
        let width = displayState == .live
            ? SimulatorDisplayGeometry.preferredWidth(screen: displayView.screenSize, height: height, gutter: Self.gutter, minimum: 280)
            : 0 // no preference until a device is showing
        guard abs(width - lastPreferredWidth) > 1 else { return }
        lastPreferredWidth = width
        Log.layout.debug("simulator pane prefers width \(Int(width)) (height \(Int(height)), state \(String(describing: self.displayState), privacy: .public))")
        onPreferredWidthChange(width)
    }

    // MARK: - Observation

    private func startObservingModel() {
        withObservationTracking {
            _ = model.devices
            _ = model.selectedUDID
            _ = model.isBusy
            _ = model.activity
            _ = model.errorMessage
            _ = model.isSlimPreferred
            _ = model.isSimslimInstalled
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.reconcile()
                self?.updateEmptyState()
                self?.startObservingModel()
            }
        }
    }

    // MARK: - Empty state

    private func updateEmptyState() {
        emptyStateHost?.removeFromSuperview()
        emptyStateHost = nil
        guard displayState != .live else { return }
        let content = SimulatorEmptyState(
            state: displayState,
            deviceName: model.selectedDevice?.name,
            isBusy: model.isBusy,
            activity: model.activity,
            willBootSlim: model.willBootSlim,
            errorMessage: model.errorMessage
        ) { [weak self] in
            self?.emptyStatePrimaryAction()
        }
        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        displayView.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: displayView.centerXAnchor),
            host.centerYAnchor.constraint(equalTo: displayView.centerYAnchor),
            host.widthAnchor.constraint(lessThanOrEqualTo: displayView.widthAnchor, constant: -16),
        ])
        emptyStateHost = host
    }

    private func emptyStatePrimaryAction() {
        switch displayState {
        case .noDevices:
            Task { await model.createDefaultDevice(); reconcile() }
        case .shutdown:
            boot()
        case .connecting, .live:
            break
        case .failed:
            if let udid = attachedUDID { attach(udid: udid) } else { reconcile() }
        }
    }

    // MARK: - Actions

    private func boot() {
        Task {
            await model.bootSelected()
            reconcile()
        }
    }

    private func shutdown() {
        Task {
            await model.shutdownSelected()
            reconcile()
        }
    }

    /// Copies the screen and keeps it in the history for Compare.
    private func screenshot() {
        Task {
            guard let png = await model.copyScreenshot() else { return }
            snapshots.add(png: png, label: "Screenshot", device: model.bootedDevice?.name ?? "Simulator")
        }
    }

    /// For Run and `simulator_snapshot`: saves the current screen with a label, without copying it.
    @discardableResult
    func captureSnapshot(label: String) async -> SnapshotHistory.Snapshot? {
        guard let png = await model.screenshotPNG() else { return nil }
        return snapshots.add(png: png, label: label, device: model.bootedDevice?.name ?? "Simulator")
    }

    private func toggleSlim() {
        Task {
            await model.toggleSlimSelected()
            reconcile()
        }
    }

    @objc func bootDevice(_ sender: Any?) { boot() }
    @objc func shutdownDevice(_ sender: Any?) { shutdown() }
    @objc func copyScreenshot(_ sender: Any?) { screenshot() }
    @objc func pressHome(_ sender: Any?) { input?.press(.home) }
    @objc func pressLock(_ sender: Any?) { input?.press(.lock) }

    @objc func toggleSlimPreference(_ sender: Any?) {
        model.isSlimPreferred.toggle()
        updateEmptyState()
    }

    @objc func toggleSlimNow(_ sender: Any?) { toggleSlim() }

    @objc func installSimslim(_ sender: Any?) {
        runInTerminal(Simslim.installCommand)
        Task {
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(5))
                if Simslim.isInstalled {
                    await model.refresh()
                    return
                }
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(bootDevice(_:)): return !(model.selectedDevice?.isBooted ?? true) && !model.isBusy
        case #selector(shutdownDevice(_:)): return (model.selectedDevice?.isBooted ?? false) && !model.isBusy
        case #selector(copyScreenshot(_:)): return model.bootedDevice != nil && !model.isBusy
        case #selector(pressHome(_:)), #selector(pressLock(_:)): return displayState == .live
        case #selector(toggleSlimPreference(_:)):
            menuItem.state = model.isSlimPreferred ? .on : .off
            return model.isSimslimInstalled
        case #selector(toggleSlimNow(_:)):
            let isSlim = model.selectedSlimInfo?.isSlim ?? false
            menuItem.title = isSlim ? "Restore Stock Simulator" : "Slim Simulator Now"
            return model.isSimslimInstalled && model.selectedDevice != nil && !model.isBusy
        case #selector(installSimslim(_:)): return !model.isSimslimInstalled
        default: return true
        }
    }
}
