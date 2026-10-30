import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Vibex

@MainActor @Suite struct DesignTests {
    private func folder(design: String? = nil, screens: [String: String] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-design-\(UUID().uuidString)/\(DesignDocument.folderName)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("screens"), withIntermediateDirectories: true)
        if let design { try design.write(to: root.appendingPathComponent("design.json"), atomically: true, encoding: .utf8) }
        for (name, text) in screens { try text.write(to: root.appendingPathComponent("screens/\(name)"), atomically: true, encoding: .utf8) }
        return root
    }

    private func node(_ json: String, styles: [String: [String: Any]] = [:], components: [String: [String: Any]] = [:]) throws -> DesignNode {
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return DesignNode(object, styles: styles, components: components)
    }

    @Test func `the format forgives other names for the same thing`() throws {
        let view = try node(##"{"type":"VStack","spacing":8,"backgroundColor":"#fff","cornerRadius":12,"children":[{"type":"label","content":"Hi","fontSize":20,"fontWeight":"bold","textColor":"$text"}]}"##)
        #expect(view.kind == .column)
        #expect(view.gap == 8)
        #expect(view.fill == .color("#fff"))
        #expect(view.radius == 12)
        let text = try #require(view.children.first)
        #expect(text.kind == .text)
        #expect(text.text == "Hi")
        #expect(text.size == 20)
        #expect(text.color == "$text")
    }

    @Test func `lengths, insets and paints read every form`() {
        #expect(DesignLength(120) == .points(120))
        #expect(DesignLength("fill") == .fill)
        #expect(DesignLength("auto") == .hug)
        #expect(DesignLength("banana") == nil)
        let two = DesignInsets([12, 16])
        #expect(two?.top == 12 && two?.left == 16)
        #expect(DesignInsets(["x": 4, "top": 2])?.right == 4)
        #expect(DesignPaint(["gradient": ["#000", "#fff"], "angle": 90]) == .gradient(colors: ["#000", "#fff"], angle: 90))
    }

    @Test func `colors parse in every length`() {
        #expect(DesignColor.parse("#fff") == DesignColor.RGBA(red: 1, green: 1, blue: 1, alpha: 1))
        #expect(DesignColor.parse("#00000080")?.alpha == Double(0x80) / 255)
        #expect(DesignColor.parse("clear")?.alpha == 0)
        #expect(DesignColor.parse("tomato") == nil)
    }

    @Test func `styles and components are shared, and what an element says wins`() throws {
        let styles: [String: [String: Any]] = ["title": ["size": 30, "weight": "bold"], "muted": ["color": "$muted"]]
        let components: [String: [String: Any]] = ["Cta": ["type": "button", "text": "Go", "variant": "primary"]]
        let styled = try node(#"{"type":"text","text":"Hi","style":["title","muted"],"weight":"medium"}"#, styles: styles)
        #expect(styled.size == 30)
        #expect(styled.weight == "medium")
        #expect(styled.color == "$muted")
        let used = try node(#"{"type":"Cta","text":"Start"}"#, components: components)
        #expect(used.kind == .button)
        #expect(used.text == "Start")
        #expect(used.variant == "primary")
    }

    @Test func `a component that uses itself stops instead of hanging`() throws {
        let components: [String: [String: Any]] = ["Loop": ["type": "Loop"]]
        _ = try node(#"{"type":"Loop"}"#, components: components)
    }

    @Test func `the folder loads in order, and one bad file stays one bad screen`() throws {
        let root = try folder(
            design: ##"{"name":"Pantry","font":"rounded","tokens":{"primary":"#D9572B"}}"##,
            screens: [
                "02-home.json": #"{"name":"Home","device":"iphone","root":{"type":"column"}}"#,
                "01-welcome-back.json": #"{"device":"desktop","height":"auto","group":"Start","url":"pantry.app","root":{"type":"column"}}"#,
                "03-broken.json": "{ nope",
            ]
        )
        let document = DesignDocument.load(folder: root)
        #expect(document.name == "Pantry")
        #expect(document.tokens["primary"] == "#D9572B")
        #expect(document.screens.map(\.name) == ["Welcome Back", "Home", "Broken"])
        #expect(document.screens[0].device.width == 1440)
        #expect(document.screens[0].device.height == nil)
        #expect(document.screens[1].device.chrome == .phone)
        #expect(document.screens[2].error != nil)
        #expect(document.problems().contains { $0.hasPrefix("03-broken.json") })
    }

    @Test func `problems name unknown tokens and icons`() throws {
        let root = try folder(screens: ["a.json": #"{"root":{"type":"row","fill":"$nope","children":[{"type":"icon","icon":"not.a.symbol"},{"type":"icon","icon":"house.fill","color":"$text"}]}}"#])
        let problems = DesignDocument.load(folder: root).problems()
        #expect(problems.contains { $0.contains("$nope") })
        #expect(problems.contains { $0.contains("not.a.symbol") })
        #expect(!problems.contains { $0.contains("house.fill") })
    }

    @Test func `screens without a group share a row, and groups keep their order`() {
        func screen(_ id: String, _ group: String?) -> DesignScreen { DesignScreen(id: id, name: id, group: group, device: DesignDevice("iphone")) }
        let rows = DesignBoard.rows([screen("a", "Onboarding"), screen("b", "Main"), screen("c", "Onboarding")])
        #expect(rows.map(\.title) == ["Onboarding", "Main"])
        #expect(rows[0].screens.map(\.id) == ["a", "c"])
    }

    @Test func `the canvas zooms around the pointer and fits everything`() {
        let canvas = DesignCanvasModel()
        canvas.viewport = CGSize(width: 1000, height: 800)
        canvas.contentSize = CGSize(width: 4000, height: 1000)
        canvas.fit(animated: false)
        #expect(abs(canvas.zoom - (1000 - 96) / 4000) < 0.001)
        #expect(!canvas.hasMoved)

        let before = canvas.offset, zoom = canvas.zoom
        let anchor = CGPoint(x: 300, y: 200)
        let boardPoint = CGPoint(x: (anchor.x - before.width) / zoom, y: (anchor.y - before.height) / zoom)
        canvas.zoom(by: 2, around: anchor)
        #expect(abs(boardPoint.x * canvas.zoom + canvas.offset.width - anchor.x) < 0.001)
        #expect(abs(boardPoint.y * canvas.zoom + canvas.offset.height - anchor.y) < 0.001)
        #expect(canvas.hasMoved)

        canvas.zoom(by: 1000, around: anchor)
        #expect(canvas.zoom == DesignCanvasModel.zoomRange.upperBound)
    }

    @Test func `writing a file shows up without reading unrelated changes`() throws {
        let root = try folder()
        let model = DesignModel(project: root.deletingLastPathComponent(), environment: [:], resuming: nil)
        #expect(model.document.screens.isEmpty)
        let before = DesignModel.fingerprint(root)
        try #"{"name":"Home","root":{"type":"column"}}"#.write(to: root.appendingPathComponent("screens/home.json"), atomically: true, encoding: .utf8)
        #expect(DesignModel.fingerprint(root) != before)
        model.reload()
        #expect(model.document.screens.map(\.name) == ["Home"])
        model.select("home.json")
        #expect(model.chat.contextLabel == "Home")
        #expect(model.chat.messageContext()?.contains("home.json") == true)
        try FileManager.default.removeItem(at: root.appendingPathComponent("screens/home.json"))
        model.reload()
        #expect(model.selection == nil)
        #expect(model.chat.contextLabel == nil)
    }

    @Test func `a full-bleed picture stays inside its screen`() async throws {
        let root = try folder(screens: ["a.json": #"{"name":"Hero","safeArea":false,"root":{"type":"layer","width":"fill","height":"fill","children":[{"type":"image","src":"wide.png","width":"fill","height":"fill"},{"type":"text","text":"Over the art","place":"bottom","width":"fill"}]}}"#])
        let wide = NSImage(size: NSSize(width: 3000, height: 400), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        try NSBitmapImageRep(data: try #require(wide.tiffRepresentation))?.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("wide.png"))
        let image = try #require(await DesignSnapshot.image(of: DesignDocument.load(folder: root), screen: "Hero", scale: 1))
        #expect(abs(image.size.width - (393 + 20 + 32)) < 1)
    }

    @Test func `a button with a set width paints that width`() throws {
        let view = DesignNodeView(node: try node(#"{"type":"button","text":"Pay","width":300,"height":50}"#), theme: DesignTheme(document: DesignDocument(folder: FileManager.default.temporaryDirectory)))
        let renderer = ImageRenderer(content: view.fixedSize())
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        #expect(bitmap.pixelsWide >= 300)
        // Near the far edge, where a label-sized button wouldn't reach.
        let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide - Int(10 * renderer.scale), y: bitmap.pixelsHigh / 2))
        #expect(color.alphaComponent > 0.9)
    }

    @Test func `a screen renders at its device's size`() async throws {
        let root = try folder(design: ##"{"tokens":{"primary":"#0A84FF"}}"##, screens: [
            "a.json": #"{"name":"Phone","root":{"type":"column","children":[{"type":"text","text":"Hi"},{"type":"button","text":"Go"}]}}"#,
        ])
        let image = try #require(await DesignSnapshot.image(of: DesignDocument.load(folder: root), screen: "Phone", scale: 1))
        // The device, its bezel, and the snapshot's margin.
        #expect(abs(image.size.width - (393 + 20 + 32)) < 1)
        #expect(abs(image.size.height - (852 + 20 + 32)) < 1)
        #expect(try #require(DesignSnapshot.jpeg(image, maxWidth: 200)).count > 100)
    }
}

@MainActor @Suite struct DesignActivityTests {
    private func tool(_ name: String, _ path: String? = nil) -> ClaudeToolUse {
        ClaudeToolUse(id: UUID().uuidString, name: name, input: path.map { ["file_path": $0] } ?? [:])
    }
    private let root = "/p/vibex-design"

    @Test func `design runs on auto, without changing its brief`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("design-auto-\(UUID().uuidString)")
        let model = DesignModel(project: folder, environment: [:], resuming: nil)
        #expect(model.chat.mode == .auto)
        let line = ClaudeChatModel.commandLine(resume: nil, mode: model.chat.mode, model: "", extra: model.chat.extraArguments)
        #expect(line.contains("'--permission-mode' 'auto'"))
        #expect(line.contains("--append-system-prompt"))
        #expect(line.contains("Write(./vibex-design/**)"))
    }

    @Test func `work is described in design's own words`() {
        #expect(DesignActivity.working(nil) == "Thinking…")
        #expect(DesignActivity.working(tool("Write")) == "Drawing…")
        #expect(DesignActivity.working(tool("Write", "\(root)/screens/01-today.json")) == "Drawing Today…")
        #expect(DesignActivity.working(tool("Edit", "\(root)/screens/02-plant-detail.json")) == "Updating Plant Detail…")
        #expect(DesignActivity.working(tool("Write", "\(root)/design.json")) == "Setting the look…")
        #expect(DesignActivity.working(tool("mcp__vibex__design_screenshot")) == "Checking how it looks…")
        #expect(DesignActivity.summary([tool("Read", "/p/a"), tool("Write", "\(root)/design.json"), tool("Write", "\(root)/screens/a.json"), tool("Write", "\(root)/screens/b.json"), tool("Edit", "\(root)/screens/a.json")]) == "Drew 2 screens")
        #expect(DesignActivity.summary([tool("Edit", "\(root)/screens/01-today.json")]) == "Updated Today")
        #expect(DesignActivity.summary([tool("Read", "/p/a")]) == "Read the project")
    }

    @Test func `a turn folds into one line and keeps what Claude says at the end`() {
        typealias Item = ClaudeChatModel.Item
        let items = [Item(kind: .user("Go")), Item(kind: .text("First I'll set the look.")), Item(kind: .tool(tool("Write"), nil)), Item(kind: .text("Now the screen.")), Item(kind: .tool(tool("Write"), nil)), Item(kind: .text("All done.")), Item(kind: .done(seconds: 3)), Item(kind: .user("Again"))]
        let rows = ClaudeChatModel.rows(items, folding: true)
        #expect(rows.count == 5)
        guard case let .activity(work) = rows[1] else { Issue.record("not folded"); return }
        #expect(work.count == 4)
        #expect(rows[2] == .item(items[5]))
        #expect(ClaudeChatModel.rows(items, folding: false).count == items.count)
    }

    @Test func `the file being written can be read before it's finished`() {
        #expect(ClaudeChatModel.filePath(inPartialInput: #"{"file_path":"/a/b.json","con"#) == "/a/b.json")
        #expect(ClaudeChatModel.filePath(inPartialInput: #"{"file_path":"/a/b"#) == nil)
        #expect(ClaudeEvent.parse(#"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"Write"}}}"#) == [.toolStarting("Write")])
        #expect(ClaudeEvent.parse(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{"}}}"#) == [.toolInputDelta("{")])

        let chat = ClaudeChatModel(folder: "/tmp", environment: [:])
        chat.apply(.toolStarting("Write"))
        chat.apply(.toolInputDelta(#"{"file_path":"/x/"#))
        #expect(chat.pendingTool?.input["file_path"] == nil)
        chat.apply(.toolInputDelta(#"y.json","content":"#))
        #expect(chat.pendingTool?.input["file_path"] == "/x/y.json")
        chat.apply(.toolUse(tool("Write", "/x/y.json")))
        #expect(chat.pendingTool == nil)
    }

    @Test func `auto falls back openly when Claude Code starts in another mode`() {
        let chat = ClaudeChatModel(folder: "/tmp", environment: [:])
        chat.mode = .auto
        chat.apply(.permissionMode("auto"))
        #expect(chat.mode == .auto)
        #expect(chat.items.isEmpty)
        chat.apply(.permissionMode("default"))
        #expect(chat.mode == .ask)
        #expect(chat.items.count == 1)
        #expect(ClaudeEvent.parse(#"{"type":"system","subtype":"init","session_id":"s","permissionMode":"auto"}"#).contains(.permissionMode("auto")))
    }

    @Test func `the note about a selected screen stays out of a reloaded chat`() {
        let line = #"{"type":"user","message":{"role":"user","content":"[The user has selected the screen \"Home\" on the canvas: x.json. This message is about it.]\n\nMake it bolder"}}"#
        #expect(ClaudeEvent.parse(line) == [.userText("Make it bolder")])
    }

    @Test func `a design tab comes back with its project`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-restore-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("habits")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(directory: root.appendingPathComponent("state"))
        let project = Project(url: folder)
        var state = ProjectState()
        state.editorTab = "design"
        state.terminalClosed = true
        store.save(state, for: project)
        let controller = MainWindowController(session: ProjectSession(project: project, store: store))
        controller.window?.setFrame(NSRect(x: -6000, y: 200, width: 1500, height: 820), display: false)
        controller.showWindow(nil)
        defer { controller.close() }
        try await Task.sleep(for: .seconds(0.5))
        #expect(controller.workspace.editor.tabs.selected == .design)
    }
}
