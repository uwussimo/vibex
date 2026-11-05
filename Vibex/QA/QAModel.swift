import AppKit
import Observation

/// One file in `vibex-qa/flows/`, or what's wrong with it.
nonisolated struct QAFlowEntry: Equatable, Sendable, Identifiable {
    var file: String
    var flow: QAFlow?
    var error: String?
    var id: String { file }
    var name: String { flow?.name ?? (file as NSString).deletingPathExtension }
}

/// The QA tab: flows on disk, the run in progress or the last one, and a Claude chat that writes,
/// runs and explains them. Runs use the Devices grid's simulators, side by side.
@Observable
final class QAModel {
    let project: URL
    let folder: URL
    let chat: ClaudeChatModel
    let matrix: DeviceMatrixModel
    private(set) var flows: [QAFlowEntry] = []
    /// The run in progress, or the last one.
    private(set) var run: QARun?
    private(set) var isRunning = false
    /// What each device is doing right now, by UDID.
    private(set) var liveStep: [String: String] = [:]
    var problem: String?
    /// The result whose steps are open, by its id.
    var selectedResult: String?
    var onSessionChange: (String?) -> Void = { _ in }
    var onAttentionChange: (Bool) -> Void = { _ in }
    /// The app the last iOS Run built, so a run can install it on every device first.
    var lastLaunch: () -> Runner.Launch? = { nil }

    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var fingerprint = ""
    @ObservationIgnored private var runTask: Task<QARun?, Never>?
    /// One per device, so stopping reaches each.
    @ObservationIgnored private var deviceTasks: [Task<Void, Never>] = []

    static let folderName = "vibex-qa"
    var flowsFolder: URL { folder.appendingPathComponent("flows", isDirectory: true) }
    var runsFolder: URL { folder.appendingPathComponent("runs", isDirectory: true) }

    static let welcome = ClaudeChatWelcome(
        title: "Test it like a user would",
        detail: "Claude writes test flows for your app, runs them on several simulators at once, and explains what broke.",
        placeholder: "Ask Claude to test something…",
        starters: [
            ("Write tests for this app's main journeys", .beaker),
            ("Run every test on all devices", .play),
            ("Explore the app and report bugs", .search),
        ],
        showsTerminal: false,
        showsRecent: false
    )

    init(project: URL, environment: [String: String], resuming session: String?, matrix: DeviceMatrixModel) {
        self.project = project
        self.matrix = matrix
        folder = project.appendingPathComponent(Self.folderName, isDirectory: true)
        chat = ClaudeChatModel(folder: project.path, environment: environment, resuming: session, name: "QA")
        chat.extraArguments = Self.claudeArguments
        // Testing writes only its own folder freely. Fixing the app asks first, like any chat.
        chat.mode = .ask
        chat.onChange = { [weak self] in
            guard let self else { return }
            onSessionChange(chat.sessionID)
            onAttentionChange(chat.needsAttention)
        }
        reload()
        run = Self.lastRun(in: runsFolder)
    }

