import AppKit
import Observation
import SwiftUI

/// The Design tab's state: the document on disk, the canvas looking at it, and a Claude chat whose
/// job is to write it. The files are the source of truth, so anything that edits them shows up.
@Observable
final class DesignModel {
    let project: URL
    let folder: URL
    let canvas = DesignCanvasModel()
    let chat: ClaudeChatModel
    private(set) var document: DesignDocument
    /// The screen, or the kit card (`kit:Button`, `kit:Button#secondary`), in focus.
    private(set) var selection: String?
    /// The element selected inside it, by its path from the root.
    private(set) var element: [Int]?
    var hovered: DesignHover?
    /// Changes to a kit element's style reach every use, unless this says otherwise.
    var styleOnlyHere = false
    var showsLayers = true
    var showsStyle = false
    /// Sends a finished design to be built: `asAgent` starts it on its own branch.
    var build: (_ prompt: String, _ asAgent: Bool) -> Void = { _, _ in }
    var onSessionChange: (String?) -> Void = { _ in }
    /// Claude is waiting on the user, whichever tab is in front.
    var onAttentionChange: (Bool) -> Void = { _ in }

    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var fingerprint = ""
    @ObservationIgnored var undoStack: [DesignUndoStep] = []
    @ObservationIgnored var redoStack: [DesignUndoStep] = []

    static let welcome = ClaudeChatWelcome(
        title: "Design it before you build it",
        detail: "Describe an app or a site. Claude draws it on the canvas, screen by screen, in a format it can build from later.",
        placeholder: "Describe what to design…",
        starters: [
            ("Design this project's iOS app", .phone),
            ("Design a landing page for it", .globe),
            ("Propose a better design for it", .search),
        ],
        showsTerminal: false,
        showsRecent: false,
        activity: ClaudeActivityStyle(working: DesignActivity.working, summary: DesignActivity.summary, step: DesignActivity.step)
    )

    init(project: URL, environment: [String: String], resuming session: String?) {
        self.project = project
        folder = DesignDocument.folder(inProject: project)
        document = DesignDocument.load(folder: folder)
        chat = ClaudeChatModel(folder: project.path, environment: environment, resuming: session, name: "Design")
        chat.extraArguments = Self.claudeArguments
        // Designing is safe to leave running: its files are all this chat is meant to touch.
        chat.mode = .auto
        chat.messageContext = { [weak self] in self?.selectionContext }
        chat.onChange = { [weak self] in
            guard let self else { return }
            onSessionChange(chat.sessionID)
            onAttentionChange(chat.needsAttention)
        }
        chat.clearContext = { [weak self] in self?.select(nil) }
        fingerprint = Self.fingerprint(folder)
    }

