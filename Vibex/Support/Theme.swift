import AppKit
import SwiftUI

/// Vibex's palette, the same tokens as the landing page (docs/assets/site.css): warm paper, hairline
/// rules and ink in the light appearance; warm ink with paper-coloured text in the dark one. Every
/// token is dynamic, so views follow `NSApp.appearance` (System, Light or Dark in Settings) live.
enum Theme {
    /// Content areas: the sheet the work sits on.
    static let background = dynamic(0xFBFBF9, 0x161618)
    /// Sidebars, headers, tab strips and the activity bar: the paper around the sheet.
    static let surface = dynamic(0xF4F3F0, 0x1D1D20)
    /// Controls, wells and selected rows.
    static let raised = dynamic(0xEBEAE6, 0x2A2A2E)
    /// Cards on the sheet.
    static let card = dynamic(0xFFFFFF, 0x212124)
    /// Code, logs and other monospaced panels.
    static let code = dynamic(0xF7F6F3, 0x1A1A1D)
    static let line = dynamic(0xE4E2DD, 0x2E2E33)
    static let lineStrong = dynamic(0xD3D1CB, 0x3D3D43)
    static let text = dynamic(0x17171A, 0xF1F0EC)
    static let muted = dynamic(0x6F6E74, 0xA09FA5)
    static let faint = dynamic(0xA19FA4, 0x6B6A70)
    /// Primary actions and selection: ink on paper, paper on ink. Colour is kept for meaning.
    static let accent = dynamic(0x17171A, 0xF1F0EC)
    /// Text and icons on `accent`.
    static let onAccent = dynamic(0xFFFFFF, 0x17171A)
    /// The base of hover and pressed washes.
    static let ink = dynamic(0x17171A, 0xFFFFFF)
    static let link = dynamic(0x2F6FDB, 0x6EA3FF)
    /// A hover or selection wash. Takes the white-on-dark amounts the views were tuned with and
    /// returns ink on paper, a little lighter.
    static func wash(_ amount: Double) -> Color { ink.opacity(amount * 0.7) }
    static let green = dynamic(0x2F9E62, 0x4CC38A)
    static let red = dynamic(0xD2453D, 0xF0625C)
    static let orange = dynamic(0xC26A1E, 0xE8A25C)
    static let violet = dynamic(0x7C5CD6, 0xA990F5)
    static let pink = dynamic(0xC2508F, 0xE77CB8)
    static let yellow = dynamic(0xB8901A, 0xE5C55A)

    /// Corner radii: small and square-ish, like the site's buttons and cells.
    static let cardRadius: CGFloat = 10
    static let controlRadius: CGFloat = 4
    static let chipRadius: CGFloat = 3

    enum NS {
        static let background = NSColor.vibex(0xFBFBF9, 0x161618)
        static let surface = NSColor.vibex(0xF4F3F0, 0x1D1D20)
        static let card = NSColor.vibex(0xFFFFFF, 0x212124)
        static let line = NSColor.vibex(0xE4E2DD, 0x2E2E33)
        static let green = NSColor.vibex(0x2F9E62, 0x4CC38A)
        static let orange = NSColor.vibex(0xC26A1E, 0xE8A25C)
        static let accent = NSColor.vibex(0x17171A, 0xF1F0EC)
        static let text = NSColor.vibex(0x17171A, 0xF1F0EC)
        static let faint = NSColor.vibex(0xA19FA4, 0x6B6A70)
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: .vibex(light, dark))
    }
}

/// Light, Dark, or whatever the Mac uses. Stored in Defaults and applied to the whole app.
enum AppearanceChoice: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    static var current: AppearanceChoice {
        get { UserDefaults.standard.string(forKey: "Vibex.appearance").flatMap(AppearanceChoice.init(rawValue:)) ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "Vibex.appearance")
            newValue.apply()
        }
    }

    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension Color {
    nonisolated init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

extension NSColor {
    /// A colour that follows the appearance it's drawn in.
    nonisolated static func vibex(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in NSColor(hex: appearance.isDark ? dark : light) }
    }

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

/// The one primary button, as on the site: ink on paper in the light appearance, paper on ink in the
/// dark one. Sized by the control size, like the system's bordered buttons.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let height: CGFloat = switch controlSize {
        case .mini: 20
        case .small: 24
        case .large, .extraLarge: 34
        default: 28
        }
        configuration.label
            .font(.vibex(size: controlSize == .large || controlSize == .extraLarge ? 13.5 : 12.5, weight: .medium))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, height * 0.5)
            .frame(minHeight: height)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.accent))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

/// A layer-backed view filled with a dynamic colour. A layer's colour is a CGColor fixed when set, so
/// this sets it again whenever the view's appearance changes.
class ThemedLayerView: NSView {
    var fill: NSColor { didSet { updateFill() } }

    init(fill: NSColor) {
        self.fill = fill
        super.init(frame: .zero)
        wantsLayer = true
        updateFill()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = fill.cgColor }
    }
}
