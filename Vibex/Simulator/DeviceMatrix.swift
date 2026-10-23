import AppKit
import Observation
import os
import SwiftUI

/// Which simulators the Devices tab shows, per project, and the actions across all of them.
@Observable
final class DeviceMatrixModel {
    private(set) var devices: [SimDevice] = []
    private(set) var selected: [String]
    private(set) var busy: String?
    var problem: String?

    private let session: ProjectSession
    private let simctl = Simctl()

    init(session: ProjectSession) {
        self.session = session
        selected = session.state.matrixDevices ?? []
    }

    var shown: [SimDevice] { selected.compactMap { udid in devices.first { $0.udid == udid } } }
    var available: [SimDevice] { devices.filter { !selected.contains($0.udid) } }

    func refresh() async {
        devices = (try? await simctl.listDevices()) ?? []
        // Devices deleted in Xcode drop out.
        let known = Set(devices.map(\.udid))
        if selected.contains(where: { !known.contains($0) }), !devices.isEmpty { save(selected.filter(known.contains)) }
    }

    /// One small phone, one large phone and an iPad, from the newest runtime that has them.
    var presets: [SimDevice] { Self.presets(from: devices) }

    /// `devices` come newest runtime first, as Simctl lists them.
    static func presets(from devices: [SimDevice]) -> [SimDevice] {
        let phones = devices.filter { $0.name.hasPrefix("iPhone") }
        let small = phones.first { $0.name.contains("SE") || $0.name.hasSuffix("e") || $0.name.contains("mini") } ?? phones.last
        let large = phones.first { $0.name.contains("Pro Max") || $0.name.contains("Plus") } ?? phones.first
        let pad = devices.first { $0.name.hasPrefix("iPad") }
        return [small, large, pad].compactMap { $0 }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    func add(_ device: SimDevice) async {
        guard !selected.contains(device.udid) else { return }
        save(selected + [device.udid])
        await boot(device)
    }

    func addPresets() async {
        for device in presets where !selected.contains(device.udid) { await add(device) }
    }

    func remove(_ udid: String) {
        save(selected.filter { $0 != udid })
    }

    func shutdown(_ udid: String) async {
        try? await simctl.shutdown(udid)
        await refresh()
    }

    private func boot(_ device: SimDevice) async {
        guard !device.isBooted else { return }
        busy = "Booting \(device.name)…"
        defer { busy = nil }
        do {
            try await simctl.boot(device.udid)
        } catch {
            problem = error.localizedDescription
        }
        await refresh()
    }

    /// Installs and launches the app the last iOS run built on every device here.
    func runEverywhere(_ launch: Runner.Launch) async {
        busy = "Installing on \(shown.count) devices…"
        problem = nil
        defer { busy = nil }
        for device in shown {
            do {
                if !device.isBooted { try await simctl.boot(device.udid) }
                try await simctl.install(device.udid, appPath: launch.app.path)
                _ = try await simctl.launch(device.udid, bundleID: launch.bundleID, arguments: [])
            } catch {
                problem = "\(device.name): \(error.localizedDescription)"
            }
        }
        await refresh()
    }

    private func save(_ udids: [String]) {
        selected = udids
        session.update { $0.matrixDevices = udids }
    }
}

/// The Devices tab: live screens of several simulators side by side, each touchable.
final class DeviceMatrixViewController: NSViewController {
    let model: DeviceMatrixModel
    let runner: Runner
    private let grid = DeviceGridView()
    private var tiles: [String: DeviceTileView] = [:]

