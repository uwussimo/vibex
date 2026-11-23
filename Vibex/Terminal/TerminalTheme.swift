import AppKit
import SwiftTerm

/// The terminal on paper, the main surface of the window: the site's sheet colour, ink text and an
/// ANSI palette tuned to stay readable on a light background. Claude Code reads best here with its
/// light theme (`/theme`).
enum TerminalTheme {
    static let background = NSColor(hex: 0xFBFBF9)   // Theme.background
    static let foreground = NSColor(hex: 0x26262B)
    static let caret = NSColor(hex: 0x17171A)
    static let selection = NSColor(hex: 0x17171A, alpha: 0.12)
    static let tabBar = NSColor(hex: 0xF4F3F0)       // Theme.surface
    static let font = AppFont.code(size: 13)

    /// ANSI 0–15, readable on paper. White (7, 15) is a light grey so "white" text still shows.
    static let ansi: [SwiftTerm.Color] = [
        rgb(0x26262B), rgb(0xC9372C), rgb(0x1F7A45), rgb(0x8A6100),
        rgb(0x2F6FDB), rgb(0x7C5CD6), rgb(0x1B7C83), rgb(0x8C8B90),
        rgb(0x5C5B61), rgb(0xD2453D), rgb(0x2F9E62), rgb(0xA87A0C),
        rgb(0x4A86E8), rgb(0x9277E0), rgb(0x2793A0), rgb(0xB5B3B8),
    ]

    static func apply(to terminal: LocalProcessTerminalView) {
        terminal.font = font
        terminal.nativeBackgroundColor = background
        terminal.nativeForegroundColor = foreground
        terminal.caretColor = caret
        terminal.selectedTextBackgroundColor = selection
        terminal.installColors(ansi)
        terminal.optionAsMetaKey = true
        terminal.allowMouseReporting = true
        terminal.scrollerStyle = .overlay
        terminal.bellStyle = .sound
        terminal.setCursorStyle(.blinkBar)
    }

    private static func rgb(_ hex: UInt32) -> SwiftTerm.Color {
        let r = UInt16((hex >> 16) & 0xFF)
        let g = UInt16((hex >> 8) & 0xFF)
        let b = UInt16(hex & 0xFF)
        return SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
    }
}
