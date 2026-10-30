import Foundation

/// Tools for Vibex Design: Claude writes JSON files and looks at what they turned into.
enum DesignTools {
    static func make() -> [Tool] {
        func window() throws -> MainWindowController { try WindowManager.shared.toolTarget() }
        return [
            Tool(
                name: "design_screenshot",
                description: "See screens from Vibex Design (vibex-design/ in the project) as they really render, with a list of problems such as unreadable files, unknown tokens and icons that aren't SF Symbols. Pass a screen's name or file name for one screen; leave it out for all of them side by side.",
                inputSchema: Schema.object(["screen": Schema.string("Screen name or file name, or \"kit\" for the UI kit (optional)"), "maxWidth": Schema.integer("Max image width in pixels (default 1400)")])
            ) { args in
                let document = DesignDocument.load(folder: DesignDocument.folder(inProject: try window().project.url))
                let problems = document.problems()
                let summary = problems.isEmpty ? "No problems." : "Problems:\n" + problems.map { "- \($0)" }.joined(separator: "\n")
                guard !document.screens.isEmpty || !document.kit.isEmpty else { throw ToolError("There are no screens yet. Write them to \(DesignDocument.folderName)/screens/.") }
                if let screen = args.string("screen"), screen.lowercased() != "kit", !document.screens.contains(where: { $0.id == screen || $0.name.lowercased() == screen.lowercased() }) {
                    throw ToolError("No screen called \(screen). Screens: \(document.screens.map(\.name).joined(separator: ", ")).")
                }
                guard let image = await DesignSnapshot.image(of: document, screen: args.string("screen")),
                      let jpeg = DesignSnapshot.jpeg(image, maxWidth: CGFloat(args.int("maxWidth") ?? 1400)) else {
                    throw ToolError("Couldn't render the design.\n\(summary)")
                }
                return .image(jpeg, caption: summary)
            },
            Tool(
                name: "design_open",
                description: "Open the Design tab, where the user sees vibex-design/ on a canvas and can chat about it. Returns the format to write it in, so a design can be started from any Claude session.",
                inputSchema: Schema.object()
            ) { _ in
                try window().showDesign(nil)
                let brief = Bundle.main.url(forResource: "DesignBrief", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                return .text(brief.map { $0 + DesignModel.kitBrief } ?? "Opened.")
            },
        ]
    }
}
