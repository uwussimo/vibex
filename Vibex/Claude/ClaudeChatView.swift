import AppKit
import SwiftUI

/// Claude Code as a native conversation: Markdown replies, a card per tool call, approvals as buttons.
struct ClaudeChatView: View {
    let model: ClaudeChatModel
    /// What an empty chat invites; Design has its own.
    var welcome = ClaudeChatWelcome.standard
    /// Nil where agents don't belong, such as Design.
    var agents: ClaudeAgentsContext?
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if let agents { ClaudeAgentsBar(model: agents.model, actions: agents.actions, folder: model.folder) }
            if model.items.isEmpty, !model.isLoadingHistory {
                ClaudeChatEmptyState(welcome: welcome, model: model)
            } else {
                transcript
            }
            ClaudeComposer(model: model, placeholder: welcome.placeholder, showsModes: welcome.showsModes, agents: agents)
        }
        .background(Theme.background)
        .task { ClaudeCatalog.shared.load(folder: model.folder, environment: model.environment) }
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
                    ClaudeWorkingLine(status: model.status, started: model.turnStarted)
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
            ClaudeToolCard(tool: tool, result: result, isRunning: model.isBusy, folder: model.folder, openFile: model.actions.openFile)
        case let .needsTerminal(command):
            HStack(spacing: 8) {
                IconView(.terminal, size: 14).foregroundStyle(Theme.muted)
                Text("/\(command) needs Claude Code's terminal view.").font(.vibex(size: 12.5)).foregroundStyle(Theme.text)
                Spacer(minLength: 6)
                Button("Open in Terminal") { model.actions.runInTerminal("claude /\(command)") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.muted.opacity(0.1)))
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

// MARK: - Working line

