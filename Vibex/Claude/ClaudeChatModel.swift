import AppKit
import Observation
import os

/// One Claude Code session without a terminal: runs `claude` in stream-json mode and turns what it
/// says into items for `ClaudeChatView`. It's the real Claude Code, so CLAUDE.md, skills, hooks and
/// MCP servers (Vibex's own too) all apply, and a session can be continued with `claude --resume`.
@Observable
final class ClaudeChatModel {
    struct Item: Identifiable, Equatable {
        enum Kind: Equatable {
            case user(String)
            case text(String)
            case tool(ClaudeToolUse, ClaudeToolResult?)
            case notice(String, isError: Bool)
            case done(seconds: Double)
        }

        let id = UUID()
        var kind: Kind
        static func == (a: Item, b: Item) -> Bool { a.id == b.id && a.kind == b.kind }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case ask = "default", acceptEdits, plan

        var id: String { rawValue }
        var title: String {
            switch self {
            case .ask: "Ask before changes"
            case .acceptEdits: "Accept edits"
            case .plan: "Plan first"
            }
        }
    }

    enum Model: String, CaseIterable, Identifiable {
        case automatic = "", opus, sonnet, haiku

        var id: String { rawValue }
        var title: String { self == .automatic ? "Default model" : rawValue.capitalized }
    }

    let folder: String
    private let environment: [String: String]
    private(set) var items: [Item] = []
    private(set) var isBusy = false
    /// Waiting on the user, oldest first.
    private(set) var permissions: [ClaudePermissionRequest] = []
    private(set) var sessionID: String?
    private(set) var slashCommands: [String] = []
    private(set) var title = "Claude"
    private(set) var isLoadingHistory = false
    var mode = Mode.ask {
        didSet { if mode != oldValue { write(ClaudeMessage.control("set_permission_mode", ["mode": mode.rawValue])) } }
    }
    var model = Model.automatic {
        didSet { if model != oldValue { write(ClaudeMessage.control("set_model", ["model": model == .automatic ? "default" : model.rawValue])) } }
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

    init(folder: String, environment: [String: String], resuming session: String? = nil) {
        self.folder = folder
        self.environment = environment
        sessionID = session
        if let session { loadHistory(session) }
    }

    /// For MCP calls to find which window they came from.
    var processID: pid_t? { process?.isRunning == true ? process?.processIdentifier : nil }

    var needsAttention: Bool { !permissions.isEmpty }

    func focusComposer() { focusRequest += 1 }

    // MARK: - Talking to Claude

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if title == "Claude" {
            title = text.count > 28 ? String(text.prefix(27)) + "…" : text
            onChange()
        }
        items.append(Item(kind: .user(text)))
        isBusy = true
        streaming = nil
        if process?.isRunning != true { start() }
        write(ClaudeMessage.user(text))
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
        case let .started(session, _, commands):
            sessionID = session
            slashCommands = commands
            onChange()
        case let .textDelta(text):
            if let streaming, let index = items.firstIndex(where: { $0.id == streaming }), case let .text(current) = items[index].kind {
                items[index].kind = .text(current + text)
            } else {
                let item = Item(kind: .text(text))
                items.append(item)
                streaming = item.id
            }
        case let .text(text):
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
            if title == "Claude" { title = text.count > 28 ? String(text.prefix(27)) + "…" : text }
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
            if isError, let message { items.append(Item(kind: .notice(message, isError: true))) }
            items.append(Item(kind: .done(seconds: seconds)))
            onChange()
        }
    }

    // MARK: - The process

    /// Everything goes in one command for the user's login shell, so Claude's tools get their PATH.
    nonisolated static func commandLine(binary: String = "claude", resume: String?, mode: Mode, model: Model) -> String {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode", mode.rawValue]
        if let resume { arguments += ["--resume", resume] }
        if model != .automatic { arguments += ["--model", model.rawValue] }
        return "exec '\(binary)' " + arguments.map { "'\($0)'" }.joined(separator: " ")
    }

    private func start() {
        let login = TerminalSession.login(directory: folder, environment: environment)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: login.shell)
        process.arguments = ["-l", "-c", Self.commandLine(binary: ClaudeCodeRegistrar.findClaude() ?? "claude", resume: sessionID, mode: mode, model: model)]
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.environment = Dictionary(login.environment.compactMap { pair -> (String, String)? in
            guard let equals = pair.firstIndex(of: "=") else { return nil }
            return (String(pair[..<equals]), String(pair[pair.index(after: equals)...]))
        }, uniquingKeysWith: { $1 })
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
                case .turnEnded, .permission, .permissionCancelled, .started: continue
                default: apply(event)
                }
            }
            streaming = nil
            isLoadingHistory = false
            onChange()
        }
    }
}
