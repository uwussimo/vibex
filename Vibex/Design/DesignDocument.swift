import AppKit
import Foundation

/// How long a side is: a fixed number, as wide as the parent allows, or as small as the content.
nonisolated enum DesignLength: Equatable, Sendable {
    case points(Double)
    case fill
    case hug

    init?(_ value: Any?) {
        if let number = value as? Double { self = .points(number); return }
        if let number = value as? Int { self = .points(Double(number)); return }
        switch (value as? String)?.lowercased() {
        case "fill", "full", "100%", "infinity", "max": self = .fill
        case "hug", "auto", "fit", "content": self = .hug
        default: return nil
        }
    }
}

nonisolated struct DesignInsets: Equatable, Sendable {
    var top = 0.0, right = 0.0, bottom = 0.0, left = 0.0

    /// 16, [12, 16] (vertical, horizontal), [top, right, bottom, left], or {"top": 8, "x": 16}.
    init?(_ value: Any?) {
        if let all = Self.number(value) {
            top = all; right = all; bottom = all; left = all
        } else if let list = value as? [Any] {
            let numbers = list.compactMap(Self.number)
            switch numbers.count {
            case 1: top = numbers[0]; right = numbers[0]; bottom = numbers[0]; left = numbers[0]
            case 2: top = numbers[0]; bottom = numbers[0]; right = numbers[1]; left = numbers[1]
            case 4: top = numbers[0]; right = numbers[1]; bottom = numbers[2]; left = numbers[3]
            default: return nil
            }
        } else if let sides = value as? [String: Any] {
            let x = Self.number(sides["x"]), y = Self.number(sides["y"])
            top = Self.number(sides["top"]) ?? y ?? 0
            bottom = Self.number(sides["bottom"]) ?? y ?? 0
            left = Self.number(sides["left"]) ?? x ?? 0
            right = Self.number(sides["right"]) ?? x ?? 0
        } else {
            return nil
        }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? Int).map(Double.init)
    }
}

/// A flat color or token, or a gradient between several.
nonisolated enum DesignPaint: Equatable, Sendable {
    case color(String)
    case gradient(colors: [String], angle: Double)

    init?(_ value: Any?) {
        if let text = value as? String {
            self = .color(text)
        } else if let object = value as? [String: Any], let colors = (object["gradient"] ?? object["colors"]) as? [String], !colors.isEmpty {
            self = .gradient(colors: colors, angle: (object["angle"] as? Double) ?? (object["angle"] as? Int).map(Double.init) ?? 180)
        } else {
            return nil
        }
    }

    var colorNames: [String] {
        switch self {
        case let .color(name): [name]
        case let .gradient(colors, _): colors
        }
    }
}

nonisolated struct DesignShadow: Equatable, Sendable {
    var y: Double, blur: Double, color: String?

    /// "sm", "md", "lg" or {"y": 8, "blur": 24, "color": "#00000033"}
    init?(_ value: Any?) {
        if let name = value as? String {
            switch name {
            case "sm": y = 1; blur = 3
            case "md": y = 4; blur = 14
            case "lg": y = 12; blur = 36
            default: return nil
            }
        } else if let object = value as? [String: Any] {
            y = (object["y"] as? Double) ?? (object["y"] as? Int).map(Double.init) ?? 4
            blur = (object["blur"] as? Double) ?? (object["blur"] as? Int).map(Double.init) ?? 14
            color = object["color"] as? String
        } else {
            return nil
        }
    }
}

/// Where an element is defined in the kit: a component's name and the path inside it.
nonisolated struct DesignMainRef: Equatable, Sendable {
    var component: String
    var path: [Int]
}

