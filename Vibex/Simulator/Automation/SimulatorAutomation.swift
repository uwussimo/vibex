import AppKit
import CoreImage
import Foundation
import IOSurface

/// What the simulator tools call: the attached device's screen and input, plus simctl for the rest.
final class SimulatorAutomation {
    private let pane: SimulatorPaneViewController
    private let simctl = Simctl()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    /// Refs from the last describe, so tap_element can use them.
    private var lastRefs: [String: AXNode] = [:]
    private var lastTree: AXNode?

    init(pane: SimulatorPaneViewController) {
        self.pane = pane
    }

    var model: SimulatorModel { pane.model }

    struct Live {
        let device: CoreSimulatorBridge.Device
        let input: SimulatorInput
        let surface: IOSurface
        /// Screen size in points.
        var pointSize: CGSize { CGSize(width: device.screenSize.width / device.screenScale, height: device.screenSize.height / device.screenScale) }
    }

    func live() throws -> Live {
        guard let device = pane.attachedDevice, let input = pane.automationInput, let surface = pane.automationSurface else {
            throw ToolError("no simulator is live in Vibex; boot one with simulator_boot or check simulator_list")
        }
        return Live(device: device, input: input, surface: surface)
    }

    func bootedUDID() throws -> String {
        if let device = pane.attachedDevice { return device.udid }
        if let booted = model.bootedDevice { return booted.udid }
        throw ToolError("no booted simulator")
    }

    // MARK: - Screen

    func screenshot(maxWidth: Int) throws -> Data {
        let live = try live()
        let image = CIImage(ioSurface: live.surface)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { throw ToolError("could not read the framebuffer") }
        return try ImageEncoding.jpeg(from: cgImage, maxWidth: maxWidth)
    }

