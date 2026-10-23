import AppKit
import SwiftUI

/// Vibex's type: Google Sans for the interface, Google Sans Code wherever columns must line up
/// (terminal, diffs, ports). Both are bundled variable fonts (SIL OFL), registered through
/// `ATSApplicationFontsPath`; SF Symbols keep the system font so icons stay optically sized.
nonisolated enum AppFont {
    private static let sans = "GoogleSans-Regular"
    private static let code = "GoogleSansCode-Regular"
    private static let weightAxis = 0x7767_6874 // 'wght'

    static func ui(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        variable(sans, size: size, weight: weight, range: 400...700)
    }

    static func code(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        variable(code, size: size, weight: weight, range: 300...800)
    }

    private static func variable(_ name: String, size: CGFloat, weight: NSFont.Weight, range: ClosedRange<CGFloat>) -> NSFont {
        let value = min(max(cssWeight(weight), range.lowerBound), range.upperBound)
        let descriptor = NSFontDescriptor(fontAttributes: [.name: name, .variation: [weightAxis: value]])
        guard let font = NSFont(descriptor: descriptor, size: size), font.fontName.hasPrefix(name.prefix { $0 != "-" }) else {
            return .systemFont(ofSize: size, weight: weight)
        }
        return font
    }

    /// NSFont.Weight runs −1…1; variable fonts use the CSS 100…900 scale.
    private static func cssWeight(_ weight: NSFont.Weight) -> CGFloat {
        switch weight.rawValue {
        case ..<(-0.7): 100
        case ..<(-0.5): 200
        case ..<(-0.2): 300
        case ..<0.1: 400
        case ..<0.27: 500
        case ..<0.35: 600
        case ..<0.5: 700
        case ..<0.6: 800
        default: 900
        }
    }
}

extension Font {
    /// Google Sans at a fixed point size.
    static func vibex(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(AppFont.ui(size: size, weight: weight.nsWeight))
    }

    /// Google Sans Code, for text whose characters must line up.
    static func vibexCode(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(AppFont.code(size: size, weight: weight.nsWeight))
    }
}

private extension Font.Weight {
    var nsWeight: NSFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}
