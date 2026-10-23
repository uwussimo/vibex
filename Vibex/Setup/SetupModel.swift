import AppKit
import Observation
import UserNotifications

/// One thing Vibex needs from the Mac, with its live state.
struct SetupItem: Identifiable, Equatable {
    enum ID: String, CaseIterable {
        case fullDiskAccess, folders, notifications, xcode, claude, vibexSkill, commandLine
    }

    enum Status: Equatable {
        case checking
        case ready
        case needed
        case working(String)
        case failed(String)
    }

    let id: ID
    var status: Status = .checking
}

/// Checks and grants the permissions and tools Vibex depends on. Statuses refresh whenever Vibex
/// comes back to the front, so granting something in System Settings shows up right away.
@Observable
final class SetupModel {
    private(set) var items: [SetupItem] = SetupItem.ID.allCases.map { SetupItem(id: $0) }
    private var activationObserver: NSObjectProtocol?

    /// Bumped when a new release adds something users must see once.
    static let currentVersion = 1

    static var needsSetup: Bool { Defaults.setupVersion < currentVersion }

    init() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func status(_ id: SetupItem.ID) -> SetupItem.Status {
        items.first { $0.id == id }?.status ?? .checking
    }

    /// How many rows are done, counting folders as done once Full Disk Access covers them.
    var readyCount: Int {
        items.filter { item in
            item.status == .ready || (item.id == .folders && status(.fullDiskAccess) == .ready)
        }.count
    }

    var totalCount: Int { items.count }

    /// Everything that matters for the core workflow is ready.
    var isComplete: Bool {
        [.xcode, .claude].allSatisfy { status($0) == .ready }
            && (status(.fullDiskAccess) == .ready || status(.folders) == .ready)
    }

    func refresh() {
        Task {
            let snapshot = await SetupProbe.run(foldersAsked: Defaults.foldersRequested)
            for (id, ready) in snapshot where !isWorking(id) {
                set(id, ready ? .ready : .needed)
            }
            let notifications = await UNUserNotificationCenter.current().notificationSettings()
            if !isWorking(.notifications) {
                set(.notifications, notifications.authorizationStatus == .authorized || notifications.authorizationStatus == .provisional ? .ready : .needed)
            }
        }
    }

    func perform(_ id: SetupItem.ID) {
        switch id {
        case .fullDiskAccess:
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        case .folders:
            Defaults.foldersRequested = true
            run(id, "Asking…") { try await SetupProbe.requestFolders() }
        case .notifications:
            if status(.notifications) == .needed, Defaults.notificationsRequested {
                open("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
                return
            }
            Defaults.notificationsRequested = true
            run(id, "Asking…") {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            }
        case .xcode:
            if FileManager.default.fileExists(atPath: Toolchain.developerDir) {
                run(id, "Downloading the iOS simulator…") { try await SetupProbe.downloadIOSRuntime() }
            } else {
                open("macappstore://apps.apple.com/app/id497799835")
            }
        case .claude:
            run(id, "Installing Claude Code…") { try await SetupProbe.installClaude() }
        case .vibexSkill:
            Defaults.vibexSkillRemoved = false
            run(id, "Installing…") { try VibexSkill.install() }
        case .commandLine:
            run(id, "Installing…") { _ = try await CommandLineTool.install() }
        }
    }

    func markSeen() { Defaults.setupVersion = Self.currentVersion }

    // MARK: - Private

    private func run(_ id: SetupItem.ID, _ activity: String, _ work: @escaping () async throws -> Void) {
        set(id, .working(activity))
        Task {
            do {
                try await work()
                set(id, .checking)
            } catch {
                set(id, .failed(error.localizedDescription))
                return
            }
            refresh()
        }
    }

    private func isWorking(_ id: SetupItem.ID) -> Bool {
        if case .working = status(id) { return true }
        return false
    }

    private func set(_ id: SetupItem.ID, _ status: SetupItem.Status) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status != status else { return }
        items[index].status = status
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

/// The blocking checks, run off the main actor.
nonisolated enum SetupProbe {
    static let folders: [FileManager.SearchPathDirectory] = [.desktopDirectory, .documentDirectory, .downloadsDirectory]

    @concurrent static func run(foldersAsked: Bool) async -> [SetupItem.ID: Bool] {
        let fullDisk = hasFullDiskAccess()
        return [
            .fullDiskAccess: fullDisk,
            // Listing a folder is what triggers its prompt, so only look once the user has asked.
            .folders: fullDisk || (foldersAsked && folders.allSatisfy(canList)),
            .xcode: hasIOSRuntime(),
            .claude: ClaudeCodeRegistrar.findClaude() != nil,
            .vibexSkill: [.current, .userOwned].contains(VibexSkill.status),
            .commandLine: CommandLineTool.installedPath != nil,
        ]
    }

    /// The user's TCC database is readable only with Full Disk Access.
    static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let handle = FileHandle(forReadingAtPath: "\(home)/Library/Application Support/com.apple.TCC/TCC.db") else { return false }
        try? handle.close()
        return true
    }

    /// Lists Desktop, Documents and Downloads, which makes macOS ask for each one.
    @concurrent static func requestFolders() async throws {
        for directory in folders { _ = canList(directory) }
    }

    private static func canList(_ directory: FileManager.SearchPathDirectory) -> Bool {
        guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    /// Xcode is installed and has at least one usable iOS simulator runtime.
    static func hasIOSRuntime() -> Bool {
        struct Runtimes: Decodable {
            struct Runtime: Decodable { let platform: String?; let isAvailable: Bool }
            let runtimes: [Runtime]
        }
        guard FileManager.default.fileExists(atPath: Toolchain.developerDir),
              let data = try? Shell.run("/usr/bin/xcrun", ["simctl", "list", "runtimes", "--json"], environment: ["DEVELOPER_DIR": Toolchain.developerDir]),
              let list = try? JSONDecoder().decode(Runtimes.self, from: data) else { return false }
        return list.runtimes.contains { $0.platform == "iOS" && $0.isAvailable }
    }

    @concurrent static func downloadIOSRuntime() async throws {
        _ = try Shell.run("/usr/bin/xcrun", ["xcodebuild", "-downloadPlatform", "iOS"], environment: ["DEVELOPER_DIR": Toolchain.developerDir])
    }

    /// Anthropic's native installer, which needs neither Node nor sudo.
    @concurrent static func installClaude() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        _ = try Shell.run("/bin/bash", ["-c", "curl -fsSL https://claude.ai/install.sh | bash"], environment: [
            "HOME": home,
            "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        ])
    }
}
