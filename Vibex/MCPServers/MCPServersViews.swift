import SwiftUI

/// The MCP sidebar: the servers Claude Code uses here, for every project and for this one.
struct MCPServersSidebar: View {
    let model: MCPServersModel
    let browse: () -> Void
    /// Opens Claude Code in a terminal tab, where `/mcp` signs in and approves servers.
    let openClaude: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("MCP Servers").font(.vibex(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                Spacer()
                if model.isCheckingHealth { ProgressView().controlSize(.mini).help("Checking which servers connect…") }
                ToolbarIconButton(icon: .refresh, help: "Refresh and check connections", action: model.refresh)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 38)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Button(action: browse) {
                        HStack(spacing: 8) {
                            IconView(.search, size: 14)
                            Text("Browse MCP Servers").font(.vibex(size: 12.5, weight: .medium))
                            Spacer()
                            IconView(.chevronRight, size: 12).foregroundStyle(Theme.faint)
                        }
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .card(fill: Theme.card, radius: 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressFeedbackButtonStyle())
                    if let problem = model.problem {
                        Text(problem).font(.vibex(size: 11.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                    }
                    if let attention = attentionNote {
                        HStack(alignment: .top, spacing: 8) {
                            IconView(.info, size: 13).foregroundStyle(Theme.orange)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(attention).font(.vibex(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                                Button("Open Claude Code", action: openClaude).buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        .padding(10)
                        .card(fill: Theme.card, radius: 10)
                    }
                    section("Every project", servers: model.installed.filter { $0.scope == .user })
                    section("This project", servers: model.installed.filter { $0.scope != .user })
                    if !model.external.isEmpty {
                        section("From plugins and claude.ai", servers: model.external)
                    }
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: model.refresh)
    }

    /// What to do when a server can't start yet: both fixes happen inside Claude Code, in `/mcp`.
    private var attentionNote: String? {
        let states = Set((model.installed + model.external).compactMap { model.health[$0.name] })
        if states.contains(.waitingForApproval), states.contains(.needsSignIn) {
            return "Some servers need you to sign in or approve them. Open Claude Code here and type /mcp."
        }
        if states.contains(.needsSignIn) { return "Some servers need you to sign in. Open Claude Code here and type /mcp." }
        if states.contains(.waitingForApproval) { return "This project's .mcp.json has servers Claude Code hasn't approved yet. Open Claude Code here to approve them." }
        return nil
    }

    @ViewBuilder
    private func section(_ title: String, servers: [InstalledMCPServer]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.vibex(size: 10.5, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.faint)
            if servers.isEmpty {
                Text("None yet").font(.vibex(size: 12)).foregroundStyle(Theme.faint).padding(.vertical, 4)
            }
            ForEach(servers) { server in
                InstalledServerRow(server: server, health: model.health[server.name], remove: { model.remove(server) })
            }
        }
    }
}

private struct InstalledServerRow: View {
    let server: InstalledMCPServer
    let health: MCPHealth?
    let remove: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ServerLogo(name: server.displayName, size: 26)
                .overlay(alignment: .bottomTrailing) {
                    if let health {
                        Circle().fill(color(health)).frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(server.displayName).font(.vibex(size: 12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    if server.scope == .project { chip(".mcp.json") }
                    if server.isVibex { chip("Vibex") }
                    if let origin = server.origin { chip(origin) }
                }
                Text(status ?? server.detail)
                    .font(.vibex(size: 11))
                    .foregroundStyle(status == nil ? Theme.faint : color(health ?? .failed))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 2)
            if isHovering, !server.isVibex, server.origin == nil {
                RowIconButton(icon: .trash, help: "Remove from Claude Code", action: remove)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(isHovering ? 0.05 : 0)))
        .onHover { isHovering = $0 }
        .help(server.isVibex ? "Vibex's own server; it registers itself" : server.detail)
    }

    /// Only said when something is wrong; a working server shows its command or URL.
    private var status: String? {
        switch health {
        case .needsSignIn: "Needs sign-in · /mcp in Claude Code"
        case .waitingForApproval: "Waiting for approval in Claude Code"
        case .failed: "Couldn't connect"
        case .connected, nil: nil
        }
    }

    private func color(_ health: MCPHealth) -> Color {
        switch health {
        case .connected: Theme.green
        case .needsSignIn, .waitingForApproval: Theme.orange
        case .failed: Theme.red
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.vibex(size: 10, weight: .medium)).foregroundStyle(Theme.muted)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Theme.raised))
    }
}

/// A server's logo, or its initial on a tinted tile when there is none.
struct ServerLogo: View {
    let name: String
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let logo = BrandLogo.forServer(name) {
                BrandLogoView(logo, size: size * 0.6)
            } else {
                Text(name.prefix(1).uppercased()).font(.vibex(size: size * 0.45, weight: .semibold)).foregroundStyle(Theme.text)
            }
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Theme.line))
    }
}

