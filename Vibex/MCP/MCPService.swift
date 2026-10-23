import AppKit
import os
import UserNotifications

/// Owns the MCP server for the app's lifetime: port, token, registry, status and Claude Code registration.
@Observable
final class MCPService {
    static let preferredPort: UInt16 = 5150

    private(set) var port: UInt16 = 0
    private(set) var isRunning = false
    private(set) var registration = "Not registered"
    private(set) var lastActivity: Date?

    let registry = ToolRegistry()
    private(set) var token = Defaults.mcpToken
    private var http: MCPHTTPServer?
    private var server: MCPServer?

    var url: String { "http://127.0.0.1:\(port)/mcp" }
    var registrar: ClaudeCodeRegistrar { ClaudeCodeRegistrar(url: url, token: token) }
    var isClientActive: Bool { lastActivity.map { Date().timeIntervalSince($0) < 120 } ?? false }

    /// Picks the port before anything else, so terminal sessions can carry it in their environment.
    /// Always tries 5150 first; a fallback port is never remembered, so the next launch comes back to it.
    func choosePort() {
        port = MCPHTTPServer.freePort(preferring: Self.preferredPort)
        if port != Self.preferredPort { Log.mcp.notice("port \(Self.preferredPort) busy, using \(self.port)") }
        Defaults.mcpPort = Int(port)
    }

    func start() {
        guard http == nil else { return }
        if port == 0 { choosePort() }
        let server = MCPServer(registry: registry)
        server.onActivity = { [weak self] in self?.lastActivity = Date() }
        server.projectLabel = {
            let manager = WindowManager.shared
            guard manager.windows.count > 1, let window = try? manager.toolTarget() else { return nil }
            return "[project: \(window.project.name)]"
        }
        let resolver = CallerResolver()
        server.resolveCaller = { port in
            let candidates = WindowManager.shared.windows.map {
                CallerResolver.Candidate(windowID: $0.session.windowID, shellPIDs: $0.workspace.terminalPane.shellPIDs)
            }
            return resolver.windowID(forClientPort: port, among: candidates)
        }
        self.server = server
        do {
            let http = try MCPHTTPServer(port: port, token: token, handler: { request in
                await server.handle(body: request.body, clientPort: request.clientPort)
            }, hookHandler: { request in
                guard let event = AttentionCenter.Event.parse(request.body),
                      let tab = request.headers["x-vibex-tab"].flatMap(UUID.init(uuidString:)),
                      let window = request.headers["x-vibex-window"] else { return }
                await MainActor.run { AttentionCenter.shared.handle(event, tabID: tab, windowID: window) }
            })
            http.start()
            self.http = http
            isRunning = true
        } catch {
            Log.mcp.error("could not start MCP server: \(error.localizedDescription, privacy: .public)")
            isRunning = false
        }
        Task { await register(force: false) }
        // The MCP tools come with a skill that teaches Claude Code how to use them.
        let removed = Defaults.vibexSkillRemoved
        Task.detached { VibexSkill.installIfNeeded(removedByUser: removed) }
        // Hooks feed the approval inbox: which terminal tab's Claude is waiting for the user.
        let hooksRemoved = Defaults.claudeHooksRemoved
        Task.detached { ClaudeHooks.installIfNeeded(removedByUser: hooksRemoved) }
    }

    func register(force: Bool) async {
        let outcome = await registrar.ensureRegistered(force: force)
        switch outcome {
        case .alreadyRegistered: registration = "Registered with Claude Code"
        case .registered: registration = "Registered with Claude Code"
        case .claudeNotFound: registration = "Claude Code CLI not found"
        case let .failed(message): registration = "Registration failed: \(message)"
        }
        Log.mcp.info("\(self.registration, privacy: .public)")
    }

    func rotateToken() async {
        Defaults.resetMCPToken()
        token = Defaults.mcpToken
        http?.stop()
        http = nil
        isRunning = false
        start()
        await register(force: true)
    }

    func environmentVariables() -> [String: String] {
        ["VIBEX_MCP_URL": url, "VIBEX_MCP_TOKEN": token, "VIBEX_MCP_PORT": String(port), "VIBEX_HOOK_URL": "http://127.0.0.1:\(port)/hooks"]
    }
}
