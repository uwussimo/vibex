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
    init(_ raw: [String: Any], styles: [String: [String: Any]] = [:], components: [String: [String: Any]] = [:], depth: Int = 0) {
        var object = raw
        // A component's properties sit under the element's own. The limit stops one that uses itself.
        for _ in 0..<12 {
            guard let name = (object["type"] as? String) ?? (object["component"] as? String), let component = components[name] else { break }
            var merged = component.merging(object) { $1 }
            merged["type"] = component["type"]
            merged["component"] = nil
            object = merged
        }
        // Named styles too, so what the element says itself wins.
        var names: [String] = []
        if let one = object["style"] as? String { names = [one] }
        if let many = object["style"] as? [String] { names = many }
        for name in names.reversed() {
            object = (styles[name.replacingOccurrences(of: "$", with: "")] ?? [:]).merging(object) { $1 }
        }
        let typeName = (object["type"] as? String) ?? ""
        let childObjects = (object["children"] as? [[String: Any]]) ?? (object["items"] as? [[String: Any]]) ?? []
        if let known = Self.kinds[typeName.lowercased()] {
            kind = known
        } else if !childObjects.isEmpty {
            kind = .column
        } else if object["text"] != nil || object["content"] != nil {
            kind = .text
        } else {
            kind = .column
        }
        children = depth < 60 ? childObjects.map { DesignNode($0, styles: styles, components: components, depth: depth + 1) } : []

        func number(_ names: String...) -> Double? {
            for name in names {
                if let value = object[name] as? Double { return value }
                if let value = object[name] as? Int { return Double(value) }
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
        padding = DesignInsets(object["padding"])
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
        icon = string("icon", "symbol", "name")
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

    var isEmpty: Bool { screens.isEmpty && error == nil }

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
            } catch {
                document.error = "design.json: \(error.localizedDescription)"
            }
        }
        let directory = folder.appendingPathComponent("screens", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        document.screens = files.map { screen(at: $0, styles: styles, components: components) }
        return document
    }

    private static func screen(at url: URL, styles: [String: [String: Any]], components: [String: [String: Any]]) -> DesignScreen {
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
                root: root.map { DesignNode($0, styles: styles, components: components) },
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

    /// What's wrong that Claude can fix: unreadable files, tokens that don't exist, icons SF Symbols doesn't have.
    func problems() -> [String] {
        var found: [String] = error.map { [$0] } ?? []
        for screen in screens {
            if let error = screen.error { found.append("\(screen.id): \(error)") }
            var missing = Set<String>(), icons = Set<String>()
            screen.background?.colorNames.forEach { if isMissing($0) { missing.insert($0) } }
            screen.root?.walk { node in
                let colors = (node.fill?.colorNames ?? []) + [node.color, node.borderColor, node.shadow?.color].compactMap(\.self)
                for color in colors where isMissing(color) { missing.insert(color) }
                if node.kind == .icon || node.kind == .button || node.kind == .input, let icon = node.icon, NSImage(systemSymbolName: icon, accessibilityDescription: nil) == nil {
                    icons.insert(icon)
                }
            }
            if !missing.isEmpty { found.append("\(screen.id): unknown colors \(missing.sorted().joined(separator: ", "))") }
            if !icons.isEmpty { found.append("\(screen.id): not SF Symbols: \(icons.sorted().joined(separator: ", "))") }
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
