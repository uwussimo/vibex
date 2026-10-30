import SwiftUI

/// What the window does for the Agents sidebar: chat tabs, Source Control, confirmations.
struct AgentActions {
    /// Creates an agent and opens its Claude chat, starting on the task when there is one.
    var create: (_ name: String, _ task: String?) -> Void
    var open: (AgentsModel.Agent) -> Void
    var review: (AgentsModel.Agent) -> Void
    var merge: (AgentsModel.Agent) -> Void
    var remove: (AgentsModel.Agent) -> Void
    var reveal: (AgentsModel.Agent) -> Void
    /// What the agent's Claude is waiting for, if anything.
    var waiting: (AgentsModel.Agent) -> String?
    /// Whether the agent has a tab open.
    var isOpen: (AgentsModel.Agent) -> Bool
    /// Whether the agent's Claude is in the middle of a turn.
    var isWorking: (AgentsModel.Agent) -> Bool
}

/// The Agents sidebar: parallel Claude Code attempts, each on its own branch and worktree.
struct AgentsSidebar: View {
    @Bindable var model: AgentsModel
    let attention: AttentionCenter
    let actions: AgentActions

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.isComposing { NewAgentForm(model: model, create: create, cancel: { model.isComposing = false }) }
                    if let problem = model.problem { message(problem.message, icon: .alert, tint: Theme.red) { model.problem = nil } }
                    if case let .merged(name, base) = model.notice {
                        mergedNotice(name: name, base: base)
                    }
                    content
                }
                .padding(12)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: model.refresh)
        .task {
            // Agents work in their own tabs; keep their numbers fresh while the panel is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                model.refresh()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 1), value: model.agents)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: model.isComposing)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Agents")
                .font(.vibex(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted)
            if let busy = model.busy {
                ProgressView().controlSize(.mini)
                Text(busy).font(.vibex(size: 11)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            Spacer()
            if model.state == .ready {
                ToolbarIconButton(icon: .plus, help: "New Agent (⌥⌘N)", isEnabled: model.busy == nil) { model.isComposing = true }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 38)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 30)
        case .notRepository:
            emptyState(
                title: "Agents need Git",
                detail: "Each agent works on its own branch. Initialize a repository in Source Control first.",
                button: nil
            )
        case .ready where model.agents.isEmpty && !model.isComposing:
            emptyState(
                title: "Run Claude in parallel",
                detail: "Each agent gets its own branch and folder, so attempts never collide. Compare them in Source Control and merge the best one.",
                button: "New Agent"
            )
        case .ready:
            ForEach(model.agents) { agent in
                AgentCard(agent: agent, base: model.baseBranch, waiting: actions.waiting(agent), isOpen: actions.isOpen(agent), isBusy: model.busy != nil, actions: actions)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func create(name: String, task: String?) {
        model.isComposing = false
        actions.create(name, task)
    }

    private func emptyState(title: String, detail: String, button: String?) -> some View {
        VStack(spacing: 10) {
            IconView(.users, size: 28).foregroundStyle(Theme.faint)
            Text(title).font(.vibex(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text)
            Text(detail)
                .font(.vibex(size: 12))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let button {
                Button { model.isComposing = true } label: {
                    Text(button).font(.vibex(size: 12.5, weight: .medium)).frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 8)
    }

    private func mergedNotice(name: String, base: String) -> some View {
        HStack(spacing: 8) {
            IconView(.merge, size: 15).foregroundStyle(Theme.green)
            Text("Merged \(name) into \(base)").font(.vibex(size: 12)).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
            if let agent = model.agents.first(where: { $0.name == name }) {
                Button("Remove Agent") { actions.remove(agent) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            DismissButton { model.notice = nil }
        }
        .padding(.leading, 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.green.opacity(0.1)))
    }

    private func message(_ text: String, icon: Icon, tint: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            IconView(icon, size: 14).foregroundStyle(tint).padding(.top, 5)
            Text(text).font(.vibex(size: 12)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            DismissButton(action: dismiss)
        }
        .padding(.leading, 10)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.1)))
    }
}

private struct DismissButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            IconView(.close, size: 11).foregroundStyle(Theme.muted).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .help("Dismiss")
    }
}

/// The inline form for a new agent: the task first (it names the agent), the name editable after.
private struct NewAgentForm: View {
    let model: AgentsModel
    let create: (String, String?) -> Void
    let cancel: () -> Void
    @State private var task = ""
    @State private var name = ""
    @State private var nameEdited = false
    @FocusState private var taskFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New agent").font(.vibex(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            TextField("What should Claude do? (optional)", text: $task, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.vibex(size: 12.5))
                .lineLimit(2...6)
                .focused($taskFocused)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(taskFocused ? Theme.accent.opacity(0.7) : Theme.line))
                .onChange(of: task) { _, text in if !nameEdited { name = text.isEmpty ? "" : AgentsModel.slug(text) } }
            HStack(spacing: 6) {
                IconView(.branch, size: 13).foregroundStyle(Theme.faint)
                Text(AgentsModel.branchPrefix).font(.vibexCode(size: 11.5)).foregroundStyle(Theme.faint)
                TextField("name", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
                    .textFieldStyle(.plain)
                    .font(.vibexCode(size: 11.5))
            }
            Text("Starts from \(model.baseBranch ?? "the current branch")'s last commit, in its own folder.")
                .font(.vibex(size: 11))
                .foregroundStyle(Theme.faint)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(.bordered).controlSize(.regular)
                Button {
                    create(name.isEmpty ? (task.isEmpty ? "agent" : task) : name, task.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    Text(task.isEmpty ? "Create" : "Create and Start").font(.vibex(size: 12.5, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy != nil)
            }
        }
        .padding(12)
        .card(fill: Theme.card, radius: 12)
        .onAppear { taskFocused = true }
        .onExitCommand(perform: cancel)
    }
}

private struct AgentCard: View {
    let agent: AgentsModel.Agent
    let base: String?
    let waiting: String?
    let isOpen: Bool
    let isBusy: Bool
    let actions: AgentActions
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(agent.name).font(.vibex(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 4)
                Menu {
                    Button("Open Chat") { actions.open(agent) }
                    Button("Show in Finder") { actions.reveal(agent) }
                    Divider()
                    Button("Remove Agent…", role: .destructive) { actions.remove(agent) }
                } label: {
                    IconView(.dots, size: 15).foregroundStyle(Theme.muted).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
            if let task = agent.task {
                Text(task).font(.vibex(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            if let waiting {
                HStack(spacing: 6) {
                    IconView(.bellRinging, size: 12)
                    Text(waiting).lineLimit(1)
                }
                .font(.vibex(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Theme.orange.opacity(0.12)))
                .onTapGesture { actions.open(agent) }
            }
            if waiting == nil, actions.isWorking(agent) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Working…").font(.vibex(size: 11.5)).foregroundStyle(Theme.muted)
                }
            }
            stats
            HStack(spacing: 6) {
                Button { actions.review(agent) } label: {
                    Text("Review").font(.vibex(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .disabled(agent.stats.isEmpty)
                .help("Show this agent's changes in Source Control")
                Button { actions.merge(agent) } label: {
                    Text("Merge").font(.vibex(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .disabled(agent.stats.isEmpty || isBusy)
                .help("Commit what's left and merge \(agent.branch) into \(base ?? "the base branch")")
                Spacer()
                ToolbarIconButton(icon: .message, help: isOpen ? "Show Chat" : "Open Chat") { actions.open(agent) }
            }
        }
        .padding(12)
        .card(fill: isHovering ? Theme.raised : Theme.card, radius: 12)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var stats: some View {
        HStack(spacing: 10) {
            if agent.stats.isEmpty {
                Text("No changes yet").foregroundStyle(Theme.faint)
            } else {
                if agent.stats.insertions > 0 { Text("+\(agent.stats.insertions)").foregroundStyle(Theme.green) }
                if agent.stats.deletions > 0 { Text("−\(agent.stats.deletions)").foregroundStyle(Theme.red) }
                Text("\(agent.stats.files) file\(agent.stats.files == 1 ? "" : "s")").foregroundStyle(Theme.muted)
                if agent.stats.commits > 0 { Text("\(agent.stats.commits) commit\(agent.stats.commits == 1 ? "" : "s")").foregroundStyle(Theme.muted) }
            }
        }
        .font(.vibex(size: 11.5, weight: .medium))
        .monospacedDigit()
    }

    private var statusColor: Color {
        if waiting != nil { return Theme.orange }
        return isOpen ? Theme.green : Theme.faint
    }
}
