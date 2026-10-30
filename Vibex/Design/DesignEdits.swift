import Foundation

/// Where a hand edit lands in the files. Editing is plain JSON surgery: the files stay the source of
/// truth, and Claude reads back whatever the user changed.
nonisolated enum DesignEditPlace: Equatable, Sendable {
    /// An element the screen owns.
    case screen(file: String, path: [Int])
    /// A component's definition in design.json: everything using it follows.
    case main(component: String, path: [Int])
    /// One variant's differences from its component.
    case variant(component: String, variant: String)
    /// A difference on one use of a component, leaving the kit alone.
    case override(file: String, instance: [Int], relative: [Int])

    /// The file it lives in, relative to the design's folder.
    var file: String {
        switch self {
        case let .screen(file, _), let .override(file, _, _): "screens/\(file)"
        case .main, .variant: "design.json"
        }
    }
}

nonisolated enum DesignEdits {
    /// What a use of a component keeps through a reset: what it is, and where it sits.
    private static let structural: Set<String> = ["type", "component", "variant", "props", "overrides", "children", "items", "place", "x", "y", "name"]

    // MARK: Reading and writing values

    static func value(of key: String, at place: DesignEditPlace, in object: [String: Any]) -> Any? {
        switch place {
        case let .override(_, instance, relative):
            guard let target = element(at: rootSteps(instance, in: object), in: object) else { return nil }
            if relative.isEmpty { return target[key] }
            return ((target["overrides"] as? [String: [String: Any]])?[overrideKey(relative)])?[key]
        default:
            return element(at: steps(for: place, in: object), in: object)?[key]
        }
    }

    /// The file's object with one property set, or removed when `value` is nil.
    static func setting(_ key: String, to value: Any?, at place: DesignEditPlace, in object: [String: Any]) -> [String: Any] {
        switch place {
        case let .override(_, instance, relative) where !relative.isEmpty:
            return updating(object, at: rootSteps(instance, in: object)) { target in
                var overrides = (target["overrides"] as? [String: [String: Any]]) ?? [:]
                var entry = overrides[overrideKey(relative)] ?? [:]
                entry[key] = value
                overrides[overrideKey(relative)] = entry.isEmpty ? nil : entry
                target["overrides"] = overrides.isEmpty ? nil : overrides
            }
        default:
            return updating(object, at: steps(for: place, in: object)) { $0[key] = value }
        }
    }

    /// Whether this use of a component differs from the kit.
    static func isOverridden(at place: DesignEditPlace, in object: [String: Any]) -> Bool {
        guard case let .override(_, instance, relative) = place,
              let target = element(at: rootSteps(instance, in: object), in: object) else { return false }
        if relative.isEmpty { return target.keys.contains { !structural.contains($0) } }
        return (target["overrides"] as? [String: Any])?[overrideKey(relative)] != nil
    }

    /// Back to what the kit says.
    static func resetting(at place: DesignEditPlace, in object: [String: Any]) -> [String: Any] {
        guard case let .override(_, instance, relative) = place else { return object }
        return updating(object, at: rootSteps(instance, in: object)) { target in
            if relative.isEmpty {
                target = target.filter { structural.contains($0.key) }
            } else {
                var overrides = (target["overrides"] as? [String: [String: Any]]) ?? [:]
                overrides[overrideKey(relative)] = nil
                target["overrides"] = overrides.isEmpty ? nil : overrides
            }
        }
    }

    // MARK: Changing structure

    /// A copy of the element straight after it. Works where the structure is owned: a screen or the kit.
    static func duplicating(_ place: DesignEditPlace, in object: [String: Any]) -> [String: Any]? {
        guard let (parent, index) = parent(of: place) else { return nil }
        return updatingChildren(of: parent, in: object) { children in
            guard children.indices.contains(index) else { return }
            children.insert(children[index], at: index + 1)
        }
    }

    static func removing(_ place: DesignEditPlace, in object: [String: Any]) -> [String: Any]? {
        guard let (parent, index) = parent(of: place) else { return nil }
        return updatingChildren(of: parent, in: object) { children in
            guard children.indices.contains(index) else { return }
            children.remove(at: index)
        }
    }

    /// Moves an element within its parent, to where it'll sit in the finished list.
    static func moving(_ place: DesignEditPlace, to destination: Int, in object: [String: Any]) -> [String: Any]? {
        guard let (parent, index) = parent(of: place) else { return nil }
        return updatingChildren(of: parent, in: object) { children in
            guard children.indices.contains(index) else { return }
            let child = children.remove(at: index)
            children.insert(child, at: min(max(destination, 0), children.count))
        }
    }

    private static func parent(of place: DesignEditPlace) -> (DesignEditPlace, Int)? {
        switch place {
        case let .screen(file, path):
            guard let last = path.last else { return nil }
            return (.screen(file: file, path: Array(path.dropLast())), last)
        case let .main(component, path):
            guard let last = path.last else { return nil }
            return (.main(component: component, path: Array(path.dropLast())), last)
        case .variant, .override:
            return nil
        }
    }

    private static func updatingChildren(of parent: DesignEditPlace, in object: [String: Any], _ change: (inout [[String: Any]]) -> Void) -> [String: Any] {
        updating(object, at: steps(for: parent, in: object)) { target in
            let key = target["items"] != nil && target["children"] == nil ? "items" : "children"
            var children = (target[key] as? [[String: Any]]) ?? []
            change(&children)
            target[key] = children
        }
    }

    // MARK: The design's foundations

    /// A color token, wherever this design keeps them.
    static func settingColorToken(_ name: String, to value: String, in manifest: [String: Any]) -> [String: Any] {
        var manifest = manifest
        var tokens = (manifest["tokens"] as? [String: Any]) ?? [:]
        if var colors = tokens["colors"] as? [String: Any] {
            colors[name] = value
            tokens["colors"] = colors
        } else {
            tokens[name] = value
        }
        manifest["tokens"] = tokens
        return manifest
    }

    /// A corner size or a spacing step: `scale` is `radii` or `spacing`.
    static func settingScale(_ scale: String, _ name: String, to value: Double, in manifest: [String: Any]) -> [String: Any] {
        var manifest = manifest
        var tokens = (manifest["tokens"] as? [String: Any]) ?? [:]
        var values = (tokens[scale] as? [String: Any]) ?? [:]
        values[name] = value
        tokens[scale] = values
        manifest["tokens"] = tokens
        return manifest
    }

    static func settingTextStyle(_ name: String, _ key: String, to value: Any, in manifest: [String: Any]) -> [String: Any] {
        var manifest = manifest
        var styles = (manifest["styles"] as? [String: [String: Any]]) ?? [:]
        styles[name, default: [:]][key] = value
        manifest["styles"] = styles
        return manifest
    }

    // MARK: Finding things in the JSON

    private enum Step {
        case key(String)
        case index(Int)
    }

    private static func overrideKey(_ path: [Int]) -> String {
        path.map(String.init).joined(separator: "/")
    }

    private static func steps(for place: DesignEditPlace, in object: [String: Any]) -> [Step] {
        switch place {
        case let .screen(_, path):
            return rootSteps(path, in: object)
        case let .main(component, path):
            return childSteps(path, from: [.key("components"), .key(component)], in: object)
        case let .variant(component, variant):
            return [.key("components"), .key(component), .key("variants"), .key(variant)]
        case let .override(_, instance, _):
            return rootSteps(instance, in: object)
        }
    }

    private static func rootSteps(_ path: [Int], in object: [String: Any]) -> [Step] {
        childSteps(path, from: [.key(object["root"] == nil && object["body"] != nil ? "body" : "root")], in: object)
    }

    private static func childSteps(_ path: [Int], from start: [Step], in object: [String: Any]) -> [Step] {
        var steps = start
        for index in path {
            let current = element(at: steps, in: object)
            steps += [.key(current?["items"] != nil && current?["children"] == nil ? "items" : "children"), .index(index)]
        }
        return steps
    }

    private static func element(at steps: [Step], in object: [String: Any]) -> [String: Any]? {
        var current: Any = object
        for step in steps {
            switch step {
            case let .key(key):
                guard let next = (current as? [String: Any])?[key] else { return nil }
                current = next
            case let .index(index):
                guard let list = current as? [Any], list.indices.contains(index) else { return nil }
                current = list[index]
            }
        }
        return current as? [String: Any]
    }

    private static func updating(_ object: [String: Any], at steps: [Step], _ change: (inout [String: Any]) -> Void) -> [String: Any] {
        func walk(_ value: Any?, _ steps: ArraySlice<Step>) -> Any? {
            guard let step = steps.first else {
                var target = (value as? [String: Any]) ?? [:]
                change(&target)
                return target
            }
            switch step {
            case let .key(key):
                var dictionary = (value as? [String: Any]) ?? [:]
                dictionary[key] = walk(dictionary[key], steps.dropFirst())
                return dictionary
            case let .index(index):
                guard var list = value as? [Any], list.indices.contains(index) else { return value }
                list[index] = walk(list[index], steps.dropFirst()) ?? list[index]
                return list
            }
        }
        return (walk(object, steps[...]) as? [String: Any]) ?? object
    }

    // MARK: Files

    static func read(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func data(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
