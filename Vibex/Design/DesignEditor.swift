import AppKit
import SwiftUI

/// Hand edits: they go straight into the files, so the canvas, Claude and a later build all see them.
extension DesignModel {
    /// A kit card's id: `kit:Button`, or `kit:Button#secondary` for a variant.
    var kitSelection: (name: String, variant: String?)? {
        guard let selection, selection.hasPrefix("kit:") else { return nil }
        let parts = selection.dropFirst(4).split(separator: "#", maxSplits: 1).map(String.init)
        return parts.first.map { ($0, parts.count > 1 ? parts[1] : nil) }
    }

    func root(of id: String) -> DesignNode? {
        if id.hasPrefix("kit:") {
            let parts = id.dropFirst(4).split(separator: "#", maxSplits: 1).map(String.init)
            guard let item = document.kit.first(where: { $0.name == parts.first }) else { return nil }
            return parts.count > 1 ? item.variants.first { $0.name == parts[1] }?.node : item.node
        }
        return document.screens.first { $0.id == id }?.root
    }

    var selectedNode: DesignNode? {
        guard let selection, let element else { return nil }
        return root(of: selection)?.node(at: element)
    }

    /// Editing is off while Claude writes, so the two can't overwrite each other.
    var isEditingLocked: Bool { chat.isBusy }

    /// Whether the selection is part of a component used on a screen, rather than the screen's own.
    var isUseOfKit: Bool { kitSelection == nil && selectedNode?.instance != nil }

    /// Where an edit to an element goes. Content stays on one use; style follows `styleOnlyHere`.
    func place(of node: DesignNode, isContent: Bool = false) -> DesignEditPlace? {
        if let kit = kitSelection {
            if let variant = kit.variant, node.path.isEmpty { return .variant(component: kit.name, variant: variant) }
            return node.main.map { .main(component: $0.component, path: $0.path) }
        }
        guard let selection else { return nil }
        guard let instance = node.instance else { return .screen(file: selection, path: node.path) }
        if !isContent, !styleOnlyHere, let main = node.main { return .main(component: main.component, path: main.path) }
        return .override(file: selection, instance: instance, relative: Array(node.path.dropFirst(instance.count)))
    }

    /// Where one use's differences are kept, for resetting them.
    private func overridePlace(of node: DesignNode) -> DesignEditPlace? {
        guard kitSelection == nil, let selection, let instance = node.instance else { return nil }
        return .override(file: selection, instance: instance, relative: Array(node.path.dropFirst(instance.count)))
    }

    /// Reordering, duplicating and deleting need to own the structure: a use's insides belong to the kit.
    func structurePlace(of node: DesignNode) -> DesignEditPlace? {
        if kitSelection != nil { return node.main.map { .main(component: $0.component, path: $0.path) } }
        guard node.instance == nil, let selection, !node.path.isEmpty else { return nil }
        return .screen(file: selection, path: node.path)
    }

    // MARK: Editing

    func set(_ key: String, to value: Any?, on node: DesignNode, isContent: Bool = false) {
        guard let place = place(of: node, isContent: isContent) else { return }
        change(file: place.file, group: "\(place)\(key)") { DesignEdits.setting(key, to: value, at: place, in: $0) }
    }

    /// The variant a use shows is always its own.
    func setVariant(_ variant: String?, on node: DesignNode) {
        guard let selection, kitSelection == nil, let instance = node.instance else { return }
        let place: DesignEditPlace = node.instance == nil ? .screen(file: selection, path: node.path) : .override(file: selection, instance: instance, relative: Array(node.path.dropFirst(instance.count)))
        change(file: place.file, group: nil) { DesignEdits.setting("variant", to: variant, at: place, in: $0) }
    }

    func isOverridden(_ node: DesignNode) -> Bool {
        guard let place = overridePlace(of: node), let object = DesignEdits.read(folder.appendingPathComponent(place.file)) else { return false }
        return DesignEdits.isOverridden(at: place, in: object)
    }

    func resetToKit(_ node: DesignNode) {
        guard let place = overridePlace(of: node) else { return }
        change(file: place.file, group: nil) { DesignEdits.resetting(at: place, in: $0) }
    }

    func setHidden(_ hidden: Bool, on node: DesignNode) {
        let place = kitSelection != nil || node.instance == nil ? place(of: node) : overridePlace(of: node)
        guard let place else { return }
        change(file: place.file, group: nil) { DesignEdits.setting("hidden", to: hidden ? true : nil, at: place, in: $0) }
    }

    func duplicateSelected() {
        guard let node = selectedNode, let place = structurePlace(of: node), let selection else { return }
        guard change(file: place.file, group: nil, { DesignEdits.duplicating(place, in: $0) ?? $0 }) else { return }
        var path = node.path
        path[path.count - 1] += 1
        select(element: path, in: selection)
    }

    func deleteSelected() {
        guard let node = selectedNode, let place = structurePlace(of: node), let selection else { return }
        guard change(file: place.file, group: nil, { DesignEdits.removing(place, in: $0) ?? $0 }) else { return }
        select(element: Array(node.path.dropLast()), in: selection)
    }

