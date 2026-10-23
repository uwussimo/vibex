import AppKit
import Foundation
import os

/// Runs a project: builds and launches on the window's simulator, starts a dev server and previews it,
/// or just runs a command. Output goes to a "Run" terminal tab; a transcript is kept for MCP.
@Observable
final class Runner {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case building
        case launching
        case serving(URL)
        case running
        case succeeded(String)
        case failed(String)
        case stopped

        var isActive: Bool {
            switch self {
            case .preparing, .building, .launching, .serving, .running: true
            default: false
            }
        }

        /// A spinner beside the label while work is under way.
        var showsProgress: Bool {
            switch self {
            case .preparing, .building, .launching: true
            default: false
            }
        }

        var label: String {
            switch self {
            case .idle: "Run"
            case let .preparing(what): what
            case .building: "Building…"
            case .launching: "Launching…"
            case let .serving(url): url.host().map { "\($0):\(url.port ?? 80)" } ?? "Serving"
            case .running: "Running"
            case let .succeeded(what): what
            case let .failed(why): why
            case .stopped: "Stopped"
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var config: RunConfig?
    private(set) var lastExitCode: Int32?

    private unowned let window: MainWindowController
    private var tabID: UUID?
    private var pollTask: Task<Void, Never>?
    private var previewTabID: UUID?
    private let simctl = Simctl()

    init(window: MainWindowController) {
        self.window = window
    }

    private var project: Project { window.project }
    private var terminal: TerminalPaneViewController { window.workspace.terminalPane }

    var logURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vibex/Logs/\(project.id)-run.log")
    }

    private var derivedData: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vibex/DerivedData/\(project.id)", isDirectory: true)
    }

    /// `.vibex.json` if present, else detected from the folder.
    func resolveConfig() -> RunConfig? {
        RunConfig.load(from: project.url) ?? RunDetector.detect(in: project.url)
    }

    // MARK: - Run / stop

    func run() {
        stop(quietly: true)
        guard let config = resolveConfig() else {
            fail("Nothing to run", detail: "Add a \(RunConfig.fileName) to the project, or use Run → Edit Run Configuration.")
            return
        }
        self.config = config
        lastExitCode = nil
        Log.app.info("run \(config.summary, privacy: .public) in \(self.project.name, privacy: .public)")
        switch config.kind {
        case .ios: Task { await runIOS(config) }
        case .macos: runXcode(config, destination: "platform=macOS")
        case .web: runWeb(config)
        case .command: runCommand(config)
        }
    }

    func stop(quietly: Bool = false) {
        pollTask?.cancel()
        pollTask = nil
        if let tabID, terminal.isRunning(tabID) {
            terminal.terminate(tabID)
            if !quietly { phase = .stopped }
        } else if !quietly, phase.isActive {
            phase = .stopped
        }
    }

    // MARK: - Kinds

    private func runIOS(_ config: RunConfig) async {
        let model = window.workspace.simulatorPane.model
        await model.refresh()
        guard let device = model.selectedDevice else {
            fail("No simulator", detail: "Pick a device in the simulator header first.")
            return
        }
        if !device.isBooted {
            phase = .preparing("Booting \(device.name)…")
            // Boot alongside the build; launching waits for it below.
            Task { await model.bootSelected() }
        }
        runXcode(config, destination: "platform=iOS Simulator,id=\(device.udid)") { [weak self] app in
            await self?.installAndLaunch(app: app, udid: device.udid)
        }
    }

    private func runXcode(_ config: RunConfig, destination: String, launch: ((URL) async -> Void)? = nil) {
        let containerFlag = (config.project ?? "").hasSuffix(".xcworkspace") ? "-workspace" : "-project"
        var steps: [String] = []
        if let prepare = config.prepare { steps.append(prepare) }
        var build = "xcodebuild"
        if let container = config.project { build += " \(containerFlag) \(Self.quote(container))" }
        if let scheme = config.scheme { build += " -scheme \(Self.quote(scheme))" }
        build += " -configuration Debug -destination \(Self.quote(destination)) -derivedDataPath \(Self.quote(derivedData.path)) build"
        steps.append(build)
        let platformFolder = config.kind == .ios ? "Debug-iphonesimulator" : "Debug"
        let products = derivedData.appendingPathComponent("Build/Products/\(platformFolder)", isDirectory: true)
        phase = .building
        startTab(steps.joined(separator: " && ")) { [weak self] code in
            guard let self else { return }
            guard code == 0 else {
                fail("Build failed", detail: "xcodebuild exited with \(code ?? -1). See the Run tab.")
                return
            }
            guard let app = Self.newestApp(in: products, scheme: config.scheme) else {
                fail("No app built", detail: "Could not find a .app in \(products.path).")
                return
            }
            if let launch {
                phase = .launching
                Task { await launch(app) }
            } else {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                succeed("Opened \(app.deletingPathExtension().lastPathComponent)")
            }
        }
    }

