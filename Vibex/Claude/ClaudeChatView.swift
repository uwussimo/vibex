import AppKit
import SwiftUI

/// Claude Code as a native conversation: Markdown replies, a card per tool call, approvals as buttons.
struct ClaudeChatView: View {
    let model: ClaudeChatModel
    let openFile: (URL) -> Void
    let openTerminal: () -> Void
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty, !model.isLoadingHistory {
                ClaudeChatEmptyState(send: model.send, openTerminal: openTerminal)
            } else {
                transcript
            }
            ClaudeComposer(model: model)
        }
        .background(Theme.background)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            model.attachments += files.map(ClaudeAttachment.init(url:))
            model.focusComposer()
            return !files.isEmpty
        } isTargeted: { isDropTargeted = $0 }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(model.items) { item in
                    if !isAwaitingApproval(item) { row(item) }
                }
                ForEach(model.permissions) { request in
                    ClaudePermissionCard(request: request, model: model)
                }
                if model.isBusy, model.permissions.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("Claude is working…").font(.vibex(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
    }

    /// The approval card already says what this call is.
    private func isAwaitingApproval(_ item: ClaudeChatModel.Item) -> Bool {
        guard case let .tool(tool, _) = item.kind else { return false }
        return model.permissions.contains { $0.tool.id == tool.id }
    }

    @ViewBuilder
    private func row(_ item: ClaudeChatModel.Item) -> some View {
        switch item.kind {
        case let .user(text):
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .font(.vibex(size: 13.5))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
            }
        case let .attachments(images, files):
            HStack(spacing: 6) {
                Spacer(minLength: 60)
                ForEach(files, id: \.self) { file in
                    ClaudeFileChip(name: file)
                }
                ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                    if let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 220, maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        case let .text(text):
            MarkdownView(document: MarkdownDocument(text))
        case let .tool(tool, result):
            ClaudeToolCard(tool: tool, result: result, isRunning: model.isBusy, folder: model.folder, openFile: openFile)
        case let .notice(message, isError):
            HStack(alignment: .top, spacing: 8) {
                IconView(isError ? .alert : .info, size: 14).foregroundStyle(isError ? Theme.red : Theme.muted)
                Text(message).font(.vibex(size: 12.5)).foregroundStyle(Theme.text).textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill((isError ? Theme.red : Theme.muted).opacity(0.1)))
        case let .done(seconds):
            Text(seconds > 0 ? "Finished in \(Self.duration(seconds))" : "Finished")
                .font(.vibex(size: 11))
                .foregroundStyle(Theme.faint)
        }
    }

    private static func duration(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds.rounded()))s" : "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }
}

// MARK: - Empty state

private struct ClaudeChatEmptyState: View {
    let send: (String) -> Void
    let openTerminal: () -> Void

