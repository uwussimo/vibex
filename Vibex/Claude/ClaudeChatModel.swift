import AppKit
import Observation
import os

/// What a chat asks of the window around it.
struct ClaudeChatActions {
    var openFile: (URL) -> Void = { _ in }
    var openTerminal: () -> Void = {}
    /// Opens a terminal tab and types this, for what only works there.
    var runInTerminal: (String) -> Void = { _ in }
    var newChat: () -> Void = {}
    var resume: (String) -> Void = { _ in }
    var showSkills: () -> Void = {}
    var showMCP: () -> Void = {}
}

/// One Claude Code session without a terminal: runs `claude` in stream-json mode and turns what it
/// says into items for `ClaudeChatView`. It's the real Claude Code, so CLAUDE.md, skills, hooks and
/// MCP servers (Vibex's own too) all apply, and a session can be continued with `claude --resume`.
@Observable
final class ClaudeChatModel {
    struct Item: Identifiable, Equatable {
        enum Kind: Equatable {
            case user(String)
            case attachments(images: [Data], files: [String])
            case text(String)
            case tool(ClaudeToolUse, ClaudeToolResult?)
            case notice(String, isError: Bool)
            /// A command only Claude Code's terminal interface has.
            case needsTerminal(String)
            case done(seconds: Double)
        }

        let id = UUID()
        var kind: Kind
        static func == (a: Item, b: Item) -> Bool { a.id == b.id && a.kind == b.kind }
    }

    /// How much Claude does before asking, in Claude Code's own terms. ⇧⇥ steps through them.
    enum Mode: String, CaseIterable, Identifiable {
        case ask = "default", acceptEdits, plan, auto

        var id: String { rawValue }
        var title: String {
            switch self {
            case .ask: "Ask"
            case .acceptEdits: "Accept edits"
            case .plan: "Plan"
            case .auto: "Auto"
            }
        }
        var summary: String {
            switch self {
            case .ask: "Asks before edits and commands"
            case .acceptEdits: "Edits files freely, asks before commands"
            case .plan: "Reads and proposes a plan, changes nothing"
            case .auto: "Works on its own, stops only for risky actions"
            }
        }
        var next: Mode {
            let all = Self.allCases
            return all[(all.firstIndex(of: self)! + 1) % all.count]
        }
    }

    let folder: String
    let environment: [String: String]
    private(set) var items: [Item] = []
    private(set) var isBusy = false
    /// Waiting on the user, oldest first.
    private(set) var permissions: [ClaudePermissionRequest] = []
    private(set) var sessionID: String?
    private(set) var slashCommands: [String] = []
    /// The model in use right now, as Claude Code reports it.
    private(set) var activeModel: String?
    /// How full the conversation is, once Claude Code has said.
    private(set) var contextPercent: Int?
    /// What Claude Code is busy with beyond thinking, such as compacting.
    private(set) var status: String?
    private(set) var turnStarted: Date?
    /// For /resume and the empty state.
    private(set) var recentSessions: [ClaudeSessionSummary] = []
    /// Extra `claude` arguments, for a chat with a job of its own (Design).
    var extraArguments: [String] = []
    /// Added to what's sent but not to what's shown, such as the screen selected on the canvas.
    var messageContext: () -> String? = { nil }
    var actions = ClaudeChatActions()
    private(set) var title = "Claude"
    private(set) var isLoadingHistory = false
    /// Added to the next message.
    var attachments: [ClaudeAttachment] = []
    /// A fixed tab title (an agent's name) rather than the first thing asked.
    let name: String?
    var mode = Mode.ask {
        didSet { if mode != oldValue { write(ClaudeMessage.control("set_permission_mode", ["mode": mode.rawValue])) } }
    }
    /// What `--model` takes; empty is Claude Code's default.
    var model = "" {
        didSet { if model != oldValue { write(ClaudeMessage.control("set_model", ["model": model.isEmpty ? "default" : model])) } }
    }
    /// Bumped to put the cursor in the composer.
    private(set) var focusRequest = 0
    /// The tab title or waiting state changed.
    var onChange: () -> Void = {}

    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    /// The text item still receiving deltas.
    private var streaming: UUID?
    private var toolItems: [String: UUID] = [:]