    /// Moves an element among its siblings, to the position it'll end up at.
    func move(_ node: DesignNode, to destination: Int) {
        guard let place = structurePlace(of: node), let selection else { return }
        guard change(file: place.file, group: nil, { DesignEdits.moving(place, to: destination, in: $0) ?? $0 }) else { return }
        select(element: Array(node.path.dropLast()) + [destination], in: selection)
    }

    func selectParent() {
        guard let selection else { return }
        if let element, !element.isEmpty {
            select(element: Array(element.dropLast()), in: selection)
        } else {
            self.select(nil)
        }
    }

    /// Goes to the component's own card in the kit, where its structure can change too.
    func revealInKit(_ node: DesignNode) {
        guard let main = node.main else { return }
        select(element: main.path, in: "kit:\(main.component)")
    }

    // MARK: Foundations

    func setColorToken(_ name: String, to value: String) {
        change(file: "design.json", group: "token\(name)") { DesignEdits.settingColorToken(name, to: value, in: $0) }
    }

    func setScale(_ scale: String, _ name: String, to value: Double) {
        change(file: "design.json", group: "\(scale)\(name)") { DesignEdits.settingScale(scale, name, to: value, in: $0) }
    }

    func setTextStyle(_ name: String, _ key: String, to value: Any) {
        change(file: "design.json", group: "style\(name)\(key)") { DesignEdits.settingTextStyle(name, key, to: value, in: $0) }
    }

    func setFont(_ font: String) {
        change(file: "design.json", group: nil) { manifest in
            var manifest = manifest
            manifest["font"] = font
            return manifest
        }
    }

    // MARK: Writing and undoing

    /// `group` joins a run of small changes to one property, such as typing, into one undo step.
    @discardableResult
    func change(file: String, group: String?, _ edit: ([String: Any]) -> [String: Any]) -> Bool {
        guard !isEditingLocked else { return false }
        let url = folder.appendingPathComponent(file)
        guard let before = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: before) as? [String: Any],
              let after = DesignEdits.data(edit(object)) else { return false }
        guard (try? after.write(to: url, options: .atomic)) != nil else { return false }
        let now = Date.now
        if let group, let last = undoStack.last, last.group == group, last.url == url, now.timeIntervalSince(last.date) < 1.5 {
            undoStack[undoStack.count - 1].date = now
        } else {
            undoStack.append(DesignUndoStep(url: url, data: before, group: group, date: now))
            if undoStack.count > 200 { undoStack.removeFirst() }
        }
        redoStack = []
        reload()
        return true
    }

    func undo() { restore(from: \.undoStack, to: \.redoStack) }
    func redo() { restore(from: \.redoStack, to: \.undoStack) }

    private func restore(from source: ReferenceWritableKeyPath<DesignModel, [DesignUndoStep]>, to other: ReferenceWritableKeyPath<DesignModel, [DesignUndoStep]>) {
        guard !isEditingLocked, let step = self[keyPath: source].popLast(), let current = try? Data(contentsOf: step.url) else { return }
        guard (try? step.data.write(to: step.url, options: .atomic)) != nil else { return }
        self[keyPath: other].append(DesignUndoStep(url: step.url, data: current, group: nil, date: .now))
        reload()
    }
}

/// A file as it was before a hand edit.
struct DesignUndoStep {
    let url: URL
    let data: Data
    let group: String?
    var date: Date
}

struct DesignHover: Equatable {
    var screen: String
    var path: [Int]
}

/// Lets the elements of a screen on the canvas be picked. Screenshots go without.
struct DesignEditing {
    let model: DesignModel
    let screen: String
}

extension EnvironmentValues {
    @Entry var designEditing: DesignEditing?
}

/// A click picks the element under the pointer, and hovering shows what a click would pick.
struct DesignHitArea: ViewModifier {
    let node: DesignNode
    @Environment(\.designEditing) private var editing

    func body(content: Content) -> some View {
        if let editing, node.kind != .spacer {
            content
                .contentShape(Rectangle())
                .onTapGesture { editing.model.select(element: node.path, in: editing.screen) }
                .onHover { inside in
                    if inside {
                        editing.model.hovered = DesignHover(screen: editing.screen, path: node.path)
                    } else if editing.model.hovered == DesignHover(screen: editing.screen, path: node.path) {
                        editing.model.hovered = node.path.isEmpty ? nil : DesignHover(screen: editing.screen, path: Array(node.path.dropLast()))
                    }
                }
                .overlay { DesignElementOutline(model: editing.model, screen: editing.screen, path: node.path).allowsHitTesting(false) }
        } else {
            content
        }
    }
}

/// Its own view, so a selection change redraws an outline and not the element under it.
private struct DesignElementOutline: View {
    let model: DesignModel
    let screen: String
    let path: [Int]

