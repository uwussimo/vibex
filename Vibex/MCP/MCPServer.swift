import Foundation
import os

/// JSON-RPC method dispatch for the MCP protocol. Everything runs on the main actor; the HTTP layer
/// awaits `handle`.
final class MCPServer {
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let serverVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    let registry: ToolRegistry
    private(set) var lastClientActivity: Date?
    private(set) var clientName: String?
    var onActivity: () -> Void = {}
    /// Maps a request's client port to the project window that sent it (nil: unknown caller).
    var resolveCaller: (UInt16) -> String? = { _ in nil }

    init(registry: ToolRegistry) {
        self.registry = registry
    }

    /// Returns the HTTP status and JSON body for one POSTed JSON-RPC message.
    func handle(body: Data, clientPort: UInt16? = nil) async -> (status: Int, reason: String, body: Data) {
        let request: JSONRPC.Request
        do {
            request = try JSONRPC.parse(body)
        } catch let failure as JSONRPC.Failure {
            return (400, "Bad Request", JSONRPC.errorResponse(id: nil, failure))
        } catch {
            return (400, "Bad Request", JSONRPC.errorResponse(id: nil, .parseError))
        }
        lastClientActivity = Date()
        onActivity()
        if request.isNotification {
            Log.mcp.debug("notification \(request.method, privacy: .public)")
            return (202, "Accepted", Data())
        }
        do {
            let caller = clientPort.flatMap(resolveCaller)
            let result = try await ToolCall.$callerWindowID.withValue(caller) { try await dispatch(request) }
            return (200, "OK", JSONRPC.response(id: request.id, result: result))
        } catch let failure as JSONRPC.Failure {
            return (200, "OK", JSONRPC.errorResponse(id: request.id, failure))
        } catch {
            return (200, "OK", JSONRPC.errorResponse(id: request.id, .internalError(error.localizedDescription)))
        }
    }

    private func dispatch(_ request: JSONRPC.Request) async throws -> Any {
        switch request.method {
        case "initialize":
            let requested = request.params.string("protocolVersion") ?? Self.supportedProtocolVersions[0]
            let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
            clientName = (request.params["clientInfo"] as? JSONObject)?.string("name")
            Log.mcp.info("initialize from \(self.clientName ?? "unknown", privacy: .public) (protocol \(version, privacy: .public))")
            return [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "vibex", "version": Self.serverVersion],
                "instructions": MCPInstructions.text,
            ] as JSONObject
        case "ping":
            return [:] as JSONObject
        case "tools/list":
            return ["tools": registry.tools.map(\.listing)] as JSONObject
        case "tools/call":
            let name = try request.params.requireStringOrFailure("name")
            guard let tool = registry.tool(named: name) else { throw JSONRPC.Failure.invalidParams("unknown tool \(name)") }
            let arguments = request.params["arguments"] as? JSONObject ?? [:]
            Log.mcp.info("tool \(name, privacy: .public)")
            do {
                var result = try await withTimeout(seconds: 60) { try await tool.handler(arguments) }
                // With several projects open, say which window acted so the model can tell.
                if WindowManager.shared.windows.count > 1, let window = try? WindowManager.shared.toolTarget() {
                    result.content.insert(.text("[project: \(window.project.name)]"), at: 0)
                }
                return result.json
            } catch {
                // Tool failures are results, not protocol errors, so the model can read them.
                return ToolResult.error("\(name): \(error.localizedDescription)").json
            }
        case "resources/list", "prompts/list":
            return [request.method == "resources/list" ? "resources" : "prompts": [] as [Any]] as JSONObject
        default:
            throw JSONRPC.Failure.methodNotFound(request.method)
        }
    }
}

/// Runs `body` or fails after `seconds`, so a stalled device never hangs a client request.
private func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @MainActor () async throws -> T) async throws -> T {
    let work = Task { @MainActor in try await body() }
    let timer = Task {
        try await Task.sleep(for: .seconds(seconds))
        work.cancel()
    }
    defer { timer.cancel() }
    do {
        return try await work.value
    } catch is CancellationError {
        throw ToolError("timed out after \(Int(seconds))s")
    }
}

private extension Dictionary where Key == String, Value == Any {
    func requireStringOrFailure(_ key: String) throws -> String {
        guard let value = self[key] as? String, !value.isEmpty else { throw JSONRPC.Failure.invalidParams("missing \(key)") }
        return value
    }
}

enum MCPInstructions {
    static let text = """
    Vibex is the workstation this Claude Code session runs in: a terminal, an embedded iOS Simulator and a side browser, all in one window the user is looking at.

    Simulator tools act on the embedded device. Coordinates are in screen points (see simulator_info for the size); simulator_screenshot returns the live screen as an image. Prefer simulator_describe + simulator_tap_element (by label) over raw coordinates when the UI has accessibility labels. After tapping, swiping or typing, call simulator_screenshot or simulator_describe to see the result; actions do not return screenshots themselves.

    Browser tools act on the side browser's tabs. Call browser_snapshot to get a compact tree of the page with element refs like e12, then browser_click / browser_type with that ref. Use browser_screenshot only when layout matters. browser_console and browser_requests show what the page logged. Netflix may be playing on another tab; open your own tab with browser_new_tab instead of navigating the user's.

    Workspace tools change what the user sees: vibex_layout, vibex_focus, vibex_notify (toast) and terminal_run (opens a terminal tab and types a command the user can watch and stop).

    Vibex opens one window per project folder. Calls from Claude Code running in a project's terminal act on that project's window automatically; other callers act on the most recently focused window. With several projects open, results start with [project: name]. vibex_projects lists them.
    """
}
