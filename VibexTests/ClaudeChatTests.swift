import AppKit
import Foundation
import Testing
@testable import Vibex

@MainActor @Suite struct ClaudeChatTests {
    private func model() -> ClaudeChatModel { ClaudeChatModel(folder: "/tmp", environment: [:]) }

    @Test func `stream lines become events`() {
        #expect(ClaudeEvent.parse(#"{"type":"system","subtype":"init","session_id":"abc","model":"haiku","slash_commands":["review"]}"#)
            == [.started(sessionID: "abc", model: "haiku", slashCommands: ["review"])])
        #expect(ClaudeEvent.parse(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}}"#) == [.textDelta("Hi")])
        #expect(ClaudeEvent.parse(#"{"type":"system","subtype":"status","status":"requesting"}"#).isEmpty)
        #expect(ClaudeEvent.parse("not json").isEmpty)
        // A subagent's steps stay out of the conversation.
        #expect(ClaudeEvent.parse(#"{"type":"assistant","parent_tool_use_id":"t","message":{"content":[{"type":"text","text":"x"}]}}"#).isEmpty)
        #expect(ClaudeEvent.parse(#"{"type":"result","duration_ms":4200,"is_error":false,"result":"Done"}"#) == [.turnEnded(seconds: 4.2, isError: false, message: nil)])
    }

    @Test func `tool calls, results and approvals`() throws {
        let use = ClaudeEvent.parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls","timeout":5}}]}}"#)
        #expect(use == [.toolUse(ClaudeToolUse(id: "t1", name: "Bash", input: ["command": "ls", "timeout": "5"]))])
        let image = Data("png".utf8).base64EncodedString()
        let result = ClaudeEvent.parse(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":[{"type":"text","text":"nope"},{"type":"image","source":{"data":"\#(image)"}}]}]}}"#)
        #expect(result == [.toolResult(ClaudeToolResult(toolUseID: "t1", text: "nope", images: [Data("png".utf8)], isError: true))])

        let events = ClaudeEvent.parse(#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/a"},"permission_suggestions":[{"type":"setMode"}],"tool_use_id":"t2"}}"#)
        guard case let .permission(request) = try #require(events.first) else { Issue.record("not a permission"); return }
        #expect(request.tool.input["file_path"] == "/a")
        let allow = try JSONSerialization.jsonObject(with: Data(ClaudeMessage.allow(requestID: "r1", input: request.rawInput, permissions: request.suggestions).utf8)) as? [String: Any]
        let response = (allow?["response"] as? [String: Any])?["response"] as? [String: Any]
        #expect(response?["behavior"] as? String == "allow")
        #expect((response?["updatedInput"] as? [String: String])?["file_path"] == "/a")
        #expect((response?["updatedPermissions"] as? [Any])?.count == 1)
    }

    @Test func `deltas grow one message and the final text replaces them`() {
        let chat = model()
        chat.apply(.textDelta("Hel"))
        chat.apply(.textDelta("lo"))
        #expect(chat.items.map(\.kind) == [.text("Hello")])
        chat.apply(.text("Hello!"))
        #expect(chat.items.map(\.kind) == [.text("Hello!")])
        // The next block is a new message, and a repeat of the same text isn't.
        chat.apply(.text("Hello!"))
        chat.apply(.textDelta("Next"))
        #expect(chat.items.map(\.kind) == [.text("Hello!"), .text("Next")])
    }

    @Test func `a result lands on its tool, and a turn ending clears approvals`() {
        let chat = model()
        let tool = ClaudeToolUse(id: "t", name: "Read", input: ["file_path": "/a/b.swift"])
        let result = ClaudeToolResult(toolUseID: "t", text: "ok", images: [], isError: false)
        chat.apply(.toolUse(tool))
        chat.apply(.toolResult(result))
        #expect(chat.items.map(\.kind) == [.tool(tool, result)])
        chat.apply(.permission(ClaudePermissionRequest(id: "r", tool: tool, rawInput: Data("{}".utf8), suggestions: nil)))
        #expect(chat.needsAttention)
        chat.apply(.turnEnded(seconds: 2, isError: false, message: nil))
        #expect(!chat.needsAttention && !chat.isBusy)
    }

    @Test func `tool calls read as sentences`() {
        func title(_ name: String, _ input: [String: String]) -> String { ClaudeToolSummary(ClaudeToolUse(id: "", name: name, input: input)).title }
        #expect(title("Read", ["file_path": "/x/App.swift"]) == "Read App.swift")
        #expect(title("Bash", ["command": "ls -la"]) == "ls -la")
        #expect(title("mcp__vibex__simulator_tap_element", [:]) == "Simulator: tap element")
        #expect(title("mcp__clickup__clickup_search", [:]) == "clickup: clickup search")
    }

    @Test func `the command line and transcript path`() {
        let line = ClaudeChatModel.commandLine(resume: "abc", mode: .plan, model: "haiku")
        #expect(line.hasPrefix("exec 'claude' '-p'"))
        #expect(line.contains("'--resume' 'abc'") && line.contains("'--permission-mode' 'plan'") && line.contains("'--model' 'haiku'"))
        #expect(!ClaudeChatModel.commandLine(resume: nil, mode: .ask, model: "").contains("--model"))
        let file = ClaudeTranscript.file(session: "s", folder: "/Users/a/my.app", home: URL(fileURLWithPath: "/h"))
        #expect(file.path == "/h/.claude/projects/-Users-a-my-app/s.jsonl")
    }

    @Test func `a transcript's plumbing isn't shown as something the user typed`() {
        #expect(ClaudeEvent.parse(#"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#).isEmpty)
        #expect(ClaudeEvent.parse(#"{"type":"user","isMeta":true,"message":{"content":"hidden"}}"#).isEmpty)
        #expect(ClaudeEvent.parse(#"{"type":"user","message":{"content":"Fix the bug"}}"#) == [.userText("Fix the bug")])
    }

    @Test func `images go as content blocks and files as paths`() throws {
        let image = ClaudeAttachment.Image(data: Data("png".utf8), mediaType: "image/png")
        let line = ClaudeMessage.user("Look", images: [image])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let content = try #require((object["message"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "text"])
        #expect((content[0]["source"] as? [String: String])?["media_type"] == "image/png")
        #expect(ClaudeChatModel.message("Fix it", files: [URL(fileURLWithPath: "/a/b.log")]) == "Fix it\n\nAttached files:\n- /a/b.log")
        #expect(ClaudeChatModel.message("Fix it", files: []) == "Fix it")
        #expect(ClaudeEvent.parse(#"{"type":"user","message":{"content":[{"type":"image","source":{"data":"\#(image.data.base64EncodedString())"}}]}}"#) == [.userImages([image.data])])
    }

    @Test func `an attachment is an image only if it is one`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let large = folder.appendingPathComponent("wide.png"), small = folder.appendingPathComponent("small.png"), log = folder.appendingPathComponent("run.log")
        try rep.representation(using: .png, properties: [:])?.write(to: large)
        let tiny = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try tiny.representation(using: .png, properties: [:])?.write(to: small)
        try Data("hello".utf8).write(to: log)
        guard case let .image(kept, _) = ClaudeAttachment(url: small).kind else { Issue.record("not an image"); return }
        #expect(kept.mediaType == "image/png")
        guard case let .image(shrunk, _) = ClaudeAttachment(url: large).kind else { Issue.record("not an image"); return }
        #expect(shrunk.mediaType == "image/jpeg")
        #expect(NSBitmapImageRep(data: shrunk.data)?.pixelsWide == 2000)
        #expect(ClaudeAttachment(url: log).kind == .file(log.standardizedFileURL))
    }

    @Test func `a chat's requests read like a hook's`() {
        func request(_ name: String, _ input: [String: String]) -> ClaudePermissionRequest {
            ClaudePermissionRequest(id: "r", tool: ClaudeToolUse(id: "t", name: name, input: input), rawInput: Data(), suggestions: nil)
        }
        #expect(AttentionCenter.Event(chatRequest: request("Bash", ["command": "npm test"])).waitingMessage?.1 == "Allow Bash: npm test?")
        let question = request("AskUserQuestion", ["questions": #"[{"question":"Which color?","options":[]}]"#])
        #expect(AttentionCenter.Event(chatRequest: question).waitingMessage?.1 == "Which color?")
        #expect(AttentionCenter.Event(chatRequest: request("ExitPlanMode", [:])).waitingMessage?.0 == .question)
    }

    @Test func `the latest session in a folder is the one to resume`() async throws {
        let folder = "/tmp/vibex-latest-\(UUID().uuidString)"
        let directory = ClaudeTranscript.file(session: "x", folder: folder).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, name) in ["older", "newer"].enumerated() {
            let file = directory.appendingPathComponent(name + ".jsonl")
            try Data().write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + index))], ofItemAtPath: file.path)
        }
        #expect(await ClaudeTranscript.latestSession(folder: folder) == "newer")
        #expect(await ClaudeTranscript.latestSession(folder: "/tmp/nothing-\(UUID().uuidString)") == nil)
    }
}

