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
            // Outside the menu: a macOS menu label only draws its title.
            if model.selectedSlimInfo?.isSlim ?? false {
                IconView(.feather, size: 11.5)
                    .foregroundStyle(Color.accentColor)
                    .help("Slim: \(model.selectedSlimInfo?.managedDisabled ?? 0) of \(model.selectedSlimInfo?.managedTotal ?? 0) daemons off")
            }
            Spacer(minLength: 4)
            ToolbarIconButton(
                icon: isBooted ? .stop : .play,
                help: isBooted ? "Shut Down" : (model.willBootSlim ? "Boot Slim" : "Boot"),
                isEnabled: selected != nil && !model.isBusy,
                action: isBooted ? actions.shutdown : actions.boot
            )
            ToolbarIconButton(icon: .home, help: "Home (⇧⌘H)", isEnabled: isLive(), action: actions.home)
            ToolbarIconButton(
                icon: flashScreenshot ? .check : .camera,
                help: "Copy Screenshot (⇧⌘S)",
                isEnabled: isBooted && !model.isBusy
            ) {
                actions.screenshot()
                withAnimation(.spring(response: 0.25, dampingFraction: 1)) { flashScreenshot = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    withAnimation(.spring(response: 0.25, dampingFraction: 1)) { flashScreenshot = false }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(Theme.surface)
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
            // Rarer device actions live here rather than as more header icons.
            Section {
                Button("Lock / Wake", action: actions.lock).disabled(!isLive())
                slimMenuItem
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(selected?.name ?? "No simulators")
                    .font(.vibex(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(secondaryLabel)
                    .font(.vibex(size: 11))
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

    @ViewBuilder
    private var slimMenuItem: some View {
        if model.isSimslimInstalled {
            let isSlim = model.selectedSlimInfo?.isSlim ?? false
            Button(isSlim ? "Restore Stock Simulator (Reboots)" : "Slim This Simulator (Reboots)", action: actions.toggleSlim)
                .disabled(selected == nil || model.isBusy)
        } else {
            Button("Install simslim…", action: actions.installSimslim)
                .disabled(model.isBusy)
        }
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
            IconView(icon, size: 34)
                .foregroundStyle(Theme.faint)
            VStack(spacing: 4) {
                Text(title)
                    .font(.vibex(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.vibex(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            .font(.vibex(size: 13, weight: .medium))
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isBusy || state == .connecting)
            if let errorMessage {
                Text(errorMessage)
                    .font(.vibex(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .padding(24)
        .frame(width: 280)
    }

    private var icon: Icon {
        switch state {
        case .noDevices, .shutdown, .live: .phone
        case .connecting: .hourglass
        case .failed: .alert
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
        case .noDevices: "Vibex can make an iPhone on the newest iOS runtime installed."
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
        case .noDevices: "Create iPhone"
        case .shutdown: willBootSlim ? "Boot Slim" : "Boot"
        case .connecting: "Connecting…"
        case .failed: "Retry"
        case .live: ""
        }
    }
}
