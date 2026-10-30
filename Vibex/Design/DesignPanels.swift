import AppKit
import SwiftUI

/// A panel floating over the canvas, so the board keeps its width on a narrow pane.
private struct DesignPanel<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: width)
            .frame(maxHeight: .infinity, alignment: .top)
            .fixedSize(horizontal: true, vertical: false)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
    }
}

// MARK: - Layers

/// The selected screen's tree, or what there is to pick when nothing is selected.
struct DesignLayersPanel: View {
    let model: DesignModel
    /// Rows the user opened or closed, against what each starts as.
    @State private var toggled = Set<[Int]>()

    var body: some View {
        DesignPanel(width: 224) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    if model.selection != nil {
                        Button { model.select(nil) } label: {
                            IconView(.chevronLeft, size: 13).foregroundStyle(Theme.muted).frame(width: 18, height: 18).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("All screens")
                    }
                    Text(title).font(.vibex(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                Rectangle().fill(Theme.line).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            if let selection = model.selection, let root = model.root(of: selection) {
                                DesignLayerRow(model: model, node: root, screen: selection, depth: 0, toggled: $toggled)
                            } else {
                                overview
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.element) { _, path in
                        guard let path else { return }
                        withAnimation(.spring(response: 0.3, dampingFraction: 1)) { proxy.scrollTo(path) }
                    }
                }
            }
        }
    }

    private var title: String {
        if let kit = model.kitSelection { return kit.variant.map { "\(kit.name) · \($0)" } ?? kit.name }
        return model.selectedScreen?.name ?? "Layers"
    }