@MainActor @Suite struct ClaudeCommandsTests {
    private let commands = [
        ClaudeCommand(name: "compact", summary: "Free up context"),
        ClaudeCommand(name: "model", summary: "Choose a model"),
        ClaudeCommand(name: "clear", summary: "Start over"),
        ClaudeCommand(name: "review-pr", summary: "Review a pull request", argumentHint: "<number>"),
        ClaudeCommand(name: "ux-laws", summary: "Usability heuristics"),
    ]
    private let models = [
        ClaudeModelOption(value: "default", title: "Default (recommended)", summary: "Sonnet 5.5 · Efficient for routine tasks"),
        ClaudeModelOption(value: "opus", title: "Opus 5.5", summary: "For complex work", effortLevels: ["low", "high"]),
        ClaudeModelOption(value: "claude-opus-4-8", title: "Opus 4.8", summary: "Older"),
    ]

    private func rows(_ text: String, sessions: [ClaudeSessionSummary] = [], files: [String] = []) -> [ClaudeSuggestion] {
        ClaudeCompleter.suggestions(for: text, commands: commands, models: models, sessions: sessions, files: files)
    }

    @Test func `the initialize reply gives commands and models with versions`() {
        let reply: [String: Any] = [
            "commands": [
                ["name": "ux-laws", "description": "Apply the laws. Use whenever. (user)", "argumentHint": ""],
                ["name": "__secret", "description": "internal"],
                ["name": "effort", "description": "Set effort", "argumentHint": "<level>"],
            ],
            "models": [["value": "opus", "displayName": "Opus 5.5", "description": "For complex work", "supportedEffortLevels": ["low", "max"]]],
        ]
        let capabilities = ClaudeCapabilities(reply: reply)
        #expect(capabilities.commands.map(\.name) == ["ux-laws", "effort"])
        #expect(capabilities.commands[0].summary == "Apply the laws")
        #expect(capabilities.commands[1].argumentHint == "<level>")
        #expect(capabilities.models == [ClaudeModelOption(value: "opus", title: "Opus 5.5", summary: "For complex work", effortLevels: ["low", "max"])])
    }

