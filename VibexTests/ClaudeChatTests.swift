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
        let line = ClaudeChatModel.commandLine(resume: "abc", mode: .plan, model: .haiku)
        #expect(line.hasPrefix("exec 'claude' '-p'"))
        #expect(line.contains("'--resume' 'abc'") && line.contains("'--permission-mode' 'plan'") && line.contains("'--model' 'haiku'"))
        #expect(!ClaudeChatModel.commandLine(resume: nil, mode: .ask, model: .automatic).contains("--model"))
        let file = ClaudeTranscript.file(session: "s", folder: "/Users/a/my.app", home: URL(fileURLWithPath: "/h"))
        #expect(file.path == "/h/.claude/projects/-Users-a-my-app/s.jsonl")
    }

    @Test func `a transcript's plumbing isn't shown as something the user typed`() {
        #expect(ClaudeEvent.parse(#"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#).isEmpty)
        #expect(ClaudeEvent.parse(#"{"type":"user","isMeta":true,"message":{"content":"hidden"}}"#).isEmpty)
        #expect(ClaudeEvent.parse(#"{"type":"user","message":{"content":"Fix the bug"}}"#) == [.userText("Fix the bug")])
    }
}
