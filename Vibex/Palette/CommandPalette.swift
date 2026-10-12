import AppKit
import SwiftUI

@Observable
final class PaletteModel {
    var query = "" {
        didSet { selection = 0 }
    }
    var selection = 0
    private(set) var base: [PaletteItem] = []
    private let dynamicItems: (String) -> [PaletteItem]

    init(items: [PaletteItem], dynamicItems: @escaping (String) -> [PaletteItem]) {
        base = items
        self.dynamicItems = dynamicItems
    }

    struct Row: Identifiable {
        let item: PaletteItem
        let positions: [Int]
        var id: String { item.id }
    }

    var rows: [Row] {
        let dynamic = dynamicItems(query).map { Row(item: $0, positions: []) }
        let ranked = FuzzyMatch.rank(base, query: query) { $0.title }.map { Row(item: $0.item, positions: $0.result.positions) }
        return Array((dynamic + ranked).prefix(60))
    }

    func move(_ delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }
}

/// The palette: a search field over a ranked list. ↑↓ to move, ⏎ to run, ⎋ to close.
struct CommandPaletteView: View {
    @Bindable var model: PaletteModel
    let run: (PaletteItem) -> Void
    let dismiss: () -> Void

    @FocusState private var fieldFocused: Bool
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
            panel
                .padding(.top, 72)
                .scaleEffect(appeared ? 1 : 0.97, anchor: .top)
                .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.22, dampingFraction: 1)) { appeared = true }
            // Next run loop: the hosting view is first responder by then.
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    private var panel: some View {
        let rows = model.rows
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search commands, projects, tabs… ($ runs a command)", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($fieldFocused)
                    .onSubmit { runSelected(rows) }
                    .onExitCommand(perform: dismiss)
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
                    .onKeyPress(.tab) { model.move(1); return .handled }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            if !rows.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                PaletteRow(row: row, isSelected: index == model.selection)
                                    .id(row.id)
                                    .onTapGesture { run(row.item) }
                                    .onHover { if $0 { model.selection = index } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: model.selection) { _, selection in
                        guard rows.indices.contains(selection) else { return }
                        proxy.scrollTo(rows[selection].id)
                    }
                }
            } else if !model.query.isEmpty {
                Divider()
                Text("No matches")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
        }
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 14)
    }

    private func runSelected(_ rows: [PaletteModel.Row]) {
        guard rows.indices.contains(model.selection) else { return }
        run(rows[model.selection].item)
    }
}

private struct PaletteRow: View {
    let row: PaletteModel.Row
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.item.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted)
                    .font(.system(size: 13.5))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                if let subtitle = row.item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = row.item.shortcut {
                Text(shortcut)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.primary.opacity(0.5))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: row.item.subtitle == nil ? 34 : 42)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
    }

    /// Matched characters in semibold.
    private var highlighted: AttributedString {
        var text = AttributedString(row.item.title)
        let characters = Array(row.item.title)
        for position in row.positions where position < characters.count {
            let start = text.index(text.startIndex, offsetByCharacters: position)
            let end = text.index(start, offsetByCharacters: 1)
            text[start..<end].font = .system(size: 13.5, weight: .bold)
        }
        return text
    }
}
