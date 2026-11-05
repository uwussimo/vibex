import CoreGraphics
import Foundation
import Yams

/// What a step looks for on screen: text (a regular expression, as in Maestro), an accessibility
/// identifier, or a point.
nonisolated struct QASelector: Equatable, Sendable, Codable {
    var text: String?
    var id: String?
    /// Which match, top to bottom, when several fit.
    var index: Int?
    /// "50%,90%" or "120,400" in points.
    var point: String?
    var isOptional = false

    var summary: String {
        if let text { return "“\(text)”" }
        if let id { return "#\(id)" }
        if let point { return point }
        return "the screen"
    }
}

nonisolated enum QASwipeDirection: String, Equatable, Sendable, Codable {
    case up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT"
}

nonisolated enum QATapKind: String, Equatable, Sendable, Codable {
    case tap, long, double
}

/// One step of a flow, in Maestro's vocabulary.
nonisolated enum QACommand: Equatable, Sendable {
    case launchApp(appId: String?, clearState: Bool)
    case stopApp(appId: String?)
    case clearState(appId: String?)
    case tapOn(QASelector, kind: QATapKind)
    case inputText(String)
    case eraseText(Int)
    case pressKey(String)
    case hideKeyboard
    case back
    case assertVisible(QASelector)
    case assertNotVisible(QASelector)
    case scroll
    case scrollUntilVisible(QASelector, direction: QASwipeDirection, timeout: Double)
    case swipe(direction: QASwipeDirection?, start: String?, end: String?)
    case waitForAnimationToEnd
    case extendedWaitUntil(visible: QASelector?, notVisible: QASelector?, timeout: Double)
    case takeScreenshot(String)
    case openLink(String)
    case runFlow(String)
    /// A Maestro command Vibex doesn't run yet. It fails the flow and says so, rather than being skipped.
    case unsupported(String)

    /// How the step reads in results.
    var title: String {
        switch self {
        case let .launchApp(appId, clearState): "Launch \(appId ?? "the app")\(clearState ? " fresh" : "")"
        case let .stopApp(appId): "Stop \(appId ?? "the app")"
        case let .clearState(appId): "Clear \(appId ?? "the app")'s data"
        case let .tapOn(selector, kind): "\(kind == .long ? "Long press" : kind == .double ? "Double tap" : "Tap") \(selector.summary)"
        case let .inputText(text): "Type “\(text)”"
        case let .eraseText(count): "Erase \(count) characters"
        case let .pressKey(key): "Press \(key)"
        case .hideKeyboard: "Hide the keyboard"
        case .back: "Go back"
        case let .assertVisible(selector): "See \(selector.summary)"
        case let .assertNotVisible(selector): "Don't see \(selector.summary)"
        case .scroll: "Scroll"
        case let .scrollUntilVisible(selector, _, _): "Scroll to \(selector.summary)"
        case let .swipe(direction, _, _): "Swipe \(direction?.rawValue.lowercased() ?? "")".trimmingCharacters(in: .whitespaces)
        case .waitForAnimationToEnd: "Wait for animations"
        case let .extendedWaitUntil(visible, notVisible, _): visible.map { "Wait for \($0.summary)" } ?? "Wait until \(notVisible?.summary ?? "") is gone"
        case let .takeScreenshot(name): "Screenshot \(name)"
        case let .openLink(url): "Open \(url)"
        case let .runFlow(file): "Run \(file)"
        case let .unsupported(name): name
        }
    }
}

/// One test: a `.yaml` file in `vibex-qa/flows/`, written the way Maestro writes them.
nonisolated struct QAFlow: Equatable, Sendable {
    var file: String
    var name: String
    var appId: String?
    var tags: [String] = []
    var commands: [QACommand] = []
}

