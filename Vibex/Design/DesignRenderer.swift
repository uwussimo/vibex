import AppKit
import SwiftUI

/// What every element needs to know about the document it's in.
struct DesignTheme {
    let document: DesignDocument

    func rgba(_ name: String) -> DesignColor.RGBA? {
        if name.hasPrefix("$") {
            let token = String(name.dropFirst())
            return (document.tokens[token] ?? DesignColor.defaultTokens[token]).flatMap(DesignColor.parse)
        }
        return DesignColor.parse(name)
    }

    func color(_ name: String?) -> Color? {
        guard let name, let value = rgba(name) else { return nil }
        return Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: value.alpha)
    }

    func color(token: String) -> Color { color("$\(token)") ?? .gray }

    func font(_ node: DesignNode, defaultSize: Double = 15, defaultWeight: String? = nil) -> Font {
        let size = node.size ?? defaultSize
        let weight = Self.weight(node.weight ?? defaultWeight)
        switch (node.font ?? document.font)?.lowercased() {
        case nil, "sans", "system", "sf", "sf pro": return .system(size: size, weight: weight)
        case "rounded": return .system(size: size, weight: weight, design: .rounded)
        case "serif", "new york": return .system(size: size, weight: weight, design: .serif)
        case "mono", "monospace", "code": return .system(size: size, weight: weight, design: .monospaced)
        default:
            let name = node.font ?? document.font ?? ""
            return NSFont(name: name, size: size) != nil ? .custom(name, size: size).weight(weight) : .system(size: size, weight: weight)
        }
    }

    private static func weight(_ name: String?) -> Font.Weight {
        switch name?.lowercased() {
        case "thin", "100": .thin
        case "light", "300": .light
        case "medium", "500": .medium
        case "semibold", "600": .semibold
        case "bold", "700": .bold
        case "heavy", "800": .heavy
        case "black", "900": .black
        default: .regular
        }
    }

    /// Whether this fill is dark enough to need a light status bar.
    func isDark(_ paint: DesignPaint?) -> Bool {
        let name = paint?.colorNames.first ?? "$background"
        guard let value = rgba(name) else { return false }
        return 0.299 * value.red + 0.587 * value.green + 0.114 * value.blue < 0.5
    }
}

/// Pictures a design points at, by URL or by path from the project. Screens read them from here, so a
/// screenshot can wait until they've arrived.
@Observable
final class DesignImageStore {
    static let shared = DesignImageStore()
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var requested = Set<String>()

    func image(_ source: String, folder: URL) -> NSImage? {
        if let image = images[source] { return image }
        load(source, folder: folder)
        return nil
    }

    private func load(_ source: String, folder: URL) {
        guard requested.insert(source).inserted else { return }
        Task { if let image = await Self.fetch(source, folder: folder) { images[source] = image } }
    }

    /// Every picture in the document, waited for.
    func preload(_ document: DesignDocument) async {
        var sources = Set<String>()
        for screen in document.screens {
            screen.root?.walk { if let source = $0.src { sources.insert(source) } }
        }
        await withTaskGroup(of: (String, NSImage?).self) { group in
            for source in sources where images[source] == nil {
                let folder = document.folder
                group.addTask { (source, await Self.fetch(source, folder: folder)) }
            }
            for await (source, image) in group {
                requested.insert(source)
                if let image { images[source] = image }
            }
        }
    }

    @concurrent private static func fetch(_ source: String, folder: URL) async -> NSImage? {
        if source.hasPrefix("http://") || source.hasPrefix("https://") {
            guard let url = URL(string: source) else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
            return NSImage(data: data)
        }
        let project = folder.deletingLastPathComponent()
        for base in [folder, project] {
            if let image = NSImage(contentsOf: base.appendingPathComponent(source)) { return image }
        }
        return nil
    }
}

/// Draws one element, and through it everything below.
struct DesignNodeView: View {
    let node: DesignNode
    let theme: DesignTheme
    /// Set by a parent with `align: stretch`: take the whole cross axis.
    var stretch: Axis?

    var body: some View {
        styled(content)
    }

