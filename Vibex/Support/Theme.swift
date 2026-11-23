import AppKit
import SwiftUI

/// Vibex's palette: warm paper, hairline rules and ink, the same tokens as the landing page
/// (docs/assets/site.css). The app runs in the light appearance; materials and system controls
/// follow from `NSApp.appearance`.
enum Theme {
    /// Content areas: the sheet the work sits on.
    static let background = Color(hex: 0xFBFBF9)
    /// Sidebars, headers, tab strips and the activity bar: the paper around the sheet.
    static let surface = Color(hex: 0xF4F3F0)
    /// Controls, wells and selected rows.
    static let raised = Color(hex: 0xEBEAE6)
    /// Cards on the sheet.
    static let card = Color(hex: 0xFFFFFF)
    /// Code, logs and other monospaced panels.
    static let code = Color(hex: 0xF7F6F3)
    static let line = Color(hex: 0xE4E2DD)
    static let lineStrong = Color(hex: 0xD3D1CB)
    static let text = Color(hex: 0x17171A)
    static let muted = Color(hex: 0x6F6E74)
    static let faint = Color(hex: 0xA19FA4)
    /// Primary actions and selection are ink, as on the site; colour is kept for meaning.
    static let accent = Color(hex: 0x17171A)
    /// Hover and pressed washes over any surface.
    static let ink = Color(hex: 0x17171A)
    static let link = Color(hex: 0x2F6FDB)
    /// A hover or selection wash. Takes the white-on-dark amounts the views were tuned with and
    /// returns ink on paper, a little lighter.
    static func wash(_ amount: Double) -> Color { ink.opacity(amount * 0.7) }
    static let green = Color(hex: 0x2F9E62)
    static let red = Color(hex: 0xD2453D)
    static let orange = Color(hex: 0xC26A1E)
    static let violet = Color(hex: 0x7C5CD6)
    static let pink = Color(hex: 0xC2508F)
    static let yellow = Color(hex: 0xB8901A)

    /// Corner radii: small and square-ish, like the site's buttons and cells.
    static let cardRadius: CGFloat = 10
    static let controlRadius: CGFloat = 4
    static let chipRadius: CGFloat = 3

    enum NS {
        static let background = NSColor(hex: 0xFBFBF9)
        static let surface = NSColor(hex: 0xF4F3F0)
        static let card = NSColor(hex: 0xFFFFFF)
        static let line = NSColor(hex: 0xE4E2DD)
        static let green = NSColor(hex: 0x2F9E62)
        static let orange = NSColor(hex: 0xC26A1E)
        static let accent = NSColor(hex: 0x17171A)
        static let text = NSColor(hex: 0x17171A)
        static let faint = NSColor(hex: 0xA19FA4)
    }
}

extension Color {
    nonisolated init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

extension NSColor {
    nonisolated convenience init(hex: UInt32, alpha: CGFloat = 1) {
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
