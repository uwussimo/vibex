import SwiftUI

/// One tab in a `TabStrip`.
struct TabStripItem: Identifiable, Equatable {
    let id: UUID
    var title: String
    var isLoading: Bool = false
    /// Claude in this tab is waiting for an approval or an answer.
    var needsAttention = false
    /// A native Claude chat rather than a terminal.
    var isClaude = false
}

struct TabStripActions {
    var select: (UUID) -> Void
    var close: (UUID) -> Void
    var new: () -> Void
    var newClaude: () -> Void
}

/// The tab row shared by the terminal and the browser. `dark` forces the terminal's always-dark look;
/// otherwise it follows the system appearance with a bar material.
struct TabStrip: View {
    let items: [TabStripItem]
    let selectedID: UUID?
    var dark = false
    let actions: TabStripActions

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(items) { item in
                        TabStripCell(
                            item: item,
                            isSelected: item.id == selectedID,
                            dark: dark,
                            select: { actions.select(item.id) },
                            close: { actions.close(item.id) }
                        )
                        .contextMenu {
                            TabCloseCommands(id: item.id, all: items.map(\.id), close: actions.close)
                        }
                    }
                }
                .padding(.leading, 8)
            }
            if items.count > tabListThreshold {
                TabListMenu(tabs: items.map { ($0.id, $0.title, $0.id == selectedID) }, select: actions.select)
            }
            Button(action: actions.newClaude) {
                BrandLogoView(.claude, size: 14)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressFeedbackButtonStyle())
            .help("New Claude Chat (⌃⇧C)")
            Button(action: actions.new) {
                IconView(.plus, size: 15)
                    .frame(width: 26, height: 26)
                    .foregroundStyle(dark ? Color.white.opacity(0.7) : Color.primary.opacity(0.7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressFeedbackButtonStyle())
            .help("New Terminal Tab (⌘T)")
            .padding(.trailing, 6)
        }
        .frame(height: 36)
        .background {
            if dark {
                Color(nsColor: TerminalTheme.tabBar)
            } else {
                Rectangle().fill(Theme.surface)
            }
        }
    }
}

private struct TabStripCell: View {
    let item: TabStripItem
    let isSelected: Bool
    let dark: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    private var textColor: Color {
        if dark { return Color.white.opacity(isSelected ? 0.92 : 0.55) }
        return Color.primary.opacity(isSelected ? 0.95 : 0.6)
    }

    private var fill: Color {
        let base = dark ? Color.white : Color.primary
        return base.opacity(isSelected ? 0.10 : (isHovering ? 0.05 : 0))
    }

    var body: some View {
        HStack(spacing: 6) {
            if item.needsAttention {
                Circle()
                    .fill(Theme.orange)
                    .frame(width: 7, height: 7)
                    .help("Claude is waiting for you")
                    .transition(.scale.combined(with: .opacity))
            } else if item.isLoading {
                ProgressView().controlSize(.mini)
            } else if item.isClaude {
                BrandLogoView(.claude, size: 13)
            } else {
                IconView(.terminal, size: 13).foregroundStyle(textColor)
            }
            Text(item.title)
                .font(.vibex(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: close) {
                IconView(.close, size: 11)
                    .foregroundStyle(textColor)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill((dark ? Color.white : Color.primary).opacity(isHovering ? 0.12 : 0)))
                    // A 24pt hit area around the 16pt circle.
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("Close Tab (⌘W)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 3)
        .frame(height: 26)
        .frame(minWidth: 90, maxWidth: 200)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.2, dampingFraction: 1), value: isHovering)
        .animation(.spring(response: 0.2, dampingFraction: 1), value: isSelected)
    }
}

/// Past this many tabs some are likely scrolled out of sight.
let tabListThreshold = 3

/// Every tab in a list, for when they no longer fit in the strip.
struct TabListMenu<ID: Hashable>: View {
    let tabs: [(id: ID, title: String, isSelected: Bool)]
    let select: (ID) -> Void

    var body: some View {
        Menu {
            ForEach(tabs, id: \.id) { tab in
                Toggle(tab.title, isOn: Binding(get: { tab.isSelected }, set: { _ in select(tab.id) }))
            }
        } label: {
            IconView(.chevronDown, size: 13).foregroundStyle(Theme.muted)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 22, height: 26)
        .help("All Tabs")
    }
}

/// Close, Close Others and Close to the Right, as in every browser and editor.
struct TabCloseCommands<ID: Hashable>: View {
    let id: ID
    let all: [ID]
    let close: (ID) -> Void

    var body: some View {
        Button("Close Tab") { close(id) }
        Button("Close Other Tabs") { for other in all where other != id { close(other) } }
            .disabled(all.count < 2)
        Button("Close Tabs to the Right") { for other in right { close(other) } }
            .disabled(right.isEmpty)
    }

    private var right: [ID] {
        guard let index = all.firstIndex(of: id) else { return [] }
        return Array(all[(index + 1)...])
    }
}
