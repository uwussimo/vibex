import SwiftUI

/// skills.sh inside Vibex: the most-installed skills, or search results, each one click from
/// installing globally or for this project.
struct SkillsMarketplaceView: View {
    let model: SkillsModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Skills")
                        .font(.vibex(size: 20, weight: .semibold))
                    Text("from skills.sh")
                        .font(.vibex(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link(destination: URL(string: "https://skills.sh")!) {
                        Label("Open skills.sh", systemImage: "arrow.up.right")
                            .font(.vibex(size: 12, weight: .medium))
                    }
                }
                searchField
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            Divider()
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear {
            model.loadMarketplace()
            model.refresh()
            searchFocused = true
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Search skills, e.g. swiftui, react, testing", text: Binding(get: { model.query }, set: { model.query = $0 }))
                .textFieldStyle(.plain)
                .font(.vibex(size: 13.5))
                .focused($searchFocused)
            if model.isSearching {
                ProgressView().controlSize(.small)
            } else if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(searchFocused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5)
        )
    }

    @ViewBuilder
    private var list: some View {
        if let problem = model.problem, model.results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
                Text(problem).font(.vibex(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { model.loadMarketplace() }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.results.isEmpty, !model.isSearching {
            Text(model.query.count < 2 ? "Loading skills…" : "No skills match “\(model.query)”.")
                .font(.vibex(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(model.query.count < 2 ? "Most installed" : "Results")
                        .font(.vibex(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                    if let problem = model.problem {
                        Text(problem)
                            .font(.vibex(size: 12))
                            .foregroundStyle(Color(nsColor: .systemRed))
                            .padding(.horizontal, 20)
                            .padding(.bottom, 6)
                    }
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, skill in
                        MarketplaceRow(
                            rank: model.query.count < 2 ? index + 1 : nil,
                            skill: skill,
                            installed: model.scopes(of: skill),
                            isInstalling: model.isInstalling(skill),
                            projectName: model.projectName,
                            install: { model.install(skill, scope: $0) }
                        )
                        Divider().padding(.leading, 20)
                    }
                }
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
        }
    }
}

private struct MarketplaceRow: View {
    let rank: Int?
    let skill: MarketplaceSkill
    let installed: Set<InstalledSkill.Scope>
    let isInstalling: Bool
    let projectName: String
    let install: (InstalledSkill.Scope) -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            if let rank {
                Text("\(rank)")
                    .font(.vibex(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .frame(width: 26, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.vibex(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(skill.source)
                    Text("·")
                    Text("\(skill.installs.formatted(.number.notation(.compactName))) installs")
                }
                .font(.vibex(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Link(destination: skill.page) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .help("View on skills.sh")
            .opacity(isHovering ? 1 : 0.5)
            action
                .frame(minWidth: 116, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(isHovering ? 0.03 : 0))
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var action: some View {
        if isInstalling {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing…").font(.vibex(size: 12)).foregroundStyle(.secondary)
            }
        } else if installed.count == 2 {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.vibex(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: .systemGreen))
        } else {
            HStack(spacing: 8) {
                if let scope = installed.first {
                    Label(scope == .global ? "Global" : "Project", systemImage: "checkmark.circle.fill")
                        .font(.vibex(size: 11.5, weight: .medium))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                        .help(scope == .global ? "Installed for every project" : "Installed for \(projectName)")
                }
                // Click installs for every project; the arrow offers this project only.
                Menu {
                    if !installed.contains(.global) {
                        Button("Install for All Projects") { install(.global) }
                    }
                    if !installed.contains(.project) {
                        Button("Install for \(projectName) Only") { install(.project) }
                    }
                } label: {
                    Text(installed.isEmpty ? "Install" : "Add").font(.vibex(size: 12.5, weight: .medium))
                } primaryAction: {
                    install(installed.contains(.global) ? .project : .global)
                }
                .menuStyle(.borderedButton)
                .controlSize(.regular)
                .fixedSize()
                .help(installed.contains(.global) ? "Install for \(projectName)" : "Install for all projects (the arrow has more options)")
            }
        }
    }
}