nonisolated enum QAFlowParser {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func parse(_ text: String, file: String, environment: [String: String] = [:]) throws -> QAFlow {
        var documents: [Any?] = []
        do {
            // The parser directly: the loader's sequence ends quietly at a syntax error, losing steps.
            let parser = try Parser(yaml: text)
            while let node = try parser.nextRoot() { documents.append(Constructor.default.any(from: node)) }
        } catch {
            throw Failure(message: "The YAML doesn't read: \(error.localizedDescription)")
        }
        // Maestro puts the config first, then `---`, then the steps. A file with only steps works too.
        let config = documents.count > 1 ? (documents.first as? [String: Any]) ?? [:] : [:]
        let last: Any? = documents.last ?? nil
        guard let steps = (last as? [Any]) ?? (last == nil ? [] : nil) else {
            throw Failure(message: "The steps should be a list after `---`, one `- command` per line.")
        }
        var env = environment
        for (key, value) in (config["env"] as? [String: Any]) ?? [:] where env[key] == nil { env[key] = "\(value)" }
        let base = (file as NSString).deletingPathExtension
        return QAFlow(
            file: file,
            name: (config["name"] as? String) ?? base,
            appId: config["appId"] as? String,
            tags: (config["tags"] as? [String]) ?? [],
            commands: steps.map { command(from: substituting($0, env)) }
        )
    }

    /// `${NAME}` from the flow's `env`.
    private static func substituting(_ value: Any, _ env: [String: String]) -> Any {
        guard !env.isEmpty else { return value }
        switch value {
        case let text as String: return env.reduce(text) { $0.replacingOccurrences(of: "${\($1.key)}", with: $1.value) }
        case let list as [Any]: return list.map { substituting($0, env) }
        case let map as [String: Any]: return map.mapValues { substituting($0, env) }
        default: return value
        }
    }

    static func command(from step: Any) -> QACommand {
        let name: String
        let argument: Any?
        if let plain = step as? String {
            name = plain
            argument = nil
        } else if let map = step as? [String: Any], map.count == 1, let entry = map.first {
            name = entry.key
            argument = entry.value
        } else {
            return .unsupported("A step that isn't one command")
        }
        let options = argument as? [String: Any] ?? [:]
        func number(_ key: String) -> Double? { (options[key] as? Double) ?? (options[key] as? Int).map(Double.init) }
        // Maestro's timeouts are in milliseconds.
        func timeout(_ fallback: Double) -> Double { number("timeout").map { $0 / 1000 } ?? fallback }

        switch name {
        case "launchApp":
            return .launchApp(appId: (argument as? String) ?? options["appId"] as? String, clearState: options["clearState"] as? Bool ?? false)
        case "stopApp":
            return .stopApp(appId: argument as? String)
        case "clearState":
            return .clearState(appId: argument as? String)
        case "tapOn", "longPressOn", "doubleTapOn":
            let kind: QATapKind = name == "longPressOn" ? .long : (name == "doubleTapOn" ? .double : .tap)
            return .tapOn(selector(argument), kind: options["longPress"] as? Bool == true ? .long : kind)
        case "inputText":
            return .inputText((argument as? String) ?? (argument.map { "\($0)" } ?? ""))
        case "eraseText":
            return .eraseText((argument as? Int) ?? (options["charactersToErase"] as? Int) ?? 50)
        case "pressKey":
            return .pressKey((argument as? String) ?? "Enter")
        case "hideKeyboard":
            return .hideKeyboard
        case "back":
            return .back
        case "assertVisible":
            return .assertVisible(selector(argument))
        case "assertNotVisible":
            return .assertNotVisible(selector(argument))
        case "scroll":
            return .scroll
        case "scrollUntilVisible":
            let direction = (options["direction"] as? String).flatMap { QASwipeDirection(rawValue: $0.uppercased()) } ?? .down
            return .scrollUntilVisible(selector(options["element"] ?? argument), direction: direction, timeout: timeout(20))
        case "swipe":
            let direction = ((argument as? String) ?? options["direction"] as? String).flatMap { QASwipeDirection(rawValue: $0.uppercased()) }
            return .swipe(direction: direction, start: options["start"] as? String, end: options["end"] as? String)
        case "waitForAnimationToEnd":
            return .waitForAnimationToEnd
        case "extendedWaitUntil":
            let visible = options["visible"].map(selector)
            let notVisible = options["notVisible"].map(selector)
            return .extendedWaitUntil(visible: visible, notVisible: notVisible, timeout: timeout(10))
        case "takeScreenshot":
            return .takeScreenshot((argument as? String) ?? (options["path"] as? String) ?? "screenshot")
        case "openLink":
            return .openLink((argument as? String) ?? (options["link"] as? String) ?? "")
        case "runFlow":
            return .runFlow((argument as? String) ?? (options["file"] as? String) ?? "")
        default:
            return .unsupported(name)
        }
    }

    /// `"Sign in"`, or `{ text: "Sign in", index: 1 }`, `{ id: "email" }`, `{ point: "50%,90%" }`.
    static func selector(_ value: Any?) -> QASelector {
        if let text = value as? String { return QASelector(text: text) }
        let map = value as? [String: Any] ?? [:]
        return QASelector(
            text: (map["text"] as? String) ?? (map["label"] as? String),
            id: map["id"] as? String,
            index: map["index"] as? Int,
            point: map["point"] as? String,
            isOptional: map["optional"] as? Bool ?? false
        )
    }
}

