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
        #expect(DesignActivity.working(tool("Write", "\(root)/design.json")) == "Building the UI kit…")
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

@Suite struct DesignKitFormatTests {
    private let button: [String: Any] = [
        "type": "button", "text": "{{label}}", "radius": "$md", "fill": "$primary", "props": ["label": "Continue"],
        "variants": ["ghost": ["fill": "clear", "variant": "ghost"], "disabled": ["opacity": 0.4]],
    ]
    private let card: [String: Any] = [
        "type": "column", "padding": "$md", "children": [["type": "text", "text": "{{title}}"], ["type": "Button"]], "props": ["title": "Card"],
    ]
    private let scales = DesignScales(radii: ["md": 12], spacing: ["md": 16])
    private func node(_ raw: [String: Any]) -> DesignNode {
        DesignNode(raw, components: ["Button": button, "Card": card], scales: scales)
    }

    @Test func `props fill a component and number tokens resolve`() {
        #expect(node(["type": "Button"]).text == "Continue")
        let used = node(["type": "Button", "props": ["label": "Buy"]])
        #expect(used.text == "Buy")
        #expect(used.radius == 12)
        #expect(used.radiusToken == "md")
        #expect(node(["type": "Card"]).padding?.top == 16)
    }

    @Test func `a variant sits between the component and the element`() {
        let ghost = node(["type": "Button", "variant": "ghost"])
        #expect(ghost.activeVariant == "ghost")
        #expect(ghost.variant == "ghost")
        #expect(ghost.fill == .color("clear"))
        #expect(ghost.variantNames == ["disabled", "ghost"])
        let disabled = node(["type": "Button", "variant": "disabled", "opacity": 0.9])
        #expect(disabled.opacity == 0.9)
        // A kit variant isn't mistaken for one of the built-in button's looks.
        #expect(disabled.variant == nil)
    }

    @Test func `an element knows where it came from`() throws {
        let screen = node(["type": "column", "children": [
            ["type": "text", "text": "Plain"],
            ["type": "Card"],
        ]])
        #expect(screen.children[0].main == nil)
        #expect(screen.children[0].instance == nil)
        let used = screen.children[1]
        #expect(used.component == "Card")
        #expect(used.instance == [1])
        #expect(used.main == DesignMainRef(component: "Card", path: []))
        #expect(used.children[0].main == DesignMainRef(component: "Card", path: [0]))
        #expect(used.children[0].instance == [1])
        // A component inside a component answers to its own definition, under the outermost use.
        let inner = used.children[1]
        #expect(inner.component == "Button")
        #expect(inner.main == DesignMainRef(component: "Button", path: []))
        #expect(inner.instance == [1])
        #expect(inner.path == [1, 1])
    }

    @Test func `children given to a use belong to the screen`() {
        let used = node(["type": "column", "children": [["type": "Card", "children": [["type": "text", "text": "Mine"]]]]]).children[0]
        #expect(used.instance == [0])
        #expect(used.children[0].instance == nil)
        #expect(used.children[0].main == nil)
    }

    @Test func `overrides reach one element inside a use`() {
        let used = node(["type": "Card", "overrides": ["0": ["text": "Changed"], "1": ["hidden": true]]])
        #expect(used.children[0].text == "Changed")
        #expect(used.children[1].isHidden)
        #expect(node(["type": "Card"]).children[0].text == "Card")
    }

    @Test func `a kit alone is already a design`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("design-kit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(DesignDocument.load(folder: folder).isEmpty)
        try #"{"components":{"Dot":{"type":"column","aspect":1,"width":"fill"},"Bar":{"type":"row","preview":{"width":1200}}}}"#.write(to: folder.appendingPathComponent("design.json"), atomically: true, encoding: .utf8)
        let document = DesignDocument.load(folder: folder)
        #expect(!document.isEmpty)
        // Kit cards size themselves: a square that fills stays small, and a preview width is obeyed.
        #expect(document.kit.map(\.width) == [1200, 96])
    }