/// Number tokens, written `$md`: corner sizes, and spacing for padding and gaps. Changing one reaches
/// everything that uses it.
nonisolated struct DesignScales: Equatable, Sendable {
    var radii: [String: Double] = [:]
    var spacing: [String: Double] = [:]

    init(radii: [String: Double] = [:], spacing: [String: Double] = [:]) {
        self.radii = radii
        self.spacing = spacing
    }

    func value(_ text: String, isRadius: Bool) -> Double? {
        guard text.hasPrefix("$") else { return nil }
        return (isRadius ? radii : spacing)[String(text.dropFirst())]
    }

    /// Padding, with any tokens in it turned to numbers.
    func resolved(_ value: Any?) -> Any? {
        switch value {
        case let text as String: self.value(text, isRadius: false)
        case let list as [Any]: list.map { resolved($0) ?? 0 }
        case let sides as [String: Any]: sides.mapValues { resolved($0) ?? 0 }
        default: value
        }
    }
}

/// One element of a screen. The format forgives: Claude may write `vstack` or `column`,
/// `cornerRadius` or `radius`. It's a design tool, and a missing style shouldn't lose a screen.
nonisolated struct DesignNode: Equatable, Sendable {
    enum Kind: String, Sendable {
        case column, row, layer, grid, text, icon, image, button, input, toggle, divider, spacer, chart
    }

    var kind: Kind
    var children: [DesignNode] = []
    var text: String?
    var placeholder: String?
    var label: String?
    var gap: Double?
    var padding: DesignInsets?
    var align: String?
    var justify: String?
    var width: DesignLength?
    var height: DesignLength?
    var minWidth: Double?
    var maxWidth: Double?
    var minHeight: Double?
    var maxHeight: Double?
    var aspect: Double?
    var fill: DesignPaint?
    var radius: Double?
    var borderColor: String?
    var borderWidth: Double?
    var shadow: DesignShadow?
    var opacity: Double?
    var size: Double?
    var weight: String?
    var color: String?
    var textAlign: String?
    var lineHeight: Double?
    var tracking: Double?
    var lines: Int?
    var font: String?
    var icon: String?
    var src: String?
    var fit: String?
    var columns: Int?
    var variant: String?
    var isOn: Bool?
    var values: [Double]?
    var chart: String?
    var place: String?
    var x: Double?
    var y: Double?
    var clips = false
    /// The element's own name, for the layer list.
    var name: String?
    var isHidden = false
    /// A number written as a `$token`, so editing can show the token rather than what it resolved to.
    var radiusToken: String?

    // Where this element came from, which is what editing it needs to know.

    /// Its place in the drawn tree: child indexes from the screen's root.
    var path: [Int] = []
    /// The kit component this element is a use of.
    var component: String?
    /// The variant it's showing, and the ones its component offers.
    var activeVariant: String?
    var variantNames: [String] = []
    /// Its definition in the kit, when it's from one or sits inside one.
    var main: DesignMainRef?
    /// The path of the outermost use of a component it's part of. Nil for an element the screen owns.
    var instance: [Int]?
    /// A type that's neither built in nor in the kit.
    var unknownType: String?

    private static let kinds: [String: Kind] = [
        "column": .column, "vstack": .column, "stack": .column, "col": .column, "view": .column, "container": .column, "box": .column, "card": .column, "section": .column, "div": .column,
        "row": .row, "hstack": .row,
        "layer": .layer, "zstack": .layer, "overlay": .layer,
        "grid": .grid,
        "text": .text, "label": .text, "title": .text, "heading": .text, "paragraph": .text,
        "icon": .icon, "symbol": .icon,
        "image": .image, "img": .image, "photo": .image, "avatar": .image,
        "button": .button, "input": .input, "textfield": .input, "field": .input, "search": .input,
        "toggle": .toggle, "switch": .toggle,
        "divider": .divider, "separator": .divider,
        "spacer": .spacer,
        "chart": .chart,
    ]

    /// `styles` are shared bundles of properties and `components` shared elements, from design.json.
    init(_ raw: [String: Any], styles: [String: [String: Any]] = [:], components: [String: [String: Any]] = [:], scales: DesignScales = DesignScales()) {
        self.init(raw, library: Library(styles: styles, components: components, scales: scales), path: [], overrides: [:], owner: Owner())
    }

    private struct Library {
        let styles: [String: [String: Any]]
        let components: [String: [String: Any]]
        let scales: DesignScales
    }

    /// Which definition and which use of a component an element belongs to.
    private struct Owner {
        var main: DesignMainRef?
        var instance: [Int]?
    }

    private init(_ raw: [String: Any], library: Library, path: [Int], overrides inherited: [String: [String: Any]], owner: Owner) {
        var object = raw
        // A use's overrides reach down the tree, and the outermost says last.
        if let here = inherited[""] { object.merge(here) { $1 } }
        var overrides = (object.removeValue(forKey: "overrides") as? [String: [String: Any]]) ?? [:]
        overrides.merge(inherited) { $1 }
        overrides[""] = nil

        var component: String?
        var activeVariant: String?
        var variantNames: [String] = []
        var childOwner: String?
        // A component's properties sit under the element's own. The limit stops one that uses itself.
        for _ in 0..<12 {
            guard let name = (object["type"] as? String) ?? (object["component"] as? String), var definition = library.components[name] else { break }
            if component == nil { component = name }
            if Self.children(of: object) == nil, Self.children(of: definition) != nil { childOwner = name }
            let props = ((definition.removeValue(forKey: "props") as? [String: Any]) ?? [:])
                .merging((object.removeValue(forKey: "props") as? [String: Any]) ?? [:]) { $1 }
            let variants = (definition.removeValue(forKey: "variants") as? [String: [String: Any]]) ?? [:]
            if variantNames.isEmpty { variantNames = variants.keys.sorted() }
            if let chosen = object["variant"] as? String, let variant = variants[chosen] {
                definition.merge(variant) { $1 }
                activeVariant = chosen
                // What's left is for the built-in button's own looks, if the variant names one.
                object["variant"] = definition["variant"]
                if definition["variant"] == nil { object.removeValue(forKey: "variant") }
            }
            var merged = definition.merging(object) { $1 }
            merged["type"] = definition["type"]
            merged["component"] = nil
            object = Self.filling(merged, with: props)
        }
        // Named styles too, so what the element says itself wins.
        var names: [String] = []
        if let one = object["style"] as? String { names = [one] }
        if let many = object["style"] as? [String] { names = many }
        for name in names.reversed() {
            object = (library.styles[name.replacingOccurrences(of: "$", with: "")] ?? [:]).merging(object) { $1 }
        }
        let typeName = (object["type"] as? String) ?? ""
        let childObjects = Self.children(of: object) ?? []
        if let known = Self.kinds[typeName.lowercased()] {
            kind = known
        } else if !childObjects.isEmpty {
            kind = .column
            unknownType = typeName.isEmpty ? nil : typeName
        } else if object["text"] != nil || object["content"] != nil {
            kind = .text
        } else {
            kind = .column
            unknownType = typeName.isEmpty ? nil : typeName
        }
        self.path = path
        self.component = component
        self.activeVariant = activeVariant
        self.variantNames = variantNames
        main = component.map { DesignMainRef(component: $0, path: []) } ?? owner.main
        instance = component == nil ? owner.instance : (owner.instance ?? path)
        if path.count < 60 {
            children = childObjects.enumerated().map { index, child in
                let prefix = "\(index)"
                var below: [String: [String: Any]] = [:]
                for (key, value) in overrides {
                    if key == prefix { below[""] = value } else if key.hasPrefix(prefix + "/") { below[String(key.dropFirst(prefix.count + 1))] = value }
                }
                let next = childOwner.map { Owner(main: DesignMainRef(component: $0, path: [index]), instance: owner.instance ?? path) }
                    ?? Owner(main: owner.main.map { DesignMainRef(component: $0.component, path: $0.path + [index]) }, instance: owner.instance)
                return DesignNode(child, library: library, path: path + [index], overrides: below, owner: next)
            }
        }
        name = object["name"] as? String
        isHidden = object["hidden"] as? Bool ?? false
        if let token = (object["radius"] ?? object["cornerRadius"]) as? String, token.hasPrefix("$") { radiusToken = String(token.dropFirst()) }

        func number(_ names: String...) -> Double? {
            for name in names {
                if let value = object[name] as? Double { return value }
                if let value = object[name] as? Int { return Double(value) }
                if let value = object[name] as? String, let token = library.scales.value(value, isRadius: name.lowercased().contains("radius")) { return token }
            }
            return nil
        }
        func string(_ names: String...) -> String? {
            for name in names {
                if let value = object[name] as? String { return value }
            }
            return nil
        }
        text = string("text", "content", "value", "title") ?? (kind == .text || kind == .button ? string("label") : nil)
        label = kind == .input ? string("label") : nil
        placeholder = string("placeholder", "hint")
        gap = number("gap", "spacing")
        padding = DesignInsets(library.scales.resolved(object["padding"]))
        align = string("align", "alignItems", "alignment")
        justify = string("justify", "justifyContent", "distribute")
        width = DesignLength(object["width"] ?? object["w"])
        height = DesignLength(object["height"] ?? object["h"])
        minWidth = number("minWidth")
        maxWidth = number("maxWidth")
        minHeight = number("minHeight")
        maxHeight = number("maxHeight")
        aspect = number("aspect", "aspectRatio")
        fill = DesignPaint(object["fill"] ?? object["background"] ?? object["backgroundColor"] ?? object["bg"])
        if let value = string("radius", "cornerRadius", "borderRadius"), value == "full" {
            radius = 9999
        } else {
            radius = number("radius", "cornerRadius", "borderRadius")
        }
        if let border = object["border"] as? [String: Any] {
            borderColor = border["color"] as? String
            borderWidth = (border["width"] as? Double) ?? (border["width"] as? Int).map(Double.init) ?? 1
        } else if let border = object["border"] as? String {
            borderColor = border
            borderWidth = 1
        }
        borderColor = borderColor ?? string("borderColor")
        borderWidth = borderWidth ?? number("borderWidth")
        shadow = DesignShadow(object["shadow"])
        opacity = number("opacity")
        size = number("size", "fontSize")
        weight = string("weight", "fontWeight")
        color = string("color", "textColor", "tint", "foreground")
        textAlign = string("textAlign")
        lineHeight = number("lineHeight")
        tracking = number("tracking", "letterSpacing")
        lines = (object["lines"] as? Int) ?? (object["lineLimit"] as? Int)
        font = string("font", "fontFamily")
        icon = string("icon", "symbol") ?? (kind == .icon ? string("name") : nil)
        src = string("src", "url")
        fit = string("fit", "contentMode")
        columns = object["columns"] as? Int
        variant = string("variant", "kind")
        isOn = (object["isOn"] as? Bool) ?? (object["on"] as? Bool) ?? (object["value"] as? Bool)
        values = (object["values"] as? [Any])?.compactMap { ($0 as? Double) ?? ($0 as? Int).map(Double.init) }
        chart = string("chart", "chartType")
        place = string("place", "position")
        x = number("x", "offsetX")
        y = number("y", "offsetY")
        clips = object["clip"] as? Bool ?? (string("overflow") == "clip" || string("overflow") == "hidden")
    }

    private static func children(of object: [String: Any]) -> [[String: Any]]? {
        (object["children"] as? [[String: Any]]) ?? (object["items"] as? [[String: Any]])
    }

    /// Puts a component's props in place of `{{name}}`, everywhere in it.
    private static func filling(_ value: [String: Any], with props: [String: Any]) -> [String: Any] {
        guard !props.isEmpty else { return value }
        func fill(_ value: Any) -> Any {
            switch value {
            case let text as String:
                guard text.contains("{{") else { return text }
                // A prop that's the whole value keeps its type, so a number stays a number.
                if text.hasPrefix("{{"), text.hasSuffix("}}"), let whole = props[String(text.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)] { return whole }
                return props.reduce(text) { $0.replacingOccurrences(of: "{{\($1.key)}}", with: "\($1.value)") }
            case let list as [Any]:
                return list.map(fill)
            case let object as [String: Any]:
                return object.mapValues(fill)
            default:
                return value
            }
        }
        return value.mapValues(fill)
    }

    var visibleChildren: [DesignNode] { children.filter { !$0.isHidden } }

    /// What the layer list calls this element.
    var layerName: String {
        if let name { return name }
        if let component { return component }
        if let text, !text.isEmpty { return text }
        if let icon { return icon }
        return kind.rawValue.capitalized
    }

    /// The element at a path below this one.
    func node(at path: [Int]) -> DesignNode? {
        var node = self
        for index in path {
            guard node.children.indices.contains(index) else { return nil }
            node = node.children[index]
        }
        return node
    }

    /// Every color name and icon in this element and below, for checking the screen.
    func walk(_ visit: (DesignNode) -> Void) {
        visit(self)
        for child in children { child.walk(visit) }
    }
}

