import AppKit
import Observation
import os

/// Keeps Vibex current without Sparkle: checks GitHub's latest release in the background, and
/// installs it by running the same `install.sh` the curl one-liner uses (which verifies the DMG's
/// SHA-256). Installing waits for quit unless the user picks Restart to Update, so a running
/// terminal session is never cut off. `UpdateWindow` is its face: progress is read back from the
/// installer's log.
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
    /// How far the install has got; nil before it starts.
    private(set) var progress: InstallProgress?
    /// Shows the update window; set by the app delegate.
    var showWindow: () -> Void = {}
    /// Tells the user Vibex was just updated, with a way to see what changed.
    var announceUpdated: (String) -> Void = { _ in }
    /// A version waiting to be offered once a window is on screen.
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

    init(state: State = .idle, releaseNotes: String? = nil, progress: InstallProgress? = nil) {
        self.state = state
        self.releaseNotes = releaseNotes
        self.progress = progress
    }

    /// Checks on every launch, then every six hours while Vibex runs. A release found at launch is
    /// offered in the update window, once per version; after Later, or when one turns up mid-session,
    /// the title bar's button is what's left, so a long session isn't interrupted.
    func start() {
        guard Self.isEnabled, loop == nil else { return }
        noteLaunch()
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
        // Opens at once so the click shows something; the window follows the state from here.
        if userInitiated { showWindow() }
        state = .checking
        do {
            let release = try await Self.latestRelease()
            let latest = release.version
            releaseNotes = release.notes
            if Self.isNewer(latest, than: currentVersion) {
                state = .available(latest)
                if prompt, Defaults.dismissedUpdate != latest { offer(latest) }
            } else {
                state = .upToDate
            }
        } catch {
            state = userInitiated ? .failed(error.localizedDescription) : .idle
            Log.app.error("update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Later: the window stays away for this version, and it installs at quit.
    func postpone() {
        if let version = availableVersion { Defaults.dismissedUpdate = version }
    }

    /// Installs now: the installer quits Vibex, replaces it and opens the new version.
    func restartToUpdate() {
        guard let version = availableVersion else { return }
        state = .installing(version)
        progress = InstallProgress(step: .downloading)
        runInstaller(version: version, reopen: true)
    }

    /// The first launch of a new version says so.
    private func noteLaunch() {
        let last = Defaults.lastRunVersion
        Defaults.lastRunVersion = currentVersion
        guard let last, Self.isNewer(currentVersion, than: last) else { return }
        Task { [weak self, currentVersion] in
            try? await Task.sleep(for: .seconds(2)) // the first window takes a moment
            self?.announceUpdated(currentVersion)
        }
    }

    /// Called from applicationWillTerminate: a pending update installs once Vibex has quit.
    func installOnQuitIfNeeded() {
        guard let version = availableVersion else { return }
        runInstaller(version: version, reopen: false)
    }

    // MARK: - Private

    /// Opens once a window is on screen, so it isn't lost behind one still appearing at launch.
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
        showWindow()
        return true
    }

    /// Detached from Vibex so it survives the quit it triggers. Output goes to ~/Library/Logs/Vibex/update.log.
    private func runInstaller(version: String, reopen: Bool) {
        let appPath = Bundle.main.bundleURL
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Vibex")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("update.log").path
        let logStart = (try? FileManager.default.attributesOfItem(atPath: log)[.size] as? Int) ?? 0

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
            return
        }
        guard reopen else { return }
        // On success the installer quits Vibex, so this only ever sees it fail.
        Task { [weak self] in
            while process.isRunning {
                self?.progress = Self.readProgress(log: log, from: logStart)
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self, process.terminationStatus != 0 else { return }
            let reason = Self.readProgress(log: log, from: logStart).failure ?? "The installer stopped without saying why."
            state = .failed(reason)
            progress = nil
        }
    }

    private static func readProgress(log: String, from offset: Int) -> InstallProgress {
        guard let handle = FileHandle(forReadingAtPath: log) else { return InstallProgress(step: .downloading) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))
        return InstallProgress(log: String(decoding: handle.readDataToEndOfFile(), as: UTF8.self))
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

/// Where the installer has got, read from what it writes to its log.
nonisolated struct InstallProgress: Equatable, Sendable {
    enum Step: Int, CaseIterable, Sendable {
        case downloading, verifying, installing

        var title: String {
            switch self {
            case .downloading: "Download"
            case .verifying: "Verify"
            case .installing: "Install"
            }
        }
    }

    var step: Step
    /// The download's share done, once curl has reported one.
    var fraction: Double?
    /// The installer's own error line.
    var failure: String?

    init(step: Step, fraction: Double? = nil, failure: String? = nil) {
        self.step = step
        self.fraction = fraction
        self.failure = failure
    }

    init(log: String) {
        step = .downloading
        // curl redraws its bar with carriage returns: "#####     12.3%".
        let plain = log.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let pieces = plain.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        for piece in pieces {
            if piece.contains("Checksum verified") || piece.contains("no checksum file") { step = .verifying }
            if piece.contains("Quitting the running Vibex") || piece.contains("Installing to") { step = .installing }
            if piece.contains("%"), let number = piece.split(separator: " ").last?.dropLast(), let percent = Double(number) { fraction = percent / 100 }
            if let range = piece.range(of: "error:", options: .caseInsensitive) {
                failure = piece[range.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
    }
}