    private func installAndLaunch(app: URL, udid: String) async {
        let model = window.workspace.simulatorPane.model
        // Wait (up to a minute) for a boot that started with the build.
        for _ in 0..<60 {
            await model.refresh()
            if model.devices.first(where: { $0.udid == udid })?.isBooted == true { break }
            try? await Task.sleep(for: .seconds(1))
        }
        guard let bundleID = Bundle(url: app)?.bundleIdentifier else {
            fail("No bundle id", detail: "\(app.lastPathComponent) has no CFBundleIdentifier.")
            return
        }
        do {
            try await simctl.install(udid, appPath: app.path)
            _ = try await simctl.launch(udid, bundleID: bundleID, arguments: [])
            succeed("Launched \(app.deletingPathExtension().lastPathComponent)")
        } catch {
            fail("Launch failed", detail: error.localizedDescription)
        }
    }

    private func runWeb(_ config: RunConfig) {
        guard let command = config.command else {
            fail("No command", detail: "Set \"command\" in \(RunConfig.fileName).")
            return
        }
        let url = config.url.flatMap(URL.init(string:)) ?? URL(string: "http://localhost:3000")!
        phase = .running
        startTab(command) { [weak self] code in
            guard let self else { return }
            pollTask?.cancel()
            if case .stopped = phase { return }
            code == 0 ? succeed("Server exited") : fail("Server exited", detail: "\(command) exited with \(code ?? -1).")
        }
        pollTask = Task { [weak self] in
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                if await Self.responds(url) {
                    self?.serverIsUp(url)
                    return
                }
            }
        }
    }

    private func runCommand(_ config: RunConfig) {
        guard let command = config.command else {
            fail("No command", detail: "Set \"command\" in \(RunConfig.fileName).")
            return
        }
        phase = .running
        startTab(command) { [weak self] code in
            guard let self else { return }
            if case .stopped = phase { return }
            code == 0 ? succeed("Finished") : fail("Exited \(code ?? -1)", detail: "\(command) exited with \(code ?? -1).")
        }
    }

    private func serverIsUp(_ url: URL) {
        phase = .serving(url)
        let browser = window.workspace.browserPane
        if let previewTabID, let tab = browser.tab(withID: previewTabID) {
            tab.load(url)
            browser.select(tab.id)
        } else {
            previewTabID = browser.openTab(url: url).id
        }
        window.toast.show(title: "Preview ready", message: url.absoluteString)
    }

    // MARK: - Helpers

    private func startTab(_ command: String, onExit: @escaping (Int32?) -> Void) {
        try? FileManager.default.removeItem(at: logURL)
        tabID = terminal.runProcessTab(
            title: "Run",
            command: command,
            directory: project.path,
            logURL: logURL,
            replacing: tabID
        ) { [weak self] code in
            self?.lastExitCode = code
            onExit(code)
        }
    }

    private func succeed(_ message: String) {
        phase = .succeeded(message)
        window.toast.show(title: message, message: project.name)
    }

    private func fail(_ title: String, detail: String) {
        phase = .failed(title)
        window.toast.show(title: title, message: detail)
        Log.app.error("run failed: \(title, privacy: .public) — \(detail, privacy: .public)")
    }

    /// Last lines of the transcript with terminal escapes removed.
    func outputTail(lines: Int = 60) -> String {
        guard let data = try? Data(contentsOf: logURL) else { return "" }
        let text = Self.stripANSI(String(decoding: data, as: UTF8.self))
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    nonisolated static func stripANSI(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x{1B}\][^\x{07}]*\x{07}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\u{04}", with: "")
            .replacingOccurrences(of: "\u{08}", with: "")
    }

    nonisolated static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The scheme's app if present, else the most recently built .app (test runners excluded).
    nonisolated static func newestApp(in folder: URL, scheme: String?) -> URL? {
        let apps = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "app" && !$0.lastPathComponent.contains("-Runner") }
        if let scheme, let match = apps.first(where: { $0.deletingPathExtension().lastPathComponent == scheme }) { return match }
        return apps.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    nonisolated static func responds(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 1)
        request.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else { return false }
        return http.statusCode < 500
    }
}
