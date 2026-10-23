import Foundation

struct SimDevice: Identifiable, Hashable, Sendable {
    let udid: String
    let name: String
    /// Human runtime name, e.g. "iOS 26.5".
    let runtime: String
    /// "Booted", "Shutdown", "Booting", "Shutting Down".
    let state: String

    var id: String { udid }
    var isBooted: Bool { state == "Booted" }
    var isTransitioning: Bool { state == "Booting" || state == "Shutting Down" }
    /// The title Simulator.app gives this device's window.
    var windowTitle: String { "\(name) – \(runtime)" }
}

nonisolated enum SimctlError: Error, LocalizedError {
    case noRuntime

    var errorDescription: String? {
        switch self {
        case .noRuntime: "No iOS simulator runtime is installed. Download one from Vibex → Setup & Permissions."
        }
    }
}

/// Thin wrapper around `xcrun simctl`. Everything runs on the concurrent pool and returns values.
nonisolated struct Simctl: Sendable {
    @concurrent
    func listDevices() async throws -> [SimDevice] {
        let data = try run("/usr/bin/xcrun", ["simctl", "list", "-j", "devices", "available"])
        let list = try JSONDecoder().decode(DeviceList.self, from: data)
        return list.devices
            .flatMap { runtimeID, entries in
                entries
                    .filter { $0.isAvailable ?? true }
                    .map { SimDevice(udid: $0.udid, name: $0.name, runtime: Self.runtimeName(runtimeID), state: $0.state) }
            }
            .sorted { lhs, rhs in
                if lhs.runtime != rhs.runtime { return lhs.runtime.localizedStandardCompare(rhs.runtime) == .orderedDescending }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// Creates an iPhone on the newest installed iOS runtime and returns its UDID. Picks the newest
    /// "iPhone N Pro" that runtime supports, or else the last iPhone it lists.
    @concurrent
    func createDefaultiPhone() async throws -> String {
        let data = try run("/usr/bin/xcrun", ["simctl", "list", "-j", "runtimes", "available"])
        let runtimes = try JSONDecoder().decode(RuntimeList.self, from: data).runtimes
            .filter { $0.platform == "iOS" && ($0.isAvailable ?? true) }
            .sorted { $0.version.localizedStandardCompare($1.version) == .orderedDescending }
        guard let runtime = runtimes.first else { throw SimctlError.noRuntime }
        let iPhones = (runtime.supportedDeviceTypes ?? []).filter { $0.productFamily == "iPhone" }
        let pro = iPhones
            .filter { $0.name.range(of: #"^iPhone \d+ Pro$"#, options: .regularExpression) != nil }
            .max { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard let type = pro ?? iPhones.last else { throw SimctlError.noRuntime }
        let output = try run("/usr/bin/xcrun", ["simctl", "create", type.name, type.identifier, runtime.identifier])
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @concurrent
    func boot(_ udid: String) async throws {
        do {
            _ = try run("/usr/bin/xcrun", ["simctl", "boot", udid])
        } catch let ShellError.failed(_, _, message) where message.contains("current state: Booted") {
            // Already booted. Fine.
        }
    }

    @concurrent
    func shutdown(_ udid: String) async throws {
        _ = try run("/usr/bin/xcrun", ["simctl", "shutdown", udid])
    }

    /// Captures the device screen as PNG data.
    @concurrent
    func screenshot(_ udid: String) async throws -> Data {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: path) }
        _ = try run("/usr/bin/xcrun", ["simctl", "io", udid, "screenshot", path.path])
        return try Data(contentsOf: path)
    }

    @concurrent
    func install(_ udid: String, appPath: String) async throws {
        _ = try run("/usr/bin/xcrun", ["simctl", "install", udid, appPath])
    }

    /// Launches an app; returns simctl's output (the pid line).
    @concurrent
    func launch(_ udid: String, bundleID: String, arguments: [String]) async throws -> String {
        let data = try run("/usr/bin/xcrun", ["simctl", "launch", "--terminate-running-process", udid, bundleID] + arguments)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @concurrent
    func terminate(_ udid: String, bundleID: String) async throws {
        _ = try run("/usr/bin/xcrun", ["simctl", "terminate", udid, bundleID])
    }

    @concurrent
    func openURL(_ udid: String, url: String) async throws {
        _ = try run("/usr/bin/xcrun", ["simctl", "openurl", udid, url])
    }

    struct InstalledApp: Sendable {
        let bundleID: String
        let name: String
        let type: String
    }

    @concurrent
    func listApps(_ udid: String) async throws -> [InstalledApp] {
        let data = try run("/usr/bin/xcrun", ["simctl", "listapps", udid])
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] else { return [] }
        return plist.map { bundleID, info in
            InstalledApp(
                bundleID: bundleID,
                name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? bundleID,
                type: info["ApplicationType"] as? String ?? ""
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Unified log lines from inside the device for the last `seconds`.
    @concurrent
    func logs(_ udid: String, seconds: Int, predicate: String?) async throws -> String {
        var arguments = ["simctl", "spawn", udid, "log", "show", "--last", "\(seconds)s", "--style", "compact", "--info"]
        if let predicate, !predicate.isEmpty { arguments += ["--predicate", predicate] }
        let data = try run("/usr/bin/xcrun", arguments)
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(300).joined(separator: "\n")
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-5" → "iOS 26.5"
    static func runtimeName(_ identifier: String) -> String {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        var name = identifier.hasPrefix(prefix) ? String(identifier.dropFirst(prefix.count)) : identifier
        guard let dash = name.firstIndex(of: "-") else { return name }
        let platform = name[..<dash]
        let version = name[name.index(after: dash)...].replacingOccurrences(of: "-", with: ".")
        name = "\(platform) \(version)"
        return name
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> Data {
        try Shell.run(executable, arguments)
    }

    private struct RuntimeList: Decodable {
        let runtimes: [Runtime]
    }

    private struct Runtime: Decodable {
        let identifier: String
        let version: String
        let platform: String?
        let isAvailable: Bool?
        let supportedDeviceTypes: [DeviceType]?
    }

    private struct DeviceType: Decodable {
        let identifier: String
        let name: String
        let productFamily: String?
    }

    private struct DeviceList: Decodable {
        let devices: [String: [Entry]]
    }

    private struct Entry: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
    }
}