    @Test func `a type nobody knows is reported`() {
        #expect(node(["type": "Nonsense"]).unknownType == "Nonsense")
        #expect(node(["type": "Card"]).unknownType == nil)
    }
}

@Suite struct DesignEditsTests {
    private let screen: [String: Any] = ["name": "Home", "root": ["type": "column", "children": [
        ["type": "text", "text": "Hello"],
        ["type": "Card", "padding": 8, "variant": "big", "overrides": ["0": ["text": "One"]]],
        ["type": "divider"],
    ]]]
    private let manifest: [String: Any] = ["components": ["Card": ["type": "column", "radius": 4, "children": [["type": "text", "text": "Title"], ["type": "button"]], "variants": ["big": ["size": 20]]]]]

    private func children(_ object: [String: Any]) -> [[String: Any]] {
        ((object["root"] as? [String: Any])?["children"] as? [[String: Any]]) ?? []
    }

    @Test func `a screen's own element is edited where it is`() {
        let place = DesignEditPlace.screen(file: "a.json", path: [0])
        let edited = DesignEdits.setting("text", to: "Hi", at: place, in: screen)
        #expect(children(edited)[0]["text"] as? String == "Hi")
        #expect(DesignEdits.value(of: "text", at: place, in: edited) as? String == "Hi")
        #expect(children(DesignEdits.setting("text", to: nil, at: place, in: screen))[0]["text"] == nil)
        // Nothing else moved.
        #expect(children(edited).count == 3)
        #expect(edited["name"] as? String == "Home")
    }

    @Test func `the kit's definition is edited, at any depth`() {
        let root = DesignEdits.setting("radius", to: 9, at: .main(component: "Card", path: []), in: manifest)
        #expect(DesignEdits.value(of: "radius", at: .main(component: "Card", path: []), in: root) as? Int == 9)
        let deep = DesignEdits.setting("text", to: "New", at: .main(component: "Card", path: [0]), in: manifest)
        #expect(DesignEdits.value(of: "text", at: .main(component: "Card", path: [0]), in: deep) as? String == "New")
        let variant = DesignEdits.setting("size", to: 30, at: .variant(component: "Card", variant: "big"), in: manifest)
        #expect(DesignEdits.value(of: "size", at: .variant(component: "Card", variant: "big"), in: variant) as? Int == 30)
    }

    @Test func `an edit on one use stays on that use, and resets`() {
        let rootPlace = DesignEditPlace.override(file: "a.json", instance: [1], relative: [])
        let childPlace = DesignEditPlace.override(file: "a.json", instance: [1], relative: [1])
        var edited = DesignEdits.setting("fill", to: "#FF0000", at: rootPlace, in: screen)
        edited = DesignEdits.setting("text", to: "Buy", at: childPlace, in: edited)
        let card = children(edited)[1]
        #expect(card["fill"] as? String == "#FF0000")
        let overrides = card["overrides"] as? [String: [String: Any]]
        #expect(overrides?["1"]?["text"] as? String == "Buy")
        #expect(overrides?["0"]?["text"] as? String == "One")
        #expect(DesignEdits.isOverridden(at: rootPlace, in: edited))
        #expect(DesignEdits.isOverridden(at: childPlace, in: edited))

        let child = DesignEdits.resetting(at: childPlace, in: edited)
        #expect((children(child)[1]["overrides"] as? [String: Any])?["1"] == nil)
        let whole = DesignEdits.resetting(at: rootPlace, in: edited)
        // Which component and variant it is, and its other overrides, survive a reset of its own look.
        #expect(children(whole)[1]["type"] as? String == "Card")
        #expect(children(whole)[1]["variant"] as? String == "big")
        #expect(children(whole)[1]["fill"] == nil)
        #expect(children(whole)[1]["padding"] == nil)
        #expect(children(whole)[1]["overrides"] != nil)
    }