/// What's going on, and for how long, so a long turn doesn't look stuck.
private struct ClaudeWorkingLine: View {
    let status: String?
    let started: Date?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(status == "compacting" ? "Compacting the conversation…" : "Claude is working…")
                .font(.vibex(size: 12))
                .foregroundStyle(Theme.muted)
            if let started {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(started)))
                    if seconds >= 3 {
                        Text(seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s")
                            .font(.vibex(size: 12))
                            .foregroundStyle(Theme.faint)
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}

// MARK: - Empty state

/// What an empty chat says and suggests.
struct ClaudeChatWelcome {
    var title: String
    var detail: String
    var placeholder: String
    var starters: [(String, Icon)]
    var showsTerminal = true
    var showsRecent = true
    var tip: String?
    var showsModes = true

    static let standard = ClaudeChatWelcome(
        title: "What should we build?",
        detail: "Claude can see the simulator and browser next to this tab, and check its own work.",
        placeholder: "Ask Claude to build, fix or explain…  / for commands, @ for files",
        starters: [
            ("Build and run this app, then check it works", .play),
            ("Explain how this project is put together", .book),
            ("Find a bug and fix it", .search),
        ],
        tip: "Want to try several ideas at once? ⌘Return starts a message as its own agent, on its own branch."
    )
}

private struct ClaudeChatEmptyState: View {
    let welcome: ClaudeChatWelcome
    let model: ClaudeChatModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            BrandLogoView(.claude, size: 34)
            VStack(spacing: 5) {
                Text(welcome.title)
                    .font(.vibex(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(welcome.detail)
                    .font(.vibex(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 6) {
                ForEach(welcome.starters, id: \.0) { title, icon in
                    row(title, icon: icon) { model.send(title) }
                }
            }
            .frame(maxWidth: 380)
            if welcome.showsRecent, !recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PICK UP WHERE YOU LEFT OFF")
                        .font(.vibex(size: 10.5, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.faint)
                    ForEach(recent) { session in
                        row(session.title, icon: .clock) { model.actions.resume(session.id) }
                    }
                }
                .frame(maxWidth: 380)
            }
            if let tip = welcome.tip {
                Text(tip)
                    .font(.vibex(size: 11.5))
                    .foregroundStyle(Theme.faint)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            if welcome.showsTerminal {
                Button("Open a terminal instead", action: model.actions.openTerminal)
                    .buttonStyle(.plain)
                    .font(.vibex(size: 11.5))
                    .foregroundStyle(Theme.faint)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if welcome.showsRecent { model.loadRecentSessions() } }
    }

    private var recent: [ClaudeSessionSummary] { Array(model.recentSessions.prefix(3)) }

    private func row(_ title: String, icon: Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                IconView(icon, size: 14).foregroundStyle(Theme.muted)
                Text(title).font(.vibex(size: 12.5)).foregroundStyle(Theme.text).lineLimit(1)
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

// MARK: - Composer

private struct ClaudeComposer: View {
    let model: ClaudeChatModel
    let placeholder: String
    let showsModes: Bool
    let agents: ClaudeAgentsContext?
    @State private var text = ""
    @State private var pasteMonitor: Any?
    @State private var highlighted = 0
    /// Esc closed the menu; typing brings it back.
    @State private var isMenuDismissed = false
    /// How far back ↑ has gone through what was sent, from the newest.
    @State private var historyIndex: Int?
    @State private var projectFiles: [String] = []
    @FocusState private var isFocused: Bool

    private var suggestions: [ClaudeSuggestion] {
        guard !isMenuDismissed, !text.isEmpty else { return [] }
        return ClaudeCompleter.suggestions(
            for: text,
            commands: model.capabilities.commands,
            models: model.capabilities.models,
            sessions: model.recentSessions,
            files: projectFiles
        )
    }

    private var sentPrompts: [String] {
        model.items.compactMap { item in
            if case let .user(prompt) = item.kind { prompt } else { nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !suggestions.isEmpty {
                ClaudeSuggestionMenu(suggestions: suggestions, highlighted: min(highlighted, suggestions.count - 1), hover: { highlighted = $0 }, choose: choose)
                Rectangle().fill(Theme.line).frame(height: 1)
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
            if let label = model.contextLabel {
                HStack(spacing: 5) {
                    IconView(.target, size: 12).foregroundStyle(Theme.accent)
                    Text("About \(label)").font(.vibex(size: 11.5, weight: .medium)).foregroundStyle(Theme.text)
                    Button { model.clearContext() } label: {
                        IconView(.close, size: 9).foregroundStyle(Theme.muted).frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Talk about the whole design")
                }
                .padding(.leading, 8)
                .padding(.trailing, 2)
                .frame(height: 24)
                .background(Capsule().fill(Theme.accent.opacity(0.14)))
                .padding(.horizontal, 10)
                .padding(.top, 10)
            }
            TextField(isAgentMode ? "Describe the task. It gets its own branch and its own chat." : placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.vibex(size: 13.5))
                .lineLimit(1...10)
                .focused($isFocused)
                .padding(.horizontal, 12)
                .padding(.top, 11)
                .padding(.bottom, 8)
                .onKeyPress(phases: [.down, .repeat], action: handleKey)
                .onExitCommand { if isAgentMode { agents?.model.isComposing = false } }
                .onChange(of: text) { old, new in
                    highlighted = 0
                    isMenuDismissed = false
                    if old.isEmpty || !new.isEmpty, historyIndex != nil, !sentPrompts.reversed().contains(new) { historyIndex = nil }
                    prepareMenu(for: new)
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
                if showsModes { modeMenu }
                modelMenu
                Spacer()
                contextMeter
                agentToggle
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
                    Group {
                        if isAgentMode {
                            Text("Start Agent").font(.vibex(size: 12, weight: .semibold)).padding(.horizontal, 12)
                        } else {
                            IconView(.arrowUp, size: 15).frame(width: 28)
                        }
                    }
                    .foregroundStyle(canSend ? Theme.background : Theme.faint)
                    .frame(height: 28)
                    .background(Capsule().fill(canSend ? Theme.accent : Theme.raised))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressFeedbackButtonStyle())
                .disabled(!canSend)
                .help(isAgentMode ? "Start this as a new agent (Return)" : "Send (Return). Shift-Return adds a line. ⌘Return starts it as a new agent.")
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

    // MARK: Keys

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let isTab = press.key == .tab || press.key == KeyEquivalent("\u{19}")
        if isTab, press.modifiers.contains(.shift) || press.key != .tab {
            model.mode = model.mode.next
            return .handled
        }
        let rows = suggestions
        switch press.key {
        case .return:
            if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                text += "\n"
            } else if press.modifiers.contains(.command) {
                startAgent()
            } else if !rows.isEmpty {
                choose(rows[min(highlighted, rows.count - 1)])
            } else {
                submit()
            }
            return .handled
        case .tab:
            guard !rows.isEmpty else { return .ignored }
            text = rows[min(highlighted, rows.count - 1)].completion
            return .handled
        case .upArrow:
            if !rows.isEmpty {
                highlighted = (min(highlighted, rows.count - 1) + rows.count - 1) % rows.count
                return .handled
            }
            return stepHistory(by: 1)
        case .downArrow:
            if !rows.isEmpty {
                highlighted = (min(highlighted, rows.count - 1) + 1) % rows.count
                return .handled
            }
            return stepHistory(by: -1)
        case .escape:
            guard !rows.isEmpty else { return .ignored }
            isMenuDismissed = true
            return .handled
        default:
            return .ignored
        }
    }

    /// ↑ and ↓ walk through what was sent, as in a shell, but only when they wouldn't move the cursor.
    private func stepHistory(by offset: Int) -> KeyPress.Result {
        let prompts = sentPrompts
        guard !prompts.isEmpty, text.isEmpty || historyIndex != nil else { return .ignored }
        let next = (historyIndex ?? -1) + offset
        if next < 0 {
            historyIndex = nil
            text = ""
        } else if next < prompts.count {
            historyIndex = next
            text = prompts[prompts.count - 1 - next]
        }
        return .handled
    }

    private func choose(_ suggestion: ClaudeSuggestion) {
        switch suggestion.action {
        case let .insert(new): text = new
        case let .run(command):
            model.send(command)
            text = ""
        }
        isFocused = true
    }

    private func prepareMenu(for text: String) {
        if text.hasPrefix("/resume ") { model.loadRecentSessions() }
        if projectFiles.isEmpty, text.split(whereSeparator: \.isWhitespace).last?.hasPrefix("@") == true {
            let root = URL(fileURLWithPath: model.folder)
            Task { projectFiles = await ExplorerModel.projectFiles(root) }
        }
    }

    // MARK: Controls

    private var modeMenu: some View {
        Menu {
            ForEach(ClaudeChatModel.Mode.allCases) { mode in
                Button { model.mode = mode } label: {
                    if mode == model.mode { Image(systemName: "checkmark") }
                    Text(mode.title)
                    Text(mode.summary)
                }
            }
        } label: {
            HStack(spacing: 5) {
                IconView(Self.icon(model.mode), size: 12)
                Text(model.mode.title).font(.vibex(size: 11.5, weight: model.mode == .ask ? .regular : .medium))
            }
            .foregroundStyle(Self.tint(model.mode))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(model.mode == .ask ? .clear : Self.tint(model.mode).opacity(0.14)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(model.mode.summary). ⇧⇥ changes the mode.")
    }

    private static func icon(_ mode: ClaudeChatModel.Mode) -> Icon {
        switch mode {
        case .ask: .lock
        case .acceptEdits: .fileCode
        case .plan: .book
        case .auto: .zap
        }
    }

    private static func tint(_ mode: ClaudeChatModel.Mode) -> Color {
        switch mode {
        case .ask: Theme.muted
        case .acceptEdits: Theme.accent
        case .plan: Theme.violet
        case .auto: Theme.green
        }
    }

    private var modelMenu: some View {
        let models = model.capabilities.models
        let current = models.filter { !$0.isOlderVersion }
        let older = models.filter(\.isOlderVersion)
        let efforts = models.first { $0.value == (model.model.isEmpty ? "default" : model.model) }?.effortLevels ?? []
        return Menu {
            if models.isEmpty { Text("Loading models…") }
            ForEach(current) { option in modelButton(option) }
            if !older.isEmpty {
                Menu("Older Versions") {
                    ForEach(older) { option in modelButton(option) }
                }
            }
            if !efforts.isEmpty {
                Divider()
                Menu("Effort") {
                    ForEach(efforts, id: \.self) { level in
                        Button(level.capitalized) { model.send("/effort \(level)") }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                IconView(.cpu, size: 12)
                Text(model.modelTitle).font(.vibex(size: 11.5))
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
        .help("Model")
    }

    private func modelButton(_ option: ClaudeModelOption) -> some View {
        let isCurrent = option.value == (model.model.isEmpty ? "default" : model.model)
        return Button { model.model = option.value == "default" ? "" : option.value } label: {
            if isCurrent { Image(systemName: "checkmark") }
            Text(option.title)
            Text(option.summary)
        }
    }

    /// Stays out of the way until the conversation is filling up, then offers the fix.
    @ViewBuilder
    private var contextMeter: some View {
        if let percent = model.contextPercent, percent >= 50 {
            Button { model.send("/compact") } label: {
                Text("\(percent)% full")
                    .font(.vibex(size: 11, weight: .medium))
                    .foregroundStyle(percent >= 80 ? Theme.orange : Theme.muted)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("The conversation is \(percent)% of what Claude can hold. Click to compact it.")
            .disabled(model.isBusy)
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

    private var isAgentMode: Bool { agents?.model.isComposing == true }

    /// Sits right by Send, because whether this runs here or as its own agent is decided while writing it.
    @ViewBuilder
    private var agentToggle: some View {
        if let agents {
            let isAvailable = agents.model.state == .ready
            Button { agents.model.isComposing.toggle() } label: {
                HStack(spacing: 5) {
                    IconView(.branch, size: 12)
                    Text("Agent").font(.vibex(size: 11.5, weight: isAgentMode ? .medium : .regular))
                }
                .foregroundStyle(isAgentMode ? Theme.accent : Theme.muted)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Capsule().fill(isAgentMode ? Theme.accent.opacity(0.14) : .clear))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .opacity(isAvailable ? 1 : 0.5)
            .help(isAvailable
                ? "Run this message as a parallel agent, on its own branch and in its own chat (⌘Return)"
                : "Agents need a Git repository. Initialize one in Source Control.")
        }
    }

    private func startAgent() {
        guard canSend, let agents, agents.model.state == .ready, agents.model.busy == nil else { return }
        let task = text.trimmingCharacters(in: .whitespacesAndNewlines)
        agents.actions.create(AgentsModel.slug(task.isEmpty ? "agent" : task), task, model.attachments)
        model.attachments = []
        agents.model.isComposing = false
        text = ""
        historyIndex = nil
    }

    private func submit() {
        guard canSend else { return }
        if isAgentMode {
            startAgent()
            return
        }
        model.send(text)
        text = ""
        historyIndex = nil
    }
}

/// Commands, models, conversations or files, depending on what's being typed.
private struct ClaudeSuggestionMenu: View {
    let suggestions: [ClaudeSuggestion]
    let highlighted: Int
    let hover: (Int) -> Void
    let choose: (ClaudeSuggestion) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        Button { choose(suggestion) } label: {
                            HStack(spacing: 10) {
                                Text(suggestion.title)
                                    .font(suggestion.isCode ? .vibexCode(size: 12) : .vibex(size: 12.5))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                    .layoutPriority(1)
                                Text(suggestion.detail)
                                    .font(.vibex(size: 11.5))
                                    .foregroundStyle(Theme.faint)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(index == highlighted ? Color.white.opacity(0.07) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(suggestion.id)
                        .onContinuousHover { phase in if case .active = phase { hover(index) } }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: min(CGFloat(suggestions.count) * 28 + 8, 232))
            .onChange(of: highlighted) { _, index in
                if suggestions.indices.contains(index) { proxy.scrollTo(suggestions[index].id) }
            }
        }
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
                .help("Edits go ahead; commands still ask")
                Button("Build on Auto") {
                    model.mode = .auto
                    model.allow(request)
                }
                .help("Claude works on its own and stops only for risky actions")
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
