import AppKit
import Foundation
import Testing
@testable import Vibex

@Suite struct ClaudeHooksTests {
    let userHooks: [String: Any] = [
        "theme": "dark",
        "hooks": [
            "Stop": [["hooks": [["type": "command", "command": "afplay done.mp3", "async": true]]]],
            "PreToolUse": [["matcher": "*", "hooks": [["type": "command", "command": "node log.js"]]]],
        ],
    ]

    @Test func `adds every event and keeps the user's own hooks`() throws {
        let settings = ClaudeHooks.installed(into: userHooks)
        #expect(ClaudeHooks.isInstalled(in: settings))
        #expect(settings["theme"] as? String == "dark")
        let hooks = try #require(settings["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stop.count == 2)
        #expect((stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String == "afplay done.mp3")
        #expect((hooks["PreToolUse"] as? [[String: Any]])?.count == 1)
        let permission = try #require((hooks["PermissionRequest"] as? [[String: Any]])?.first)
        #expect(permission["matcher"] as? String == "*")
        #expect((permission["hooks"] as? [[String: Any]])?.first?["async"] as? Bool == true)
    }

    @Test func `installing twice doesn't duplicate, and removing restores the original`() throws {
        let twice = ClaudeHooks.installed(into: ClaudeHooks.installed(into: userHooks))
        let hooks = try #require(twice["hooks"] as? [String: Any])
        #expect((hooks["Stop"] as? [[String: Any]])?.count == 2)
        let removed = ClaudeHooks.removed(from: twice)
        #expect(!ClaudeHooks.isInstalled(in: removed))
        let left = try #require(removed["hooks"] as? [String: Any])
        #expect(Set(left.keys) == ["Stop", "PreToolUse"])
        #expect(ClaudeHooks.removed(from: ClaudeHooks.installed(into: [:]))["hooks"] == nil)
    }

    @Test func `the command does nothing outside Vibex`() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ClaudeHooks.command]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data("{}".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

@MainActor @Suite(.serialized) struct AttentionCenterTests {
    func event(_ json: String) -> AttentionCenter.Event { AttentionCenter.Event.parse(Data(json.utf8))! }

    @Test func `parses what Claude is waiting for`() {
        let permission = event(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test\nnpm run lint"}}"#)
        #expect(permission.waitingMessage?.1 == "Allow Bash: npm test?")
        let mcp = event(#"{"hook_event_name":"PermissionRequest","tool_name":"mcp__vibex__simulator_tap"}"#)
        #expect(mcp.waitingMessage?.1 == "Allow simulator_tap?")
        let question = event(#"{"hook_event_name":"Notification","message":"Claude needs your input"}"#)
        #expect(question.waitingMessage?.0 == .question)
        #expect(event(#"{"hook_event_name":"Stop"}"#).waitingMessage == nil)
        #expect(AttentionCenter.Event.parse(Data(#"{"hook_event_name":"SomethingElse"}"#.utf8)) == nil)
    }

    @Test func `a tab waits until Claude moves on`() {
        let center = AttentionCenter()
        let tab = UUID()
        center.handle(event(#"{"hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"file_path":"App.swift"}}"#), tabID: tab, windowID: "w1")
        #expect(center.isWaiting(tab: tab))
        #expect(center.count(windowID: "w1") == 1)
        #expect(center.count(windowID: "w2") == 0)
        // The notification Claude Code sends for the same prompt doesn't replace the specific message.
        center.handle(event(#"{"hook_event_name":"Notification","message":"Claude needs your permission"}"#), tabID: tab, windowID: "w1")
        #expect(center.waiting[tab]?.message == "Allow Edit: App.swift?")
        center.handle(event(#"{"hook_event_name":"PostToolUse","tool_name":"Edit"}"#), tabID: tab, windowID: "w1")
        #expect(!center.isWaiting(tab: tab))
    }

    @Test func `closed tabs stop waiting`() {
        let center = AttentionCenter()
        let open = UUID(), closed = UUID()
        for tab in [open, closed] {
            center.handle(event(#"{"hook_event_name":"Notification","message":"?"}"#), tabID: tab, windowID: "w")
        }
        center.forget(tabs: [open], inWindow: "w")
        #expect(center.isWaiting(tab: open))
        #expect(!center.isWaiting(tab: closed))
    }
}

@MainActor @Suite(.serialized) struct HooksEndpointTests {
    @Test func `hooks reach the attention center through the HTTP server`() async throws {
        let port = MCPHTTPServer.freePort(preferring: 5190)
        let tab = UUID()
        let server = try MCPHTTPServer(port: port, token: "secret", handler: { _ in (200, "OK", Data()) }, hookHandler: { request in
            guard let event = AttentionCenter.Event.parse(request.body),
                  let id = request.headers["x-vibex-tab"].flatMap(UUID.init(uuidString:)),
                  let window = request.headers["x-vibex-window"] else { return }
            await MainActor.run { AttentionCenter.shared.handle(event, tabID: id, windowID: window) }
        })
        server.start()
        defer { server.stop(); AttentionCenter.shared.clear(tab) }
        try await Task.sleep(for: .milliseconds(300))

        // Exactly what the installed hook runs, with a terminal tab's environment.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ClaudeHooks.command]
        process.environment = [
            "PATH": "/usr/bin:/bin", "VIBEX_HOOK_URL": "http://127.0.0.1:\(port)/hooks", "VIBEX_MCP_TOKEN": "secret",
            "VIBEX_TAB": tab.uuidString, "VIBEX_WINDOW": "window-1",
        ]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        try await Task.sleep(for: .milliseconds(300))
        #expect(AttentionCenter.shared.waiting[tab]?.message == "Allow Bash: rm -rf build?")
        #expect(AttentionCenter.shared.waiting[tab]?.windowID == "window-1")
    }

    @Test func `a wrong token is refused`() async throws {
        let port = MCPHTTPServer.freePort(preferring: 5195)
        let server = try MCPHTTPServer(port: port, token: "secret", handler: { _ in (200, "OK", Data()) })
        server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(300))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hooks")!)
        request.httpMethod = "POST"
        request.setValue("Bearer nope", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 401)
    }
}