    init(folder: String, environment: [String: String], resuming session: String? = nil, name: String? = nil) {
        self.folder = folder
        self.environment = environment
        self.name = name
        sessionID = session
        if let name { title = name }
        if let session { loadHistory(session) }
    }

    /// For MCP calls to find which window they came from.
    var processID: pid_t? { process?.isRunning == true ? process?.processIdentifier : nil }

    var needsAttention: Bool { !permissions.isEmpty }

    func focusComposer() { focusRequest += 1 }

    // MARK: - Talking to Claude

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attached = attachments
        guard !text.isEmpty || !attached.isEmpty else { return }
        if attached.isEmpty, runLocally(text) { return }
        attachments = []
        if title == "Claude" {
            noteTitle(text.isEmpty ? "Attachment" : text)
            onChange()
        }
        var images: [ClaudeAttachment.Image] = []
        var files: [URL] = []
        for attachment in attached {
            switch attachment.kind {
            case let .image(image, _): images.append(image)
            case let .file(url): files.append(url)
            }
        }
        if !attached.isEmpty {
            items.append(Item(kind: .attachments(images: images.map(\.data), files: files.map(\.lastPathComponent))))
        }
        if !text.isEmpty { items.append(Item(kind: .user(text))) }
        streaming = nil
        if process?.isRunning != true { start() }
        isBusy = true
        turnStarted = Date()
        let context = text.hasPrefix("/") ? nil : messageContext()
        write(ClaudeMessage.user(Self.message(context.map { "\($0)\n\n\(text)" } ?? text, files: files), images: images))
    }

    /// Commands Vibex answers itself: the ones about its own controls, and the ones that need a
    /// terminal Claude Code doesn't have here. Returns false for everything Claude Code handles.
    private func runLocally(_ text: String) -> Bool {
        guard text.hasPrefix("/") else { return false }
        let parts = text.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        guard let name = parts.first else { return false }
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        func switchMode(_ new: Mode) {
            mode = new
            if argument.isEmpty {
                items.append(Item(kind: .notice("\(new.title) mode. \(new.summary).", isError: false)))
            } else {
                send(argument)
            }
        }
        switch name {
        case "plan": switchMode(.plan)
        case "auto": switchMode(.auto)
        case "ask": switchMode(.ask)
        case "accept-edits": switchMode(.acceptEdits)
        case "new": actions.newChat()
        case "skills": actions.showSkills()
        case "mcp": actions.showMCP()
        case "help":
            items.append(Item(kind: .notice("Type / for every command and skill, with what each one does. @ adds a file. ⇧⇥ changes the mode.", isError: false)))
        case "resume":
            if argument.isEmpty {
                items.append(Item(kind: .notice("Type /resume and a space to pick a conversation.", isError: false)))
            } else {
                actions.resume(argument)
            }
        case "model":
            if argument.isEmpty {
                items.append(Item(kind: .notice("Using \(modelTitle). Type /model and a space to pick another.", isError: false)))
            } else {
                let option = capabilities.models.first { $0.value == argument || $0.title.lowercased() == argument.lowercased() }
                model = option?.value == "default" ? "" : option?.value ?? argument
                items.append(Item(kind: .notice("Using \(modelTitle).", isError: false)))
            }
        default:
            guard terminalCommands.contains(name) else { return false }
            items.append(Item(kind: .needsTerminal(name)))
        }
        return true
    }

    /// Claude Code's commands for its terminal interface, which do nothing in this mode.
    private var terminalCommands: Set<String> = ["color", "focus", "reload-plugins"]

    var capabilities: ClaudeCapabilities { ClaudeCatalog.shared.capabilities(folder: folder) }

    /// "Opus 5.5", or the default model by the name Claude Code gives it now.
    var modelTitle: String {
        if model.isEmpty {
            guard let option = capabilities.models.first(where: { $0.value == "default" }) else { return "Default model" }
            return option.summary.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? option.title
        }
        return capabilities.models.first { $0.value == model }?.title ?? model
    }

    func loadRecentSessions() {
        let folder = folder
        Task { [weak self] in
            let sessions = await ClaudeTranscript.recentSessions(folder: folder)
            self?.recentSessions = sessions.filter { $0.id != self?.sessionID }
        }
    }

    /// Files reach Claude as paths, which it reads with its own tools.
    nonisolated static func message(_ text: String, files: [URL]) -> String {
        guard !files.isEmpty else { return text }
        let list = files.map { "- \($0.path)" }.joined(separator: "\n")
        return (text.isEmpty ? "" : text + "\n\n") + "Attached files:\n" + list
    }

    private func noteTitle(_ text: String) {
        title = text.count > 28 ? String(text.prefix(27)) + "…" : text
    }

    func stopTurn() { write(ClaudeMessage.control("interrupt")) }

    func allow(_ request: ClaudePermissionRequest, always: Bool = false) {
        answered(request, ClaudeMessage.allow(requestID: request.id, input: request.rawInput, permissions: always ? request.suggestions : nil))
    }

    func deny(_ request: ClaudePermissionRequest) {
        answered(request, ClaudeMessage.deny(requestID: request.id, message: "The user said no. Ask what they'd like instead."))
    }

    func answer(_ request: ClaudePermissionRequest, answers: [String: String]) {
        items.append(Item(kind: .user(answers.values.sorted().joined(separator: ", "))))
        answered(request, ClaudeMessage.answer(requestID: request.id, input: request.rawInput, answers: answers))
    }

    private func answered(_ request: ClaudePermissionRequest, _ line: String) {
        permissions.removeAll { $0.id == request.id }
        write(line)
        onChange()
    }

    func terminate() {
        reader?.cancel()
        process?.terminate()
        process = nil
        input = nil
    }

    // MARK: - Applying events

    func apply(_ event: ClaudeEvent) {
        switch event {
        case let .started(session, model, commands):
            sessionID = session
            slashCommands = commands
            activeModel = model
            onChange()
        case let .conversationReset(session):
            sessionID = session
            items = []
            toolItems = [:]
            streaming = nil
            contextPercent = nil
            if name == nil { title = "Claude" }
            onChange()
        case let .status(status):
            self.status = status
        case .compacted:
            items.append(Item(kind: .notice("Compacted the conversation.", isError: false)))
        case let .commandsChanged(commands):
            ClaudeCatalog.shared.update(folder: folder, commands: commands)
        case let .contextUsage(percent):
            contextPercent = percent
        case let .controlFailed(message):
            items.append(Item(kind: .notice(message, isError: true)))
        case let .textDelta(text):
            if let streaming, let index = items.firstIndex(where: { $0.id == streaming }), case let .text(current) = items[index].kind {
                items[index].kind = .text(current + text)
            } else {
                let item = Item(kind: .text(text))
                items.append(item)
                streaming = item.id
            }
        case let .text(text):
            if let command = Self.terminalOnlyCommand(text) {
                terminalCommands.insert(command)
                items.append(Item(kind: .needsTerminal(command)))
                return
            }
            if let streaming, let index = items.firstIndex(where: { $0.id == streaming }) {
                items[index].kind = .text(text)
            } else if items.last?.kind != .text(text) {
                items.append(Item(kind: .text(text)))
            }
            streaming = nil
        case let .toolUse(tool):
            streaming = nil
            // These are the user's turn, not work: the question card or plan card stands in for them.
            if tool.name == "AskUserQuestion" || tool.name == "ExitPlanMode" { return }
            if let id = toolItems[tool.id], let index = items.firstIndex(where: { $0.id == id }) {
                items[index].kind = .tool(tool, nil)
            } else {
                let item = Item(kind: .tool(tool, nil))
                toolItems[tool.id] = item.id
                items.append(item)
            }
        case let .toolResult(result):
            guard let id = toolItems[result.toolUseID], let index = items.firstIndex(where: { $0.id == id }),
                  case let .tool(tool, _) = items[index].kind else { return }
            items[index].kind = .tool(tool, result)
        case let .userText(text):
            if items.last?.kind != .user(text) { items.append(Item(kind: .user(text))) }
            if title == "Claude" { noteTitle(text) }
        case let .userImages(images):
            items.append(Item(kind: .attachments(images: images, files: [])))
        case let .permission(request):
            permissions.append(request)
            onChange()
            NSApp.requestUserAttention(.informationalRequest)
        case let .permissionCancelled(id):
            permissions.removeAll { $0.id == id }
            onChange()
        case let .turnEnded(seconds, isError, message):
            streaming = nil
            isBusy = false
            permissions = []
            status = nil
            turnStarted = nil
            if isError, let message { items.append(Item(kind: .notice(message, isError: true))) }
            // Commands answer at once; only real work is worth a line about how long it took.
            if seconds >= 1, !items.isEmpty { items.append(Item(kind: .done(seconds: seconds))) }
            onChange()
            write(ClaudeMessage.control("get_context_usage"))
        }
    }

    // MARK: - The process

    /// "/resume isn't available in this environment." → "resume"
    nonisolated static func terminalOnlyCommand(_ text: String) -> String? {
        guard text.hasPrefix("/"), text.hasSuffix("isn't available in this environment."), let word = text.dropFirst().split(separator: " ").first else { return nil }
        return String(word)
    }

    /// Everything goes in one command for the user's login shell, so Claude's tools get their PATH.
    nonisolated static func commandLine(binary: String = "claude", resume: String?, mode: Mode, model: String, extra: [String] = []) -> String {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode", mode.rawValue]
        if let resume { arguments += ["--resume", resume] }
        if !model.isEmpty { arguments += ["--model", model] }
        return "exec " + ([binary] + arguments + extra).map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " ")
    }

    /// `claude` in the user's login shell, in `folder`, not yet started.
    static func process(folder: String, environment: [String: String], command: String) -> Process {
        let login = TerminalSession.login(directory: folder, environment: environment)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: login.shell)
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.environment = Dictionary(login.environment.compactMap { pair -> (String, String)? in
            guard let equals = pair.firstIndex(of: "=") else { return nil }
            return (String(pair[..<equals]), String(pair[pair.index(after: equals)...]))
        }, uniquingKeysWith: { $1 })
        return process
    }

    private func start() {
        let process = Self.process(folder: folder, environment: environment, command: Self.commandLine(
            binary: ClaudeCodeRegistrar.findClaude() ?? "claude", resume: sessionID, mode: mode, model: model, extra: extraArguments))
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            fail("Couldn't start Claude Code: \(error.localizedDescription)")
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        let output = stdout.fileHandleForReading, errors = stderr.fileHandleForReading
        reader = Task { [weak self] in
            await Self.read(output) { event in self?.apply(event) }
            let message = await Self.drain(errors)
            self?.ended(process, message: message)
        }
    }

    @concurrent private static func read(_ handle: FileHandle, _ deliver: @MainActor @escaping (ClaudeEvent) -> Void) async {
        do {
            for try await line in handle.bytes.lines {
                for event in ClaudeEvent.parse(line) { await deliver(event) }
            }
        } catch {
            Log.app.error("claude output ended: \(error.localizedDescription, privacy: .public)")
        }
    }

    @concurrent private static func drain(_ handle: FileHandle) async -> String {
        String(decoding: handle.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ended(_ ended: Process, message: String) {
        guard process === ended else { return }
        process = nil
        input = nil
        permissions = []
        onChange()
        guard isBusy else { return }
        // Still mid-turn: it stopped on us. The next message resumes the session.
        isBusy = false
        let notInstalled = message.contains("command not found") || message.contains("Unknown command")
        fail(notInstalled ? "Claude Code isn't installed. Install it from Setup & Permissions." : (message.isEmpty ? "Claude Code stopped unexpectedly." : message))
    }

    private func fail(_ message: String) {
        isBusy = false
        items.append(Item(kind: .notice(message, isError: true)))
    }

    private func write(_ line: String) {
        guard let input else { return }
        do {
            try input.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            Log.app.error("couldn't write to claude: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadHistory(_ session: String) {
        isLoadingHistory = true
        let folder = folder
        Task { [weak self] in
            let events = await ClaudeTranscript.load(session: session, folder: folder)
            guard let self else { return }
            for event in events {
                switch event {
                case .turnEnded, .permission, .permissionCancelled, .started, .status, .contextUsage, .controlFailed, .commandsChanged: continue
                default: apply(event)
                }
            }
            streaming = nil
            isLoadingHistory = false
            onChange()
        }
    }
}
