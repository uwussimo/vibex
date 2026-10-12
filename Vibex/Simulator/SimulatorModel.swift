import AppKit
import os

/// Device list, selection, slim state and the simctl/simslim actions behind the simulator header.
@Observable
final class SimulatorModel {
    private(set) var devices: [SimDevice] = []
    private(set) var slimInfo: [String: SlimInfo] = [:]
    private(set) var isBusy = false
    /// What the long-running action is doing, shown while busy.
    private(set) var activity: String?
    private(set) var errorMessage: String?
    private(set) var isSimslimInstalled = Simslim.isInstalled

    var selectedUDID: String? = Defaults.selectedDeviceUDID {
        didSet { Defaults.selectedDeviceUDID = selectedUDID }
    }

    var isSlimPreferred: Bool = Defaults.slimPreferred {
        didSet { Defaults.slimPreferred = isSlimPreferred }
    }

    private let simctl = Simctl()
    private let simslim = Simslim()

    var selectedDevice: SimDevice? {
        devices.first { $0.udid == selectedUDID } ?? devices.first { $0.isBooted } ?? devices.first
    }

    var bootedDevice: SimDevice? { devices.first { $0.isBooted } }

    var selectedSlimInfo: SlimInfo? { selectedDevice.flatMap { slimInfo[$0.udid] } }

    /// True when a boot would go through simslim.
    var willBootSlim: Bool { isSlimPreferred && isSimslimInstalled }

    func refresh() async {
        isSimslimInstalled = Simslim.isInstalled
        do {
            let list = try await simctl.listDevices()
            devices = list
            if selectedUDID == nil || !list.contains(where: { $0.udid == selectedUDID }) {
                selectedUDID = list.first { $0.isBooted }?.udid ?? list.first?.udid
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            Log.simulator.error("list devices failed: \(error.localizedDescription, privacy: .public)")
        }
        await refreshSlimInfo()
    }

    func refreshSlimInfo() async {
        guard isSimslimInstalled else { slimInfo = [:]; return }
        do {
            slimInfo = try await simslim.list()
        } catch {
            Log.simulator.notice("simslim list failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Boots the selected device headlessly (slim when preferred and simslim is installed). Vibex renders it itself.
    func bootSelected() async {
        guard let device = selectedDevice, !isBusy else { return }
        await perform(willBootSlim ? "Booting \(device.name) slim…" : "Booting \(device.name)…") {
            if willBootSlim, !(slimInfo[device.udid]?.isSlim ?? false) {
                try await simslim.slim(device.udid)
            } else {
                try await simctl.boot(device.udid)
            }
        }
    }

    func shutdownSelected() async {
        guard let device = selectedDevice, !isBusy else { return }
        await perform("Shutting down \(device.name)…") {
            try await simctl.shutdown(device.udid)
        }
    }

    /// Slims the selected device, or restores it to stock when it is already slim. Reboots it either way.
    func toggleSlimSelected() async {
        guard let device = selectedDevice, !isBusy, isSimslimInstalled else { return }
        let isSlim = slimInfo[device.udid]?.isSlim ?? false
        await perform(isSlim ? "Restoring \(device.name) to stock…" : "Slimming \(device.name)…") {
            if isSlim {
                try await simslim.restore(device.udid)
            } else {
                try await simslim.slim(device.udid)
            }
        }
    }

    /// Copies a PNG of the booted device to the pasteboard. Returns true on success.
    func copyScreenshot() async -> Bool {
        guard let device = bootedDevice ?? selectedDevice, !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let data = try await simctl.screenshot(device.udid)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func perform(_ description: String, _ work: () async throws -> Void) async {
        isBusy = true
        activity = description
        defer {
            isBusy = false
            activity = nil
        }
        Log.simulator.info("\(description, privacy: .public)")
        do {
            try await work()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            Log.simulator.error("\(description, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        await refresh()
    }
}
