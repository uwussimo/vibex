import SwiftUI

/// One tab in a `TabStrip`.
struct TabStripItem: Identifiable, Equatable {
    let id: UUID
    var title: String
    var isLoading: Bool = false
}

struct TabStripActions {
    var select: (UUID) -> Void
    var close: (UUID) -> Void
    var new: () -> Void
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
                    }
                }
                .padding(.leading, 8)
            }
            Button(action: actions.new) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(dark ? Color.white.opacity(0.7) : Color.primary.opacity(0.7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressFeedbackButtonStyle())
            .help("New tab (⌘T)")
            .padding(.trailing, 6)
        }
        .frame(height: 36)
        .background {
            if dark {
                Color(nsColor: TerminalTheme.tabBar)
            } else {
                Rectangle().fill(.bar)
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
            if item.isLoading {
                ProgressView().controlSize(.mini)
            }
            Text(item.title)
                .font(.vibex(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(textColor)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill((dark ? Color.white : Color.primary).opacity(isHovering ? 0.12 : 0)))
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("Close tab (⌘W)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
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