    static var brief: String {
        Bundle.main.url(forResource: "QABrief", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    private static var claudeArguments: [String] {
        ["--append-system-prompt", brief, "--allowedTools",
         "Write(./\(folderName)/**)", "Edit(./\(folderName)/**)",
         "mcp__vibex__qa_devices", "mcp__vibex__qa_run", "mcp__vibex__qa_try",
         "mcp__vibex__vibex_run", "mcp__vibex__vibex_run_status", "mcp__vibex__simulator_logs"]
    }

    // MARK: Flows

    func start() {
        guard watcher == nil else { return }
        reload()
        watcher = FileWatcher(path: project.path, latency: 0.3) { [weak self] in self?.reloadIfChanged() }
        Task { await matrix.refresh() }
    }

    func stop() {
        watcher = nil
        runTask?.cancel()
        chat.terminate()
    }

    func reload() {
        fingerprint = Self.fingerprint(flowsFolder)
        let files = ((try? FileManager.default.contentsOfDirectory(at: flowsFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let loaded = files.map { url -> QAFlowEntry in
            let file = url.lastPathComponent
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return QAFlowEntry(file: file, error: "Couldn't read the file.") }
            do {
                return QAFlowEntry(file: file, flow: try QAFlowParser.parse(text, file: file))
            } catch {
                return QAFlowEntry(file: file, error: error.localizedDescription)
            }
        }
        if loaded != flows { flows = loaded }
    }

    private func reloadIfChanged() {
        if Self.fingerprint(flowsFolder) != fingerprint { reload() }
    }

    nonisolated static func fingerprint(_ folder: URL) -> String {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).map(\.path).sorted().map { path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return "\(path)|\(attributes?[.size] as? Int ?? 0)|\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "\n")
    }

    // MARK: Running

    var devices: [SimDevice] { matrix.shown }

    /// Every flow, or those named, on every device in the grid, or those named. Devices run side by
    /// side; on each, flows run one after another.
    @discardableResult
    func runFlows(_ names: [String]? = nil, on deviceNames: [String]? = nil) async -> QARun? {
        guard !isRunning else { return nil }
        let task = Task { await performRun(names, deviceNames) }
        runTask = task
        return await task.value
    }

    func stopRun() {
        runTask?.cancel()
        deviceTasks.forEach { $0.cancel() }
    }

    private func performRun(_ names: [String]?, _ deviceNames: [String]?) async -> QARun? {
        problem = nil
        reload()
        let wanted = names.map { list in Set(list.map { $0.lowercased() }) }
        let chosen = flows.compactMap(\.flow).filter { flow in
            wanted.map { $0.contains(flow.file.lowercased()) || $0.contains(flow.name.lowercased()) || $0.contains((flow.file as NSString).deletingPathExtension.lowercased()) } ?? true
        }
        guard !chosen.isEmpty else {
            problem = flows.isEmpty ? "There are no flows yet. Ask Claude to write some." : "No flow matches \(names?.joined(separator: ", ") ?? "")."
            return nil
        }
        await matrix.refresh()
        let targets = devices.filter { device in
            deviceNames.map { list in list.contains { device.udid == $0 || device.name.localizedCaseInsensitiveContains($0) } } ?? true
        }
        guard !targets.isEmpty else {
            problem = devices.isEmpty ? "Add devices to the Devices grid to run tests on." : "No device in the grid matches \(deviceNames?.joined(separator: ", ") ?? "")."
            return nil
        }
        isRunning = true
        defer {
            isRunning = false
            liveStep = [:]
        }
        let id = Self.runID(Date.now)
        let output = runsFolder.appendingPathComponent(id, isDirectory: true)
        run = QARun(id: id, date: .now, results: chosen.flatMap { flow in
            targets.map { QAFlowResult(flow: flow.file, flowName: flow.name, device: $0.udid, deviceName: $0.name, status: .waiting) }
        })
        selectedResult = nil
        let launch = lastLaunch()
        deviceTasks = targets.map { target in
            Task { [weak self] in await self?.run(chosen, on: target, output: output, install: launch) }
        }
        for task in deviceTasks { await task.value }
        let wasStopped = deviceTasks.contains { $0.isCancelled }
        deviceTasks = []
        if wasStopped || Task.isCancelled, var current = run {
            for index in current.results.indices where [.waiting, .running].contains(current.results[index].status) {
                current.results[index].status = .skipped
            }
            run = current
        }
        run?.isFinished = true
        if let run { save(run, to: output) }
        return run
    }

    private func run(_ chosen: [QAFlow], on target: SimDevice, output: URL, install launch: Runner.Launch?) async {
        let device: QADevice
        do {
            device = try await ready(target)
        } catch {
            for flow in chosen { update(flow.file, target.udid) { $0.status = .failed; $0.steps = [QAStepResult(index: 1, title: "Start \(target.name)", status: .failed, message: error.localizedDescription)] } }
            return
        }
        if let launch, chosen.contains(where: { $0.appId == launch.bundleID }) {
            liveStep[target.udid] = "Installing \(launch.app.deletingPathExtension().lastPathComponent)…"
            try? await device.simctl.install(target.udid, appPath: launch.app.path)
        }
        let execution = QAExecution(device: device, flows: flowsFolder, output: output)
        for flow in chosen {
            guard !Task.isCancelled else { return }
            update(flow.file, target.udid) { $0.status = .running }
            execution.onStep = { [weak self] step in
                self?.liveStep[target.udid] = step.status == .running ? step.title : nil
                self?.update(flow.file, target.udid) { result in
                    if let index = result.steps.firstIndex(where: { $0.index == step.index }) { result.steps[index] = step } else { result.steps.append(step) }
                }
            }
            let result = await execution.run(flow)
            update(flow.file, target.udid) { $0 = result }
        }
    }

    /// The device booted and its screen reachable, which takes a moment after a fresh boot.
    private func ready(_ target: SimDevice) async throws -> QADevice {
        if !target.isBooted {
            liveStep[target.udid] = "Booting…"
            try await Simctl().boot(target.udid)
        }
        var lastError: Error = QAFailure("\(target.name) didn't start.")
        for _ in 0..<60 {
            do { return try QADevice(udid: target.udid) } catch { lastError = error }
            try await Task.sleep(for: .seconds(1))
        }
        throw lastError
    }

    private func update(_ flow: String, _ device: String, _ change: (inout QAFlowResult) -> Void) {
        guard var current = run, let index = current.results.firstIndex(where: { $0.flow == flow && $0.device == device }) else { return }
        change(&current.results[index])
        run = current
    }

    /// Runs a few steps on one device and says what's on screen afterwards: how Claude explores.
    func tryCommands(_ yaml: String?, appId: String?, on deviceName: String?) async throws -> (result: QAFlowResult, screen: String, jpeg: Data?) {
        await matrix.refresh()
        guard let target = deviceName.map({ name in devices.first { $0.udid == name || $0.name.localizedCaseInsensitiveContains(name) } }) ?? devices.first else {
            throw QAFailure(devices.isEmpty ? "Add devices to the Devices grid first." : "No device in the grid is called \(deviceName ?? "").")
        }
        let flow = try QAFlowParser.parse(yaml ?? "[]", file: "try.yaml")
        let device = try await ready(target)
        let execution = QAExecution(device: device, flows: flowsFolder, output: runsFolder.appendingPathComponent("try", isDirectory: true))
        var tried = flow
        tried.appId = appId ?? flow.appId ?? flows.compactMap(\.flow?.appId).first ?? lastLaunch()?.bundleID
        let result = await execution.run(tried)
        let tree = try await device.tree()
        return (result, AXTreeSerializer.serialize(tree, limit: 200).text, device.jpeg(maxWidth: 900))
    }

    // MARK: History

    private func save(_ run: QARun, to output: URL) {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(run).write(to: output.appendingPathComponent("run.json"))
        // Runs are evidence, not source: they stay out of git, and only the last ten are kept.
        let ignore = folder.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) { try? "runs/\n".write(to: ignore, atomically: true, encoding: .utf8) }
        let all = ((try? FileManager.default.contentsOfDirectory(at: runsFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != "try" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(10) { try? FileManager.default.removeItem(at: old) }
    }

    static func lastRun(in folder: URL) -> QARun? {
        let all = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != "try" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return all.lazy.compactMap { try? decoder.decode(QARun.self, from: Data(contentsOf: $0.appendingPathComponent("run.json"))) }.first
    }

    nonisolated static func runID(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }

    func screenshot(_ name: String?) -> URL? {
        guard let name, let run else { return nil }
        return runsFolder.appendingPathComponent(run.id).appendingPathComponent(name)
    }

    func result(for flow: String, device: String) -> QAFlowResult? {
        run?.results.first { $0.flow == flow && $0.device == device }
    }

    /// Hands a failure to Claude, with where to look.
    func diagnose(_ result: QAFlowResult) {
        guard let failure = result.failure else { return }
        let shot = screenshot(failure.screenshot).map { " Its screen after the step is \($0.path)." } ?? ""
        chat.send("The flow \(result.flow) failed on \(result.deviceName) at step \(failure.index), \"\(failure.title)\": \(failure.message ?? "no message").\(shot) Find out why. Use qa_try to look at the app on that device. Tell me whether the test or the app is wrong, and propose the fix.")
    }
}
