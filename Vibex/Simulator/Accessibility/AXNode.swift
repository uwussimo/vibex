import CoreGraphics
import Foundation

/// One element of a simulator accessibility tree, in screen points. A plain value so it can cross
/// from the translator's queue to the main actor and be serialized without touching private objects.
nonisolated struct AXNode: Sendable, Equatable {
    var role: String
    var label: String
    var value: String
    var identifier: String
    var frame: CGRect
    var isEnabled: Bool
    var children: [AXNode]

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    /// "AXButton" → "button", "AXStaticText" → "text".
    static func shortRole(_ raw: String) -> String {
        let trimmed = raw.hasPrefix("AX") ? String(raw.dropFirst(2)) : raw
        switch trimmed {
        case "StaticText": return "text"
        case "TextField", "SecureTextField": return "textfield"
        case "Application": return "app"
        case "Image": return "image"
        default: return trimmed.lowercased()
        }
    }
}

/// Renders a tree as compact indented lines with refs (`r1`, `r2`…) and returns the ref table.
nonisolated enum AXTreeSerializer {
    struct Output: Sendable {
        var text: String
        var refs: [String: AXNode]
        var count: Int
    }

    static func serialize(_ root: AXNode, limit: Int = 400, alwaysIncludeRoot: Bool = false) -> Output {
        var lines: [String] = []
        var refs: [String: AXNode] = [:]
        var counter = 0
        func walk(_ node: AXNode, depth: Int) {
            guard lines.count < limit else { return }
            let isRoot = depth == 0 && lines.isEmpty
            let meaningful = (alwaysIncludeRoot && isRoot) || !node.label.isEmpty || !node.value.isEmpty || !node.identifier.isEmpty || node.role != "AXGroup"
            var childDepth = depth
            if meaningful {
                counter += 1
                let ref = "r\(counter)"
                refs[ref] = node
                var parts = [AXNode.shortRole(node.role)]
                if !node.label.isEmpty { parts.append("\"\(node.label)\"") }
                if !node.value.isEmpty, node.value != node.label { parts.append("value=\"\(node.value.prefix(80))\"") }
                if !node.identifier.isEmpty { parts.append("id=\(node.identifier)") }
                parts.append("[ref=\(ref)]")
                parts.append(String(format: "(%.0f,%.0f %.0fx%.0f)", node.frame.minX, node.frame.minY, node.frame.width, node.frame.height))
                if !node.isEnabled { parts.append("disabled") }
                lines.append(String(repeating: "  ", count: depth) + parts.joined(separator: " "))
                childDepth = depth + 1
            }
            for child in node.children { walk(child, depth: childDepth) }
        }
        walk(root, depth: 0)
        if lines.count >= limit { lines.append("… (truncated at \(limit) elements)") }
        return Output(text: lines.joined(separator: "\n"), refs: refs, count: counter)
    }

    /// Depth-first search by label or identifier (case-insensitive substring).
    static func find(in root: AXNode, label: String?, identifier: String?) -> [AXNode] {
        var matches: [AXNode] = []
        func walk(_ node: AXNode) {
            let labelHit = label.map { node.label.localizedCaseInsensitiveContains($0) || node.value.localizedCaseInsensitiveContains($0) } ?? true
            let idHit = identifier.map { node.identifier.localizedCaseInsensitiveContains($0) } ?? true
            if labelHit, idHit, (label != nil || identifier != nil) { matches.append(node) }
            node.children.forEach(walk)
        }
        walk(root)
        return matches
    }
}