    @Test func `slash lists commands, common ones first, and finds them by any part`() {
        let all = rows("/")
        #expect(all.prefix(4).map(\.id) == ["plan", "auto", "agent", "model"])
        #expect(all.contains { $0.id == "ux-laws" })
        #expect(rows("/com").first?.id == "compact")
        #expect(rows("/laws").first?.id == "ux-laws")
        #expect(rows("/heuristics").first?.id == "ux-laws")
    }

    @Test func `return runs a bare command and waits for a required argument`() {
        #expect(rows("/compact").first?.action == .run("/compact"))
        #expect(rows("/review").first?.action == .insert("/review-pr "))
        #expect(rows("/mod").first?.action == .insert("/model "))
        #expect(rows("/compact").first?.completion == "/compact ")
    }

    @Test func `common commands win a shared prefix, and long hints stay out of the row`() {
        let list = [ClaudeCommand(name: "color", summary: "Set the color", argumentHint: "[red|blue|green|yellow|purple]"), ClaudeCommand(name: "compact", summary: "Free up context", argumentHint: "[notes]")]
        let suggestions = ClaudeCompleter.suggestions(for: "/co", commands: list, models: [], sessions: [], files: [])
        #expect(suggestions.map(\.id) == ["compact", "color"])
        #expect(suggestions[0].title == "/compact")
        #expect(suggestions[0].detail == "[notes]  Free up context")
        #expect(suggestions[1].detail == "Set the color")
    }

