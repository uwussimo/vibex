import AppKit
import SwiftUI

/// Chat on the left; on the right the devices running, and what passed on each.
struct QATabView: View {
    let model: QAModel
    var openDevices: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            ClaudeChatView(model: model.chat, welcome: QAModel.welcome)
                .frame(width: 360)
            Rectangle().fill(Theme.line).frame(width: 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    toolbar
                    Rectangle().fill(Theme.line).frame(height: 1)
                    if model.devices.isEmpty {
                        noDevices
                    } else {
                        QADeviceStrip(model: model)
                            .frame(height: 340)
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                    QAResultsView(model: model)
                }
                // A column of its own, so the grid's devices and Run stay in reach while it's open.
                if let id = model.selectedResult, let result = model.run?.results.first(where: { $0.id == id }) {
                    QAResultDetail(model: model, result: result)
                        .padding(10)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 1), value: model.selectedResult)
        }
        .background(Theme.background)
        .onAppear(perform: model.start)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("QA").font(.vibex(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            let flows = model.flows.count, devices = model.devices.count
            Text("\(flows) flow\(flows == 1 ? "" : "s") · \(devices) device\(devices == 1 ? "" : "s")").font(.vibex(size: 12)).foregroundStyle(Theme.faint)
            if let problem = model.problem {
                Text(problem).font(.vibex(size: 12)).foregroundStyle(Theme.orange).lineLimit(1)
            }
            Spacer()
            if model.isRunning, let run = model.run {
                ProgressView().controlSize(.mini)
                let done = run.results.count { [.passed, .failed, .skipped].contains($0.status) }
                Text("\(done) of \(run.results.count)").font(.vibex(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
                Button("Stop", action: model.stopRun)
            } else {
                Menu {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: model.flowsFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([model.flowsFolder])
                    }
                    Button("Manage Devices", action: openDevices)
                } label: {
                    IconView(.dots, size: 15).foregroundStyle(Theme.muted).frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                if model.flows.isEmpty {
                    // Nothing to run yet, so the button says what comes first.
                    Button("Write Tests", action: model.writeTests)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.chat.isBusy)
                        .help("Ask Claude to write test flows for this app")
                } else {
                    Button("Run All") { Task { await model.runFlows() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.devices.isEmpty)
                        .help(model.devices.isEmpty ? "Add devices first" : "Run every flow on every device in the grid")
                }
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var noDevices: some View {
        VStack(spacing: 10) {
            IconView(.grid, size: 26).foregroundStyle(Theme.faint)
            Text("Tests run on the Devices grid").font(.vibex(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            Text("Add a small phone, a large one and an iPad to catch what breaks at each size.")
                .font(.vibex(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 340)
            HStack(spacing: 8) {
                Button("Add Standard Devices") { Task { await model.matrix.addStandardDevices() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.matrix.busy != nil)
                Button("Choose Devices…", action: openDevices)
            }
            if let busy = model.matrix.busy { Text(busy).font(.vibex(size: 11.5)).foregroundStyle(Theme.faint) }
            if let problem = model.matrix.problem { Text(problem).font(.vibex(size: 11.5)).foregroundStyle(Theme.orange) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
    }
}

/// The grid's devices, live, each with what it's doing.
private struct QADeviceStrip: View {
    let model: QAModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(model.devices) { device in
                    VStack(spacing: 6) {
                        QATile(device: device, matrix: model.matrix)
                            .frame(width: width(device), height: 290)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        caption(device)
                    }
                }
            }
            .padding(14)
        }
    }

    private func width(_ device: SimDevice) -> CGFloat {
        device.name.hasPrefix("iPad") ? 240 : 170
    }

    @ViewBuilder
    private func caption(_ device: SimDevice) -> some View {
        let step = model.liveStep[device.udid]
        let results = model.run?.results.filter { $0.device == device.udid } ?? []
        HStack(spacing: 5) {
            if let step {
                ProgressView().controlSize(.mini)
                Text(step).foregroundStyle(Theme.muted)
            } else if !results.isEmpty {
                let failed = results.count { $0.status == .failed }
                QAStatusDot(status: failed > 0 ? .failed : (results.allSatisfy { $0.status == .passed } ? .passed : .waiting))
                Text(failed > 0 ? "\(failed) failed" : "\(results.count { $0.status == .passed }) passed").foregroundStyle(Theme.muted)
            } else {
                Text(device.isBooted ? "Ready" : "Off").foregroundStyle(Theme.faint)
            }
        }
        .font(.vibex(size: 11.5))
        .lineLimit(1)
        .frame(width: width(device))
    }
}

/// The Devices grid's tile, streaming a booted simulator's screen.
private struct QATile: NSViewRepresentable {
    let device: SimDevice
    let matrix: DeviceMatrixModel

    func makeNSView(context: Context) -> DeviceTileView {
        let tile = DeviceTileView(device: device, model: matrix)
        tile.update(device)
        return tile
    }

    func updateNSView(_ tile: DeviceTileView, context: Context) { tile.update(device) }

    static func dismantleNSView(_ tile: DeviceTileView, coordinator: ()) { tile.detach() }
}

struct QAStatusDot: View {
    let status: QAStatus

    var body: some View {
        Group {
            switch status {
            case .running: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
            case .passed: IconView(.checkCircle, size: 12).foregroundStyle(Theme.green)
            case .failed: IconView(.alert, size: 12).foregroundStyle(Theme.red)
            case .waiting, .skipped: Circle().strokeBorder(Theme.lineStrong, lineWidth: 1.5).frame(width: 10, height: 10).frame(width: 12, height: 12)
            }
        }
        .help(status.rawValue.capitalized)
    }
}

/// Flows down the side, devices across: where each passed and failed.
private struct QAResultsView: View {
    let model: QAModel

    var body: some View {
        if model.flows.isEmpty {
            VStack(spacing: 8) {
                IconView(.beaker, size: 26).foregroundStyle(Theme.faint)
                Text("No test flows yet").font(.vibex(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Ask Claude to write tests for this app. They're Maestro-style YAML files in \(QAModel.folderName)/flows, one journey per file.")
                    .font(.vibex(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 380)
                Button("Write Tests for This App", action: model.writeTests)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.chat.isBusy)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    ForEach(model.flows) { entry in row(entry) }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private var devices: [SimDevice] { model.devices }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Flow").frame(maxWidth: .infinity, alignment: .leading)
            ForEach(devices) { device in
                Text(Self.short(device.name)).frame(width: 92).lineLimit(1)
            }
            Color.clear.frame(width: 34)
        }
        .font(.vibex(size: 11, weight: .medium))
        .foregroundStyle(Theme.faint)
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    /// "iPhone 17 Pro Max" → "17 Pro Max", "iPhone SE (3rd generation)" → "SE".
    static func short(_ name: String) -> String {
        var text = name.replacingOccurrences(of: "iPhone ", with: "")
        if let paren = text.range(of: " (") { text = String(text[..<paren.lowerBound]) }
        return text
    }

    private func row(_ entry: QAFlowEntry) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.vibex(size: 12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                if let error = entry.error {
                    Text(error).font(.vibex(size: 11)).foregroundStyle(Theme.red).lineLimit(2)
                } else {
                    Text("\(entry.file) · \(entry.flow?.commands.count ?? 0) steps").font(.vibex(size: 11)).foregroundStyle(Theme.faint).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(devices) { device in
                let result = model.result(for: entry.file, device: device.udid)
                Button {
                    model.selectedResult = result?.id == model.selectedResult ? nil : result?.id
                } label: {
                    HStack(spacing: 5) {
                        QAStatusDot(status: result?.status ?? .waiting)
                        if let result, result.status == .passed || result.status == .failed {
                            Text(String(format: "%.0fs", result.seconds)).font(.vibex(size: 11)).foregroundStyle(Theme.faint).monospacedDigit()
                        }
                    }
                    .frame(width: 92, height: 30)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(result?.id == model.selectedResult && result != nil ? Theme.accent.opacity(0.18) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(result == nil)
            }
            Button { Task { await model.runFlows([entry.file]) } } label: {
                IconView(.play, size: 12).foregroundStyle(Theme.muted).frame(width: 34, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isRunning || entry.flow == nil || devices.isEmpty)
            .help("Run this flow on every device")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 14) }
    }
}

/// One flow on one device: every step, what the screen looked like after it, and why it failed.
private struct QAResultDetail: View {
    let model: QAModel
    let result: QAFlowResult
    @State private var shown: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                QAStatusDot(status: result.status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.flowName).font(.vibex(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(result.deviceName).font(.vibex(size: 11)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { model.selectedResult = nil } label: {
                    IconView(.close, size: 11).foregroundStyle(Theme.muted).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let failure = result.failure {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Step \(failure.index) failed").font(.vibex(size: 11, weight: .medium)).foregroundStyle(Theme.red)
                            Text(failure.message ?? "").font(.vibex(size: 12)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                            Button("Ask Claude Why") { model.diagnose(result) }
                                .controlSize(.small)
                                .disabled(model.chat.isBusy)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    if let image = (shown.flatMap { index in result.steps.first { $0.index == index } } ?? result.failure ?? result.steps.last)
                        .flatMap({ model.screenshot($0.screenshot) }).flatMap({ NSImage(contentsOf: $0) }) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(result.steps) { step in
                            Button { shown = step.index } label: {
                                HStack(spacing: 8) {
                                    QAStatusDot(status: step.status)
                                    Text(step.title).font(.vibex(size: 12)).foregroundStyle(step.status == .failed ? Theme.red : Theme.text).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(String(format: "%.1fs", step.seconds)).font(.vibex(size: 10.5)).foregroundStyle(Theme.faint).monospacedDigit()
                                }
                                .padding(.horizontal, 6)
                                .frame(height: 26)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(shown == step.index ? Color.white.opacity(0.06) : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
    }
}
