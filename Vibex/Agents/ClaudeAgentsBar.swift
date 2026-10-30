import SwiftUI

/// What the window does for agents: chat tabs, Source Control, confirmations.
struct AgentActions {
    /// Creates an agent and opens its Claude chat, starting on the task when there is one.
    var create: (_ name: String, _ task: String?, _ attachments: [ClaudeAttachment]) -> Void
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

/// Agents and what's done to them, for a Claude chat to show.
struct ClaudeAgentsContext {
    let model: AgentsModel
    let actions: AgentActions
}

/// Agents live inside Claude, because an agent is a Claude chat on its own branch. This strip tops
/// each chat once there are any: one pill per agent to jump between them, with Review and Merge right
/// there in the agent's own chat. It takes no room until the first agent exists.
struct ClaudeAgentsBar: View {
    @Bindable var model: AgentsModel
    let actions: AgentActions
    /// The folder of the chat this strip is in, to mark its agent.
    let folder: String
    @State private var isExpanded = false

    private var current: AgentsModel.Agent? {
        model.agents.first { $0.path.standardizedFileURL.path == URL(fileURLWithPath: folder).standardizedFileURL.path }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.agents.isEmpty || model.busy != nil {
                strip
                if isExpanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.agents) { agent in
                                AgentCard(agent: agent, base: model.baseBranch, waiting: actions.waiting(agent), isOpen: actions.isOpen(agent), isBusy: model.busy != nil, actions: actions)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .padding(10)
                    }
                    .frame(maxHeight: 300)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            if let problem = model.problem {
                message(problem.message, icon: .alert, tint: Theme.red) { model.problem = nil }.padding(8)
            }
            if case let .merged(name, base) = model.notice {
                mergedNotice(name: name, base: base).padding(8)
            }
        }
        .background(Theme.surface)
        .onAppear(perform: model.refresh)
        .task {
            // Agents work in their own tabs; keep their numbers fresh while this is showing.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                model.refresh()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 1), value: model.agents)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: isExpanded)
    }

    private var strip: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.agents) { agent in
                        AgentPill(agent: agent, isCurrent: agent.id == current?.id, waiting: actions.waiting(agent), isWorking: actions.isWorking(agent), actions: actions)
                    }
                    if let busy = model.busy {
                        ProgressView().controlSize(.mini)
                        Text(busy).font(.vibex(size: 11)).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                }
                .padding(.leading, 8)
            }
            if let current {
                Button("Review") { actions.review(current) }
                    .disabled(current.stats.isEmpty)
                    .help("Show this agent's changes in Source Control")
                Button("Merge") { actions.merge(current) }
                    .disabled(current.stats.isEmpty || model.busy != nil)
                    .help("Commit what's left and merge \(current.branch) into \(model.baseBranch ?? "the base branch")")
            }
            ToolbarIconButton(icon: isExpanded ? .chevronUp : .chevronDown, help: isExpanded ? "Hide agent details" : "Show agent details") { isExpanded.toggle() }
                .padding(.trailing, 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(height: 36)
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

/// One agent in the strip: how it's doing, and a click away from its chat.
private struct AgentPill: View {
    let agent: AgentsModel.Agent
    let isCurrent: Bool
    let waiting: String?
    let isWorking: Bool
    let actions: AgentActions
    @State private var isHovering = false

    var body: some View {
        Button { actions.open(agent) } label: {
            HStack(spacing: 6) {
                if isWorking, waiting == nil {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 8, height: 8)
                } else {
                    Circle().fill(waiting != nil ? Theme.orange : (actions.isOpen(agent) ? Theme.green : Theme.faint)).frame(width: 7, height: 7)
                }
                Text(agent.name).font(.vibex(size: 11.5, weight: isCurrent ? .semibold : .medium)).foregroundStyle(isCurrent ? Theme.text : Theme.muted).lineLimit(1)
                if agent.stats.insertions > 0 { Text("+\(agent.stats.insertions)").foregroundStyle(Theme.green) }
                if agent.stats.deletions > 0 { Text("−\(agent.stats.deletions)").foregroundStyle(Theme.red) }
            }
            .font(.vibex(size: 10.5, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(isCurrent ? 0.09 : (isHovering ? 0.05 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(waiting ?? agent.task ?? agent.branch)
        .contextMenu {
            Button("Open Chat") { actions.open(agent) }
            Button("Review Changes") { actions.review(agent) }.disabled(agent.stats.isEmpty)
            Button("Merge…") { actions.merge(agent) }.disabled(agent.stats.isEmpty)
            Button("Show in Finder") { actions.reveal(agent) }
            Divider()
            Button("Remove Agent…", role: .destructive) { actions.remove(agent) }
        }
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
