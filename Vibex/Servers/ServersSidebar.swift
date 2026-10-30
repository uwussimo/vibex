import AppKit
import SwiftUI

/// The Servers sidebar: saved SSH servers, one click from a terminal tab.
struct ServersSidebar: View {
    @Bindable var model: ServersModel
    let connect: (ServerProfile) -> Void
    @State private var query = ""
    @State private var editing: EditTarget?
    @State private var deleting: ServerProfile?

    private enum EditTarget: Identifiable {
        case new
        case server(ServerProfile)

        var id: String {
            switch self {
            case .new: "new"
            case let .server(server): server.id.uuidString
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Servers").font(.vibex(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                Spacer()
                lockButton
                ToolbarIconButton(icon: .plus, help: "Add Server") { editing = .new }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 38)
            if model.servers.count > 5 { search }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let problem = model.problem { problemView(problem) }
                    if model.servers.isEmpty { emptyState }
                    ForEach(model.matching(query)) { server in
                        ServerRow(server: server, hasSecret: model.hasSecret(server), connect: { connect(server) }, edit: { editing = .server(server) }, forget: { model.forgetSecret(of: server) }, delete: { deleting = server })
                    }
                    if !model.servers.isEmpty, model.matching(query).isEmpty {
                        Text("No servers match “\(query)”.").font(.vibex(size: 12)).foregroundStyle(Theme.faint).padding(8)
                    }
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $editing) { target in
            switch target {
            case .new:
                ServerEditorView(profile: nil) { draft in model.save(draft, editing: nil) }
            case let .server(server):
                ServerEditorView(profile: server) { draft in model.save(draft, editing: server) }
            }
        }
        .alert("Delete \(deleting?.name ?? "this server")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let deleting { model.delete(deleting) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its saved password or passphrase is removed from the Keychain too.")
        }
    }

    private var search: some View {
        HStack(spacing: 7) {
            IconView(.search, size: 13).foregroundStyle(Theme.faint)
            TextField("Search servers", text: $query).textFieldStyle(.plain).font(.vibex(size: 12.5))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    /// When to ask again, and a way to lock right now. Hidden until there's something to protect.
    @ViewBuilder
    private var lockButton: some View {
        if !model.servers.isEmpty {
            Menu {
                Picker("Ask for Touch ID", selection: Binding(get: { model.lock.policy }, set: { model.lock.policy = $0 })) {
                    ForEach(UnlockPolicy.allCases) { policy in Text(policy.title).tag(policy) }
                }
                Divider()
                Button("Lock Now") { model.lock.relock(.manual) }
            } label: {
                IconView(model.lock.isUnlocked ? .unlock : .lock, size: 14)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(model.lock.availability.canAuthenticate ? "Saved passwords need \(model.lock.availability.headline)" : "This Mac can't confirm it's you, so saved passwords can't be used")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            IconView(.server, size: 28).foregroundStyle(Theme.faint)
            Text("Your servers, one click away").font(.vibex(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text)
            Text("Save a server and connect in a terminal tab. Passwords stay in the Keychain behind Touch ID, and Claude can't read them.")
                .font(.vibex(size: 12))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { editing = .new } label: {
                Text("Add Server").font(.vibex(size: 12.5, weight: .medium)).frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 8)
    }

    private func problemView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            IconView(.alert, size: 14).foregroundStyle(Theme.red).padding(.top, 2)
            Text(text).font(.vibex(size: 12)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            Button { model.problem = nil } label: {
                IconView(.close, size: 11).foregroundStyle(Theme.muted).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.red.opacity(0.1)))
    }
}

private struct ServerRow: View {
    let server: ServerProfile
    let hasSecret: Bool
    let connect: () -> Void
    let edit: () -> Void
    let forget: () -> Void
    let delete: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: connect) {
            HStack(spacing: 10) {
                Text(server.name.prefix(1).uppercased())
                    .font(.vibex(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.raised))
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.name).font(.vibex(size: 12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(server.endpointDescription)
                        .font(.vibexCode(size: 10.5))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 2)
                if isHovering {
                    RowIconButton(icon: .settings, help: "Edit", action: edit)
                } else if hasSecret {
                    IconView(.key, size: 12).foregroundStyle(Theme.faint).help("Password saved in the Keychain")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(isHovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .onHover { isHovering = $0 }
        .help(server.notes.isEmpty ? "Connect to \(server.endpointDescription)" : server.notes)
        .contextMenu {
            Button("Connect", action: connect)
            Button("Edit…", action: edit)
            Button("Copy SSH Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("ssh -p \(String(server.port)) \(server.username)@\(server.host)", forType: .string)
            }
            if hasSecret { Button("Forget Saved Password", action: forget) }
            Divider()
            Button("Delete…", role: .destructive, action: delete)
        }
    }
}
