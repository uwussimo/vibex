import AppKit
import CoreImage
import Foundation
import IOSurface

// MARK: - Results

nonisolated enum QAStatus: String, Codable, Sendable {
    case waiting, running, passed, failed, skipped
}

nonisolated struct QAStepResult: Codable, Sendable, Equatable, Identifiable {
    var index: Int
    var title: String
    var status: QAStatus
    var seconds: Double = 0
    var message: String?
    /// The screen right after the step, relative to the run's folder.
    var screenshot: String?
    var id: Int { index }
}

/// One flow on one device.
nonisolated struct QAFlowResult: Codable, Sendable, Equatable, Identifiable {
    var flow: String
    var flowName: String
    var device: String
    var deviceName: String
    var status: QAStatus
    var steps: [QAStepResult] = []
    var seconds: Double = 0
    /// What was on screen when it failed, as the accessibility tree reads it.
    var screenText: String?
    var id: String { "\(flow)|\(device)" }

    var failure: QAStepResult? { steps.first { $0.status == .failed } }
}

nonisolated struct QARun: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var date: Date
    var results: [QAFlowResult]
    var isFinished = false

    var passed: Int { results.count { $0.status == .passed } }
    var failed: Int { results.count { $0.status == .failed } }

    /// "3 of 4 passed on 3 devices", for a tool result or a notification.
    var summary: String {
        let devices = Set(results.map(\.device)).count
        return "\(passed) of \(results.count) passed on \(devices) device\(devices == 1 ? "" : "s")"
    }
}

// MARK: - A device

/// One booted simulator, driven directly: its screen, touch, keyboard and accessibility tree.
final class QADevice {
    let udid: String
    let name: String
    private let device: CoreSimulatorBridge.Device
    private let input: SimulatorInput
    private let framebuffer: SimulatorFramebuffer
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    let simctl = Simctl()

    init(udid: String) throws {
        let bridge = try CoreSimulatorBridge.shared()
        let device = try bridge.device(udid: udid)
        guard device.isBooted else { throw ToolError("\(device.name) isn't booted") }
        self.device = device
        self.udid = udid
        name = device.name
        input = try SimulatorInput(bridge: bridge, device: device)
        framebuffer = SimulatorFramebuffer(renderable: try bridge.mainDisplay(of: device))
    }

    // On the main actor, wherever the last reference goes: the display connection is the main actor's.
    isolated deinit {
        framebuffer.stop()
    }

    /// The screen in points.
    var screen: CGSize { CGSize(width: device.screenSize.width / device.screenScale, height: device.screenSize.height / device.screenScale) }

    func tree() async throws -> AXNode {
        try await AXTranslation.shared().frontmostTree(device: device)
    }

    /// The tree, or nil while there's nothing to read: no app in front, as for a moment after a launch,
    /// or an app that came back empty because the simulator is too busy to answer.
    func treeIfReady() async -> AXNode? {
        guard let tree = try? await tree(), !tree.children.isEmpty else { return nil }
        return tree
    }

    func image() -> CGImage? {
        guard let surface = framebuffer.surface else { return nil }
        let image = CIImage(ioSurface: surface)
        return ciContext.createCGImage(image, from: image.extent)
    }

    func jpeg(maxWidth: Int) -> Data? {
        image().flatMap { try? ImageEncoding.jpeg(from: $0, maxWidth: maxWidth) }
    }

    // MARK: Input