    @ViewBuilder
    private var content: some View {
        switch node.kind {
        case .column:
            let children = VStack(alignment: horizontal, spacing: node.gap ?? 0) { distributed(.horizontal) }
            children
        case .row:
            let children = HStack(alignment: vertical, spacing: node.gap ?? 0) { distributed(.vertical) }
            if node.clips {
                // A carousel: runs off the edge instead of squeezing to fit.
                children.fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity, alignment: .leading).clipped()
            } else {
                children
            }
        case .layer:
            ZStack(alignment: .topLeading) {
                ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                    DesignNodeView(node: child, theme: theme)
                        .frame(maxWidth: child.place == nil ? nil : .infinity, maxHeight: child.place == nil ? nil : .infinity, alignment: Self.placement(child.place))
                }
            }
        case .grid:
            let count = max(node.columns ?? 2, 1)
            Grid(horizontalSpacing: node.gap ?? 0, verticalSpacing: node.gap ?? 0) {
                ForEach(Array(stride(from: 0, to: node.children.count, by: count)), id: \.self) { start in
                    GridRow {
                        ForEach(start..<min(start + count, node.children.count), id: \.self) { index in
                            DesignNodeView(node: node.children[index], theme: theme, stretch: .horizontal)
                        }
                    }
                }
            }
        case .text:
            textView(node.text ?? "")
        case .icon:
            symbol(node.icon ?? "questionmark", size: node.size ?? 20, color: theme.color(node.color) ?? theme.color(token: "text"))
        case .image:
            picture
        case .button:
            button
        case .input:
            input
        case .toggle:
            toggle
        case .divider:
            Rectangle().fill(theme.color(node.color) ?? theme.color(token: "border")).frame(height: node.size ?? 1).frame(maxWidth: .infinity)
        case .spacer:
            Spacer(minLength: node.size ?? 0)
        case .chart:
            DesignChart(node: node, theme: theme)
        }
    }

    // MARK: Layout

    private var horizontal: HorizontalAlignment {
        switch node.align?.lowercased() {
        case "center", "middle": .center
        case "end", "right", "trailing", "flex-end": .trailing
        default: .leading
        }
    }

    private var vertical: VerticalAlignment {
        switch node.align?.lowercased() {
        case "start", "top", "flex-start": .top
        case "end", "bottom", "flex-end": .bottom
        default: .center
        }
    }

    private var isStretching: Bool { node.align?.lowercased() == "stretch" }

    /// Children, with spacers where `justify` asks and each stretched when `align` does.
    @ViewBuilder
    private func distributed(_ cross: Axis) -> some View {
        let justify = node.justify?.lowercased()
        let isBetween = justify == "between" || justify == "space-between"
        let isAround = justify == "around" || justify == "space-around" || justify == "evenly" || justify == "space-evenly"
        if isAround { Spacer(minLength: 0) }
        ForEach(Array(node.children.enumerated()), id: \.offset) { index, child in
            DesignNodeView(node: child, theme: theme, stretch: isStretching ? cross : nil)
            if isBetween || isAround, index < node.children.count - 1 { Spacer(minLength: 0) }
        }
        if isAround { Spacer(minLength: 0) }
    }

    /// Where the content sits inside a frame bigger than it.
    private var frameAlignment: Alignment {
        let justify = node.justify?.lowercased()
        let main: Int = switch justify {
        case "center", "middle": 1
        case "end", "flex-end": 2
        default: 0
        }
        let cross: Int = switch node.align?.lowercased() {
        case "center", "middle": 1
        case "end", "right", "bottom", "trailing", "flex-end": 2
        default: node.kind == .row ? 1 : 0
        }
        let (across, down) = node.kind == .row ? (main, cross) : (cross, main)
        if node.kind == .text || node.kind == .icon {
            return Self.alignment(across: Self.textColumn(node.textAlign), down: 1)
        }
        return Self.alignment(across: across, down: down)
    }

    private static func textColumn(_ align: String?) -> Int {
        switch align?.lowercased() {
        case "center": 1
        case "right", "end", "trailing": 2
        default: 0
        }
    }

    private static func alignment(across: Int, down: Int) -> Alignment {
        let table: [[Alignment]] = [[.topLeading, .top, .topTrailing], [.leading, .center, .trailing], [.bottomLeading, .bottom, .bottomTrailing]]
        return table[down][across]
    }

    private static func placement(_ place: String?) -> Alignment {
        switch place?.lowercased() {
        case "top": .top
        case "bottom": .bottom
        case "left", "leading": .leading
        case "right", "trailing": .trailing
        case "center": .center
        case "topright", "top-right", "toptrailing": .topTrailing
        case "topleft", "top-left", "topleading": .topLeading
        case "bottomright", "bottom-right", "bottomtrailing": .bottomTrailing
        case "bottomleft", "bottom-left", "bottomleading": .bottomLeading
        default: .topLeading
        }
    }

    // MARK: Style

    private func styled(_ view: some View) -> some View {
        let shape = RoundedRectangle(cornerRadius: min(node.radius ?? 0, 2000), style: .continuous)
        let insets = node.padding
        var wantsWidth: CGFloat?
        var wantsHeight: CGFloat?
        if case let .points(value) = node.width { wantsWidth = CGFloat(value) }
        if case let .points(value) = node.height { wantsHeight = CGFloat(value) }
        let fillsWidth = node.width == .fill || (node.width == nil && stretch == .horizontal)
        let fillsHeight = node.height == .fill || (node.height == nil && stretch == .vertical)
        let minWidth = node.minWidth.map { CGFloat($0) }, minHeight = node.minHeight.map { CGFloat($0) }
        let maxWidth: CGFloat? = fillsWidth ? .infinity : node.maxWidth.map { CGFloat($0) }
        let maxHeight: CGFloat? = fillsHeight ? .infinity : node.maxHeight.map { CGFloat($0) }
        let spacing = EdgeInsets(top: insets?.top ?? 0, leading: insets?.left ?? 0, bottom: insets?.bottom ?? 0, trailing: insets?.right ?? 0)
        return view
            .padding(spacing)
            .frame(width: wantsWidth, height: wantsHeight, alignment: frameAlignment)
            .frame(minWidth: minWidth, maxWidth: maxWidth, minHeight: minHeight, maxHeight: maxHeight, alignment: frameAlignment)
            .modifier(AspectIfSet(ratio: node.aspect))
            .background { if let fill = node.fill { paint(fill).clipShape(shape) } }
            .overlay { if let border = theme.color(node.borderColor) { shape.strokeBorder(border, lineWidth: CGFloat(node.borderWidth ?? 1)) } }
            .clipShape(ClippedShape(enabled: node.clips || (node.radius != nil && node.kind == .image), radius: node.radius ?? 0))
            .shadow(color: shadowColor, radius: CGFloat(node.shadow?.blur ?? 0) / 2, y: CGFloat(node.shadow?.y ?? 0))
            .opacity(node.opacity ?? 1)
            .offset(x: CGFloat(node.x ?? 0), y: CGFloat(node.y ?? 0))
    }

    private var shadowColor: Color {
        guard let shadow = node.shadow else { return .clear }
        return theme.color(shadow.color) ?? .black.opacity(0.14)
    }

    @ViewBuilder
    private func paint(_ paint: DesignPaint) -> some View {
        switch paint {
        case let .color(name):
            theme.color(name) ?? .clear
        case let .gradient(colors, angle):
            let radians = (angle - 90) * .pi / 180
            LinearGradient(
                colors: colors.compactMap { theme.color($0) },
                startPoint: UnitPoint(x: 0.5 - cos(radians) / 2, y: 0.5 - sin(radians) / 2),
                endPoint: UnitPoint(x: 0.5 + cos(radians) / 2, y: 0.5 + sin(radians) / 2)
            )
        }
    }

    // MARK: Elements

    private func textView(_ text: String) -> some View {
        let size = node.size ?? 15
        return Text(text)
            .font(theme.font(node))
            .foregroundStyle(theme.color(node.color) ?? theme.color(token: "text"))
            .multilineTextAlignment(Self.textAlignment(node.textAlign))
            .lineLimit(node.lines)
            .lineSpacing(node.lineHeight.map { max($0 - size * 1.2, 0) } ?? 0)
            .tracking(node.tracking ?? 0)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func textAlignment(_ align: String?) -> TextAlignment {
        switch align?.lowercased() {
        case "center": .center
        case "right", "end", "trailing": .trailing
        default: .leading
        }
    }

    private func symbol(_ name: String, size: Double, color: Color) -> some View {
        let known = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        return Image(systemName: known ? name : "questionmark.square.dashed")
            .font(.system(size: size, weight: Self.symbolWeight(node.weight)))
            .foregroundStyle(color)
    }

    private static func symbolWeight(_ name: String?) -> Font.Weight {
        switch name?.lowercased() {
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        default: .regular
        }
    }

    @ViewBuilder
    private var picture: some View {
        let needsHeight = node.height == nil && node.aspect == nil
        Group {
            if let source = node.src, let image = DesignImageStore.shared.image(source, folder: theme.document.folder) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: node.fit?.lowercased() == "fit" || node.fit?.lowercased() == "contain" ? .fit : .fill)
            } else {
                // No picture yet: a calm placeholder that still reads as an image.
                ZStack {
                    theme.color(node.color) ?? theme.color(token: "muted").opacity(0.14)
                    Image(systemName: node.icon ?? "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.color(token: "muted").opacity(0.7))
                }
            }
        }
        .frame(maxWidth: node.width == nil ? .infinity : nil)
        .frame(height: needsHeight ? 160 : nil)
        .clipped()
    }

    private var button: some View {
        let variant = node.variant?.lowercased() ?? "primary"
        let primary = theme.color(token: "primary")
        let isPrimary = variant == "primary" || variant == "filled"
        let foreground = theme.color(node.color) ?? (isPrimary ? theme.color(token: "onPrimary") : (variant == "ghost" || variant == "link" ? primary : theme.color(token: "text")))
        let radius = node.radius ?? 12
        return HStack(spacing: 8) {
            if let icon = node.icon { symbol(icon, size: (node.size ?? 16) + 1, color: foreground) }
            if let text = node.text {
                Text(text).font(theme.font(node, defaultSize: 16, defaultWeight: "semibold")).foregroundStyle(foreground).lineLimit(1)
            }
        }
        .padding(.horizontal, node.padding == nil ? (variant == "link" ? 0 : 18) : 0)
        .padding(.vertical, node.padding == nil ? (variant == "link" ? 0 : 13) : 0)
        .frame(maxWidth: node.width == .fill || stretch == .horizontal ? .infinity : nil)
        .background {
            if node.fill == nil {
                let shape = RoundedRectangle(cornerRadius: min(radius, 2000), style: .continuous)
                if isPrimary {
                    shape.fill(primary)
                } else if variant == "secondary" || variant == "tonal" {
                    shape.fill(theme.color(token: "surface"))
                } else if variant == "outline" {
                    shape.strokeBorder(theme.color(token: "border"))
                }
            }
        }
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label = node.label {
                Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.color(token: "muted"))
            }
            HStack(spacing: 8) {
                if let icon = node.icon { symbol(icon, size: 15, color: theme.color(token: "muted")) }
                Text(node.text ?? node.placeholder ?? "")
                    .font(theme.font(node, defaultSize: 15))
                    .foregroundStyle(node.text == nil ? theme.color(token: "muted") : theme.color(node.color) ?? theme.color(token: "text"))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                if node.fill == nil {
                    RoundedRectangle(cornerRadius: min(node.radius ?? 12, 2000), style: .continuous).fill(theme.color(token: "surface"))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var toggle: some View {
        let isOn = node.isOn ?? true
        return Capsule()
            .fill(isOn ? theme.color(node.color) ?? theme.color(token: "primary") : theme.color(token: "border"))
            .frame(width: 51, height: 31)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 27, height: 27).shadow(color: .black.opacity(0.15), radius: 2, y: 1).padding(2)
            }
    }
}