    var body: some View {
        let isSelected = model.selection == screen && model.element == path
        let isHovered = model.hovered == DesignHover(screen: screen, path: path)
        if isSelected || isHovered {
            Rectangle().strokeBorder(Theme.accent.opacity(isSelected ? 1 : 0.55), lineWidth: (isSelected ? 1.5 : 1) / max(model.canvas.zoom, 0.05))
        }
    }
}

/// The kit's own board: its foundations, and each component with its variants.
struct DesignKitBoard: View {
    let document: DesignDocument
    let theme: DesignTheme
    /// Nil in a screenshot, where nothing can be picked.
    let model: DesignModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            Text("UI Kit").font(.vibex(size: 26, weight: .semibold)).foregroundStyle(Theme.muted)
            HStack(alignment: .top, spacing: 40) {
                foundations
                VStack(alignment: .leading, spacing: 40) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 40) {
                            ForEach(row) { card($0) }
                        }
                    }
                }
            }
        }
    }

    /// Filled to about the width of a phone row, so the board stays wide rather than endless.
    private var rows: [[DesignKitItem]] {
        var rows: [[DesignKitItem]] = [[]]
        var width = 0.0
        for item in document.kit {
            if width + item.width > 1200, !rows[rows.count - 1].isEmpty {
                rows.append([])
                width = 0
            }
            rows[rows.count - 1].append(item)
            width += item.width + 40
        }
        return rows
    }

    private func card(_ item: DesignKitItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                DesignComponentMark(size: 10)
                Text(item.name).font(.vibex(size: 17, weight: .medium)).foregroundStyle(Theme.muted)
                let uses = document.uses(of: item.name)
                Text("\(uses) use\(uses == 1 ? "" : "s")").font(.vibex(size: 13)).foregroundStyle(Theme.faint)
            }
            VStack(alignment: .leading, spacing: 18) {
                specimen(item.node, id: "kit:\(item.name)", label: item.variants.isEmpty ? nil : "Default", width: item.width)
                ForEach(item.variants, id: \.name) { variant in
                    specimen(variant.node, id: "kit:\(item.name)#\(variant.name)", label: variant.name.capitalized, width: item.width)
                }
            }
            .padding(20)
            .background(theme.color(token: "background"), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1)))
        }
    }

    private func specimen(_ node: DesignNode, id: String, label: String?, width: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.color(token: "muted"))
            }
            DesignNodeView(node: node, theme: theme)
                .environment(\.designEditing, model.map { DesignEditing(model: $0, screen: id) })
                .frame(width: width, alignment: .leading)
        }
    }

    private var colors: [(String, String)] {
        let order = ["background", "surface", "text", "muted", "border", "primary", "onPrimary"]
        return document.tokens.sorted { a, b in
            let first = order.firstIndex(of: a.key) ?? order.count, second = order.firstIndex(of: b.key) ?? order.count
            return (first, a.key) < (second, b.key)
        }
    }

    private var foundations: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Text("Foundations").font(.vibex(size: 17, weight: .medium)).foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 22) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(62), spacing: 8, alignment: .top), count: 4), alignment: .leading, spacing: 12) {
                    ForEach(colors, id: \.0) { name, _ in
                        VStack(alignment: .leading, spacing: 5) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(theme.color(token: name))
                                .frame(height: 44)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.color(token: "muted").opacity(0.3)))
                            Text(name).font(.system(size: 10)).foregroundStyle(theme.color(token: "muted")).lineLimit(1)
                        }
                    }
                }
                if !document.typeScale.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(document.typeScale, id: \.name) { style in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(style.name.capitalized)
                                    .font(theme.font(specimenNode(style)))
                                    .foregroundStyle(theme.color(token: "text"))
                                    .lineLimit(1)
                                Text("\(Int(style.size)) · \(style.weight ?? "regular")").font(.system(size: 10)).foregroundStyle(theme.color(token: "muted"))
                            }
                        }
                    }
                }
                if !document.scales.radii.isEmpty {
                    HStack(alignment: .bottom, spacing: 10) {
                        ForEach(document.scales.radii.sorted { $0.value < $1.value }, id: \.key) { name, value in
                            VStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: min(value, 22), style: .continuous)
                                    .strokeBorder(theme.color(token: "muted"), lineWidth: 1.5)
                                    .frame(width: 44, height: 44)
                                Text(name).font(.system(size: 10)).foregroundStyle(theme.color(token: "muted"))
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(width: 320, alignment: .leading)
            .background(theme.color(token: "background"), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1)))
        }
    }

    private func specimenNode(_ style: DesignTypeStyle) -> DesignNode {
        var node = DesignNode([:])
        node.size = style.size
        node.weight = style.weight
        return node
    }
}

/// Marks a component, as the diamond does in Figma.
struct DesignComponentMark: View {
    var size: CGFloat = 8

    var body: some View {
        Rectangle()
            .fill(Theme.accent)
            .frame(width: size * 0.72, height: size * 0.72)
            .rotationEffect(.degrees(45))
            .frame(width: size, height: size)
    }
}