    @Test func `the last override removed leaves no empty overrides behind`() {
        let place = DesignEditPlace.override(file: "a.json", instance: [1], relative: [0])
        let edited = DesignEdits.setting("text", to: nil, at: place, in: screen)
        #expect(children(edited)[1]["overrides"] == nil)
    }

    @Test func `structure changes where it's owned`() throws {
        let second = DesignEditPlace.screen(file: "a.json", path: [1])
        let copied = try #require(DesignEdits.duplicating(second, in: screen))
        #expect(children(copied).map { $0["type"] as? String } == ["text", "Card", "Card", "divider"])
        let removed = try #require(DesignEdits.removing(second, in: screen))
        #expect(children(removed).map { $0["type"] as? String } == ["text", "divider"])
        let moved = try #require(DesignEdits.moving(.screen(file: "a.json", path: [0]), to: 2, in: screen))
        #expect(children(moved).map { $0["type"] as? String } == ["Card", "divider", "text"])
        // The screen's root can't be removed, and a use's insides are the kit's to change.
        #expect(DesignEdits.removing(.screen(file: "a.json", path: []), in: screen) == nil)
        #expect(DesignEdits.removing(.override(file: "a.json", instance: [1], relative: [0]), in: screen) == nil)
        let kit = try #require(DesignEdits.removing(.main(component: "Card", path: [1]), in: manifest))
        let card = (kit["components"] as? [String: [String: Any]])?["Card"]
        #expect((card?["children"] as? [Any])?.count == 1)
    }

    @Test func `the older items key keeps working`() {
        let older: [String: Any] = ["root": ["type": "row", "items": [["type": "text", "text": "A"]]]]
        let edited = DesignEdits.setting("text", to: "B", at: .screen(file: "a.json", path: [0]), in: older)
        #expect(DesignEdits.value(of: "text", at: .screen(file: "a.json", path: [0]), in: edited) as? String == "B")
        #expect((edited["root"] as? [String: Any])?["children"] == nil)
    }
}

/// Hand edits, against real files, through the same calls the panels make.
@MainActor @Suite struct DesignEditorTests {
    private func model() throws -> (DesignModel, URL) {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("design-edit-\(UUID().uuidString)")
        let screens = project.appendingPathComponent("vibex-design/screens")
        try FileManager.default.createDirectory(at: screens, withIntermediateDirectories: true)
        let manifest = ##"{"tokens":{"primary":"#112233","radii":{"md":12}},"styles":{"title":{"size":30}},"components":{"Button":{"type":"button","text":"{{label}}","radius":"$md","props":{"label":"Go"},"variants":{"quiet":{"opacity":0.5}}},"Row":{"type":"row","children":[{"type":"text","text":"Name"},{"type":"Button"}]}}}"##
        try manifest.write(to: project.appendingPathComponent("vibex-design/design.json"), atomically: true, encoding: .utf8)
        let one = #"{"name":"One","root":{"type":"column","children":[{"type":"text","text":"Hello"},{"type":"Button"},{"type":"Row"},{"type":"divider"}]}}"#
        try one.write(to: screens.appendingPathComponent("01-one.json"), atomically: true, encoding: .utf8)
        let two = #"{"name":"Two","root":{"type":"column","children":[{"type":"Button"}]}}"#
        try two.write(to: screens.appendingPathComponent("02-two.json"), atomically: true, encoding: .utf8)
        let design = DesignModel(project: project, environment: [:], resuming: nil)
        design.reload()
        return (design, project)
    }

    private func node(_ design: DesignModel, _ screen: String, _ path: [Int]) -> DesignNode? {
        design.root(of: screen)?.node(at: path)
    }

    @Test func `the kit is on the document and counts its uses`() throws {
        let (design, project) = try model()
        defer { try? FileManager.default.removeItem(at: project) }
        #expect(design.document.kit.map(\.name) == ["Button", "Row"])
        #expect(design.document.kit[0].variants.map(\.name) == ["quiet"])
        // Twice on screens directly, and once inside Row.
        #expect(design.document.uses(of: "Button") == 3)
        #expect(design.document.typeScale.map(\.name) == ["title"])
        #expect(design.document.scales.radii["md"] == 12)
    }

