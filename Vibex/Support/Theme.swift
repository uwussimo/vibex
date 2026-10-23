import AppKit
import SwiftUI

/// Vibex's dark palette, the same tokens as the landing page in dark mode (docs/index.html). The
/// app always runs dark; materials and system controls follow from `NSApp.appearance`.
enum Theme {
    /// Window and activity bar.
    static let background = Color(hex: 0x0C0C0F)
    /// Sidebars, headers and tab strips.
    static let surface = Color(hex: 0x131317)
    /// Controls and selected rows on a surface.
    static let raised = Color(hex: 0x1D1D22)
    /// Cards on the background.
    static let card = Color(hex: 0x17171B)
    static let line = Color.white.opacity(0.08)
    static let lineStrong = Color.white.opacity(0.15)
    static let text = Color(hex: 0xF1F1F4)
    static let muted = Color(hex: 0x9B9BA7)
    static let faint = Color(hex: 0x62626C)
    static let accent = Color(hex: 0x8194FF)
    static let green = Color(hex: 0x3DD68C)
    static let red = Color(hex: 0xFF6369)
    static let orange = Color(hex: 0xF0A05A)
    static let violet = Color(hex: 0xA78BFA)
    static let pink = Color(hex: 0xF17CC5)
    static let yellow = Color(hex: 0xF5D76E)

    /// Continuous corner radii: cards, controls, small chips.
    static let cardRadius: CGFloat = 16
    static let controlRadius: CGFloat = 9
    static let chipRadius: CGFloat = 6

    enum NS {
        static let background = NSColor(hex: 0x0C0C0F)
        static let surface = NSColor(hex: 0x131317)
        static let card = NSColor(hex: 0x17171B)
        static let line = NSColor.white.withAlphaComponent(0.08)
        static let green = NSColor(hex: 0x3DD68C)
        static let orange = NSColor(hex: 0xF0A05A)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// A card on the window background: Vibex's one container shape.
struct CardBackground: ViewModifier {
    var fill = Theme.card
    var radius = Theme.cardRadius

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.line))
    }
}

extension View {
    func card(fill: Color = Theme.card, radius: CGFloat = Theme.cardRadius) -> some View {
        modifier(CardBackground(fill: fill, radius: radius))
    }
}
