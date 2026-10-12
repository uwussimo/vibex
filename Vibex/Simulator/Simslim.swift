import Foundation

/// Slim status of one simulator as reported by `simslim list --json` / `status --json`.
nonisolated struct SlimInfo: Equatable, Sendable, Decodable {
    let managedDisabled: Int
    let managedTotal: Int
    let memoryBytes: Int64?
    let processes: Int?

    var isSlim: Bool { managedDisabled > 0 }

    var memoryText: String? {
        guard let memoryBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: memoryBytes, countStyle: .memory)
    }

    init(managedDisabled: Int, managedTotal: Int, memoryBytes: Int64? = nil, processes: Int? = nil) {
        self.managedDisabled = managedDisabled
        self.managedTotal = managedTotal
        self.memoryBytes = memoryBytes
        self.processes = processes
    }

    private enum CodingKeys: String, CodingKey { case managedDisabled, managedTotal, memory }
    private struct Memory: Decodable { let processes: Int?; let bytes: Int64? }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        managedDisabled = try container.decodeIfPresent(Int.self, forKey: .managedDisabled) ?? 0
        managedTotal = try container.decodeIfPresent(Int.self, forKey: .managedTotal) ?? 0
        let memory = try container.decodeIfPresent(Memory.self, forKey: .memory)
        memoryBytes = memory?.bytes
        processes = memory?.processes
    }
}

/// Wrapper around the `simslim` CLI (github.com/MobAI-App/simslim), which disables the background
/// daemons a simulator does not need so several fit in memory. Optional: everything works without it.
nonisolated struct Simslim: Sendable {
    static let installCommand = "brew install mobai-app/tap/simslim"

    static var executable: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return Shell.find(["/opt/homebrew/bin/simslim", "/usr/local/bin/simslim", "\(home)/go/bin/simslim"])
    }

    static var isInstalled: Bool { executable != nil }

    /// Slim status keyed by UDID. Memory is only present for booted devices.
    @concurrent
    func list() async throws -> [String: SlimInfo] {
        guard let executable = Self.executable else { return [:] }
        let data = try Shell.run(executable, ["list", "--json"])
        return try Self.parseList(data)
    }

    /// `simslim on`: persists the disables and reboots the simulator slim. Boots it if needed.
    /// Takes a minute or two.
    @concurrent
    func slim(_ udid: String) async throws {
        guard let executable = Self.executable else { return }
        _ = try Shell.run(executable, ["on", udid])
    }

    /// `simslim off`: back to stock, with a reboot.
    @concurrent
    func restore(_ udid: String) async throws {
        guard let executable = Self.executable else { return }
        _ = try Shell.run(executable, ["off", udid])
    }

    static func parseList(_ data: Data) throws -> [String: SlimInfo] {
        struct Entry: Decodable {
            let udid: String
            let managedDisabled: Int?
            let managedTotal: Int?
            let memory: Memory?
            struct Memory: Decodable { let processes: Int?; let bytes: Int64? }
        }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        var result: [String: SlimInfo] = [:]
        for entry in entries {
            result[entry.udid] = SlimInfo(
                managedDisabled: entry.managedDisabled ?? 0,
                managedTotal: entry.managedTotal ?? 0,
                memoryBytes: entry.memory?.bytes,
                processes: entry.memory?.processes
            )
        }
        return result
    }
}
