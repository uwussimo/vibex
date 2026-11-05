import CoreGraphics
import Foundation
import Testing
@testable import Vibex

@Suite struct QAFlowParserTests {
    @Test func `a Maestro flow reads, config and steps`() throws {
        let flow = try QAFlowParser.parse("""
        appId: com.example.tally
        name: Sign in
        tags: [smoke]
        env:
          EMAIL: me@example.com
        ---
        # Start clean.
        - launchApp:
            clearState: true
        - tapOn: "Sign in"
        - tapOn:
            id: "email"
        - inputText: ${EMAIL}
        - pressKey: Enter
        - longPressOn: Row
        - tapOn:
            text: "Delete"
            index: 1
            optional: true
        - tapOn:
            point: "50%,90%"
        - assertVisible: "Welcome.*"
        - assertNotVisible: Error
        - scrollUntilVisible:
            element: "Settings"
            direction: DOWN
            timeout: 5000
        - swipe: LEFT
        - extendedWaitUntil:
            visible: Done
            timeout: 3000
        - takeScreenshot: home
        - runFlow: 02-other.yaml
        - back
        - scroll
        - eraseText: 3
        - copyTextFrom: Total
        """, file: "01-sign-in.yaml")
        #expect(flow.appId == "com.example.tally")
        #expect(flow.name == "Sign in")
        #expect(flow.tags == ["smoke"])
        #expect(flow.commands == [
            .launchApp(appId: nil, clearState: true),
            .tapOn(QASelector(text: "Sign in"), kind: .tap),
            .tapOn(QASelector(id: "email"), kind: .tap),
            .inputText("me@example.com"),
            .pressKey("Enter"),
            .tapOn(QASelector(text: "Row"), kind: .long),
            .tapOn(QASelector(text: "Delete", index: 1, isOptional: true), kind: .tap),
            .tapOn(QASelector(point: "50%,90%"), kind: .tap),
            .assertVisible(QASelector(text: "Welcome.*")),
            .assertNotVisible(QASelector(text: "Error")),
            .scrollUntilVisible(QASelector(text: "Settings"), direction: .down, timeout: 5),
            .swipe(direction: .left, start: nil, end: nil),
            .extendedWaitUntil(visible: QASelector(text: "Done"), notVisible: nil, timeout: 3),
            .takeScreenshot("home"),
            .runFlow("02-other.yaml"),
            .back,
            .scroll,
            .eraseText(3),
            .unsupported("copyTextFrom"),
        ])
    }

    @Test func `steps alone are a flow too, and broken YAML says so`() throws {
        let steps = try QAFlowParser.parse("- launchApp\n- tapOn: Go\n", file: "try.yaml")
        #expect(steps.commands == [.launchApp(appId: nil, clearState: false), .tapOn(QASelector(text: "Go"), kind: .tap)])
        #expect(steps.name == "try")
        #expect(try QAFlowParser.parse("", file: "empty.yaml").commands.isEmpty)
        #expect(throws: QAFlowParser.Failure.self) { try QAFlowParser.parse("appId: x\n---\ntapOn: [", file: "bad.yaml") }
        #expect(throws: QAFlowParser.Failure.self) { try QAFlowParser.parse("appId: x\n---\nname: not a list", file: "bad.yaml") }
    }

    @Test func `steps read as sentences`() {
        #expect(QACommand.tapOn(QASelector(text: "Sign in"), kind: .tap).title == "Tap “Sign in”")
        #expect(QACommand.assertVisible(QASelector(id: "total")).title == "See #total")
        #expect(QACommand.launchApp(appId: nil, clearState: true).title == "Launch the app fresh")
    }
}

@Suite struct QAMatcherTests {
    private func node(_ label: String, _ frame: CGRect, id: String = "", value: String = "", role: String = "AXButton", _ children: [AXNode] = []) -> AXNode {
        AXNode(role: role, label: label, value: value, identifier: id, frame: frame, isEnabled: true, children: children)
    }
    private let screen = CGSize(width: 390, height: 844)

    private var tree: AXNode {
        node("", CGRect(x: 0, y: 0, width: 390, height: 844), role: "AXApplication", [
            node("Total $12.50", CGRect(x: 20, y: 100, width: 200, height: 20), role: "AXStaticText"),
            node("Delete", CGRect(x: 20, y: 400, width: 80, height: 44)),
            node("Delete", CGRect(x: 20, y: 300, width: 80, height: 44)),
            node("Delete all", CGRect(x: 200, y: 300, width: 120, height: 44)),
            node("Email", CGRect(x: 20, y: 200, width: 350, height: 44), id: "email-field", role: "AXTextField"),
            node("Offscreen", CGRect(x: 20, y: 1200, width: 80, height: 44)),
            node("Price", CGRect(x: 20, y: 500, width: 80, height: 20), value: "$4.50 (each)"),
        ])
    }