    @Test func `text stays on one use, and style reaches them all`() throws {
        let (design, project) = try model()
        defer { try? FileManager.default.removeItem(at: project) }
        design.select(element: [1], in: "01-one.json")
        let button = try #require(design.selectedNode)
        #expect(design.isUseOfKit)

        design.set("text", to: "Buy", on: button, isContent: true)
        #expect(node(design, "01-one.json", [1])?.text == "Buy")
        #expect(node(design, "02-two.json", [0])?.text == "Go")
        #expect(design.isOverridden(try #require(design.selectedNode)))

        design.set("fill", to: "#FF0000", on: try #require(design.selectedNode))
        #expect(node(design, "01-one.json", [1])?.fill == .color("#FF0000"))
        #expect(node(design, "02-two.json", [0])?.fill == .color("#FF0000"))
        #expect(node(design, "01-one.json", [2, 1])?.fill == .color("#FF0000"))

        design.styleOnlyHere = true
        design.set("radius", to: 2, on: try #require(design.selectedNode))
        #expect(node(design, "01-one.json", [1])?.radius == 2)
        #expect(node(design, "02-two.json", [0])?.radius == 12)

        design.resetToKit(try #require(design.selectedNode))
        #expect(node(design, "01-one.json", [1])?.text == "Go")
        #expect(node(design, "01-one.json", [1])?.radius == 12)
        // The kit's own change stays through a reset.
        #expect(node(design, "01-one.json", [1])?.fill == .color("#FF0000"))
    }

    @Test func `text inside a use stays there too`() throws {
        let (design, project) = try model()
        defer { try? FileManager.default.removeItem(at: project) }
        design.select(element: [2, 0], in: "01-one.json")
        let name = try #require(design.selectedNode)
        design.set("text", to: "Mine", on: name, isContent: true)
        #expect(node(design, "01-one.json", [2, 0])?.text == "Mine")
        #expect(design.document.kit[1].node.children[0].text == "Name")
    }

    @Test func `the kit's card edits the main component, and a variant only itself`() throws {
        let (design, project) = try model()
        defer { try? FileManager.default.removeItem(at: project) }
        design.select(element: [], in: "kit:Button")
        design.set("radius", to: 40, on: try #require(design.selectedNode))
        #expect(node(design, "02-two.json", [0])?.radius == 40)

        design.select(element: [], in: "kit:Button#quiet")
        design.set("opacity", to: 0.2, on: try #require(design.selectedNode))
        #expect(design.document.kit[0].variants[0].node.opacity == 0.2)
        #expect(node(design, "02-two.json", [0])?.opacity == nil)
    }

    @Test func `a use picks its variant`() throws {
        let (design, project) = try model()
        defer { try? FileManager.default.removeItem(at: project) }
        design.select(element: [1], in: "01-one.json")
        design.setVariant("quiet", on: try #require(design.selectedNode))
        #expect(node(design, "01-one.json", [1])?.activeVariant == "quiet")
        #expect(node(design, "01-one.json", [1])?.opacity == 0.5)
        #expect(node(design, "02-two.json", [0])?.activeVariant == nil)
    }

    @Test func `layers change structure only where it's owned`() throws {
        let (design, project) = try model()
        defer { try? FileManager.default.removeItem(at: project) }
        func kinds() -> [String] { design.root(of: "01-one.json")?.children.map(\.layerName) ?? [] }

        design.select(element: [0], in: "01-one.json")
        design.duplicateSelected()
        #expect(kinds() == ["Hello", "Hello", "Button", "Row", "Divider"])
        #expect(design.element == [1])
        design.deleteSelected()
        #expect(kinds() == ["Hello", "Button", "Row", "Divider"])
        #expect(design.element == [])

        design.move(try #require(node(design, "01-one.json", [3])), to: 0)
        #expect(kinds() == ["Divider", "Hello", "Button", "Row"])
        #expect(design.element == [0])

        // Inside a use, the kit decides what's there: this deletes nothing.
        design.select(element: [3, 0], in: "01-one.json")
        design.deleteSelected()
        #expect(node(design, "01-one.json", [3])?.children.count == 2)
        // Hiding is allowed, and only on this use.
        design.setHidden(true, on: try #require(design.selectedNode))
        #expect(node(design, "01-one.json", [3, 0])?.isHidden == true)
        #expect(node(design, "01-one.json", [3])?.visibleChildren.count == 1)
        #expect(design.document.kit[1].node.children[0].isHidden == false)
        // The screen's root stays.
        design.select(element: [], in: "01-one.json")
        design.deleteSelected()
        #expect(design.root(of: "01-one.json") != nil)
    }

    @Test func `undo and redo go through the files, and typing is one step`() throws {
        let (design, project) = try model()
        defer { try? FileManager.default.removeItem(at: project) }
        design.select(element: [0], in: "01-one.json")
        let text = try #require(design.selectedNode)
        design.set("text", to: "H", on: text, isContent: true)
        design.set("text", to: "Hi", on: text, isContent: true)
        design.set("size", to: 40, on: text)
        #expect(design.undoStack.count == 2)
        design.undo()
        #expect(node(design, "01-one.json", [0])?.size == nil)
        #expect(node(design, "01-one.json", [0])?.text == "Hi")
        design.undo()
        #expect(node(design, "01-one.json", [0])?.text == "Hello")
        design.redo()
        #expect(node(design, "01-one.json", [0])?.text == "Hi")
    }

    @Test func `foundations change everything using them`() throws {
        let (design, project) = try model()
        defer { try? FileManager.default.removeItem(at: project) }
        design.setColorToken("primary", to: "#00FF00")
        #expect(design.document.tokens["primary"] == "#00FF00")
        design.setScale("radii", "md", to: 30)
        #expect(node(design, "02-two.json", [0])?.radius == 30)
        design.setFont("serif")
        #expect(design.document.font == "serif")
        design.setTextStyle("title", "size", to: 44.0)
        #expect(design.document.typeScale.first?.size == 44)
    }

    @Test func `a selection that's gone is dropped, and Claude is told what's selected`() throws {
        let (design, project) = try model()
        defer { try? FileManager.default.removeItem(at: project) }
        design.select(element: [3], in: "01-one.json")
        #expect(design.chat.contextLabel == "One › Divider")
        design.select(element: [], in: "kit:Button#quiet")
        #expect(design.chat.contextLabel == "Button")
        let file = project.appendingPathComponent("vibex-design/screens/01-one.json")
        design.select(element: [3], in: "01-one.json")
        try #"{"name":"One","root":{"type":"column","children":[]}}"#.write(to: file, atomically: true, encoding: .utf8)
        design.reload()
        #expect(design.element == nil)
        #expect(design.selection == "01-one.json")
    }

    @Test func `the kit instructions come on top of the original brief`() throws {
        let brief = try #require(Bundle.main.url(forResource: "DesignBrief", withExtension: "md"))
        #expect(try String(contentsOf: brief, encoding: .utf8).contains("You are designing inside Vibex Design"))
        #expect(!(try String(contentsOf: brief, encoding: .utf8).contains("Build a UI kit first")))
        #expect(DesignModel.kitBrief.contains("Build a UI kit first"))
        let design = DesignModel(project: FileManager.default.temporaryDirectory, environment: [:], resuming: nil)
        let line = ClaudeChatModel.commandLine(resume: nil, mode: .auto, model: "", extra: design.chat.extraArguments)
        #expect(line.contains("You are designing inside Vibex Design"))
        #expect(line.contains("Build a UI kit first"))
    }
}