    func describeInfo() -> String {
        guard let device = pane.attachedDevice else {
            return "No live device. Selected: \(model.selectedDevice?.name ?? "none"). State: \(String(describing: pane.displayState))."
        }
        let points = CGSize(width: device.screenSize.width / device.screenScale, height: device.screenSize.height / device.screenScale)
        let slim = model.slimInfo[device.udid]
        var lines = [
            "device: \(device.name) (\(device.udid))",
            "screen: \(Int(points.width))×\(Int(points.height)) points, \(Int(device.screenSize.width))×\(Int(device.screenSize.height)) px, scale \(Int(device.screenScale))x",
            "state: live",
        ]
        if let slim { lines.append("slim: \(slim.isSlim ? "yes (\(slim.managedDisabled)/\(slim.managedTotal) daemons off)" : "no")\(slim.memoryText.map { ", memory \($0)" } ?? "")") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Touch

    private func ratio(_ live: Live, x: Double, y: Double) -> CGPoint {
        let size = live.pointSize
        return CGPoint(x: x / size.width, y: y / size.height)
    }

    func tap(x: Double, y: Double) async throws {
        let live = try live()
        let point = ratio(live, x: x, y: y)
        live.input.touch(ratio: point, down: true)
        try? await Task.sleep(for: .milliseconds(60))
        live.input.touch(ratio: point, down: false)
    }

    func longPress(x: Double, y: Double, seconds: Double) async throws {
        let live = try live()
        let point = ratio(live, x: x, y: y)
        live.input.touch(ratio: point, down: true)
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(50))
            live.input.touch(ratio: point, down: true)
        }
        live.input.touch(ratio: point, down: false)
    }

    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, seconds: Double) async throws {
        let live = try live()
        let from = ratio(live, x: fromX, y: fromY)
        let to = ratio(live, x: toX, y: toY)
        let steps = max(6, Int(seconds * 60))
        let stepDelay = max(0.004, seconds / Double(steps))
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            live.input.touch(ratio: point, down: true)
            try? await Task.sleep(for: .seconds(stepDelay))
        }
        // Hold at the end to avoid inertial scroll, like idb does.
        live.input.touch(ratio: to, down: true)
        try? await Task.sleep(for: .milliseconds(40))
        live.input.touch(ratio: to, down: false)
    }

    func type(_ text: String) async throws -> String {
        let live = try live()
        let skipped = await live.input.type(text)
        return skipped.isEmpty ? "Typed \(text.count) characters." : "Typed; could not type: \(skipped)"
    }

    func pressKey(_ name: String) async throws -> String {
        let live = try live()
        guard await live.input.pressKey(named: name) else { throw ToolError("unknown key \(name)") }
        return "Pressed \(name)."
    }

    func button(_ name: String) throws -> String {
        let live = try live()
        switch name.lowercased() {
        case "home": live.input.press(.home)
        case "lock", "power", "side": live.input.press(.lock)
        default: throw ToolError("button must be home or lock")
        }
        return "Pressed \(name)."
    }

    // MARK: - Accessibility

    func describe() async throws -> String {
        let live = try live()
        let tree = try await AXTranslation.shared().frontmostTree(device: live.device)
        let output = AXTreeSerializer.serialize(tree)
        lastRefs = output.refs
        lastTree = tree
        return output.text
    }

    func find(label: String?, identifier: String?) async throws -> String {
        let live = try live()
        let tree = try await AXTranslation.shared().frontmostTree(device: live.device)
        lastTree = tree
        let matches = AXTreeSerializer.find(in: tree, label: label, identifier: identifier)
        guard !matches.isEmpty else { return "No element matches." }
        var refs: [String: AXNode] = [:]
        let lines = matches.prefix(50).enumerated().map { index, node -> String in
            let ref = "f\(index + 1)"
            refs[ref] = node
            let name = node.label.isEmpty ? node.value : node.label
            return "\(AXNode.shortRole(node.role)) \"\(name)\" [ref=\(ref)] (\(Int(node.frame.minX)),\(Int(node.frame.minY)) \(Int(node.frame.width))x\(Int(node.frame.height)))\(node.identifier.isEmpty ? "" : " id=\(node.identifier)")"
        }
        lastRefs.merge(refs) { _, new in new }
        return lines.joined(separator: "\n")
    }

    func tapElement(ref: String?, label: String?) async throws -> String {
        var target: AXNode?
        if let ref { target = lastRefs[ref] }
        if target == nil, let label {
            let live = try live()
            let tree = try await AXTranslation.shared().frontmostTree(device: live.device)
            lastTree = tree
            target = AXTreeSerializer.find(in: tree, label: label, identifier: nil).first
        }
        guard let target else { throw ToolError(ref != nil ? "unknown ref \(ref!); call simulator_describe first" : "no element labelled \(label ?? "")") }
        let center = target.center
        try await tap(x: center.x, y: center.y)
        let name = target.label.isEmpty ? target.value : target.label
        return "Tapped \(AXNode.shortRole(target.role)) \"\(name)\" at (\(Int(center.x)), \(Int(center.y)))."
    }

    func elementAt(x: Double, y: Double) async throws -> String {
        let live = try live()
        let node = try await AXTranslation.shared().element(at: CGPoint(x: x, y: y), device: live.device)
        return AXTreeSerializer.serialize(node, alwaysIncludeRoot: true).text
    }

    // MARK: - simctl

    func install(appPath: String) async throws -> String {
        let udid = try bootedUDID()
        try await simctl.install(udid, appPath: appPath)
        return "Installed \((appPath as NSString).lastPathComponent)."
    }

    func launch(bundleID: String, arguments: [String]) async throws -> String {
        let udid = try bootedUDID()
        return try await simctl.launch(udid, bundleID: bundleID, arguments: arguments)
    }

    func terminate(bundleID: String) async throws -> String {
        try await simctl.terminate(try bootedUDID(), bundleID: bundleID)
        return "Terminated \(bundleID)."
    }

    func openURL(_ url: String) async throws -> String {
        try await simctl.openURL(try bootedUDID(), url: url)
        return "Opened \(url)."
    }

    func listApps() async throws -> String {
        let apps = try await simctl.listApps(try bootedUDID())
        let user = apps.filter { $0.type == "User" }
        let lines = (user.isEmpty ? apps : user).map { "\($0.bundleID)  \($0.name)\($0.type == "User" ? "" : "  (\($0.type))")" }
        return lines.joined(separator: "\n")
    }

    func logs(bundleID: String?, seconds: Int, filter: String?) async throws -> String {
        let udid = try bootedUDID()
        var predicate = filter
        if predicate == nil, let bundleID {
            let process = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            predicate = "subsystem == \"\(bundleID)\" OR process == \"\(process)\" OR eventMessage CONTAINS \"\(bundleID)\""
        }
        let text = try await simctl.logs(udid, seconds: seconds, predicate: predicate)
        return text.isEmpty ? "No log lines in the last \(seconds)s." : text
    }
}
