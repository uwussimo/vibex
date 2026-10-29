import AppKit
import SwiftUI

/// The Skills sidebar: what Claude Code loads for this project and everywhere, with Remove (undoable)
/// and a way into the skills.sh marketplace.
struct SkillsSidebar: View {
    let model: SkillsModel
    let browse: () -> Void
    /// Opens the skill's SKILL.md, rendered, in an editor tab.
    let view: (InstalledSkill) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let removed = model.removed {
                        removedNotice(removed.skill)
                    }
                    if let problem = model.problem {
                        Text(problem)
                            .font(.vibex(size: 12))
                            .foregroundStyle(Color(nsColor: .systemRed))
                            .padding(.horizontal, 14)
                    }
                    section(
                        "This Project",
                        detail: "Loaded only in \(model.projectName). Commit them to share with your team.",
                        skills: model.project
                    )
                    section(
                        "Global",
                        detail: "Loaded in every project.",
                        skills: model.global
                    )
                }
                .padding(.vertical, 10)
            }
            .scrollIndicators(.automatic)
            Divider()
            Button(action: browse) {
                Label("Browse skills.sh", systemImage: "sparkle.magnifyingglass")
                    .font(.vibex(size: 12.5, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: model.refresh)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: model.global)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: model.project)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Skills")
                .font(.vibex(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            ToolbarIconButton(icon: .refresh, help: "Refresh", action: model.refresh)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 38)
    }

    private func section(_ title: String, detail: String, skills: [InstalledSkill]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.vibex(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(skills.count)")
                    .font(.vibex(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            .padding(.horizontal, 14)
            if skills.isEmpty {
                Text(detail + " None yet.")
                    .font(.vibex(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            } else {
                ForEach(skills) { skill in
                    SkillRow(
                        skill: skill,
                        view: { view(skill) },
                        open: { model.open(skill) },
                        reveal: { model.reveal(skill) },
                        remove: { model.remove(skill) }
                    )
                }
            }
        }
    }

    private func removedNotice(_ skill: InstalledSkill) -> some View {
        HStack(spacing: 8) {
            IconView(.trash, size: 15)
                .foregroundStyle(.secondary)
            Text("Removed “\(skill.name)”")
                .font(.vibex(size: 12))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: model.undoRemove) {
                Text("Undo").font(.vibex(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(action: model.dismissRemoved) {
                IconView(.close, size: 10.5)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressFeedbackButtonStyle())
            .help("Dismiss")
        }
        .padding(.leading, 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 12)
    }
}

private struct SkillRow: View {
    let skill: InstalledSkill
    let view: () -> Void
    let open: () -> Void
    let reveal: () -> Void
    let remove: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            IconView(.sparkles, size: 14)
                .foregroundStyle(AgentColors.claude)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.vibex(size: 12.5, weight: .medium))
                    .lineLimit(1)
                if !skill.summary.isEmpty {
                    Text(skill.summary)
                        .font(.vibex(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isHovering {
                HStack(spacing: 0) {
                    RowIconButton(icon: .eye, help: "Read SKILL.md", action: view)
                    RowIconButton(icon: .trash, help: "Remove (Undo is available)", action: remove)
                }
                .transition(.opacity)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.05 : 0))
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: view)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering } }
        .contextMenu {
            Button("Read SKILL.md", action: view)
            Button("Open in Default App", action: open)
            Button("Show in Finder", action: reveal)
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(skill.folder.path, forType: .string)
            }
            Divider()
            Button("Remove", action: remove)
        }
        .help(skill.source.map { "From \($0) · \(skill.folder.path)" } ?? skill.folder.path)
    }
}

/// A 24pt icon button that shows its hover state, for actions inside list rows.
struct RowIconButton: View {
    let icon: Icon
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            IconView(icon, size: 12.5)
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