/// The frame a screen is drawn in.
nonisolated struct DesignDevice: Equatable, Sendable {
    enum Chrome: Sendable { case phone, tablet, android, browser, none }

    var name: String
    var width: Double
    /// Nil grows with the content, for a long web page.
    var height: Double?
    var chrome: Chrome

    init(_ value: Any?, height requested: Any? = nil) {
        var device: DesignDevice
        if let object = value as? [String: Any] {
            let width = (object["width"] as? Double) ?? (object["width"] as? Int).map(Double.init) ?? 1200
            device = DesignDevice(name: "\(Int(width))", width: width, height: (object["height"] as? Double) ?? (object["height"] as? Int).map(Double.init), chrome: .none)
        } else {
            switch (value as? String)?.lowercased() ?? "iphone" {
            case "iphone-small", "iphone-se": device = DesignDevice(name: "iPhone SE", width: 375, height: 667, chrome: .phone)
            case "iphone-max", "iphone-pro-max": device = DesignDevice(name: "iPhone Pro Max", width: 440, height: 956, chrome: .phone)
            case "ipad", "tablet": device = DesignDevice(name: "iPad", width: 820, height: 1180, chrome: .tablet)
            case "android", "pixel": device = DesignDevice(name: "Android", width: 412, height: 915, chrome: .android)
            case "desktop", "web", "website", "browser", "mac": device = DesignDevice(name: "Desktop", width: 1440, height: 900, chrome: .browser)
            case "laptop": device = DesignDevice(name: "Laptop", width: 1280, height: 800, chrome: .browser)
            case "web-mobile", "mobile-web": device = DesignDevice(name: "Mobile web", width: 390, height: 844, chrome: .browser)
            default: device = DesignDevice(name: "iPhone", width: 393, height: 852, chrome: .phone)
            }
        }
        if let requested = DesignLength(requested) {
            switch requested {
            case let .points(height): device.height = height
            case .hug: device.height = nil
            case .fill: break
            }
        }
        self = device
    }

    init(name: String, width: Double, height: Double?, chrome: Chrome) {
        self.name = name
        self.width = width
        self.height = height
        self.chrome = chrome
    }
}