    init(model: DeviceMatrixModel, runner: Runner) {
        self.model = model
        self.runner = runner
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.NS.background.cgColor
        let toolbar = NSHostingView(rootView: DeviceMatrixToolbar(model: model, runner: runner))
        toolbar.sizingOptions = []
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        grid.translatesAutoresizingMaskIntoConstraints = false
        let empty = NSHostingView(rootView: DeviceMatrixEmptyState(model: model))
        empty.sizingOptions = []
        empty.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        root.addSubview(grid)
        root.addSubview(empty)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),
            grid.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            empty.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            empty.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        observe(empty: empty)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await model.refresh() }
    }

    /// Keeps one tile per device in the matrix, and the empty state when there are none.
    private func observe(empty: NSView) {
        withObservationTracking {
            sync(empty: empty)
        } onChange: { [weak self, weak empty] in
            Task { @MainActor in
                guard let self, let empty else { return }
                self.observe(empty: empty)
            }
        }
    }

    private func sync(empty: NSView) {
        let shown = model.shown
        empty.isHidden = !model.selected.isEmpty
        for (udid, tile) in tiles where !shown.contains(where: { $0.udid == udid }) {
            tile.detach()
            tile.removeFromSuperview()
            tiles[udid] = nil
        }
        for device in shown {
            let tile = tiles[device.udid] ?? {
                let tile = DeviceTileView(device: device, model: model)
                tiles[device.udid] = tile
                grid.addSubview(tile)
                return tile
            }()
            tile.update(device)
        }
        grid.order = shown.map(\.udid)
        grid.tiles = tiles
        grid.needsLayout = true
    }

    func prepareForTermination() {
        tiles.values.forEach { $0.detach() }
    }

    /// For `simulator_screenshot_all`: every device in the matrix, side by side in one PNG.
    static func combinedScreenshot(of devices: [SimDevice]) async -> Data? {
        await combinedScreenshot(udids: devices.filter(\.isBooted).map(\.udid))
    }

    @concurrent private static func combinedScreenshot(udids: [String]) async -> Data? {
        var images: [NSImage] = []
        for udid in udids {
            if let data = try? await Simctl().screenshot(udid), let image = NSImage(data: data) { images.append(image) }
        }
        guard !images.isEmpty else { return nil }
        let height: CGFloat = 1400
        let widths = images.map { $0.size.width * height / max($0.size.height, 1) }
        let gap: CGFloat = 60
        let size = NSSize(width: widths.reduce(0, +) + gap * CGFloat(images.count - 1), height: height)
        let combined = NSImage(size: size, flipped: false) { _ in
            NSColor(hex: 0x0C0C0F).setFill()
            NSRect(origin: .zero, size: size).fill()
            var x: CGFloat = 0
            for (index, image) in images.enumerated() {
                image.draw(in: NSRect(x: x, y: 0, width: widths[index], height: height))
                x += widths[index] + gap
            }
            return true
        }
        guard let tiff = combined.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}

/// Lays the tiles out in a row, each as tall as the area allows, scaled down together to fit the width.
final class DeviceGridView: NSView {
    var order: [String] = []
    var tiles: [String: DeviceTileView] = [:]
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let tiles = order.compactMap { self.tiles[$0] }
        guard !tiles.isEmpty else { return }
        let padding: CGFloat = 20, gap: CGFloat = 20, header = DeviceTileView.headerHeight
        let available = NSSize(width: bounds.width - padding * 2, height: bounds.height - padding * 2)
        let screenHeight = max(available.height - header, 100)
        var widths = tiles.map { screenHeight * $0.aspect }
        let total = widths.reduce(0, +) + gap * CGFloat(tiles.count - 1)
        let scale = total > available.width ? available.width / total : 1
        widths = widths.map { $0 * scale }
        let height = screenHeight * scale + header
        var x = padding + max(0, (available.width - (widths.reduce(0, +) + gap * CGFloat(tiles.count - 1))) / 2)
        for (index, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: x, y: padding, width: widths[index], height: height)
            x += widths[index] + gap
        }
    }
}

/// One device: a name row and its live, touchable screen.
final class DeviceTileView: NSView {
    static let headerHeight: CGFloat = 34
    private(set) var device: SimDevice
    private let model: DeviceMatrixModel
    private let display = SimulatorDisplayView(frame: .zero)
    private let header: NSHostingView<DeviceTileHeader>
    private var framebuffer: SimulatorFramebuffer?
    private var input: SimulatorInput?
    private var retry: Task<Void, Never>?
    private(set) var aspect: CGFloat = 1179.0 / 2556.0
    override var isFlipped: Bool { true }

    init(device: SimDevice, model: DeviceMatrixModel) {
        self.device = device
        self.model = model
        header = NSHostingView(rootView: DeviceTileHeader(device: device, model: model))
        super.init(frame: .zero)
        header.sizingOptions = []
        addSubview(header)
        addSubview(display)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
        display.frame = NSRect(x: 0, y: Self.headerHeight, width: bounds.width, height: bounds.height - Self.headerHeight)
    }

    func update(_ device: SimDevice) {
        self.device = device
        header.rootView = DeviceTileHeader(device: device, model: model)
        if device.isBooted { if framebuffer == nil { attach() } } else { detach() }
    }

