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
