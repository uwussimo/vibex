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
    private(set) var selection: String?
    /// Sends a finished design to be built: `asAgent` starts it on its own branch.
    var build: (_ prompt: String, _ asAgent: Bool) -> Void = { _, _ in }
    var onSessionChange: (String?) -> Void = { _ in }

    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var fingerprint = ""

    static let welcome = ClaudeChatWelcome(
        title: "Design it before you build it",
        detail: "Describe an app or a site. Claude draws it on the canvas, screen by screen, in a format it can build from later.",
        placeholder: "Describe what to design…",
        starters: [
            ("Design the main screens of this project's iOS app", .phone),
            ("Design a landing page for this project", .globe),
            ("Look at what's here and propose a better design", .search),
        ],
        showsTerminal: false,
        showsRecent: false,
        showsModes: false
    )

    init(project: URL, environment: [String: String], resuming session: String?) {
        self.project = project
        folder = DesignDocument.folder(inProject: project)
        document = DesignDocument.load(folder: folder)
        chat = ClaudeChatModel(folder: project.path, environment: environment, resuming: session, name: "Design")
        chat.extraArguments = Self.claudeArguments
        chat.messageContext = { [weak self] in self?.selectionContext }
        chat.onChange = { [weak self] in
            guard let self else { return }
            onSessionChange(chat.sessionID)
        }
        chat.clearContext = { [weak self] in self?.select(nil) }
        fingerprint = Self.fingerprint(folder)
    }

    /// What this chat is allowed without asking: its own folder and looking at the result. Anything
    /// else, like editing the app, stops to ask.
    private static var claudeArguments: [String] {
        let brief = Bundle.main.url(forResource: "DesignBrief", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return ["--append-system-prompt", brief, "--allowedTools",
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
        if let selection, !document.screens.contains(where: { $0.id == selection }) { select(nil) }
    }

    private func reloadIfChanged() {
        if Self.fingerprint(folder) != fingerprint { reload() }
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
        chat.contextLabel = selectedScreen.map(\.name)
        if id != nil { chat.focusComposer() }
    }

    var selectedScreen: DesignScreen? { document.screens.first { $0.id == selection } }

    /// Tells Claude which screen is selected, without cluttering what the user sees they said.
    private var selectionContext: String? {
        selectedScreen.map { "[The user has selected the screen \"\($0.name)\" on the canvas: \(DesignDocument.folderName)/screens/\($0.id). This message is about it.]" }
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
        tokens, styles and shared components; each screen file describes the layout in device points. Icons are SF \
        Symbols. Follow this project's existing stack and conventions, or pick a sensible one for the device if it's \
        empty. Turn tokens and components into real theme values and reusable views rather than copying numbers around. \
        Match the design closely, then run it and compare it against the canvas with the design_screenshot tool.
        """
    }

    func startOver() {
        try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        reload()
    }

    var hasDesign: Bool { !document.isEmpty }
}

/// Chat on the left, canvas on the right. What's asked for and what it looks like stay side by side.
struct DesignTabView: View {
    let model: DesignModel

    var body: some View {
        HStack(spacing: 0) {
            ClaudeChatView(model: model.chat, welcome: DesignModel.welcome)
                .frame(width: 360)
            Rectangle().fill(Theme.line).frame(width: 1)
            ZStack {
                DesignCanvasContainer(model: model)
                if !model.hasDesign { emptyCanvas }
            }
            .overlay(alignment: .top) { toolbar }
            .overlay(alignment: .bottomTrailing) { if model.hasDesign { zoomControls } }
        }
        .background(Theme.background)
        .onAppear(perform: model.start)
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
                let count = model.document.screens.count
                Text("\(count) screen\(count == 1 ? "" : "s")").font(.vibex(size: 12)).foregroundStyle(Theme.faint)
            }
            if model.chat.isBusy, model.hasDesign {
                ProgressView().controlSize(.mini)
                Text("Designing…").font(.vibex(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if model.hasDesign {
                Menu {
                    Button("Copy Selected Screen") { model.copySelected() }.disabled(model.selection == nil)
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
