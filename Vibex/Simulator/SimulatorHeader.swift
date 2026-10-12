import SwiftUI

struct SimulatorHeaderActions {
    var boot: () -> Void
    var shutdown: () -> Void
    var screenshot: () -> Void
    var home: () -> Void
    var lock: () -> Void
    var toggleSlim: () -> Void
    var installSimslim: () -> Void
}

struct SimulatorHeader: View {
    let model: SimulatorModel
    let isLive: () -> Bool
    let actions: SimulatorHeaderActions
    @State private var flashScreenshot = false

    private var selected: SimDevice? { model.selectedDevice }
    private var isBooted: Bool { selected?.isBooted ?? false }

    var body: some View {
        HStack(spacing: 4) {
            devicePicker
            Spacer(minLength: 4)
            ToolbarIconButton(
                systemImage: isBooted ? "stop.fill" : "play.fill",
                help: isBooted ? "Shut down" : (model.willBootSlim ? "Boot slim" : "Boot"),
                isEnabled: selected != nil && !model.isBusy,
                action: isBooted ? actions.shutdown : actions.boot
            )
            ToolbarIconButton(systemImage: "house", help: "Home", isEnabled: isLive(), action: actions.home)
            ToolbarIconButton(systemImage: "lock", help: "Lock / wake", isEnabled: isLive(), action: actions.lock)
            ToolbarIconButton(
                systemImage: flashScreenshot ? "checkmark" : "camera",
                help: "Copy screenshot",
                isEnabled: isBooted && !model.isBusy
            ) {
                actions.screenshot()
                withAnimation(.spring(response: 0.25, dampingFraction: 1)) { flashScreenshot = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    withAnimation(.spring(response: 0.25, dampingFraction: 1)) { flashScreenshot = false }
                }
            }
            slimButton
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(.bar)
    }

    /// Leaf = slim (simslim). Filled when the selected device is slim, outlined when stock,
    /// and a download arrow when simslim is not installed yet.
    private var slimButton: some View {
        let info = model.selectedSlimInfo
        let isSlim = info?.isSlim ?? false
        return Group {
            if model.isSimslimInstalled {
                ToolbarIconButton(
                    systemImage: isSlim ? "leaf.fill" : "leaf",
                    help: isSlim
                        ? "Slim: \(info?.managedDisabled ?? 0) of \(info?.managedTotal ?? 0) daemons off. Click to restore stock (reboots)."
                        : "Stock. Click to slim with simslim (reboots).",
                    isEnabled: selected != nil && !model.isBusy,
                    isActive: isSlim,
                    action: actions.toggleSlim
                )
            } else {
                ToolbarIconButton(
                    systemImage: "leaf.arrow.trianglehead.clockwise",
                    help: "Install simslim to boot lighter simulators",
                    isEnabled: !model.isBusy,
                    action: actions.installSimslim
                )
            }
        }
    }

    private var devicePicker: some View {
        Menu {
            ForEach(groupedRuntimes, id: \.self) { runtime in
                Section(runtime) {
                    ForEach(model.devices.filter { $0.runtime == runtime }) { device in
                        Button {
                            model.selectedUDID = device.udid
                        } label: {
                            if device.udid == model.selectedUDID {
                                Label(device.name, systemImage: "checkmark")
                            } else if device.isBooted {
                                Label(device.name, systemImage: "circle.fill")
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(selected?.name ?? "No simulators")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(secondaryLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                if model.isBusy {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
    }

    private var secondaryLabel: String {
        if let activity = model.activity { return activity }
        guard let selected else { return "" }
        if let memory = model.selectedSlimInfo?.memoryText, selected.isBooted {
            return "\(selected.runtime) · \(memory)"
        }
        return selected.runtime
    }

    private var groupedRuntimes: [String] {
        var seen: [String] = []
        for device in model.devices where !seen.contains(device.runtime) {
            seen.append(device.runtime)
        }
        return seen
    }

    private var statusColor: Color {
        guard let selected else { return .secondary }
        if selected.isBooted { return isLive() ? .green : .orange }
        if selected.isTransitioning { return .yellow }
        return .secondary.opacity(0.5)
    }
}

/// What the column shows when the device screen is not live.
struct SimulatorEmptyState: View {
    let state: SimulatorPaneViewController.DisplayState
    let deviceName: String?
    let isBusy: Bool
    let activity: String?
    let willBootSlim: Bool
    let errorMessage: String?
    let primaryAction: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsButton {
                Button(action: primaryAction) {
                    if isBusy || state == .connecting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(activity ?? "Connecting…").lineLimit(1)
                        }
                        .frame(minWidth: 100)
                    } else {
                        Text(buttonTitle).frame(minWidth: 100)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isBusy || state == .connecting)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .padding(24)
        .frame(width: 280)
    }

    private var showsButton: Bool { true }

    private var icon: String {
        switch state {
        case .noDevices: "iphone.slash"
        case .shutdown: "iphone"
        case .connecting: "iphone.radiowaves.left.and.right"
        case .failed: "exclamationmark.triangle"
        case .live: "iphone"
        }
    }

    private var title: String {
        switch state {
        case .noDevices: "No simulators"
        case .shutdown: deviceName ?? "Simulator"
        case .connecting: "Connecting to \(deviceName ?? "the simulator")"
        case .failed: "Could not show the simulator"
        case .live: ""
        }
    }

    private var subtitle: String {
        switch state {
        case .noDevices: "Create one in Xcode → Devices and Simulators."
        case .shutdown: willBootSlim
            ? "Boots slim: simslim trims the daemons this device does not need."
            : "The device is shut down."
        case .connecting: "Waiting for the device to render its first frame."
        case let .failed(message): message
        case .live: ""
        }
    }

    private var buttonTitle: String {
        switch state {
        case .noDevices: "Refresh"
        case .shutdown: willBootSlim ? "Boot slim" : "Boot"
        case .connecting: "Connecting…"
        case .failed: "Retry"
        case .live: ""
        }
    }
}
