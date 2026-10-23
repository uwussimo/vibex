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
    /// The newest release's notes, shown in the update prompt.
    private(set) var releaseNotes: String?
    /// A version waiting to be offered in a prompt once a window is on screen.
    private var pendingPrompt: String?
    private var keyObserver: NSObjectProtocol?

    nonisolated static let repository = "uwussimo/vibex"
    static let installer = "https://vibex.cc/install.sh"
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

    /// Checks on every launch, then every six hours while Vibex runs. A release found at launch (or
    /// by Check for Updates) is offered in a prompt; one found later in the day only gets a toast,
    /// so a long session isn't interrupted.
    func start() {
        guard Self.isEnabled, loop == nil else { return }
        loop = Task { [weak self] in
            var isLaunch = true
            while !Task.isCancelled {
                await self?.check(userInitiated: false, prompt: isLaunch)
                isLaunch = false
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func check(userInitiated: Bool, prompt: Bool = false) async {
        if case .installing = state { return }
        let previous = availableVersion
        state = .checking
        do {
            let release = try await Self.latestRelease()
            let latest = release.version
            if Self.isNewer(latest, than: currentVersion) {
                state = .available(latest)
                releaseNotes = release.notes
                if prompt || userInitiated {
                    offer(latest)
                } else if previous != latest {
                    announce(latest)
                }
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

    /// Asks once a window is on screen; at launch the first window takes a moment.
    private func offer(_ version: String) {
        pendingPrompt = version
        if presentPendingPrompt() { return }
        guard keyObserver == nil else { return }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.presentPendingPrompt() }
        }
    }

    @discardableResult
    private func presentPendingPrompt() -> Bool {
        guard let version = pendingPrompt, let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible,
              window.attachedSheet == nil, availableVersion == version else { return false }
        pendingPrompt = nil
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil

        let alert = NSAlert()
        alert.messageText = "Vibex \(version) is available"
        var details = "You have \(currentVersion)."
        if let notes = releaseNotes.map({ Self.summary(ofNotes: $0) }), !notes.isEmpty {
            details += "\n\n" + notes
        }
        details += "\n\nRestarting quits Vibex, installs the update and opens it again; open terminal sessions end. Later installs it the next time you quit."
        alert.informativeText = details
        alert.addButton(withTitle: "Restart to Update")
        alert.addButton(withTitle: "Later")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.restartToUpdate() }
        }
        return true
    }

    /// The first few bullet points of a release's Markdown notes, as plain text.
    nonisolated static func summary(ofNotes notes: String, limit: Int = 5) -> String {
        notes.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
            .prefix(limit)
            .map { line in
                var text = String(line.dropFirst(2)).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                if text.count > 110 { text = String(text.prefix(107)) + "…" }
                return "• " + text
            }
            .joined(separator: "\n")
    }

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
        let body: String?
    }

    @concurrent static func latestVersion() async throws -> String {
        try await latestRelease().version
    }

    @concurrent static func latestRelease() async throws -> (version: String, notes: String?) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        return (version, release.body)
    }

    /// Numeric, component-wise: 1.10.0 is newer than 1.9.3.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }
}