private struct AspectIfSet: ViewModifier {
    let ratio: Double?
    func body(content: Content) -> some View {
        if let ratio { content.aspectRatio(ratio, contentMode: .fit) } else { content }
    }
}

private struct ClippedShape: Shape {
    let enabled: Bool
    let radius: Double
    func path(in rect: CGRect) -> Path {
        enabled ? RoundedRectangle(cornerRadius: min(radius, 2000), style: .continuous).path(in: rect) : Rectangle().path(in: rect.insetBy(dx: -4000, dy: -4000))
    }
}

/// A small chart for dashboards: bars or a line.
private struct DesignChart: View {
    let node: DesignNode
    let theme: DesignTheme

    var body: some View {
        let values = node.values ?? []
        let peak = max(values.max() ?? 1, 0.0001)
        let tint = theme.color(node.color) ?? theme.color(token: "primary")
        Group {
            if node.chart?.lowercased() == "line" {
                GeometryReader { geometry in
                    let step = geometry.size.width / max(CGFloat(values.count - 1), 1)
                    let points = values.enumerated().map { CGPoint(x: CGFloat($0) * step, y: geometry.size.height * (1 - CGFloat($1 / peak) * 0.92)) }
                    Path { path in
                        path.addLines(points)
                        path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                        path.addLine(to: CGPoint(x: 0, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { path in path.addLines(points) }
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            } else {
                GeometryReader { geometry in
                    HStack(alignment: .bottom, spacing: node.gap ?? 6) {
                        ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(tint)
                                .frame(height: max(geometry.size.height * CGFloat(value / peak), 2))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: node.height == nil ? 120 : nil)
    }
}

/// A whole screen in its device: the frame, the system bars, and the content inside.
struct DesignScreenView: View {
    let screen: DesignScreen
    let theme: DesignTheme

    private var device: DesignDevice { screen.device }
    private var isDark: Bool { theme.isDark(screen.background) }
    private var barColor: Color { isDark ? .white : .black }

    var body: some View {
        switch device.chrome {
        case .phone:
            bezel(radius: 56, bezel: 10) {
                content(top: device.height.map { $0 < 700 } == true ? 20 : 54, bottom: device.height.map { $0 < 700 } == true ? 0 : 30)
                    .overlay(alignment: .top) { phoneStatusBar }
                    .overlay(alignment: .bottom) {
                        Capsule().fill(barColor).frame(width: 134, height: 5).padding(.bottom, 8)
                    }
            }
        case .tablet:
            bezel(radius: 30, bezel: 14) {
                content(top: 24, bottom: 20).overlay(alignment: .top) { tabletStatusBar }
            }
        case .android:
            bezel(radius: 38, bezel: 8) {
                content(top: 36, bottom: 22).overlay(alignment: .top) { androidStatusBar }
            }
        case .browser:
            VStack(spacing: 0) {
                browserBar
                content(top: 0, bottom: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1)))
        case .none:
            content(top: 0, bottom: 0)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func content(top: Double, bottom: Double) -> some View {
        let useSafeArea = screen.safeArea
        return Group {
            if let root = screen.root {
                DesignNodeView(node: root, theme: theme)
                    .frame(maxWidth: .infinity, maxHeight: device.height == nil ? nil : .infinity, alignment: .topLeading)
                    .padding(.top, useSafeArea ? top : 0)
                    .padding(.bottom, useSafeArea ? bottom : 0)
            }
        }
        .frame(width: device.width, height: device.height.map { CGFloat($0) }, alignment: .topLeading)
        .background { background }
        .clipped()
    }

    @ViewBuilder
    private var background: some View {
        switch screen.background {
        case let .color(name):
            theme.color(name) ?? theme.color(token: "background")
        case let .gradient(colors, angle):
            let radians = (angle - 90) * .pi / 180
            LinearGradient(
                colors: colors.compactMap { theme.color($0) },
                startPoint: UnitPoint(x: 0.5 - cos(radians) / 2, y: 0.5 - sin(radians) / 2),
                endPoint: UnitPoint(x: 0.5 + cos(radians) / 2, y: 0.5 + sin(radians) / 2)
            )
        case nil:
            theme.color(token: "background")
        }
    }

    private func bezel(radius: CGFloat, bezel: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        content()
            .clipShape(RoundedRectangle(cornerRadius: radius - bezel, style: .continuous))
            .padding(bezel)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(white: 0.06)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1.5))
    }

    private var phoneStatusBar: some View {
        HStack {
            Text("9:41").font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity)
            if (device.height ?? 852) >= 700 {
                Capsule().fill(.black).frame(width: 122, height: 34)
            }
            HStack(spacing: 5) {
                Image(systemName: "cellularbars")
                Image(systemName: "wifi")
                Image(systemName: "battery.100percent")
            }
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(barColor)
        .padding(.top, (device.height ?? 852) >= 700 ? 11 : 2)
        .padding(.horizontal, 8)
    }

    private var tabletStatusBar: some View {
        HStack(spacing: 6) {
            Text("9:41").font(.system(size: 13, weight: .semibold))
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.100percent")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(barColor)
        .padding(.horizontal, 22)
        .padding(.top, 6)
    }

    private var androidStatusBar: some View {
        HStack(spacing: 5) {
            Text("9:41").font(.system(size: 13, weight: .medium))
            Spacer()
            Circle().fill(.black).frame(width: 18, height: 18).offset(x: -device.width / 2 + 60)
            Image(systemName: "wifi")
            Image(systemName: "battery.100percent")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(barColor)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var browserBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                ForEach([Color(hex: 0xFF5F57), Color(hex: 0xFEBC2E), Color(hex: 0x28C840)], id: \.self) { color in
                    Circle().fill(color).frame(width: 12, height: 12)
                }
            }
            Spacer(minLength: 0)
            Text(screen.url ?? "example.com")
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.45))
                .lineLimit(1)
                .frame(maxWidth: min(device.width * 0.5, 460))
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(white: 0.93)))
            Spacer(minLength: 0)
            Color.clear.frame(width: 52, height: 1)
        }
        .padding(.horizontal, 14)
        .frame(width: device.width, height: 42)
        .background(Color(white: 0.985))
    }
}
