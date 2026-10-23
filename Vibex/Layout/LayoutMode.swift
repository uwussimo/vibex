import Foundation

enum LayoutMode: String, CaseIterable, Sendable {
    /// Whatever the user dragged the divider to.
    case balanced
    /// Terminal wide; the editor area only as wide as the simulator (or a mini player) needs.
    case build
    /// The editor area (Netflix) wide, terminal narrow.
    case watch
}

/// The two columns beside the sidebar: the terminal and the tabbed editor area.
struct ColumnWidths: Equatable, Sendable {
    var terminal: CGFloat
    var editor: CGFloat

    var total: CGFloat { terminal + editor }
}

/// Pure layout math for the terminal | editor split. Kept free of AppKit so it is unit-testable.
enum LayoutPlan {
    static let minTerminal: CGFloat = 420
    static let minEditor: CGFloat = 360
    /// The editor area in Build mode when no simulator needs more: a mini player.
    static let miniPlayerWidth: CGFloat = 400
    static let watchEditorShare: CGFloat = 0.58
    static let watchEditorMin: CGFloat = 880
    /// Share of the width the terminal gets before the user has dragged the divider.
    static let defaultTerminalShare: CGFloat = 0.5

    /// - Parameters:
    ///   - available: width of the split (minus the divider).
    ///   - editorPreferred: what the active editor tab would like in Build mode (the simulator's
    ///     natural width), or 0 for no preference.
    ///   - manual: the last user-set widths, used as the baseline for `.balanced`.
    static func widths(mode: LayoutMode, available: CGFloat, editorPreferred: CGFloat, manual: ColumnWidths?) -> ColumnWidths {
        let available = max(available, minTerminal + minEditor)
        func clamped(editor: CGFloat) -> ColumnWidths {
            let editor = min(max(editor, minEditor), available - minTerminal).rounded()
            return ColumnWidths(terminal: available - editor, editor: editor)
        }
        switch mode {
        case .build:
            return clamped(editor: max(editorPreferred, miniPlayerWidth))
        case .watch:
            return clamped(editor: max(watchEditorMin, available * watchEditorShare))
        case .balanced:
            guard let manual, manual.total > 0 else {
                return clamped(editor: available * (1 - defaultTerminalShare))
            }
            return clamped(editor: available * manual.editor / manual.total)
        }
    }
}
