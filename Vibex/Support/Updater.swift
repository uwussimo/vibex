import AppKit
import Observation
import os

/// Keeps Vibex current without Sparkle: checks GitHub's latest release in the background, and
/// installs it by running the same `install.sh` the curl one-liner uses (which verifies the DMG's
/// SHA-256). Installing waits for quit unless the user picks Restart to Update, so a running
/// terminal session is never cut off.
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case installing(String)
        case failed(String)
    }

    private(set) var state: State = .idle

    nonisolated static let repository = "uwussimo/vibex"
    static let installer = "https://uwussimo.github.io/vibex/install.sh"
    private static let interval: Duration = .seconds(6 * 60 * 60)

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    private var loop: Task<Void, Never>?
    /// Debug builds live in DerivedData; updating them would replace a development build.
    static let isEnabled: Bool = {
        #if DEBUG
        false
        #else
        true
        #endif
    }()

    var availableVersion: String? {
        if case let .available(version) = state { return version }
        return nil
    }

    /// Checks now, then every six hours while Vibex runs.
    func start() {
        guard Self.isEnabled, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check(userInitiated: false)
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func check(userInitiated: Bool) async {
        if case .installing = state { return }
        state = .checking
        do {
            let latest = try await Self.latestVersion()
            if Self.isNewer(latest, than: currentVersion) {
                let isNew = availableVersion != latest
                state = .available(latest)
                if isNew || userInitiated { announce(latest) }
            } else {
                state = .upToDate
                if userInitiated {
                    WindowManager.shared.keyWindow?.toast.show(title: "Vibex is up to date", message: "You have the latest version, \(currentVersion).")
                }
            }
        } catch {
            state = userInitiated ? .failed(error.localizedDescription) : .idle
            if userInitiated {
                WindowManager.shared.keyWindow?.toast.show(title: "Could not check for updates", message: error.localizedDescription)
            }
            Log.app.error("update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Installs now: the installer quits Vibex, replaces it and opens the new version.
    func restartToUpdate() {
        guard let version = availableVersion else { return }
        state = .installing(version)
        runInstaller(version: version, reopen: true)
    }

    /// Called from applicationWillTerminate: a pending update installs once Vibex has quit.
    func installOnQuitIfNeeded() {
        guard let version = availableVersion else { return }
        runInstaller(version: version, reopen: false)
    }

    // MARK: - Private

    private func announce(_ version: String) {
        WindowManager.shared.keyWindow?.toast.show(
            title: "Vibex \(version) is available",
            message: "It installs when you quit, or choose Restart to Update in the Vibex menu.",
            seconds: 8
        )
    }

    /// Detached from Vibex so it survives the quit it triggers. Output goes to ~/Library/Logs/Vibex/update.log.
    private func runInstaller(version: String, reopen: Bool) {
        let appPath = Bundle.main.bundleURL
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Vibex")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("update.log").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // A moment's pause lets this process finish quitting when the update runs at quit time.
        process.arguments = ["-c", "sleep 1; curl -fsSL \(Self.installer) | sh >>\"$VIBEX_UPDATE_LOG\" 2>&1"]
        var environment = ProcessInfo.processInfo.environment
        environment["VIBEX_VERSION"] = version
        environment["VIBEX_INSTALL_DIR"] = appPath.deletingLastPathComponent().path
        environment["VIBEX_UPDATE_LOG"] = log
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        if !reopen { environment["VIBEX_NO_OPEN"] = "1" }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            Log.app.info("installing Vibex \(version, privacy: .public) (reopen: \(reopen))")
        } catch {
            state = .failed(error.localizedDescription)
            WindowManager.shared.keyWindow?.toast.show(title: "Could not start the update", message: error.localizedDescription)
        }
    }

    nonisolated private struct Release: Decodable {
        let tag_name: String
    }

    @concurrent static func latestVersion() async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let release = try JSONDecoder().decode(Release.self, from: data)
        return release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
    }

    /// Numeric, component-wise: 1.10.0 is newer than 1.9.3.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }
}