    /// Like the main simulator pane: waits for the booted device's display, then streams it.
    private func attach() {
        retry?.cancel()
        retry = Task { [weak self] in
            for _ in 0..<60 {
                guard let self, !Task.isCancelled else { return }
                if tryAttach() { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func tryAttach() -> Bool {
        guard let bridge = try? CoreSimulatorBridge.shared(), let device = try? bridge.device(udid: device.udid), device.isBooted,
              let renderable = try? bridge.mainDisplay(of: device) else { return false }
        let framebuffer = SimulatorFramebuffer(renderable: renderable)
        guard framebuffer.surface != nil else { framebuffer.stop(); return false }
        let input = try? SimulatorInput(bridge: bridge, device: device)
        self.framebuffer = framebuffer
        self.input = input
        aspect = device.screenSize.width / max(device.screenSize.height, 1)
        display.input = input
        display.screenSize = device.screenSize
        display.setSurface(framebuffer.surface)
        framebuffer.onSurfaceChange = { [weak self] surface in self?.display.setSurface(surface) }
        framebuffer.onFrame = { [weak self] in self?.display.frameDidRender() }
        superview?.needsLayout = true
        return true
    }

    func detach() {
        retry?.cancel()
        framebuffer?.stop()
        framebuffer = nil
        input = nil
        display.input = nil
        display.setSurface(nil)
    }
}

private struct DeviceTileHeader: View {
    let device: SimDevice
    let model: DeviceMatrixModel

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(device.isBooted ? Theme.green : (device.isTransitioning ? Theme.yellow : Theme.faint)).frame(width: 6, height: 6)
            Text(device.name).font(.vibex(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            Text(device.runtime).font(.vibex(size: 11)).foregroundStyle(Theme.faint).lineLimit(1)
            Spacer(minLength: 2)
            Menu {
                if device.isBooted { Button("Shut Down") { Task { await model.shutdown(device.udid) } } }
                Button("Remove from Devices") { model.remove(device.udid) }
            } label: {
                IconView(.dots, size: 14).foregroundStyle(Theme.muted).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 4)
        .frame(maxHeight: .infinity)
    }
}

private struct DeviceMatrixToolbar: View {
    let model: DeviceMatrixModel
    let runner: Runner

    var body: some View {
        HStack(spacing: 10) {
            Text("Devices").font(.vibex(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            if let busy = model.busy {
                ProgressView().controlSize(.mini)
                Text(busy).font(.vibex(size: 11.5)).foregroundStyle(Theme.muted)
            } else if let problem = model.problem {
                Text(problem).font(.vibex(size: 11.5)).foregroundStyle(Theme.red).lineLimit(1)
            }
            Spacer()
            Menu {
                ForEach(groupedRuntimes, id: \.self) { runtime in
                    Section(runtime) {
                        ForEach(model.available.filter { $0.runtime == runtime }) { device in
                            Button(device.name) { Task { await model.add(device) } }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) { IconView(.plus, size: 13); Text("Add Device") }
                    .font(.vibex(size: 12, weight: .medium))
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(model.available.isEmpty)
            Button {
                guard let launch = runner.lastLaunch else { return }
                Task { await model.runEverywhere(launch) }
            } label: {
                HStack(spacing: 5) { IconView(.play, size: 13); Text("Run on All") }
                    .font(.vibex(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .disabled(runner.lastLaunch == nil || model.shown.isEmpty || model.busy != nil)
            .help(runner.lastLaunch.map { "Install \($0.app.deletingPathExtension().lastPathComponent) on every device here and launch it" }
                ?? "Run the app once (Claude's vibex_run builds it), then install it on every device here")
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var groupedRuntimes: [String] {
        model.available.map(\.runtime).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
}

private struct DeviceMatrixEmptyState: View {
    let model: DeviceMatrixModel

    var body: some View {
        VStack(spacing: 12) {
            IconView(.grid, size: 30).foregroundStyle(Theme.faint)
            Text("See every screen size at once").font(.vibex(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            Text("Add simulators to watch your layout on a small phone, a large phone and an iPad side by side. Each one stays touchable.")
                .font(.vibex(size: 12))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if !model.presets.isEmpty {
                Button {
                    Task { await model.addPresets() }
                } label: {
                    Text("Add \(model.presets.map(\.name).joined(separator: ", "))").font(.vibex(size: 12.5, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.busy != nil)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