    @ViewBuilder
    private var overview: some View {
        heading("Screens")
        ForEach(model.document.screens) { screen in
            pick(screen.name, isComponent: false) { model.select(element: [], in: screen.id) }
        }
        if !model.document.kit.isEmpty {
            heading("UI Kit").padding(.top, 8)
            ForEach(model.document.kit) { item in
                pick(item.name, isComponent: true) { model.select(element: [], in: "kit:\(item.name)") }
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.vibex(size: 11, weight: .medium)).foregroundStyle(Theme.faint).padding(.horizontal, 8).padding(.vertical, 4)
    }

    private func pick(_ name: String, isComponent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isComponent { DesignComponentMark() }
                Text(name).font(.vibex(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DesignLayerRow: View {
    let model: DesignModel
    let node: DesignNode
    let screen: String
    let depth: Int
    @Binding var toggled: Set<[Int]>
    @State private var isHovering = false
    @State private var isDropTarget = false

    private var isSelected: Bool { model.selection == screen && model.element == node.path }
    /// A component starts closed, since its insides are the kit's business. The way to the selection stays open.
    private var isCollapsed: Bool {
        if model.selection == screen, let element = model.element, element.count > node.path.count, Array(element.prefix(node.path.count)) == node.path { return false }
        return (node.component != nil && depth > 0) != toggled.contains(node.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row
            if !isCollapsed {
                ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                    DesignLayerRow(model: model, node: child, screen: screen, depth: depth + 1, toggled: $toggled)
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 4) {
            Group {
                if node.children.isEmpty {
                    Color.clear
                } else {
                    Button {
                        if toggled.contains(node.path) { toggled.remove(node.path) } else { toggled.insert(node.path) }
                    } label: {
                        IconView(isCollapsed ? .chevronRight : .chevronDown, size: 11).foregroundStyle(Theme.faint).frame(width: 14, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 14)
            if node.component != nil { DesignComponentMark() }
            Text(node.layerName)
                .font(.vibex(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(node.isHidden ? Theme.faint : (node.instance != nil && node.component == nil ? Theme.muted : Theme.text))
                .lineLimit(1)
            Spacer(minLength: 0)
            if (isHovering || node.isHidden), !node.path.isEmpty {
                Button { model.setHidden(!node.isHidden, on: node) } label: {
                    IconView(node.isHidden ? .eyeOff : .eye, size: 12).foregroundStyle(Theme.faint).frame(width: 18, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isEditingLocked)
                .help(node.isHidden ? "Show" : "Hide")
            }
        }
        .padding(.leading, CGFloat(depth) * 12 + 2)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(isSelected ? Theme.accent.opacity(0.22) : (isHovering ? Color.white.opacity(0.05) : .clear)))
        .overlay(alignment: .top) { if isDropTarget { Rectangle().fill(Theme.accent).frame(height: 2) } }
        .contentShape(Rectangle())
        .onTapGesture { model.select(element: node.path, in: screen) }
        .onHover { inside in
            isHovering = inside
            model.hovered = inside ? DesignHover(screen: screen, path: node.path) : nil
        }
        .id(node.path)
        .contextMenu { menu }
        .modifier(DesignLayerDrag(model: model, node: node, screen: screen, isDropTarget: $isDropTarget))
    }

    @ViewBuilder
    private var menu: some View {
        Button("Duplicate") {
            model.select(element: node.path, in: screen)
            model.duplicateSelected()
        }
        .disabled(model.isEditingLocked || !canEditStructure)
        Button(node.isHidden ? "Show" : "Hide") { model.setHidden(!node.isHidden, on: node) }.disabled(model.isEditingLocked || node.path.isEmpty)
        if node.main != nil, model.kitSelection == nil {
            Divider()
            Button("Go to Main Component") { model.revealInKit(node) }
        }
        Divider()
        Button("Delete", role: .destructive) {
            model.select(element: node.path, in: screen)
            model.deleteSelected()
        }
        .disabled(model.isEditingLocked || !canEditStructure)
    }

    private var canEditStructure: Bool {
        model.selection == screen && model.structurePlace(of: node) != nil
    }
}

/// Dragging reorders among siblings. Inside a use the kit decides the order, so nothing drags there.
private struct DesignLayerDrag: ViewModifier {
    let model: DesignModel
    let node: DesignNode
    let screen: String
    @Binding var isDropTarget: Bool

    func body(content: Content) -> some View {
        if model.selection == screen, model.structurePlace(of: node) != nil, !model.isEditingLocked {
            content
                .draggable(node.path.map(String.init).joined(separator: "/")) {
                    Text(node.layerName).font(.vibex(size: 12)).padding(6).background(Theme.raised, in: RoundedRectangle(cornerRadius: 5))
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let item = items.first else { return false }
                    let source = item.split(separator: "/").compactMap { Int($0) }
                    guard source != node.path, source.dropLast() == node.path.dropLast(),
                          let from = source.last, let to = node.path.last,
                          let moving = model.selection.flatMap({ model.root(of: $0)?.node(at: source) }) else { return false }
                    // Dropped on a row, it lands above it, once the row it left has closed up.
                    model.move(moving, to: from < to ? to - 1 : to)
                    return true
                } isTargeted: { isDropTarget = $0 }
        } else {
            content
        }
    }
}

// MARK: - Inspector

/// What's selected, or the design's foundations when nothing is.
struct DesignInspector: View {
    let model: DesignModel

    var body: some View {
        DesignPanel(width: 268) {
            if !model.showsStyle, let node = model.selectedNode {
                DesignPropertiesView(model: model, node: node)
            } else {
                DesignStyleView(model: model)
            }
        }
    }
}

private struct DesignPropertiesView: View {
    let model: DesignModel
    let node: DesignNode

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.isEditingLocked { lockedNote }
                    if model.kitSelection != nil { kitNote } else if node.instance != nil { useSection }
                    contentSection
                    if !node.variantNames.isEmpty, model.kitSelection == nil { variantSection }
                    textSection
                    layoutSection
                    appearanceSection
                }
                .disabled(model.isEditingLocked)
            }
        }
        // A new selection starts its fields fresh.
        .id("\(model.selection ?? "")\(node.path)")
    }

    private var header: some View {
        HStack(spacing: 7) {
            Button(action: model.selectParent) {
                IconView(.chevronLeft, size: 13).foregroundStyle(Theme.muted).frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Select the parent (Esc)")
            if node.component != nil { DesignComponentMark() }
            Text(node.layerName).font(.vibex(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 0)
            Text(node.kind.rawValue).font(.vibex(size: 11)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    private var lockedNote: some View {
        Text("Claude is working. You can edit again when it's done.")
            .font(.vibex(size: 11.5)).foregroundStyle(Theme.muted)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised)
    }

    private var kitNote: some View {
        DesignSection("Main component") {
            let name = node.main?.component ?? node.component ?? ""
            let uses = model.document.uses(of: name)
            Text("Changes here reach \(uses == 1 ? "1 use" : "all \(uses) uses") of \(name).")
                .font(.vibex(size: 11.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var useSection: some View {
        DesignSection("From the UI kit") {
            let name = node.main?.component ?? ""
            let uses = model.document.uses(of: name)
            Picker("", selection: Binding(get: { model.styleOnlyHere }, set: { model.styleOnlyHere = $0 })) {
                Text(uses == 1 ? "1 use" : "All \(uses) uses").tag(false)
                Text("Only here").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            Text(model.styleOnlyHere ? "Style changes stay on this one." : "Style changes reach every \(name). Text and images always stay on this one.")
                .font(.vibex(size: 11)).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Go to Main") { model.revealInKit(node) }
                if model.isOverridden(node) {
                    Button("Reset to Kit") { model.resetToKit(node) }
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        switch node.kind {
        case .text:
            DesignSection("Text") { DesignTextArea(value: node.text ?? "") { model.set("text", to: $0, on: node, isContent: true) } }
        case .button:
            DesignSection("Content") {
                DesignRow("Label") { DesignTextInput(value: node.text ?? "") { model.set("text", to: $0.nilIfEmpty, on: node, isContent: true) } }
                iconRow
            }
        case .input:
            DesignSection("Content") {
                DesignRow("Label") { DesignTextInput(value: node.label ?? "") { model.set("label", to: $0.nilIfEmpty, on: node, isContent: true) } }
                DesignRow("Hint") { DesignTextInput(value: node.placeholder ?? "") { model.set("placeholder", to: $0.nilIfEmpty, on: node, isContent: true) } }
                iconRow
            }
        case .icon:
            DesignSection("Icon") { iconRow }
        case .image:
            DesignSection("Image") {
                DesignRow("Source") { DesignTextInput(value: node.src ?? "", placeholder: "URL or path") { model.set("src", to: $0.nilIfEmpty, on: node, isContent: true) } }
                DesignRow("Fit") {
                    DesignChoice(value: node.fit ?? "fill", options: ["fill", "fit"]) { model.set("fit", to: $0, on: node) }
                }
            }
        case .toggle:
            DesignSection("State") {
                DesignRow("On") {
                    Toggle("", isOn: Binding(get: { node.isOn ?? true }, set: { model.set("isOn", to: $0, on: node, isContent: true) })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }
        default:
            EmptyView()
        }
    }

    private var iconRow: some View {
        DesignRow("Icon") {
            DesignTextInput(value: node.icon ?? "", placeholder: "SF Symbol") { model.set("icon", to: $0.nilIfEmpty, on: node, isContent: true) }
        }
    }

    private var variantSection: some View {
        DesignSection("Variant") {
            Picker("", selection: Binding(get: { node.activeVariant ?? "" }, set: { model.setVariant($0.nilIfEmpty, on: node) })) {
                Text("Default").tag("")
                ForEach(node.variantNames, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var textSection: some View {
        if [.text, .button, .input].contains(node.kind) {
            DesignSection("Type") {
                DesignRow("Size") { DesignNumberInput(value: node.size, placeholder: "Auto") { model.set("size", to: $0, on: node) } }
                DesignRow("Weight") {
                    DesignChoice(value: node.weight ?? "regular", options: ["regular", "medium", "semibold", "bold", "heavy"]) { model.set("weight", to: $0, on: node) }
                }
                DesignRow("Color") { DesignColorInput(value: node.color, document: model.document) { model.set("color", to: $0, on: node) } }
                if node.kind == .text {
                    DesignRow("Align") {
                        DesignChoice(value: node.textAlign ?? "left", options: ["left", "center", "right"]) { model.set("textAlign", to: $0, on: node) }
                    }
                }
            }
        } else if node.kind == .icon {
            DesignSection("Look") {
                DesignRow("Size") { DesignNumberInput(value: node.size, placeholder: "20") { model.set("size", to: $0, on: node) } }
                DesignRow("Color") { DesignColorInput(value: node.color, document: model.document) { model.set("color", to: $0, on: node) } }
            }
        }
    }

    private var layoutSection: some View {
        DesignSection("Layout") {
            DesignRow("Width") { DesignLengthInput(value: node.width) { model.set("width", to: $0, on: node) } }
            DesignRow("Height") { DesignLengthInput(value: node.height) { model.set("height", to: $0, on: node) } }
            DesignRow("Padding") { DesignPaddingInput(value: node.padding) { model.set("padding", to: $0, on: node) } }
            if [.column, .row, .grid].contains(node.kind) {
                DesignRow("Gap") { DesignNumberInput(value: node.gap, placeholder: "0") { model.set("gap", to: $0, on: node) } }
            }
            if [.column, .row].contains(node.kind) {
                DesignRow("Align") {
                    DesignChoice(value: node.align ?? "start", options: ["start", "center", "end", "stretch"]) { model.set("align", to: $0, on: node) }
                }
                DesignRow("Justify") {
                    DesignChoice(value: node.justify ?? "start", options: ["start", "center", "end", "between", "around"]) { model.set("justify", to: $0, on: node) }
                }
            }
        }
    }

    private var appearanceSection: some View {
        DesignSection("Appearance") {
            DesignRow("Fill") { DesignColorInput(value: node.fill?.colorNames.first, isGradient: node.fill?.colorNames.count ?? 0 > 1, document: model.document) { model.set("fill", to: $0, on: node) } }
            DesignRow("Corners") {
                HStack(spacing: 4) {
                    DesignNumberInput(value: node.radius, placeholder: "0") { model.set("radius", to: $0, on: node) }
                    if !model.document.scales.radii.isEmpty {
                        DesignTokenMenu(current: node.radiusToken, names: model.document.scales.radii.sorted { $0.value < $1.value }.map(\.key)) { model.set("radius", to: "$\($0)", on: node) }
                    }
                }
            }
            DesignRow("Border") { DesignColorInput(value: node.borderColor, document: model.document) { model.set("border", to: $0.map { ["color": $0, "width": node.borderWidth ?? 1] as [String: Any] }, on: node) } }
            DesignRow("Shadow") {
                DesignChoice(value: shadowName, options: ["none", "sm", "md", "lg"]) { model.set("shadow", to: $0 == "none" ? nil : $0, on: node) }
            }
            DesignRow("Opacity") { DesignNumberInput(value: node.opacity.map { ($0 * 100).rounded() }, placeholder: "100") { model.set("opacity", to: $0.map { min(max($0 / 100, 0), 1) }, on: node) } }
        }
    }

    private var shadowName: String {
        guard let shadow = node.shadow else { return "none" }
        return shadow.blur <= 3 ? "sm" : (shadow.blur <= 14 ? "md" : "lg")
    }
}

// MARK: - Style

/// One place for the look of the whole design. Everything here is a token, so every screen follows.
private struct DesignStyleView: View {
    let model: DesignModel

    private static let fonts = ["sans", "rounded", "serif", "mono"]

    private var tokens: [String] {
        let order = ["background", "surface", "text", "muted", "border", "primary", "onPrimary"]
        return Array(Set(order).union(model.document.tokens.keys)).sorted { a, b in
            ((order.firstIndex(of: a) ?? order.count), a) < ((order.firstIndex(of: b) ?? order.count), b)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text("Style").font(.vibex(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                if model.showsStyle {
                    Button { model.showsStyle = false } label: {
                        IconView(.close, size: 11).foregroundStyle(Theme.muted).frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DesignSection("Colors") {
                        ForEach(tokens, id: \.self) { name in
                            DesignRow(name) {
                                DesignHexInput(value: model.document.tokens[name] ?? DesignColor.defaultTokens[name] ?? "#808080") { model.setColorToken(name, to: $0) }
                            }
                        }
                    }
                    DesignSection("Font") {
                        DesignChoice(value: model.document.font?.lowercased() ?? "sans", options: Self.fonts) { model.setFont($0) }
                    }
                    if !model.document.typeScale.isEmpty {
                        DesignSection("Type scale") {
                            ForEach(model.document.typeScale, id: \.name) { style in
                                DesignRow(style.name) {
                                    HStack(spacing: 4) {
                                        DesignNumberInput(value: style.size, placeholder: "") { value in
                                            if let value { model.setTextStyle(style.name, "size", to: value) }
                                        }
                                        .frame(width: 44)
                                        DesignChoice(value: style.weight ?? "regular", options: ["regular", "medium", "semibold", "bold", "heavy"]) { model.setTextStyle(style.name, "weight", to: $0) }
                                    }
                                }
                            }
                        }
                    }
                    if !model.document.scales.radii.isEmpty {
                        DesignSection("Corners") {
                            ForEach(model.document.scales.radii.sorted { $0.value < $1.value }, id: \.key) { name, value in
                                DesignRow(name) {
                                    DesignNumberInput(value: value, placeholder: "") { if let new = $0 { model.setScale("radii", name, to: new) } }
                                }
                            }
                        }
                    }
                    if !model.document.scales.spacing.isEmpty {
                        DesignSection("Spacing") {
                            ForEach(model.document.scales.spacing.sorted { $0.value < $1.value }, id: \.key) { name, value in
                                DesignRow(name) {
                                    DesignNumberInput(value: value, placeholder: "") { if let new = $0 { model.setScale("spacing", name, to: new) } }
                                }
                            }
                        }
                    }
                }
                .disabled(model.isEditingLocked)
            }
        }
    }
}

// MARK: - Fields

private struct DesignSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.vibex(size: 11, weight: .medium)).foregroundStyle(Theme.faint)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

private struct DesignRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.vibex(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(1).frame(width: 72, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 24)
    }
}

private extension View {
    func designFieldStyle(isFocused: Bool = false) -> some View {
        padding(.horizontal, 7)
            .frame(height: 24)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(isFocused ? Theme.accent : .clear))
    }
}

/// Commits as you type, a moment after you stop, and on Return.
private struct DesignTextInput: View {
    let value: String
    var placeholder = ""
    let commit: (String) -> Void
    @State private var draft = ""
    @State private var pending: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(.vibex(size: 11.5))
            .foregroundStyle(Theme.text)
            .focused($isFocused)
            .designFieldStyle(isFocused: isFocused)
            .onAppear { draft = value }
            .onChange(of: value) { _, new in if !isFocused { draft = new } }
            .onChange(of: draft) { _, new in
                guard new != value else { return }
                pending?.cancel()
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    if !Task.isCancelled { commit(new) }
                }
            }
            .onSubmit {
                pending?.cancel()
                if draft != value { commit(draft) }
            }
    }
}

private struct DesignTextArea: View {
    let value: String
    let commit: (String) -> Void
    @State private var draft = ""
    @State private var pending: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.vibex(size: 12))
            .foregroundStyle(Theme.text)
            .lineLimit(2...8)
            .focused($isFocused)
            .padding(7)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(isFocused ? Theme.accent : .clear))
            .onAppear { draft = value }
            .onChange(of: value) { _, new in if !isFocused { draft = new } }
            .onChange(of: draft) { _, new in
                guard new != value else { return }
                pending?.cancel()
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    if !Task.isCancelled { commit(new) }
                }
            }
    }
}

private struct DesignNumberInput: View {
    let value: Double?
    let placeholder: String
    /// Nil clears the property.
    let commit: (Double?) -> Void

    var body: some View {
        DesignTextInput(value: value.map(Self.format) ?? "", placeholder: placeholder) { text in
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { commit(nil) } else if let number = Double(trimmed) { commit(number) }
        }
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// "Fill", "hug" or a number of points.
private struct DesignLengthInput: View {
    let value: DesignLength?
    let commit: (Any?) -> Void

    var body: some View {
        DesignTextInput(value: text, placeholder: "Auto") { input in
            let trimmed = input.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.isEmpty { commit(nil) } else if let number = Double(trimmed) { commit(number) } else if trimmed == "fill" || trimmed == "hug" { commit(trimmed) }
        }
        .help("A number, fill or hug")
    }

    private var text: String {
        switch value {
        case let .points(points): DesignNumberInput.format(points)
        case .fill: "fill"
        case .hug: "hug"
        case nil: ""
        }
    }
}

/// One number for every side, or "12, 16", or all four.
private struct DesignPaddingInput: View {
    let value: DesignInsets?
    let commit: ([Double]?) -> Void

    var body: some View {
        DesignTextInput(value: text, placeholder: "0") { input in
            let numbers = input.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
            if input.trimmingCharacters(in: .whitespaces).isEmpty {
                commit(nil)
            } else if [1, 2, 4].contains(numbers.count) {
                commit(numbers)
            }
        }
        .help("All sides, or vertical, horizontal, or top, right, bottom, left")
    }

    private var text: String {
        guard let value else { return "" }
        let format = DesignNumberInput.format
        if value.top == value.bottom, value.left == value.right {
            return value.top == value.left ? format(value.top) : "\(format(value.top)), \(format(value.left))"
        }
        return [value.top, value.right, value.bottom, value.left].map(format).joined(separator: ", ")
    }
}

private struct DesignChoice: View {
    let value: String
    let options: [String]
    let commit: (String) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(option.capitalized) { commit(option) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(value.capitalized).font(.vibex(size: 11.5)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
                IconView(.chevronDown, size: 10).foregroundStyle(Theme.faint)
            }
            .designFieldStyle()
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// A shortcut onto the design's named sizes.
private struct DesignTokenMenu: View {
    let current: String?
    let names: [String]
    let pick: (String) -> Void

    var body: some View {
        Menu {
            ForEach(names, id: \.self) { name in
                Button(name) { pick(name) }
            }
        } label: {
            Text(current ?? "$").font(.vibex(size: 11)).foregroundStyle(current == nil ? Theme.faint : Theme.accent).frame(minWidth: 18, minHeight: 24).contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Use a corner size from the design")
    }
}

/// A token from the design, or any color.
private struct DesignColorInput: View {
    let value: String?
    var isGradient = false
    let document: DesignDocument
    let commit: (String?) -> Void

    private var theme: DesignTheme { DesignTheme(document: document) }
    private var names: [String] { Array(Set(document.tokens.keys).union(DesignColor.defaultTokens.keys)).sorted() }

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Button("None") { commit(nil) }
                Divider()
                ForEach(names, id: \.self) { name in
                    Button(name) { commit("$\(name)") }
                }
            } label: {
                HStack(spacing: 5) {
                    swatch
                    Text(label).font(.vibex(size: 11.5)).foregroundStyle(value == nil ? Theme.faint : Theme.text).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .designFieldStyle()
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            ColorPicker("", selection: Binding(get: { theme.color(value) ?? .gray }, set: { commit(DesignHex.string($0)) }), supportsOpacity: true)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 26)
        }
    }

    private var label: String {
        if isGradient { return "Gradient" }
        guard let value else { return "None" }
        return value.hasPrefix("$") ? String(value.dropFirst()) : value.uppercased()
    }

    private var swatch: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(theme.color(value) ?? .clear)
            .frame(width: 14, height: 14)
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.white.opacity(0.2)))
    }
}

/// A plain color value, for defining a token.
private struct DesignHexInput: View {
    let value: String
    let commit: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            DesignTextInput(value: value.uppercased()) { text in
                if DesignColor.parse(text) != nil { commit(text) }
            }
            ColorPicker("", selection: Binding(
                get: { DesignColor.parse(value).map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha) } ?? .gray },
                set: { commit(DesignHex.string($0)) }
            ), supportsOpacity: true)
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 26)
        }
    }
}

enum DesignHex {
    static func string(_ color: Color) -> String {
        let value = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        func byte(_ part: CGFloat) -> Int { Int((part * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(value.redComponent), byte(value.greenComponent), byte(value.blueComponent))
        return value.alphaComponent < 1 ? rgb + String(format: "%02X", byte(value.alphaComponent)) : rgb
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
