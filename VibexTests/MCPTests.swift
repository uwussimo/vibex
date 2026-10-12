import CoreGraphics
import Foundation
import Testing
@testable import Vibex

@Suite struct HTTPRequestParserTests {
    @Test func `parses a request split across chunks and keeps the remainder`() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer abc\r\nContent-Length: 5\r\n\r\nhel".utf8))
        #expect(try parser.next() == nil)
        parser.append(Data("lo{\"second\":1".utf8))
        let first = try #require(try parser.next())
        #expect(first.method == "POST")
        #expect(first.path == "/mcp")
        #expect(first.bearerToken == "abc")
        #expect(String(decoding: first.body, as: UTF8.self) == "hello")
        #expect(try parser.next() == nil)
    }

    @Test func `rejects oversized bodies`() {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /mcp HTTP/1.1\r\nContent-Length: 99999999999\r\n\r\n".utf8))
        #expect(throws: HTTPRequestParser.Failure.self) { try parser.next() }
    }
}

@Suite struct JSONRPCTests {
    @Test func `parses requests and notifications`() throws {
        let request = try JSONRPC.parse(Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"x"}}"#.utf8))
        #expect(request.method == "tools/call")
        #expect(request.id as? Int == 7)
        #expect(request.params.string("name") == "x")
        let notification = try JSONRPC.parse(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        #expect(notification.isNotification)
    }

    @Test func `rejects batches and bad versions`() {
        #expect(throws: JSONRPC.Failure.self) { try JSONRPC.parse(Data("[]".utf8)) }
        #expect(throws: JSONRPC.Failure.self) { try JSONRPC.parse(Data(#"{"jsonrpc":"1.0","method":"x"}"#.utf8)) }
        #expect(throws: JSONRPC.Failure.self) { try JSONRPC.parse(Data("nope".utf8)) }
    }

    @Test func `encodes results and errors`() throws {
        let ok = try JSONSerialization.jsonObject(with: JSONRPC.response(id: 1, result: ["a": 1])) as? [String: Any]
        #expect((ok?["result"] as? [String: Any])?["a"] as? Int == 1)
        let err = try JSONSerialization.jsonObject(with: JSONRPC.errorResponse(id: nil, .methodNotFound("zz"))) as? [String: Any]
        #expect((err?["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(err?["id"] is NSNull)
    }
}