    private func ratio(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / screen.width, y: point.y / screen.height)
    }

    func tap(_ point: CGPoint, kind: QATapKind = .tap) async {
        let at = ratio(point)
        let count = kind == .double ? 2 : 1
        for index in 0..<count {
            input.touch(ratio: at, down: true)
            try? await Task.sleep(for: kind == .long ? .seconds(1.1) : .milliseconds(60))
            input.touch(ratio: at, down: false)
            if index < count - 1 { try? await Task.sleep(for: .milliseconds(90)) }
        }
    }

    func swipe(from start: CGPoint, to end: CGPoint, seconds: Double = 0.35) async {
        let from = ratio(start), to = ratio(end)
        let steps = max(8, Int(seconds * 60))
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            input.touch(ratio: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), down: true)
            try? await Task.sleep(for: .seconds(seconds / Double(steps)))
        }
        // A short hold at the end, so the scroll stops where the finger did.
        input.touch(ratio: to, down: true)
        try? await Task.sleep(for: .milliseconds(40))
        input.touch(ratio: to, down: false)
    }

    func type(_ text: String) async -> String { await input.type(text) }
    func press(_ key: String) async -> Bool { await input.pressKey(named: key) }

    /// Waits until two looks at the screen a moment apart are the same: animations and loading done.
    func settle(timeout: Double = 3) async {
        let deadline = Date.now.addingTimeInterval(timeout)
        var last = fingerprint()
        while Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(120))
            let next = fingerprint()
            if next != nil, next == last { return }
            last = next
        }
    }

    /// The screen scaled down to a small grid: cheap to compare, and blind to the cursor's blink.
    private func fingerprint() -> [UInt8]? {
        guard let image = image() else { return nil }
        let width = 48, height = 96
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes.map { $0 & 0xF0 }
    }
}

// MARK: - Running a flow

/// Runs flows on one device, step by step, and says how each step went as it goes.
final class QAExecution {
    let device: QADevice
    /// The flows' folder, for `runFlow`.
    let flows: URL
    /// Where this run's screenshots go.
    let output: URL
    /// Called after each step, and as each starts.
    var onStep: (QAStepResult) -> Void = { _ in }

    /// How long finding something waits before it gives up, as in Maestro.
    static let findTimeout = 7.0
    /// Extra time when the screen can't be read at all, which is the simulator being slow, not the app.
    static let unreadableGrace = 13.0

    private var stepCount = 0

    init(device: QADevice, flows: URL, output: URL) {
        self.device = device
        self.flows = flows
        self.output = output
    }

    func run(_ flow: QAFlow) async -> QAFlowResult {
        var result = QAFlowResult(flow: flow.file, flowName: flow.name, device: device.udid, deviceName: device.name, status: .running)
        let started = Date.now
        stepCount = 0
        do {
            try await run(flow.commands, appId: flow.appId, depth: 0) { step in
                if let index = result.steps.firstIndex(where: { $0.index == step.index }) { result.steps[index] = step } else { result.steps.append(step) }
            }
            result.status = .passed
        } catch is CancellationError {
            result.status = .skipped
        } catch {
            result.status = .failed
            result.screenText = (try? await device.tree()).map { AXTreeSerializer.serialize($0, limit: 160).text }
        }
        result.seconds = Date.now.timeIntervalSince(started)
        return result
    }