    @Test func `text matches the whole label as a pattern, exact matches first`() {
        #expect(QAMatcher.matches(QASelector(text: "Total.*"), in: tree, screen: screen).map(\.label) == ["Total $12.50"])
        #expect(QAMatcher.matches(QASelector(text: "total \\$12\\.50"), in: tree, screen: screen).count == 1)
        // Whole label only: "Delete" doesn't match "Delete all", and the two "Delete"s go top to bottom.
        let deletes = QAMatcher.matches(QASelector(text: "delete"), in: tree, screen: screen)
        #expect(deletes.map(\.frame.minY) == [300, 400])
        #expect(QAMatcher.matches(QASelector(text: "Delete", index: 1), in: tree, screen: screen).first?.frame.minY == 400)
        #expect(QAMatcher.matches(QASelector(text: "Delete", index: 5), in: tree, screen: screen).isEmpty)
        // A pattern that also fits other labels loses to the exact one.
        #expect(QAMatcher.matches(QASelector(text: "Delete.*"), in: tree, screen: screen).count == 3)
    }

    @Test func `values, ids, invalid patterns and the edge of the screen`() {
        #expect(QAMatcher.matches(QASelector(text: "$4.50 (each)"), in: tree, screen: screen).first?.label == "Price")
        #expect(QAMatcher.matches(QASelector(id: "email-field"), in: tree, screen: screen).first?.label == "Email")
        #expect(QAMatcher.matches(QASelector(text: "Offscreen"), in: tree, screen: screen).isEmpty)
        #expect(QAMatcher.matches(QASelector(), in: tree, screen: screen).isEmpty)
    }

    @Test func `points read as percentages or points`() {
        #expect(QAMatcher.point("50%,90%", screen: screen) == CGPoint(x: 195, y: 759.6))
        #expect(QAMatcher.point("120, 400", screen: screen) == CGPoint(x: 120, y: 400))
        #expect(QAMatcher.point("middle", screen: screen) == nil)
    }

    @Test func `Maestro's key names map to the keyboard's`() {
        #expect(QAExecution.keyName("Enter") == "return")
        #expect(QAExecution.keyName("Backspace") == "delete")
        #expect(QAExecution.keyName("Tab") == "tab")
    }
}

@MainActor @Suite struct QAModelTests {
    @Test func `flows load from the folder, and a bad one stays one bad flow`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qa-\(UUID().uuidString)")
        let project = root.appendingPathComponent("app")
        let flows = project.appendingPathComponent("vibex-qa/flows")
        try FileManager.default.createDirectory(at: flows, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "appId: a\n---\n- launchApp\n".write(to: flows.appendingPathComponent("02-second.yaml"), atomically: true, encoding: .utf8)
        try "appId: a\nname: First\n---\n- tapOn: Go\n".write(to: flows.appendingPathComponent("01-first.yml"), atomically: true, encoding: .utf8)
        try "---\nnot: [closed".write(to: flows.appendingPathComponent("03-broken.yaml"), atomically: true, encoding: .utf8)
        try "notes".write(to: flows.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let store = ProjectStore(directory: root.appendingPathComponent("state"))
        let session = ProjectSession(project: Project(url: project), store: store)
        let model = QAModel(project: project, environment: [:], resuming: nil, matrix: DeviceMatrixModel(session: session))
        #expect(model.flows.map(\.file) == ["01-first.yml", "02-second.yaml", "03-broken.yaml"])
        #expect(model.flows.map(\.name) == ["First", "02-second", "03-broken"])
        #expect(model.flows[2].error != nil)
        #expect(model.chat.mode == .ask)
        let line = ClaudeChatModel.commandLine(resume: nil, mode: .ask, model: "", extra: model.chat.extraArguments)
        #expect(line.contains("You are the QA agent inside Vibex"))
        #expect(line.contains("Write(./vibex-qa/**)"))
        #expect(line.contains("mcp__vibex__qa_run"))
    }

    @Test func `a run's id sorts by time`() {
        let early = QAModel.runID(Date(timeIntervalSince1970: 1_700_000_000))
        let late = QAModel.runID(Date(timeIntervalSince1970: 1_700_000_100))
        #expect(early < late)
    }
}
