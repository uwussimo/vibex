import Foundation

enum LayoutMode: String, CaseIterable, Sendable {
    /// Whatever the user dragged the dividers to.
    case balanced
    /// Terminal wide, simulator at its natural width, Netflix as a mini player.
    case build
    /// Netflix wide, simulator hidden, terminal narrow.
    case watch
}

struct ColumnWidths: Equatable, Sendable {
    var terminal: CGFloat
    var simulator: CGFloat
    var browser: CGFloat

    var total: CGFloat { terminal + simulator + browser }
}

/// Pure layout math for the three columns. Kept free of AppKit so it is unit-testable.
enum LayoutPlan {
    static let minTerminal: CGFloat = 420
    static let minBrowser: CGFloat = 320
    static let miniPlayerWidth: CGFloat = 380
    /// Column width while nothing is docked, so the empty state (permission, boot) stays visible.
    static let emptyColumnWidth: CGFloat = 320
    static let minSimulator: CGFloat = 240
    static let watchBrowserShare: CGFloat = 0.58
    static let watchBrowserMin: CGFloat = 880

    /// - Parameters:
    ///   - available: width available to the three columns (split view width minus divider thickness).
    ///   - simulatorWidth: the width the simulator column wants (0 when nothing is docked).
    ///   - manual: the last user-set widths, used as the baseline for `.balanced`.
    static func widths(
        mode: LayoutMode,
        available: CGFloat,
        simulatorWidth: CGFloat,
        manual: ColumnWidths?
    ) -> ColumnWidths {
        let available = max(available, minTerminal + minBrowser)
        let simulatorWidth = simulatorWidth > 0 ? simulatorWidth : emptyColumnWidth
        switch mode {
        case .build:
            let simulator = min(simulatorWidth, available - minTerminal - minBrowser)
            var browser = miniPlayerWidth
            var terminal = available - simulator - browser
            if terminal < minTerminal {
                terminal = minTerminal
                browser = available - simulator - terminal
            }
            return ColumnWidths(terminal: terminal, simulator: simulator, browser: browser).rounded()

        case .watch:
            var browser = max(watchBrowserMin, (available * watchBrowserShare).rounded())
            var terminal = available - browser
            if terminal < minTerminal {
                terminal = minTerminal
                browser = available - terminal
            }
            return ColumnWidths(terminal: terminal, simulator: 0, browser: browser).rounded()

        case .balanced:
            let simulator = min(simulatorWidth, available - minTerminal - minBrowser)
            let rest = available - simulator
            guard let manual, manual.terminal + manual.browser > 0 else {
                // Default split: terminal gets ~60% of what is left.
                let terminal = max(minTerminal, (rest * 0.6).rounded())
                return ColumnWidths(terminal: terminal, simulator: simulator, browser: rest - terminal).rounded()
            }
            let share = manual.terminal / (manual.terminal + manual.browser)
            var terminal = (rest * share).rounded()
            terminal = min(max(terminal, minTerminal), rest - minBrowser)
            return ColumnWidths(terminal: terminal, simulator: simulator, browser: rest - terminal).rounded()
        }
    }
}

extension ColumnWidths {
    func rounded() -> ColumnWidths {
        ColumnWidths(terminal: terminal.rounded(), simulator: simulator.rounded(), browser: browser.rounded())
    }
}
