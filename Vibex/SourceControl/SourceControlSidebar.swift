import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Source Control sidebar: branch, commit box, and the changed files grouped the way VS Code
/// groups them (merge conflicts, staged, changes). Selecting a file opens its diff beside the terminal.
struct SourceControlSidebar: View {
    @Bindable var model: SourceControlModel
    let window: () -> NSWindow?

    @State private var collapsed: Set<GitChange.Area> = []
    @FocusState private var messageFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            switch model.state {
            case .loading:
                placeholder { ProgressView().controlSize(.small) }
            case .notRepository:
                notRepository
            case let .failed(message):
                placeholder {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.vibex(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            case .ready:
                commitBox
                changeList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: model.status)
        .animation(.spring(response: 0.25, dampingFraction: 1), value: model.busy)
        .animation(.spring(response: 0.25, dampingFraction: 1), value: model.notice)
        .animation(.spring(response: 0.25, dampingFraction: 1), value: model.problem)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Source Control")
                .font(.vibex(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if model.state == .ready {
                ToolbarIconButton(systemImage: "arrow.clockwise", help: "Refresh") { model.refresh() }
                Menu {
                    Button("Stage All Changes") { model.stageAll() }
                        .disabled(model.status.unstaged.isEmpty && model.status.conflicted.isEmpty)
                    Button("Unstage All Changes") { model.unstageAll() }
                        .disabled(model.status.staged.isEmpty)
                    Button("Discard All Changes…") { model.discard(model.status.unstaged, in: window()) }
                        .disabled(model.status.unstaged.isEmpty)
                    Divider()
                    if model.status.upstream != nil {
                        Button("Pull") { model.pull() }
                        Button("Push") { model.push() }
                    } else if model.canPublish {
                        Button("Publish Branch") { model.publish() }
                    } else {
                        Button("No Remote to Push To") {}.disabled(true)
                    }
                    Divider()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.folder]) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More Actions")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 38)
    }

    // MARK: - Commit

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            branchRow
            TextField(commitPlaceholder, text: $model.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.vibex(size: 12.5))
                .lineLimit(1...6)
                .focused($messageFocused)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(messageFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: messageFocused ? 1.5 : 1)
                )
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    model.commit()
                    return .handled
                }
            Button(action: model.commit) {
                HStack(spacing: 6) {
                    if model.busy == "Committing…" {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                    }
                    Text(commitTitle)
                        .font(.vibex(size: 12.5, weight: .medium))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!model.canCommit)

            if let busy = model.busy, busy != "Committing…" {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(busy).font(.vibex(size: 11.5)).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
            if let problem = model.problem {
                ProblemRow(problem: problem, fix: model.fix, dismiss: { model.problem = nil })
                    .transition(.opacity)
            } else if let notice = model.notice {
                NoticeRow(notice: notice, model: model)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var branchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(model.branchLabel)
                .font(.vibex(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if model.status.behind > 0 {
                SyncChip(symbol: "arrow.down", count: model.status.behind, help: "Pull \(model.status.behind) from \(model.status.upstream ?? "upstream")") { model.pull() }
            }
            if model.status.ahead > 0 {
                SyncChip(symbol: "arrow.up", count: model.status.ahead, help: "Push \(model.status.ahead) to \(model.status.upstream ?? "upstream")") { model.push() }
            }
            // While the commit notice offers Publish, one button for it is enough.
            if model.canPublish, !isCommitNotice {
                SyncChip(symbol: "icloud.and.arrow.up", label: "Publish", help: "Push \(model.branchLabel) to the remote and track it") { model.publish() }
            }
        }
    }

    private var isCommitNotice: Bool {
        if case .committed = model.notice { return true }
        return false
    }

    private var commitPlaceholder: String {
        "Message (⌘↩ to commit on \(model.branchLabel))"
    }

    private var commitTitle: String {
        if model.status.staged.isEmpty, !model.status.isClean { return "Commit All" }
        return "Commit"
    }

    // MARK: - Changes

    @ViewBuilder
    private var changeList: some View {
        Divider()
        if model.status.isClean {
            placeholder {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No changes")
                        .font(.vibex(size: 12.5, weight: .medium))
                    Text("The working tree matches \(model.branchLabel).")
                        .font(.vibex(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    group(.conflicted, title: "Merge Changes", changes: model.status.conflicted)
                    group(.staged, title: "Staged Changes", changes: model.status.staged)
                    group(.unstaged, title: "Changes", changes: model.status.unstaged)
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
        }
    }

    @ViewBuilder
    private func group(_ area: GitChange.Area, title: String, changes: [GitChange]) -> some View {
        if !changes.isEmpty {
            Section {
                if !collapsed.contains(area) {
                    ForEach(changes) { change in
                        ChangeRow(
                            change: change,
                            isSelected: model.selection?.id == change.id,
                            select: { model.select(change) },
                            stage: { model.stage([change]) },
                            unstage: { model.unstage([change]) },
                            discard: { model.discard([change], in: window()) },
                            open: { NSWorkspace.shared.open(model.folder.appendingPathComponent(change.path)) },
                            reveal: { NSWorkspace.shared.activateFileViewerSelecting([model.folder.appendingPathComponent(change.path)]) }
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            } header: {
                GroupHeader(
                    title: title,
                    count: changes.count,
                    isCollapsed: collapsed.contains(area),
                    toggle: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
                            if collapsed.contains(area) { collapsed.remove(area) } else { collapsed.insert(area) }
                        }
                    },
                    actions: groupActions(area, changes)
                )
            }
        }
    }

    private func groupActions(_ area: GitChange.Area, _ changes: [GitChange]) -> [RowAction] {
        switch area {
        case .staged:
            [RowAction(symbol: "minus", help: "Unstage All") { model.unstage(changes) }]
        case .unstaged:
            [
                RowAction(symbol: "arrow.uturn.backward", help: "Discard All…") { model.discard(changes, in: window()) },
                RowAction(symbol: "plus", help: "Stage All") { model.stage(changes) },
            ]
        case .conflicted:
            [RowAction(symbol: "plus", help: "Mark All Resolved") { model.stage(changes) }]
        }
    }

    // MARK: - Empty states

    private var notRepository: some View {
        placeholder {
            VStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Not a Git repository")
                    .font(.vibex(size: 13, weight: .medium))
                Text("Start tracking changes in this folder.")
                    .font(.vibex(size: 11.5))
                    .foregroundStyle(.secondary)
                Button {
                    model.initializeRepository()
                } label: {
                    Text("Initialize Repository").font(.vibex(size: 12.5, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy != nil)
            }
        }
    }

    private func placeholder(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Rows

struct RowAction: Identifiable {
    let symbol: String
    let help: String
    let action: () -> Void
    var id: String { symbol }
}

private struct GroupHeader: View {
    let title: String
    let count: Int
    let isCollapsed: Bool
    let toggle: () -> Void
    let actions: [RowAction]
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .frame(width: 14)
            Text(title)
                .font(.vibex(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if isHovering {
                ForEach(actions) { action in
                    HoverIconButton(symbol: action.symbol, help: action.help, action: action.action)
                }
                .transition(.opacity)
            }
            Text("\(count)")
                .font(.vibex(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .contentTransition(.numericText())
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: 28)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering } }
    }
}

private struct ChangeRow: View {
    let change: GitChange
    let isSelected: Bool
    let select: () -> Void
    let stage: () -> Void
    let unstage: () -> Void
    let discard: () -> Void
    let open: () -> Void
    let reveal: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: Self.icon(for: change.path))
                .resizable()
                .frame(width: 16, height: 16)
            HStack(spacing: 5) {
                Text(change.fileName)
                    .font(.vibex(size: 12.5))
                    .strikethrough(change.kind == .deleted, color: .secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !change.directory.isEmpty {
                    Text(change.directory)
                        .font(.vibex(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            // The selected row keeps its actions, so they don't depend on where the pointer is.
            if isHovering || isSelected {
                HStack(spacing: 0) {
                    HoverIconButton(symbol: "doc.text", help: "Open File", action: open)
                    switch change.area {
                    case .unstaged:
                        HoverIconButton(symbol: "arrow.uturn.backward", help: change.kind == .untracked ? "Delete File…" : "Discard Changes…", action: discard)
                        HoverIconButton(symbol: "plus", help: "Stage Changes", action: stage)
                    case .staged:
                        HoverIconButton(symbol: "minus", help: "Unstage Changes", action: unstage)
                    case .conflicted:
                        HoverIconButton(symbol: "plus", help: "Mark Resolved", action: stage)
                    }
                }
                .transition(.opacity)
            }
            Text(change.kind.letter)
                .font(.vibexCode(size: 11.5, weight: .semibold))
                .foregroundStyle(change.kind.color)
                .frame(width: 12)
                .help(change.kind.label)
        }
        .padding(.leading, 22)
        .padding(.trailing, 12)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : (isHovering ? Color.primary.opacity(0.06) : .clear))
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering } }
        .contextMenu {
            Button("Open Changes", action: select)
            Button("Open File", action: open)
            Button("Show in Finder", action: reveal)
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(change.path, forType: .string)
            }
            Divider()
            switch change.area {
            case .unstaged:
                Button("Stage Changes", action: stage)
                Button(change.kind == .untracked ? "Delete File…" : "Discard Changes…", action: discard)
            case .staged:
                Button("Unstage Changes", action: unstage)
            case .conflicted:
                Button("Mark Resolved", action: stage)
            }
        }
        .help(change.originalPath.map { "\($0) → \(change.path)" } ?? change.path)
    }

    private static func icon(for path: String) -> NSImage {
        let ext = (path as NSString).pathExtension
        return NSWorkspace.shared.icon(for: ext.isEmpty ? .data : (UTType(filenameExtension: ext) ?? .data))
    }
}

private struct HoverIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .help(help)
        .onHover { isHovering = $0 }
    }
}

private struct SyncChip: View {
    let symbol: String
    let label: String
    let help: String
    let action: () -> Void

    init(symbol: String, count: Int, help: String, action: @escaping () -> Void) {
        self.init(symbol: symbol, label: "\(count)", help: help, action: action)
    }

    init(symbol: String, label: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                Text(label).font(.vibex(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .help(help)
    }
}

/// What just happened, with the next step: Push after a commit, Undo after a discard.
private struct NoticeRow: View {
    let notice: SourceControlModel.Notice
    let model: SourceControlModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            text
                .font(.vibex(size: 12))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            action
            Button(action: model.dismissNotice) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressFeedbackButtonStyle())
            .help("Dismiss")
        }
        .padding(.leading, 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.1)))
    }

    private var symbol: String {
        switch notice {
        case .committed: "checkmark.circle.fill"
        case .pushed: "arrow.up.circle.fill"
        case .discarded: "arrow.uturn.backward.circle.fill"
        }
    }

    private var tint: Color {
        switch notice {
        case .committed, .pushed: Color(nsColor: .systemGreen)
        case .discarded: .secondary
        }
    }

    private var text: Text {
        switch notice {
        case let .committed(hash, branch):
            hash.isEmpty ? Text("Committed to \(branch)") : Text("Committed \(Text(hash).font(.vibexCode(size: 11.5, weight: .semibold))) to \(branch)")
        case let .pushed(destination):
            Text("Pushed to \(destination)")
        case let .discarded(summary):
            Text(summary)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch notice {
        case .committed where model.canPublish:
            noticeButton("Publish", prominent: true, action: model.publish)
        case .committed where model.hasPushWork:
            noticeButton("Push", prominent: true, action: model.push)
        case .discarded where model.canUndoDiscard:
            noticeButton("Undo", prominent: false, action: model.undoDiscard)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func noticeButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        let label = Text(title).font(.vibex(size: 12, weight: .medium))
        if prominent {
            Button(action: action) { label }.buttonStyle(.borderedProminent).controlSize(.small).disabled(model.busy != nil)
        } else {
            Button(action: action) { label }.buttonStyle(.bordered).controlSize(.small).disabled(model.busy != nil)
        }
    }
}

/// A git failure in plain words, the button that usually fixes it, and git's own text on hover.
private struct ProblemRow: View {
    let problem: GitProblem
    let fix: (GitProblem.Fix) -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemRed))
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 6) {
                Text(problem.message)
                    .font(.vibex(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(problem.detail ?? problem.message)
                if let action = problem.fix {
                    Button {
                        fix(action)
                    } label: {
                        Text(action == .pull ? "Pull" : "Publish Branch").font(.vibex(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressFeedbackButtonStyle())
            .help("Dismiss")
        }
        .padding(.leading, 10)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .systemRed).opacity(0.1)))
    }
}

extension GitChange.Kind {
    var color: Color {
        switch self {
        case .modified, .typeChanged: Color(nsColor: .systemOrange)
        case .added, .untracked, .copied: Color(nsColor: .systemGreen)
        case .deleted, .conflicted: Color(nsColor: .systemRed)
        case .renamed: Color(nsColor: .systemBlue)
        }
    }
}