    private func run(_ commands: [QACommand], appId: String?, depth: Int, record: (QAStepResult) -> Void) async throws {
        for command in commands {
            try Task.checkCancellation()
            if case let .runFlow(file) = command {
                guard depth < 8 else { throw QAFailure("runFlow goes too deep: does \(file) run itself?") }
                let url = flows.appendingPathComponent(file)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw QAFailure("There's no flow called \(file) in vibex-qa/flows.") }
                let inner = try QAFlowParser.parse(text, file: file)
                try await run(inner.commands, appId: inner.appId ?? appId, depth: depth + 1, record: record)
                continue
            }
            stepCount += 1
            var step = QAStepResult(index: stepCount, title: command.title, status: .running)
            record(step)
            onStep(step)
            let started = Date.now
            do {
                try await perform(command, appId: appId)
                await device.settle()
                step.status = .passed
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                step.status = .failed
                step.message = error.localizedDescription
            }
            step.seconds = Date.now.timeIntervalSince(started)
            step.screenshot = saveScreenshot(name: String(format: "%@-%03d.jpg", device.udid.prefix(8).description, stepCount))
            record(step)
            onStep(step)
            if step.status == .failed { throw QAFailure(step.message ?? "Failed") }
        }
    }

    private func saveScreenshot(name: String, maxWidth: Int = 420) -> String? {
        guard let data = device.jpeg(maxWidth: maxWidth) else { return nil }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard (try? data.write(to: output.appendingPathComponent(name))) != nil else { return nil }
        return name
    }

    // MARK: Steps

    private func perform(_ command: QACommand, appId: String?) async throws {
        switch command {
        case let .launchApp(id, clearState):
            let bundle = try required(id ?? appId)
            try? await device.simctl.terminate(device.udid, bundleID: bundle)
            if clearState { try await self.clearState(bundle) }
            do {
                _ = try await device.simctl.launch(device.udid, bundleID: bundle, arguments: [])
            } catch {
                throw QAFailure("\(bundle) didn't launch on \(device.name). Is it installed? Build it with Run first. (\(error.localizedDescription))")
            }
            // A first launch after an install takes a while to come to the front.
            let deadline = Date.now.addingTimeInterval(20)
            while Date.now < deadline {
                if await device.treeIfReady() != nil { break }
                try await Task.sleep(for: .milliseconds(300))
            }
        case let .stopApp(id):
            try? await device.simctl.terminate(device.udid, bundleID: try required(id ?? appId))
        case let .clearState(id):
            let bundle = try required(id ?? appId)
            try? await device.simctl.terminate(device.udid, bundleID: bundle)
            try await clearState(bundle)
        case let .tapOn(selector, kind):
            guard let point = try await locate(selector) else { return }
            await device.tap(point, kind: kind)
        case let .inputText(text):
            let skipped = await device.type(text)
            if !skipped.isEmpty { throw QAFailure("The simulator's keyboard can't type “\(skipped)”. Keep test text to US keyboard characters.") }
        case let .eraseText(count):
            for _ in 0..<count { _ = await device.press("delete") }
        case let .pressKey(key):
            guard await device.press(Self.keyName(key)) else { throw QAFailure("There's no key called \(key).") }
        case .hideKeyboard:
            _ = await device.press("return")
        case .back:
            guard let tree = await device.treeIfReady() else { throw QAFailure("No app is in front on \(device.name).") }
            // iOS has no back button of its own: use the navigation bar's, top left.
            let back = QAMatcher.matches(QASelector(text: "Back|.*"), in: tree, screen: device.screen)
                .first { $0.role.contains("Button") && $0.frame.minY < 140 && $0.frame.minX < device.screen.width * 0.3 }
            guard let back else { throw QAFailure("There's no back button at the top left.") }
            await device.tap(back.center)
        case let .assertVisible(selector):
            _ = try await locate(selector)
        case let .assertNotVisible(selector):
            let deadline = Date.now.addingTimeInterval(Self.findTimeout)
            while true {
                if let tree = await device.treeIfReady(), QAMatcher.matches(selector, in: tree, screen: device.screen).isEmpty { return }
                if Date.now > deadline { throw QAFailure("\(selector.summary) is still on screen.") }
                try await Task.sleep(for: .milliseconds(300))
            }
        case .scroll:
            await swipe(.up)
        case let .scrollUntilVisible(selector, direction, timeout):
            let deadline = Date.now.addingTimeInterval(timeout)
            while true {
                if let tree = await device.treeIfReady(), !QAMatcher.matches(selector, in: tree, screen: device.screen).isEmpty { return }
                if Date.now > deadline { throw QAFailure("Scrolled for \(Int(timeout)) seconds and didn't find \(selector.summary).") }
                // Scrolling down moves the content up.
                await swipe(Self.opposite(direction), short: true)
                await device.settle(timeout: 1.5)
            }
        case let .swipe(direction, start, end):
            if let start, let end, let from = QAMatcher.point(start, screen: device.screen), let to = QAMatcher.point(end, screen: device.screen) {
                await device.swipe(from: from, to: to)
            } else if let direction {
                await swipe(direction)
            } else {
                throw QAFailure("A swipe needs a direction, or a start and an end.")
            }
        case .waitForAnimationToEnd:
            await device.settle(timeout: 8)
        case let .extendedWaitUntil(visible, notVisible, timeout):
            let deadline = Date.now.addingTimeInterval(timeout)
            while true {
                if let tree = await device.treeIfReady() {
                    let seen = visible.map { !QAMatcher.matches($0, in: tree, screen: device.screen).isEmpty } ?? true
                    let gone = notVisible.map { QAMatcher.matches($0, in: tree, screen: device.screen).isEmpty } ?? true
                    if seen, gone { return }
                }
                if Date.now > deadline { throw QAFailure("Waited \(Int(timeout)) seconds for \(visible?.summary ?? notVisible?.summary ?? "it").") }
                try await Task.sleep(for: .milliseconds(400))
            }
        case let .takeScreenshot(name):
            let safe = name.replacingOccurrences(of: "/", with: "-")
            guard saveScreenshot(name: "\(device.udid.prefix(8))-\(safe).jpg", maxWidth: 1200) != nil else { throw QAFailure("Couldn't read the screen.") }
        case let .openLink(url):
            try await device.simctl.openURL(device.udid, url: url)
            try? await Task.sleep(for: .milliseconds(500))
        case .runFlow:
            break
        case let .unsupported(name):
            throw QAFailure("Vibex QA doesn't run `\(name)` yet. Write the step another way.")
        }
    }

    /// Where a selector is on screen, waiting for it to appear. Nil for an optional one that never did.
    private func locate(_ selector: QASelector) async throws -> CGPoint? {
        if let point = selector.point {
            guard let at = QAMatcher.point(point, screen: device.screen) else { throw QAFailure("\(point) isn't a point. Write \"50%,90%\" or \"120,400\".") }
            return at
        }
        var deadline = Date.now.addingTimeInterval(Self.findTimeout)
        var waitedForScreen = false
        while true {
            let tree = await device.treeIfReady()
            if let tree, let match = QAMatcher.matches(selector, in: tree, screen: device.screen).first { return match.center }
            // A screen that can't be read isn't a screen without the element: give a busy simulator longer.
            if tree == nil, !waitedForScreen {
                waitedForScreen = true
                deadline = deadline.addingTimeInterval(Self.unreadableGrace)
            }
            if Date.now > deadline {
                if selector.isOptional { return nil }
                if tree == nil { throw QAFailure("Couldn't read \(device.name)'s screen, so \(selector.summary) couldn't be looked for. The app may have crashed, or the Mac is too busy: close simulators you don't need.") }
                throw QAFailure("Couldn't find \(selector.summary) on screen.")
            }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    private func swipe(_ direction: QASwipeDirection, short: Bool = false) async {
        let size = device.screen
        let span = short ? 0.25 : 0.35
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let (dx, dy): (Double, Double) = switch direction {
        case .up: (0, -1)
        case .down: (0, 1)
        case .left: (-1, 0)
        case .right: (1, 0)
        }
        let from = CGPoint(x: center.x - dx * size.width * span, y: center.y - dy * size.height * span)
        let to = CGPoint(x: center.x + dx * size.width * span, y: center.y + dy * size.height * span)
        await device.swipe(from: from, to: to)
    }

    private static func opposite(_ direction: QASwipeDirection) -> QASwipeDirection {
        switch direction {
        case .up: .down
        case .down: .up
        case .left: .right
        case .right: .left
        }
    }

    /// Maestro's names for keys, in the keyboard's own.
    static func keyName(_ key: String) -> String {
        switch key.lowercased() {
        case "enter": "return"
        case "backspace": "delete"
        default: key.lowercased()
        }
    }

    private func required(_ appId: String?) throws -> String {
        guard let appId, !appId.isEmpty else { throw QAFailure("Which app? Put `appId:` at the top of the flow.") }
        return appId
    }

    /// Empties the app's data container, as a fresh install would have it.
    private func clearState(_ bundle: String) async throws {
        let output = try? Shell.run("/usr/bin/xcrun", ["simctl", "get_app_container", device.udid, bundle, "data"])
        guard let path = output.map({ String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }), !path.isEmpty else {
            throw QAFailure("\(bundle) isn't installed on \(device.name).")
        }
        let folder = URL(fileURLWithPath: path)
        for item in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            for inner in (try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: inner)
            }
        }
    }
}

nonisolated struct QAFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