    /// The kit-first way of working, separate so the original brief stays as written.
    static var kitBrief: String {
        Bundle.main.url(forResource: "DesignKit", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    /// What this chat is allowed without asking: its own folder and looking at the result. Anything
    /// else, like editing the app, stops to ask.
    private static var claudeArguments: [String] {
        let brief = Bundle.main.url(forResource: "DesignBrief", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return ["--append-system-prompt", brief + kitBrief, "--allowedTools",
                "Write(./\(DesignDocument.folderName)/**)", "Edit(./\(DesignDocument.folderName)/**)", "mcp__vibex__design_screenshot"]
    }

    // MARK: Files

    func start() {
        guard watcher == nil else { return }
        reload()
        // The folder may not exist yet, so watch the project and notice when it changes.
        watcher = FileWatcher(path: project.path, latency: 0.2) { [weak self] in self?.reloadIfChanged() }
    }

    func stop() {
        watcher = nil
        chat.terminate()
    }

    func reload() {
        fingerprint = Self.fingerprint(folder)
        let new = DesignDocument.load(folder: folder)
        if new != document { document = new }
        if let selection, root(of: selection) == nil, !document.screens.contains(where: { $0.id == selection }) { select(nil) }
        if let selection, let element, root(of: selection)?.node(at: element) == nil { self.element = nil }
    }

    private func reloadIfChanged() {
        guard Self.fingerprint(folder) != fingerprint else { return }
        // Someone else changed the files, so going back to an earlier copy would lose their work.
        undoStack = []
        redoStack = []
        reload()
    }

    /// Names, sizes and dates: enough to skip the project's many unrelated changes without reading anything.
    nonisolated static func fingerprint(_ folder: URL) -> String {
        let files = [folder.appendingPathComponent("design.json")] + ((try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("screens"), includingPropertiesForKeys: nil)) ?? [])
        return files.map(\.path).sorted().map { path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(path)|\(attributes?[.size] as? Int ?? 0)|\(date)"
        }.joined(separator: "\n")
    }

    // MARK: Selection

    func select(_ id: String?) {
        selection = id
        element = nil
        styleOnlyHere = false
        updateContextLabel()
        if id != nil { chat.focusComposer() }
    }

    /// Picks one element, without taking the keyboard: arrows, ⌘D and Delete act on it.
    func select(element path: [Int]?, in id: String) {
        if selection != id { styleOnlyHere = false }
        selection = id
        element = path
        showsStyle = false
        updateContextLabel()
    }

    private func updateContextLabel() {
        let place = selectedScreen?.name ?? kitSelection?.name
        let layer = selectedNode.flatMap { $0.path.isEmpty ? nil : $0.layerName }
        chat.contextLabel = [place, layer].compactMap(\.self).joined(separator: " › ").nilIfEmpty
    }

    var selectedScreen: DesignScreen? { document.screens.first { $0.id == selection } }

    /// Tells Claude which screen is selected, without cluttering what the user sees they said.
    private var selectionContext: String? {
        let layer = selectedNode.flatMap { node in
            node.path.isEmpty ? nil : ", its element \"\(node.layerName)\" at child position \(node.path.map(String.init).joined(separator: "/"))"
        } ?? ""
        if let kit = kitSelection {
            return "\(ClaudeEvent.selectionNotePrefix) the UI kit component \"\(kit.name)\"\(kit.variant.map { ", variant \($0)" } ?? "") in \(DesignDocument.folderName)/design.json\(layer). This message is about it.]"
        }
        return selectedScreen.map { "\(ClaudeEvent.selectionNotePrefix) the screen \"\($0.name)\" on the canvas: \(DesignDocument.folderName)/screens/\($0.id)\(layer). This message is about it.]" }
    }

    func fix(_ screen: DesignScreen) {
        chat.send("\(DesignDocument.folderName)/screens/\(screen.id) doesn't load: \(screen.error ?? "unknown error"). Please fix it.")
    }

    // MARK: Actions

    func copySelected() {
        guard let selection else { return }
        let document = document
        Task {
            guard let image = await DesignSnapshot.image(of: document, screen: selection) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
    }

    /// Uses absolute paths, because an agent works from a worktree that may not have these files yet.
    var buildPrompt: String {
        """
        Build the design in \(folder.path). Read design.json and every file in screens/. design.json has the \
        tokens, styles and the UI kit: components with `props` filling `{{name}}` and `variants`; `$name` numbers come \
        from tokens.radii and tokens.spacing. Each screen file describes the layout in device points, and `overrides` \
        change one element inside a use by child position. Icons are SF Symbols. Follow this project's existing stack and conventions, or pick a sensible one for the device if it's \
        empty. Turn tokens and components into real theme values and reusable views rather than copying numbers around. \
        Match the design closely, then run it and compare it against the canvas with the design_screenshot tool.
        """
    }

    /// Asks Claude to pull a kit out of screens designed without one.
    func makeKit() {
        chat.send("Make a UI kit from this design, following \"Making a kit from an existing design\". Keep every screen looking the same.")
    }

    func startOver() {
        try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        reload()
    }

    var hasDesign: Bool { !document.isEmpty }
}

/// Design's work in the words of designing, rather than as a list of file operations.
nonisolated enum DesignActivity {
    private enum Step: Equatable {
        case kit, screen(String, isNew: Bool), check, read, other(String)
    }

    private static func kind(_ tool: ClaudeToolUse) -> Step {
        let path = tool.input["file_path"]
        if tool.name == "mcp__vibex__design_screenshot" { return .check }
        if tool.name == "Write" || tool.name == "Edit" || tool.name == "MultiEdit", let path, path.contains("\(DesignDocument.folderName)/") {
            if path.hasSuffix("/design.json") { return .kit }
            return .screen(DesignDocument.title(fromFile: URL(fileURLWithPath: path)), isNew: tool.name == "Write")
        }
        if tool.name == "Read" || tool.name == "Glob" || tool.name == "Grep" { return .read }
        return .other(ClaudeToolSummary(tool).title)
    }

    /// What Claude is doing now. A brand-new call doesn't have its file yet, so it reads as drawing.
    static func working(_ tool: ClaudeToolUse?) -> String? {
        guard let tool else { return "Thinking…" }
        if tool.input["file_path"] == nil, tool.name == "Write" || tool.name == "Edit" { return "Drawing…" }
        switch kind(tool) {
        case .kit: return "Building the UI kit…"
        case let .screen(name, isNew): return isNew ? "Drawing \(name)…" : "Updating \(name)…"
        case .check: return "Checking how it looks…"
        case .read: return "Reading the project…"
        case .other: return "Working…"
        }
    }

    static func step(_ tool: ClaudeToolUse) -> String {
        switch kind(tool) {
        case .kit: "Built the UI kit"
        case let .screen(name, isNew): isNew ? "Drew \(name)" : "Updated \(name)"
        case .check: "Checked how it looks"
        case .read: "Read the project"
        case let .other(title): title
        }
    }

    /// "Drew 3 screens", "Updated Today", or whatever fits when nothing was drawn.
    static func summary(_ tools: [ClaudeToolUse]) -> String {
        var drawn: [String] = [], updated: [String] = []
        for tool in tools {
            guard case let .screen(name, isNew) = kind(tool) else { continue }
            if isNew {
                if !drawn.contains(name) { drawn.append(name) }
            } else if !updated.contains(name), !drawn.contains(name) {
                updated.append(name)
            }
        }
        func phrase(_ verb: String, _ names: [String]) -> String? {
            switch names.count {
            case 0: nil
            case 1: "\(verb) \(names[0])"
            default: "\(verb) \(names.count) screens"
            }
        }
        let parts = [phrase("Drew", drawn), phrase(drawn.isEmpty ? "Updated" : "updated", updated)].compactMap(\.self)
        if !parts.isEmpty { return parts.joined(separator: ", ") }
        if tools.contains(where: { kind($0) == .kit }) { return "Built the UI kit" }
        if tools.contains(where: { kind($0) == .check }) { return "Checked how it looks" }
        return "Read the project"
    }
}

/// Chat on the left, canvas on the right. What's asked for and what it looks like stay side by side.
struct DesignTabView: View {
    let model: DesignModel

    var body: some View {
        HStack(spacing: 0) {
            ClaudeChatView(model: model.chat, welcome: DesignModel.welcome)
                .frame(width: 360)
            Rectangle().fill(Theme.line).frame(width: 1)
            GeometryReader { geometry in
                ZStack {
                    DesignCanvasContainer(model: model)
                    if !model.hasDesign { emptyCanvas }
                }
                .overlay(alignment: .top) { toolbar }
                .overlay(alignment: .bottomTrailing) {
                    if model.hasDesign { zoomControls.padding(.trailing, showsInspector(in: geometry.size) ? 278 : 0) }
                }
                .overlay(alignment: .topLeading) {
                    if model.hasDesign, model.showsLayers, geometry.size.width >= 760 {
                        DesignLayersPanel(model: model).padding(.top, 52).padding([.leading, .bottom], 10)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if showsInspector(in: geometry.size) {
                        DesignInspector(model: model).padding(.top, 52).padding([.trailing, .bottom], 10)
                            .transition(.opacity.combined(with: .offset(x: 12)))
                    }
                }
                .overlay(alignment: .bottom) { if model.hasDesign, model.document.kit.isEmpty, !model.chat.isBusy { kitOffer } }
                .animation(.spring(response: 0.3, dampingFraction: 1), value: showsInspector(in: geometry.size))
                .onChange(of: panelInsets(in: geometry.size), initial: true) { _, insets in
                    model.canvas.leadingInset = insets.width
                    model.canvas.trailingInset = insets.height
                    if !model.canvas.hasMoved { model.canvas.fit() }
                }
            }
        }
        .background(Theme.background)
        .onAppear(perform: model.start)
    }

    /// What fitting keeps clear: leading as width, trailing as height. The inspector's room is kept
    /// whether it's open or not, so selecting something never moves the board under the pointer. A
    /// narrow pane can't spare it, and the panel floats over the board instead.
    private func panelInsets(in size: CGSize) -> CGSize {
        CGSize(width: model.hasDesign && model.showsLayers && size.width >= 760 ? 234 : 0, height: model.hasDesign && size.width >= 1100 ? 278 : 0)
    }

    private func showsInspector(in size: CGSize) -> Bool {
        model.hasDesign && (model.showsStyle || model.selectedNode != nil) && size.width >= 480
    }

    /// Screens designed before the kit, or without one: restyling them means editing each by hand.
    private var kitOffer: some View {
        HStack(spacing: 10) {
            Text("This design has no UI kit, so each screen has to be restyled by hand.")
                .font(.vibex(size: 12)).foregroundStyle(Theme.muted)
            Button("Make UI Kit", action: model.makeKit).buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .card(fill: Theme.card, radius: 10)
        .padding(.bottom, 12)
    }

    private var emptyCanvas: some View {
        VStack(spacing: 8) {
            IconView(.feather, size: 30).foregroundStyle(Theme.faint)
            Text(model.chat.isBusy ? "Claude is getting started…" : "Screens appear here as Claude designs them")
                .font(.vibex(size: 13))
                .foregroundStyle(Theme.muted)
        }
        .allowsHitTesting(false)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if let name = model.document.name {
                Text(name).font(.vibex(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            }
            if model.hasDesign {
                let count = model.document.screens.count, kit = model.document.kit.count
                Text("\(count) screen\(count == 1 ? "" : "s")\(kit > 0 ? " · \(kit) component\(kit == 1 ? "" : "s")" : "")").font(.vibex(size: 12)).foregroundStyle(Theme.faint)
            }
            if model.chat.isBusy, model.hasDesign {
                ProgressView().controlSize(.mini)
                Text(DesignActivity.working(model.chat.pendingTool) ?? "Designing…").font(.vibex(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            if model.hasDesign {
                ToolbarIconButton(icon: .layers, help: "Layers", isActive: model.showsLayers) { model.showsLayers.toggle() }
                ToolbarIconButton(icon: .palette, help: "Style: colors, type and corners", isActive: model.showsStyle) { model.showsStyle.toggle() }
                Menu {
                    Button("Undo Edit") { model.undo() }.disabled(model.undoStack.isEmpty)
                    Button("Redo Edit") { model.redo() }.disabled(model.redoStack.isEmpty)
                    Divider()
                    Button("Make UI Kit", action: model.makeKit).disabled(model.chat.isBusy)
                    Divider()
                    Button("Copy Selected Screen") { model.copySelected() }.disabled(model.selectedScreen == nil)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.folder]) }
                    Button("Build as an Agent") { model.build(model.buildPrompt, true) }
                    Divider()
                    Button("Start Over…", role: .destructive, action: confirmStartOver)
                } label: {
                    IconView(.dots, size: 15).foregroundStyle(Theme.muted).frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                Button("Build This") { model.build(model.buildPrompt, false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.chat.isBusy)
                    .help("Ask Claude to build this design in your project")
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Theme.background.opacity(model.hasDesign ? 0.85 : 0))
    }

    private func confirmStartOver() {
        let alert = NSAlert()
        alert.messageText = "Start over?"
        alert.informativeText = "The \(DesignDocument.folderName) folder moves to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.startOver() }
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            zoomButton(.minus, help: "Zoom Out") { model.canvas.zoomFromCenter(by: 0.8) }
            Button { model.canvas.fit() } label: {
                Text("\(Int((model.canvas.zoom * 100).rounded()))%")
                    .font(.vibex(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .frame(width: 44, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fit All Screens")
            zoomButton(.plus, help: "Zoom In") { model.canvas.zoomFromCenter(by: 1.25) }
        }
        .padding(.horizontal, 2)
        .card(fill: Theme.card, radius: 10)
        .padding(12)
    }

    private func zoomButton(_ icon: Icon, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            IconView(icon, size: 13).foregroundStyle(Theme.muted).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