/// A component shown in the kit, with each of its variants.
nonisolated struct DesignKitItem: Equatable, Sendable, Identifiable {
    var name: String
    var node: DesignNode
    var variants: [DesignKitVariant]
    var width: Double
    var id: String { name }
}

nonisolated struct DesignKitVariant: Equatable, Sendable {
    var name: String
    var node: DesignNode

    init(_ pair: (String, DesignNode)) {
        name = pair.0
        node = pair.1
    }
}

nonisolated struct DesignTypeStyle: Equatable, Sendable {
    var name: String
    var size: Double
    var weight: String?
}

/// One file in `screens/`, or what went wrong reading it.
nonisolated struct DesignScreen: Equatable, Sendable, Identifiable {
    /// The file's name, which keeps it in place while it's rewritten.
    var id: String
    var name: String
    var group: String?
    var device: DesignDevice
    var background: DesignPaint?
    var url: String?
    var safeArea = true
    var root: DesignNode?
    var error: String?
}

/// A project's design: `vibex-design/design.json` for the shared look, one file per screen in
/// `vibex-design/screens/`. Plain JSON in the repo, so it can be reviewed, committed and built from.
nonisolated struct DesignDocument: Equatable, Sendable {
    static let folderName = "vibex-design"

    var name: String?
    var tokens: [String: String] = [:]
    var font: String?
    var screens: [DesignScreen] = []
    var error: String?
    var folder: URL
    var scales = DesignScales()
    /// Text styles with a size: the design's type scale.
    var typeScale: [DesignTypeStyle] = []
    /// The UI kit, in name order.
    var kit: [DesignKitItem] = []

    /// A kit alone counts as a design: it comes first, before any screen.
    var isEmpty: Bool { screens.isEmpty && kit.isEmpty && error == nil }

    static func folder(inProject project: URL) -> URL { project.appendingPathComponent(folderName, isDirectory: true) }

    static func load(folder: URL) -> DesignDocument {
        var document = DesignDocument(folder: folder)
        var styles: [String: [String: Any]] = [:]
        var components: [String: [String: Any]] = [:]
        let manifest = folder.appendingPathComponent("design.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            do {
                let object = try jsonObject(at: manifest)
                document.name = object["name"] as? String
                document.font = object["font"] as? String
                let tokens = (object["tokens"] as? [String: Any]) ?? [:]
                // Tokens may sit under "colors", or directly under "tokens".
                let colors = (tokens["colors"] as? [String: Any]) ?? tokens
                document.tokens = colors.compactMapValues { $0 as? String }
                styles = (object["styles"] as? [String: [String: Any]]) ?? [:]
                components = (object["components"] as? [String: [String: Any]]) ?? [:]
                func numbers(_ value: Any?) -> [String: Double] {
                    ((value as? [String: Any]) ?? [:]).compactMapValues { ($0 as? Double) ?? ($0 as? Int).map(Double.init) }
                }
                document.scales = DesignScales(radii: numbers(tokens["radii"]), spacing: numbers(tokens["spacing"]))
                document.typeScale = styles.compactMap { name, style in
                    let size = (style["size"] as? Double) ?? (style["size"] as? Int).map(Double.init)
                    return size.map { DesignTypeStyle(name: name, size: $0, weight: style["weight"] as? String) }
                }
                .sorted { ($0.size, $1.name) > ($1.size, $0.name) }
            } catch {
                document.error = "design.json: \(error.localizedDescription)"
            }
        }
        let directory = folder.appendingPathComponent("screens", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let scales = document.scales
        document.screens = files.map { screen(at: $0, styles: styles, components: components, scales: scales) }
        document.kit = components.keys.sorted().map { name in
            let definition = components[name] ?? [:]
            let names = ((definition["variants"] as? [String: Any]) ?? [:]).keys.sorted()
            let preview = (definition["preview"] as? [String: Any]) ?? [:]
            let node = DesignNode(["type": name], styles: styles, components: components, scales: scales)
            // Something square that fills its parent, like a dot in a grid, would fill the whole card.
            let fallback = node.aspect != nil && (node.width == .fill || node.width == nil) ? 96.0 : 340.0
            return DesignKitItem(
                name: name,
                node: node,
                variants: names.map { ($0, DesignNode(["type": name, "variant": $0], styles: styles, components: components, scales: scales)) }.map(DesignKitVariant.init),
                width: (preview["width"] as? Double) ?? (preview["width"] as? Int).map(Double.init) ?? fallback
            )
        }
        return document
    }

    private static func screen(at url: URL, styles: [String: [String: Any]], components: [String: [String: Any]], scales: DesignScales) -> DesignScreen {
        let id = url.lastPathComponent
        let fallback = Self.title(fromFile: url)
        do {
            let object = try jsonObject(at: url)
            let root = (object["root"] as? [String: Any]) ?? (object["body"] as? [String: Any])
            return DesignScreen(
                id: id,
                name: object["name"] as? String ?? fallback,
                group: object["group"] as? String,
                device: DesignDevice(object["device"], height: object["height"]),
                background: DesignPaint(object["background"] ?? object["fill"]),
                url: object["url"] as? String,
                safeArea: object["safeArea"] as? Bool ?? true,
                root: root.map { DesignNode($0, styles: styles, components: components, scales: scales) },
                error: root == nil ? "This screen has no \"root\" element." : nil
            )
        } catch {
            return DesignScreen(id: id, name: fallback, device: DesignDevice("iphone"), error: error.localizedDescription)
        }
    }

    private static func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DesignError("The file isn't a JSON object.")
        }
        return object
    }

    /// "02-order-details.json" → "Order Details"
    static func title(fromFile url: URL) -> String {
        let words = url.deletingPathExtension().lastPathComponent.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
        return words.drop { $0.allSatisfy(\.isNumber) }.map(\.capitalized).joined(separator: " ")
    }

    /// How many times the screens use a kit component.
    func uses(of component: String) -> Int {
        var count = 0
        for screen in screens {
            screen.root?.walk { if $0.component == component { count += 1 } }
        }
        return count
    }

    /// What's wrong that Claude can fix: unreadable files, tokens that don't exist, icons SF Symbols doesn't have.
    func problems() -> [String] {
        var found: [String] = error.map { [$0] } ?? []
        for screen in screens {
            if let error = screen.error { found.append("\(screen.id): \(error)") }
            var missing = Set<String>(), icons = Set<String>(), unknown = Set<String>()
            screen.background?.colorNames.forEach { if isMissing($0) { missing.insert($0) } }
            screen.root?.walk { node in
                let colors = (node.fill?.colorNames ?? []) + [node.color, node.borderColor, node.shadow?.color].compactMap(\.self)
                for color in colors where isMissing(color) { missing.insert(color) }
                if let type = node.unknownType { unknown.insert(type) }
                if node.kind == .icon || node.kind == .button || node.kind == .input, let icon = node.icon, NSImage(systemSymbolName: icon, accessibilityDescription: nil) == nil {
                    icons.insert(icon)
                }
            }
            if !missing.isEmpty { found.append("\(screen.id): unknown colors \(missing.sorted().joined(separator: ", "))") }
            if !icons.isEmpty { found.append("\(screen.id): not SF Symbols: \(icons.sorted().joined(separator: ", "))") }
            if !unknown.isEmpty { found.append("\(screen.id): not built in and not in the kit: \(unknown.sorted().joined(separator: ", "))") }
        }
        return found
    }

    private func isMissing(_ color: String) -> Bool {
        if color.hasPrefix("$") { return tokens[String(color.dropFirst())] == nil && DesignColor.defaultTokens[String(color.dropFirst())] == nil }
        return DesignColor.parse(color) == nil
    }
}