@MainActor
@Suite struct MCPServerTests {
    @Test func `initialize, list and call a tool`() async throws {
        let registry = ToolRegistry()
        registry.register(Tool(name: "echo", description: "echoes", inputSchema: Schema.object(["text": Schema.string("t")], required: ["text"])) { args in
            .text("echo: \(try args.requireString("text"))")
        })
        let server = MCPServer(registry: registry)

        let initialize = await server.handle(body: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"test"}}}"#.utf8))
        #expect(initialize.status == 200)
        let initJSON = try JSONSerialization.jsonObject(with: initialize.body) as? [String: Any]
        #expect(((initJSON?["result"] as? [String: Any])?["protocolVersion"] as? String) == "2025-03-26")

        let notified = await server.handle(body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        #expect(notified.status == 202)

        let list = await server.handle(body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8))
        let listJSON = try JSONSerialization.jsonObject(with: list.body) as? [String: Any]
        let tools = (listJSON?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        #expect(tools?.first?["name"] as? String == "echo")

        let call = await server.handle(body: Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#.utf8))
        let callJSON = try JSONSerialization.jsonObject(with: call.body) as? [String: Any]
        let content = (callJSON?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        #expect(content?.first?["text"] as? String == "echo: hi")

        let missing = await server.handle(body: Data(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#.utf8))
        let missingJSON = try JSONSerialization.jsonObject(with: missing.body) as? [String: Any]
        #expect((missingJSON?["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    @Test func `free port probing prefers 5150`() {
        let port = MCPHTTPServer.freePort(preferring: 5150)
        #expect(port >= 5150 && port < 5250)
    }
}

@Suite struct HIDKeyboardTests {
    @Test func `letters, digits, symbols and named keys map to usages`() {
        #expect(HIDKeyboard.stroke(for: "a") == HIDKeyboard.Stroke(usage: 0x04, shift: false))
        #expect(HIDKeyboard.stroke(for: "Z") == HIDKeyboard.Stroke(usage: 0x1D, shift: true))
        #expect(HIDKeyboard.stroke(for: "0") == HIDKeyboard.Stroke(usage: 0x27, shift: false))
        #expect(HIDKeyboard.stroke(for: "!") == HIDKeyboard.Stroke(usage: 0x1E, shift: true))
        #expect(HIDKeyboard.stroke(for: "\n") == HIDKeyboard.Stroke(usage: 0x28, shift: false))
        #expect(HIDKeyboard.stroke(for: "é") == nil)
        #expect(HIDKeyboard.stroke(forKeyName: "Return")?.usage == 0x28)
        #expect(HIDKeyboard.stroke(forKeyName: "ArrowLeft")?.usage == 0x50)
        #expect(HIDKeyboard.stroke(forKeyName: "x")?.usage == 0x1B)
    }
}

@Suite struct AXTreeSerializerTests {
    private func sample() -> AXNode {
        AXNode(role: "AXApplication", label: "Spotlight", value: "", identifier: "", frame: CGRect(x: 0, y: 0, width: 440, height: 956), isEnabled: true, children: [
            AXNode(role: "AXGroup", label: "", value: "", identifier: "", frame: CGRect(x: 0, y: 0, width: 440, height: 956), isEnabled: true, children: [
                AXNode(role: "AXButton", label: "Show More", value: "", identifier: "", frame: CGRect(x: 340, y: 74, width: 80, height: 18), isEnabled: true, children: []),
                AXNode(role: "AXStaticText", label: "Reminders", value: "", identifier: "Identifier:ResultCell", frame: CGRect(x: 33, y: 116, width: 82, height: 95), isEnabled: false, children: []),
            ]),
            AXNode(role: "AXTextField", label: "", value: "Search", identifier: "SpotlightSearchField", frame: CGRect(x: 35, y: 871, width: 370, height: 48), isEnabled: true, children: []),
        ])
    }

    @Test func `serializes with refs, flattening unlabeled groups`() {
        let output = AXTreeSerializer.serialize(sample())
        #expect(output.count == 4)
        #expect(output.text.contains("app \"Spotlight\" [ref=r1]"))
        #expect(output.text.contains("  button \"Show More\" [ref=r2] (340,74 80x18)"))
        #expect(output.text.contains("disabled"))
        #expect(!output.text.contains("group"))
        #expect(output.refs["r4"]?.identifier == "SpotlightSearchField")
        #expect(output.refs["r2"]?.center == CGPoint(x: 380, y: 83))
    }

    @Test func `finds by label, value and identifier`() {
        let tree = sample()
        #expect(AXTreeSerializer.find(in: tree, label: "show", identifier: nil).count == 1)
        #expect(AXTreeSerializer.find(in: tree, label: "search", identifier: nil).first?.role == "AXTextField")
        #expect(AXTreeSerializer.find(in: tree, label: nil, identifier: "resultcell").first?.label == "Reminders")
        #expect(AXTreeSerializer.find(in: tree, label: nil, identifier: nil).isEmpty)
    }

    @Test func `short roles read naturally`() {
        #expect(AXNode.shortRole("AXStaticText") == "text")
        #expect(AXNode.shortRole("AXButton") == "button")
        #expect(AXNode.shortRole("AXSecureTextField") == "textfield")
    }
}

@MainActor
@Suite struct CallerResolverTests {
    // shell 100 → claude 200 → node 300 (port 6000) ; shell 400 → claude 500 (port 7000)
    private let table = ProcessTable(
        children: { pid in [100: [200], 200: [300], 400: [500]][pid] ?? [] },
        localTCPPorts: { pid in [300: [6000, 6001], 500: [7000]][pid] ?? [] }
    )

    @Test func `finds the window whose shell owns the calling process`() {
        let resolver = CallerResolver(processes: table)
        let candidates = [
            CallerResolver.Candidate(windowID: "A", shellPIDs: [100]),
            CallerResolver.Candidate(windowID: "B", shellPIDs: [400]),
        ]
        #expect(resolver.windowID(forClientPort: 6001, among: candidates) == "A")
        #expect(resolver.windowID(forClientPort: 7000, among: candidates) == "B")
        #expect(resolver.windowID(forClientPort: 9999, among: candidates) == nil)
    }

    @Test func `descendants walk the whole tree`() {
        #expect(Set(table.descendants(100)) == [200, 300])
        #expect(table.descendants(300).isEmpty)
    }
}