/// Finding what a selector means on a screen. Pure, so it's tested without a simulator.
nonisolated enum QAMatcher {
    /// Elements the selector matches and that are on screen, top to bottom.
    static func matches(_ selector: QASelector, in root: AXNode, screen: CGSize) -> [AXNode] {
        let bounds = CGRect(origin: .zero, size: screen)
        var found: [AXNode] = []
        func walk(_ node: AXNode) {
            if fits(node, selector), node.frame.width > 0, node.frame.height > 0, node.frame.intersects(bounds),
               !found.contains(where: { $0.frame == node.frame }) {
                found.append(node)
            }
            node.children.forEach(walk)
        }
        walk(root)
        // A label that matches exactly beats one the pattern only happens to fit.
        let exact = found.filter { node in selector.text.map { isExact($0, node) } ?? true }
        let ordered = (exact.isEmpty ? found : exact).sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        guard let index = selector.index else { return ordered }
        return ordered.indices.contains(index) ? [ordered[index]] : []
    }

    private static func fits(_ node: AXNode, _ selector: QASelector) -> Bool {
        if let id = selector.id, node.identifier != id, !matchesPattern(id, node.identifier) { return false }
        if let text = selector.text, !([node.label, node.value].contains { matchesPattern(text, $0) }) { return false }
        return selector.text != nil || selector.id != nil
    }

    private static func isExact(_ text: String, _ node: AXNode) -> Bool {
        [node.label, node.value].contains { $0.compare(text, options: [.caseInsensitive]) == .orderedSame }
    }

    /// Maestro reads text as a regular expression for the whole label. Text that isn't a valid
    /// pattern, such as "$4.50 (each)", is compared as it's written.
    static func matchesPattern(_ pattern: String, _ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if text.compare(pattern, options: [.caseInsensitive]) == .orderedSame { return true }
        guard let regex = try? NSRegularExpression(pattern: "^(?:\(pattern))$", options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// "50%,90%" or "120, 400" as a point on a screen of this size.
    static func point(_ text: String, screen: CGSize) -> CGPoint? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        func value(_ part: String, _ length: CGFloat) -> CGFloat? {
            if part.hasSuffix("%"), let percent = Double(part.dropLast()) { return length * percent / 100 }
            return Double(part).map { CGFloat($0) }
        }
        guard let x = value(parts[0], screen.width), let y = value(parts[1], screen.height) else { return nil }
        return CGPoint(x: x, y: y)
    }
}
