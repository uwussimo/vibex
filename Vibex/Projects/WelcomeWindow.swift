import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shown when no project window is open: open a folder, or pick a recent one.
final class WelcomeWindowController: NSWindowController {
    init(manager: WindowManager) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "Welcome to Vibex"
        super.init(window: window)
        window.contentView = NSHostingView(rootView: WelcomeView(
            recents: ProjectStore.shared.recents,
            open: { [weak manager] url in manager?.open(url) },
            openPanel: { [weak manager] in manager?.showOpenPanel() },
            remove: { ProjectStore.shared.removeRecent($0) }
        ))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

struct WelcomeView: View {
    @State var recents: [Project]
    let open: (URL) -> Void
    let openPanel: () -> Void
    let remove: (Project) -> Void

    @State private var selection: Project.ID?
    @State private var isDropTargeted = false
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 36)
                .padding(.bottom, 24)
            actions
                .padding(.horizontal, 28)
                .padding(.bottom, 18)
            Divider()
            recentList
        }
        .frame(width: 520, height: 540)
        .background(Theme.background)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(6)
                .opacity(isDropTargeted ? 1 : 0)
                .animation(.spring(response: 0.2, dampingFraction: 1), value: isDropTargeted)
                .allowsHitTesting(false)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in open(url) }
                }
            }
            return true
        }
        .onAppear {
            selection = recents.first?.id
            listFocused = true
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
            Text("Vibex")
                .font(.vibex(size: 26, weight: .semibold))
            Text("Terminal, simulator and browser for one project per window")
                .font(.vibex(size: 12.5))
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            WelcomeAction(title: "Open Folder…", shortcut: "⌘O", icon: .folder, action: openPanel)
            WelcomeAction(title: "Home Folder", shortcut: "⌘N", icon: .home) {
                open(FileManager.default.homeDirectoryForCurrentUser)
            }
        }
    }

    @ViewBuilder
    private var recentList: some View {
        if recents.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Text("No recent projects")
                    .font(.vibex(size: 13, weight: .medium))
                Text("Open a folder, or drop one here.")
                    .font(.vibex(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(selection: $selection) {
                Section("Recent") {
                    ForEach(recents) { project in
                        RecentRow(project: project)
                            .tag(project.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { open(project.url) }
                            .contextMenu {
                                Button("Open") { open(project.url) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                                Divider()
                                Button("Remove from Recents") { removeRecent(project) }
                            }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .focused($listFocused)
            .onKeyPress(.return) {
                guard let project = recents.first(where: { $0.id == selection }) else { return .ignored }
                open(project.url)
                return .handled
            }
            .onDeleteCommand {
                if let project = recents.first(where: { $0.id == selection }) { removeRecent(project) }
            }
        }
    }

    private func removeRecent(_ project: Project) {
        remove(project)
        withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
            recents.removeAll { $0.id == project.id }
        }
    }
}

private struct WelcomeAction: View {
    let title: String
    let shortcut: String
    let icon: Icon
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconView(icon, size: 16)
                    .frame(width: 20)
                Text(title)
                    .font(.vibex(size: 13, weight: .medium))
                Spacer()
                Text(shortcut)
                    .font(.vibex(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .onHover { isHovering = $0 }
    }
}

private struct RecentRow: View {
    let project: Project

    var body: some View {
        HStack(spacing: 10) {
            IconView(.folder, size: 17)
                .foregroundStyle(project.exists ? Theme.accent : Theme.faint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.vibex(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(project.displayPath)
                    .font(.vibex(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 3)
        .opacity(project.exists ? 1 : 0.5)
    }
}
