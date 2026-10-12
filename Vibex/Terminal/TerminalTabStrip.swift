import SwiftUI

@Observable
final class TerminalTabBarModel {
    var tabs: [TabStripItem] = []
    var selectedID: UUID?
}

/// The terminal's always-dark tab row, a thin wrapper over the shared `TabStrip`.
struct TerminalTabStrip: View {
    let model: TerminalTabBarModel
    let actions: TabStripActions

    var body: some View {
        TabStrip(items: model.tabs, selectedID: model.selectedID, dark: true, actions: actions)
    }
}