/// The marketplace tab: featured servers, and the MCP registry's search.
struct MCPMarketplaceView: View {
    @Bindable var model: MCPServersModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("MCP Servers").font(.vibex(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("tools for Claude Code").font(.vibex(size: 13)).foregroundStyle(Theme.muted)
                    Spacer()
                }
                HStack(spacing: 8) {
                    IconView(.search, size: 14).foregroundStyle(Theme.muted)
                    TextField("Search the MCP registry, e.g. postgres, slack, browser", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.vibex(size: 13.5))
                        .focused($searchFocused)
                    if model.isSearching { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(searchFocused ? Theme.accent.opacity(0.6) : Theme.line))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.query.count < 2 {
                        heading("Featured")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                            ForEach(model.featured) { spec in ServerCard(spec: spec, model: model) }
                        }
                    } else if let problem = model.problem, model.results.isEmpty {
                        VStack(spacing: 10) {
                            IconView(.alert, size: 26).foregroundStyle(Theme.faint)
                            Text(problem).font(.vibex(size: 12.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                            Button("Try Again", action: model.retrySearch).buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 50)
                    } else if model.results.isEmpty, !model.isSearching {
                        Text("No servers match “\(model.query)”.").font(.vibex(size: 12.5)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity).padding(.top, 50)
                    } else {
                        heading("From the MCP registry")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                            ForEach(model.results) { spec in ServerCard(spec: spec, model: model) }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.background)
        .onAppear {
            model.refresh()
            searchFocused = true
        }
        .sheet(isPresented: Binding(get: { model.pendingInstall != nil }, set: { if !$0 { model.pendingInstall = nil } })) {
            if let pending = model.pendingInstall {
                InstallFieldsSheet(spec: pending.spec, scope: pending.scope, model: model)
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased()).font(.vibex(size: 10.5, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.faint)
    }
}

private struct ServerCard: View {
    let spec: MCPServerSpec
    let model: MCPServersModel
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ServerLogo(name: spec.name, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.title).font(.vibex(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(spec.kindLabel + (spec.inputs.contains(where: \.isRequired) ? " · needs a key" : ""))
                        .font(.vibex(size: 11)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Spacer(minLength: 4)
                installStatus
            }
            Text(spec.summary).font(.vibex(size: 12)).foregroundStyle(Theme.muted).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let homepage = spec.homepage {
                Link(destination: homepage) {
                    HStack(spacing: 4) { Text("More info"); IconView(.arrowUpRight, size: 11) }
                        .font(.vibex(size: 11.5, weight: .medium)).foregroundStyle(Theme.accent)
                }
            }
            if model.installedScope(of: spec) == nil { installButtons }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .card(fill: isHovering ? Theme.raised : Theme.card, radius: 14)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    @ViewBuilder
    private var installStatus: some View {
        if model.installing.contains(spec.name) {
            ProgressView().controlSize(.small)
        } else if let scope = model.installedScope(of: spec) {
            HStack(spacing: 4) { IconView(.check, size: 12); Text(scope == .user ? "Global" : "This project") }
                .font(.vibex(size: 11.5, weight: .medium)).foregroundStyle(Theme.green)
        }
    }

    /// Project install uses Claude Code's local scope: this project, on this Mac, ready without an
    /// approval prompt (a shared .mcp.json would wait for one).
    private var installButtons: some View {
        HStack(spacing: 6) {
            Button { model.install(spec, scope: .local) } label: {
                Text("Project install").font(.vibex(size: 12, weight: .medium)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help("Install for this project only")
            Button { model.install(spec, scope: .user) } label: {
                Text("Global install").font(.vibex(size: 12, weight: .medium)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .help("Install for every project")
        }
        .controlSize(.small)
        .disabled(model.installing.contains(spec.name))
    }
}

/// API keys and tokens a server needs before it can start.
private struct InstallFieldsSheet: View {
    let spec: MCPServerSpec
    let scope: InstalledMCPServer.Scope
    let model: MCPServersModel
    @State private var values: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ServerLogo(name: spec.name, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install \(spec.title)").font(.vibex(size: 15, weight: .semibold))
                    Text("Claude Code keeps these in its own config.").font(.vibex(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            ForEach(spec.inputs, id: \.self) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.name + (field.isRequired ? "" : " (optional)")).font(.vibex(size: 12, weight: .medium))
                    Group {
                        if field.isSecret {
                            SecureField(field.summary ?? field.name, text: binding(field.name))
                        } else {
                            TextField(field.summary ?? field.name, text: binding(field.name))
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    if let summary = field.summary { Text(summary).font(.vibex(size: 11)).foregroundStyle(Theme.faint) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.pendingInstall = nil; dismiss() }
                Button("Install") {
                    model.install(spec, scope: scope, values: values)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(spec.inputs.contains { $0.isRequired && (values[$0.name] ?? "").isEmpty })
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }
}