    @Test func `arguments open their own menus`() {
        #expect(rows("/model ").map(\.title) == ["Default (recommended)", "Opus 5.5", "Opus 4.8"])
        #expect(rows("/model 4.8").first?.action == .run("/model claude-opus-4-8"))
        #expect(rows("/effort h").map(\.action) == [.run("/effort high")])
        let session = ClaudeSessionSummary(id: "s1", title: "Fix the login", date: .now)
        #expect(rows("/resume log", sessions: [session]).first?.action == .run("/resume s1"))
        #expect(rows("/compact now").isEmpty)
        #expect(rows("hello").isEmpty)
    }

    @Test func `at finds files and keeps what was typed`() {
        let suggestions = rows("look at @chat", files: ["README.md", "Vibex/Claude/ClaudeChatView.swift"])
        #expect(suggestions.map(\.title) == ["Vibex/Claude/ClaudeChatView.swift"])
        #expect(suggestions.first?.action == .insert("look at @Vibex/Claude/ClaudeChatView.swift "))
    }

    @Test func `commands Vibex answers itself never reach Claude`() {
        let model = ClaudeChatModel(folder: "/tmp", environment: [:])
        model.send("/plan")
        #expect(model.mode == .plan)
        model.send("/auto")
        #expect(model.mode == .auto)
        model.send("/model opus")
        #expect(model.model == "opus")
        var shown = false
        model.actions.showMCP = { shown = true }
        model.send("/mcp")
        #expect(shown)
        model.send("/color")
        #expect(model.items.last?.kind == .needsTerminal("color"))
        #expect(!model.isBusy)
    }

    @Test func `new events do what they say`() {
        #expect(ClaudeEvent.parse(#"{"type":"conversation_reset","new_conversation_id":"n1","session_id":"o"}"#) == [.conversationReset(sessionID: "n1")])
        #expect(ClaudeEvent.parse(#"{"type":"system","subtype":"status","status":"compacting"}"#) == [.status("compacting")])
        #expect(ClaudeEvent.parse(#"{"type":"control_response","response":{"subtype":"success","request_id":"a","response":{"totalTokens":5,"percentage":62}}}"#) == [.contextUsage(percent: 62)])
        #expect(ClaudeEvent.parse(#"{"type":"control_response","response":{"subtype":"error","request_id":"a","error":"Auto mode is off"}}"#) == [.controlFailed("Auto mode is off")])

        let model = ClaudeChatModel(folder: "/tmp", environment: [:])
        model.apply(.textDelta("Hi"))
        model.apply(.conversationReset(sessionID: "n1"))
        #expect(model.items.isEmpty)
        #expect(model.sessionID == "n1")
        model.apply(.text("/resume isn't available in this environment."))
        #expect(model.items.last?.kind == .needsTerminal("resume"))
    }

    @Test func `quick commands don't claim to have finished work`() {
        let model = ClaudeChatModel(folder: "/tmp", environment: [:])
        model.apply(.text("Set model"))
        model.apply(.turnEnded(seconds: 0.01, isError: false, message: nil))
        #expect(model.items.count == 1)
        model.apply(.turnEnded(seconds: 4, isError: false, message: nil))
        #expect(model.items.last?.kind == .done(seconds: 4))
    }

    @Test func `the command line quotes arguments safely`() {
        let line = ClaudeChatModel.commandLine(binary: "/x/claude", resume: nil, mode: .auto, model: "opus", extra: ["--append-system-prompt", "It's fine"])
        #expect(line.contains("'--permission-mode' 'auto'"))
        #expect(line.contains(#"'It'\''s fine'"#))
    }

    @Test func `transcripts give recent sessions titled by the first question`() async throws {
        let folder = "/tmp/vibex-recent-\(UUID().uuidString)"
        let file = ClaudeTranscript.file(session: "s1", folder: folder)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try #"""
        {"type":"user","message":{"role":"user","content":"/clear"}}
        {"type":"user","message":{"role":"user","content":"Fix the login"}}
        """#.write(to: file, atomically: true, encoding: .utf8)
        #expect(await ClaudeTranscript.recentSessions(folder: folder).map(\.title) == ["Fix the login"])
    }
}
