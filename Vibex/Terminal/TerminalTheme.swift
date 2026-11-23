import AppKit
import SwiftTerm

/// The terminal stays dark, like the code panels on the site: near-black ink set into the paper
/// window, so Claude Code's default (dark) theme reads as intended.
enum TerminalTheme {
    static let background = NSColor(hex: 0x17171A)   // Theme.ink
    static let foreground = NSColor(srgbRed: 0.898, green: 0.898, blue: 0.918, alpha: 1)   // #E5E5EA
    static let caret = NSColor(hex: 0xF4F3F0)
    static let selection = NSColor(hex: 0xF4F3F0, alpha: 0.22)
    static let tabBar = NSColor(hex: 0x1F1F23)
    static let font = AppFont.code(size: 13)

    /// ANSI 0–15.
    static let ansi: [SwiftTerm.Color] = [
        rgb(0x3A3A3C), rgb(0xFF6B6B), rgb(0x5AD178), rgb(0xFFD166),
        rgb(0x6CA8FF), rgb(0xD18BFF), rgb(0x5CD6E8), rgb(0xD1D1D6),
        rgb(0x7C7C80), rgb(0xFF8A80), rgb(0x7EE59A), rgb(0xFFE08A),
        rgb(0x8FBFFF), rgb(0xE3ADFF), rgb(0x8AE6F3), rgb(0xF2F2F7),
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
