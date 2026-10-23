import AppKit
import SwiftUI

/// Logos of the tools Vibex works with, from devicon (MIT) and svglogos (CC0); see docs/logos/README.md.
/// The black ones are templates, drawn in the text color so they show on the dark surfaces.
nonisolated enum BrandLogo: String, CaseIterable, Sendable {
    case apple, chrome, claude, docker, figma, git, github, linear, nextjs, nodejs, notion, npm, openai
    case playwright, postgresql, python, react, sentry, slack, supabase, swift, vitejs, vscode, xcode

    var assetName: String { "logo.\(rawValue)" }

    /// A guess from an MCP server's name: "chrome-devtools" → Chrome, "github-mcp" → GitHub.
    static func forServer(_ name: String) -> BrandLogo? {
        let name = name.lowercased()
        let aliases: [String: BrandLogo] = ["postgres": .postgresql, "vite": .vitejs, "next": .nextjs, "node": .nodejs, "gpt": .openai, "codex": .openai]
        if let exact = BrandLogo(rawValue: name) { return exact }
        if let match = allCases.first(where: { name.contains($0.rawValue) }) { return match }
        return aliases.first { name.contains($0.key) }?.value
    }
}

/// A logo at a size, tinted only when it's a template.
struct BrandLogoView: View {
    let logo: BrandLogo
    var size: CGFloat = 16

    init(_ logo: BrandLogo, size: CGFloat = 16) {
        self.logo = logo
        self.size = size
    }

    var body: some View {
        Image(logo.assetName)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(Theme.text)
            .frame(width: size, height: size)
    }
}
