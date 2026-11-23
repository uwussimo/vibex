import AppKit
import SwiftTerm

/// The terminal's look in each appearance: on paper in Light (the site's sheet colour, ink text, an
/// ANSI palette that stays readable on white) and on warm ink in Dark. Panes re-apply it when the
/// appearance changes. Claude Code's `/theme` set to Auto follows along.
enum TerminalTheme {
    struct Palette {
        let background: NSColor
        let foreground: NSColor
        let caret: NSColor
        let selection: NSColor
        let ansi: [SwiftTerm.Color]
    }

    static let light = Palette(
        background: NSColor(hex: 0xFBFBF9),
        foreground: NSColor(hex: 0x26262B),
        caret: NSColor(hex: 0x17171A),
        selection: NSColor(hex: 0x17171A, alpha: 0.12),
        ansi: [
            rgb(0x26262B), rgb(0xC9372C), rgb(0x1F7A45), rgb(0x8A6100),
            rgb(0x2F6FDB), rgb(0x7C5CD6), rgb(0x1B7C83), rgb(0x8C8B90),
            rgb(0x5C5B61), rgb(0xD2453D), rgb(0x2F9E62), rgb(0xA87A0C),
            rgb(0x4A86E8), rgb(0x9277E0), rgb(0x2793A0), rgb(0xB5B3B8),
        ]
    )

    static let dark = Palette(
        background: NSColor(hex: 0x161618),
        foreground: NSColor(hex: 0xE8E7E3),
        caret: NSColor(hex: 0xF1F0EC),
        selection: NSColor(hex: 0xF1F0EC, alpha: 0.2),
        ansi: [
            rgb(0x3A3A3C), rgb(0xFF6B6B), rgb(0x5AD178), rgb(0xFFD166),
            rgb(0x6CA8FF), rgb(0xD18BFF), rgb(0x5CD6E8), rgb(0xD1D1D6),
            rgb(0x7C7C80), rgb(0xFF8A80), rgb(0x7EE59A), rgb(0xFFE08A),
            rgb(0x8FBFFF), rgb(0xE3ADFF), rgb(0x8AE6F3), rgb(0xF2F2F7),
        ]
    )

    static func palette(for appearance: NSAppearance) -> Palette { appearance.isDark ? dark : light }

    /// The pane behind the terminal, following the appearance.
    static let background = NSColor.vibex(0xFBFBF9, 0x161618)
    static let tabBar = NSColor.vibex(0xF4F3F0, 0x1D1D20)
    /// Settings › Terminal › Font size.
    static var font: NSFont { AppFont.code(size: AppSettings.terminalFontSize) }

    static func apply(to terminal: LocalProcessTerminalView) {
        terminal.font = font
        applyColors(to: terminal)
        terminal.optionAsMetaKey = true
        terminal.allowMouseReporting = true
        terminal.scrollerStyle = .overlay
        terminal.bellStyle = .sound
        terminal.setCursorStyle(.blinkBar)
    }

    /// The colours alone, for when the appearance changes under a running terminal.
    static func applyColors(to terminal: LocalProcessTerminalView) {
        let palette = palette(for: NSApp.effectiveAppearance)
        terminal.nativeBackgroundColor = palette.background
        terminal.nativeForegroundColor = palette.foreground
        terminal.caretColor = palette.caret
        terminal.selectedTextBackgroundColor = palette.selection
        terminal.installColors(palette.ansi)
    }

    private static func rgb(_ hex: UInt32) -> SwiftTerm.Color {
        let r = UInt16((hex >> 16) & 0xFF)
        let g = UInt16((hex >> 8) & 0xFF)
        let b = UInt16(hex & 0xFF)
        return SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
    }
}