nonisolated struct DesignError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Reads the color strings designs are written in.
nonisolated enum DesignColor {
    struct RGBA: Equatable, Sendable { var red, green, blue, alpha: Double }

    /// What's used when a design doesn't define a token, so an early draft still looks like something.
    static let defaultTokens: [String: String] = [
        "background": "#FFFFFF", "surface": "#F4F4F6", "text": "#111114", "muted": "#6E6E78",
        "border": "#E3E3E8", "primary": "#2F6BFF", "onPrimary": "#FFFFFF",
    ]

    static func parse(_ text: String) -> RGBA? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "white": return RGBA(red: 1, green: 1, blue: 1, alpha: 1)
        case "black": return RGBA(red: 0, green: 0, blue: 0, alpha: 1)
        case "clear", "transparent", "none": return RGBA(red: 0, green: 0, blue: 0, alpha: 0)
        default: break
        }
        guard value.hasPrefix("#") else { return nil }
        var digits = String(value.dropFirst())
        if digits.count == 3 || digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let number = UInt64(digits, radix: 16) else { return nil }
        let full = digits.count == 6 ? (number << 8) | 0xFF : number
        return RGBA(red: Double((full >> 24) & 0xFF) / 255, green: Double((full >> 16) & 0xFF) / 255, blue: Double((full >> 8) & 0xFF) / 255, alpha: Double(full & 0xFF) / 255)
    }
}