    private let starters = [
        ("Build and run this app, then check it works", Icon.play),
        ("Explain how this project is put together", Icon.book),
        ("Find a bug and fix it", Icon.search),
    ]

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            BrandLogoView(.claude, size: 34)
            VStack(spacing: 5) {
                Text("What should we build?")
                    .font(.vibex(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Claude can see the simulator and browser next to this tab, and check its own work.")
                    .font(.vibex(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 6) {
                ForEach(starters, id: \.0) { title, icon in
                    Button { send(title) } label: {
                        HStack(spacing: 9) {
                            IconView(icon, size: 14).foregroundStyle(Theme.muted)
                            Text(title).font(.vibex(size: 12.5)).foregroundStyle(Theme.text)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.line))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressFeedbackButtonStyle())
                }
            }
            .frame(maxWidth: 380)
            Button("Open a terminal instead", action: openTerminal)
                .buttonStyle(.plain)
                .font(.vibex(size: 11.5))
                .foregroundStyle(Theme.faint)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Composer

private struct ClaudeComposer: View {
    let model: ClaudeChatModel
    @State private var text = ""
    @State private var pasteMonitor: Any?
    @FocusState private var isFocused: Bool

    private var matches: [String] {
        guard text.hasPrefix("/"), !text.contains(" ") else { return [] }
        let query = text.dropFirst().lowercased()
        return Array(model.slashCommands.filter { query.isEmpty || $0.lowercased().hasPrefix(query) }.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matches, id: \.self) { command in
                Button { text = "/\(command) " } label: {
                    Text("/\(command)")
                        .font(.vibexCode(size: 12))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.attachments) { attachment in
                            ClaudeAttachmentChip(attachment: attachment) {
                                model.attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .padding(.top, 10)
            }
            TextField("Ask Claude to build, fix or explain…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.vibex(size: 13.5))
                .lineLimit(1...10)
                .focused($isFocused)
                .padding(.horizontal, 12)
                .padding(.top, 11)
                .padding(.bottom, 8)
                .onKeyPress(keys: [.return], phases: .down) { press in
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                        text += "\n"
                    } else {
                        submit()
                    }
                    return .handled
                }
            HStack(spacing: 6) {
                Button(action: chooseFiles) {
                    IconView(.plus, size: 15)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Attach images or files. You can also drop them here, or paste a screenshot.")
                picker(model.mode.title, icon: model.mode == .plan ? .book : (model.mode == .acceptEdits ? .zap : .lock), help: "When Claude asks before acting") {
                    ForEach(ClaudeChatModel.Mode.allCases) { mode in
                        Button(mode.title) { model.mode = mode }
                    }
                }
                picker(model.model.title, icon: .cpu, help: "Model") {
                    ForEach(ClaudeChatModel.Model.allCases) { option in
                        Button(option.title) { model.model = option }
                    }
                }
                Spacer()
                if model.isBusy {
                    Button(action: model.stopTurn) {
                        IconView(.stop, size: 13)
                            .foregroundStyle(Theme.background)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Theme.text))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressFeedbackButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .help("Stop (Esc)")
                }
                Button(action: submit) {
                    IconView(.arrowUp, size: 15)
                        .foregroundStyle(canSend ? Theme.background : Theme.faint)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(canSend ? Theme.accent : Theme.raised))
                        .contentShape(Circle())
                }
                .buttonStyle(PressFeedbackButtonStyle())
                .disabled(!canSend)
                .help("Send (Return). Shift-Return adds a line.")
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(isFocused ? Theme.lineStrong : Theme.line))
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .frame(maxWidth: 820)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
        .onChange(of: model.focusRequest) { isFocused = true }
        .onAppear {
            isFocused = true
            // The text field would swallow ⌘V and beep on an image, so look first.
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard isFocused, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "v" else { return event }
                let pasted = ClaudeAttachment.fromPasteboard()
                guard !pasted.isEmpty else { return event }
                model.attachments += pasted
                return nil
            }
        }
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.attachments.isEmpty
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.folder)
        panel.prompt = "Attach"
        panel.begin { response in
            guard response == .OK else { return }
            model.attachments += panel.urls.map(ClaudeAttachment.init(url:))
            model.focusComposer()
        }
    }

    private func submit() {
        guard canSend else { return }
        model.send(text)
        text = ""
    }

    private func picker(_ title: String, icon: Icon, help: String, @ViewBuilder content: () -> some View) -> some View {
        Menu(content: content) {
            HStack(spacing: 5) {
                IconView(icon, size: 12)
                Text(title).font(.vibex(size: 11.5))
            }
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}

// MARK: - Attachments

private struct ClaudeFileChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 5) {
            IconView(.file, size: 13).foregroundStyle(Theme.muted)
            Text(name).font(.vibex(size: 12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised))
    }
}

private struct ClaudeAttachmentChip: View {
    let attachment: ClaudeAttachment
    let remove: () -> Void

    var body: some View {
        Group {
            switch attachment.kind {
            case let .image(image, _):
                if let picture = NSImage(data: image.data) {
                    Image(nsImage: picture)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            case let .file(url):
                ClaudeFileChip(name: url.lastPathComponent).padding(.vertical, 7)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                IconView(.close, size: 9)
                    .foregroundStyle(Theme.text)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Theme.background))
                    .overlay(Circle().strokeBorder(Theme.lineStrong))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .help("Remove")
        }
        .padding(.top, 5)
        .padding(.trailing, 5)
    }
}

// MARK: - Tool cards

/// How a tool call reads in the conversation.
nonisolated struct ClaudeToolSummary: Equatable {
    var icon: Icon
    var title: String
    /// A file the card can open.
    var path: String?
    var isCode = false

    init(icon: Icon, title: String, path: String? = nil, isCode: Bool = false) {
        self.icon = icon
        self.title = title
        self.path = path
        self.isCode = isCode
    }

    init(_ tool: ClaudeToolUse) {
        let name = tool.name
        let file = tool.input["file_path"] ?? tool.input["notebook_path"]
        let fileName = file.map { ($0 as NSString).lastPathComponent } ?? ""
        switch name {
        case "Read": self.init(icon: .file, title: "Read \(fileName)", path: file)
        case "Write": self.init(icon: .fileCode, title: "Write \(fileName)", path: file)
        case "Edit", "MultiEdit", "NotebookEdit": self.init(icon: .fileCode, title: "Edit \(fileName)", path: file)
        case "Bash": self.init(icon: .terminal, title: tool.input["command"] ?? "Ran a command", isCode: true)
        case "Grep": self.init(icon: .search, title: "Search for \(tool.input["pattern"] ?? "text")")
        case "Glob": self.init(icon: .search, title: "Find files matching \(tool.input["pattern"] ?? "a pattern")")
        case "WebFetch": self.init(icon: .globe, title: "Read \(tool.input["url"] ?? "a page")")
        case "WebSearch": self.init(icon: .globe, title: "Search the web for \(tool.input["query"] ?? "something")")
        case "Task", "Agent": self.init(icon: .users, title: tool.input["description"] ?? "Ran a subagent")
        case "TodoWrite": self.init(icon: .checkCircle, title: "Update the plan")
        case "Skill": self.init(icon: .skills, title: "Use the \(tool.input["skill"] ?? "") skill")
        case "ToolSearch": self.init(icon: .search, title: "Look up tools")
        default:
            guard name.hasPrefix("mcp__") else {
                self.init(icon: .zap, title: name)
                return
            }
            let parts = name.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
            let server = parts.count > 1 ? parts[1] : "mcp"
            let action = parts.dropFirst(2).joined(separator: " ")
            if server == "vibex" {
                let words = action.split(separator: " ").map(String.init)
                let area = words.first ?? ""
                let rest = words.dropFirst().joined(separator: " ")
                let icon: Icon = area == "simulator" ? .phone : (area == "browser" ? .globe : (area == "terminal" ? .terminal : .zap))
                self.init(icon: icon, title: "\(area.capitalized): \(rest)")
            } else {
                self.init(icon: .server, title: "\(server): \(action)")
            }
        }
    }
}

private struct ClaudeToolCard: View {
    let tool: ClaudeToolUse
    let result: ClaudeToolResult?
    let isRunning: Bool
    let folder: String
    let openFile: (URL) -> Void
    @State private var isExpanded = false

    private var summary: ClaudeToolSummary { ClaudeToolSummary(tool) }
    private var images: [NSImage] { (result?.images ?? []).compactMap(NSImage.init(data:)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.spring(response: 0.25, dampingFraction: 1)) { isExpanded.toggle() } } label: {
                HStack(spacing: 8) {
                    IconView(summary.icon, size: 13).foregroundStyle(Theme.muted).frame(width: 14)
                    Text(summary.title)
                        .font(summary.isCode ? .vibexCode(size: 11.5) : .vibex(size: 12.5))
                        .foregroundStyle(Theme.text.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    status
                    IconView(isExpanded ? .chevronUp : .chevronDown, size: 11).foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let path = summary.path { Button("Open \((path as NSString).lastPathComponent)") { openFile(URL(fileURLWithPath: path)) } }
            }
            // A screenshot is the point of the call, so it shows without expanding.
            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320, maxHeight: 420, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            if isExpanded { details }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(result?.isError == true ? Theme.red.opacity(0.4) : Theme.line))
    }

    @ViewBuilder
    private var status: some View {
        if let result {
            if result.isError { IconView(.alert, size: 13).foregroundStyle(Theme.red) }
        } else if isRunning {
            ProgressView().controlSize(.mini)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let path = summary.path {
                Button { openFile(URL(fileURLWithPath: path)) } label: {
                    Text(path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : path)
                        .font(.vibexCode(size: 11))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            if let old = tool.input["old_string"], let new = tool.input["new_string"] {
                monospaced(old.split(separator: "\n", omittingEmptySubsequences: false).map { "- \($0)" }.joined(separator: "\n"), color: Theme.red)
                monospaced(new.split(separator: "\n", omittingEmptySubsequences: false).map { "+ \($0)" }.joined(separator: "\n"), color: Theme.green)
            } else if tool.name == "Write", let content = tool.input["content"] {
                monospaced(Self.clipped(content), color: Theme.text.opacity(0.85))
            } else if let text = result?.text, !text.isEmpty {
                monospaced(Self.clipped(text), color: result?.isError == true ? Theme.red : Theme.text.opacity(0.85))
            } else if summary.path == nil {
                monospaced(tool.input.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"), color: Theme.muted)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func monospaced(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.vibexCode(size: 11))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func clipped(_ text: String) -> String {
        text.count > 4000 ? String(text.prefix(4000)) + "\n…" : text
    }
}

// MARK: - Approvals

private struct ClaudePermissionCard: View {
    let request: ClaudePermissionRequest
    let model: ClaudeChatModel

    var body: some View {
        Group {
            switch request.tool.name {
            case "AskUserQuestion": ClaudeQuestionCard(request: request, model: model)
            case "ExitPlanMode": plan
            default: approval
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.5)))
    }

    private var approval: some View {
        let summary = ClaudeToolSummary(request.tool)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Claude wants to \(Self.verb(request.tool.name))")
                .font(.vibex(size: 12, weight: .medium))
                .foregroundStyle(Theme.muted)
            Text(request.tool.input["command"] ?? relativePath ?? summary.title)
                .font(.vibexCode(size: 12))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .lineLimit(12)
            if let old = request.tool.input["old_string"], let new = request.tool.input["new_string"] {
                Text("- \(old)").font(.vibexCode(size: 11)).foregroundStyle(Theme.red).lineLimit(10)
                Text("+ \(new)").font(.vibexCode(size: 11)).foregroundStyle(Theme.green).lineLimit(10)
            }
            HStack(spacing: 8) {
                Button("Allow") { model.allow(request) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("⌘Return")
                if request.suggestions != nil {
                    Button("Always Allow") { model.allow(request, always: true) }
                }
                Button("Don't Allow") { model.deny(request) }
                Spacer()
            }
            .controlSize(.regular)
        }
    }

    private var relativePath: String? {
        guard let path = request.tool.input["file_path"] else { return nil }
        return path.hasPrefix(model.folder + "/") ? String(path.dropFirst(model.folder.count + 1)) : path
    }

    private var plan: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude's plan").font(.vibex(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
            MarkdownView(document: MarkdownDocument(request.tool.input["plan"] ?? ""))
            HStack(spacing: 8) {
                Button("Start Building") {
                    model.mode = .acceptEdits
                    model.allow(request)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                Button("Keep Planning") { model.deny(request) }
                Spacer()
            }
        }
    }

    private static func verb(_ tool: String) -> String {
        switch tool {
        case "Bash": "run"
        case "Write": "create"
        case "Edit", "MultiEdit", "NotebookEdit": "edit"
        case "WebFetch", "WebSearch": "go online"
        default: "use a tool"
        }
    }
}

/// AskUserQuestion: Claude's own multiple choice, as buttons.
private struct ClaudeQuestionCard: View {
    struct Question: Decodable {
        struct Option: Decodable { var label: String; var description: String? }
        var question: String
        var options: [Option]
    }

    let request: ClaudePermissionRequest
    let model: ClaudeChatModel
    @State private var answers: [String: String] = [:]

    private var questions: [Question] {
        guard let text = request.tool.input["questions"] else { return [] }
        return (try? JSONDecoder().decode([Question].self, from: Data(text.utf8))) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(questions, id: \.question) { question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.question).font(.vibex(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                    ForEach(question.options, id: \.label) { option in
                        Button { choose(option.label, for: question.question) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label).font(.vibex(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                                if let description = option.description {
                                    Text(description).font(.vibex(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(answers[question.question] == option.label ? Theme.accent.opacity(0.25) : Theme.card))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button("Skip") { model.deny(request) }.buttonStyle(.plain).font(.vibex(size: 11.5)).foregroundStyle(Theme.muted)
        }
    }

    private func choose(_ label: String, for question: String) {
        answers[question] = label
        if answers.count == questions.count { model.answer(request, answers: answers) }
    }
}
