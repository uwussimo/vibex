import AppKit
import SwiftUI

/// The Explorer sidebar, like VS Code's: the project's files as a tree. A click on a file opens it
/// in a preview tab (replaced by the next one), a double click keeps it open.
struct ExplorerSidebar: View {
    let model: ExplorerModel
    let open: (URL, _ keep: Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(model.root.lastPathComponent.uppercased())
                    .font(.vibex(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Spacer()
                ToolbarIconButton(icon: .chevronUp, help: "Collapse Folders", action: model.collapseAll)
                ToolbarIconButton(icon: .folder, help: "Show in Finder") { NSWorkspace.shared.open(model.root) }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 38)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.rows, id: \.node.id) { row in
                            ExplorerRow(
                                node: row.node,
                                depth: row.depth,
                                isExpanded: model.expanded.contains(row.node.url),
                                isSelected: model.selection == row.node.url,
                                isIgnored: model.isIgnored(row.node),
                                relativePath: model.relativePath(row.node.url),
                                click: { click(row.node) },
                                doubleClick: { if !row.node.isDirectory { open(row.node.url, true) } }
                            )
                            .id(row.node.url)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: model.selection) { _, url in
                    guard let url else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(url, anchor: .center) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: model.start)
    }

    private func click(_ node: FileNode) {
        if node.isDirectory {
            model.toggle(node)
        } else {
            model.selection = node.url
            open(node.url, false)
        }
    }
}

private struct ExplorerRow: View {
    let node: FileNode
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let isIgnored: Bool
    let relativePath: String
    let click: () -> Void
    let doubleClick: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Group {
                if node.isDirectory {
                    IconView(isExpanded ? .chevronDown : .chevronRight, size: 11).foregroundStyle(Theme.faint)
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)
            FileIcon(node: node, isExpanded: isExpanded)
            Text(node.name)
                .font(.vibex(size: 12.5))
                .foregroundStyle(isSelected ? Theme.text : Theme.text.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .opacity(isIgnored ? 0.45 : 1)
        .padding(.leading, 10 + CGFloat(depth) * 14)
        .padding(.trailing, 8)
        .frame(height: 24)
        .background(
            Rectangle().fill(isSelected ? Theme.accent.opacity(0.16) : Color.white.opacity(isHovering ? 0.045 : 0))
        )
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(Theme.accent).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded(doubleClick).exclusively(before: TapGesture().onEnded(click)))
        .onHover { isHovering = $0 }
        .contextMenu {
            if !node.isDirectory { Button("Open", action: doubleClick) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Button("Open in Default App") { NSWorkspace.shared.open(node.url) }
            Divider()
            Button("Copy Path") { copy(node.url.path) }
            Button("Copy Relative Path") { copy(relativePath) }
        }
        .help(relativePath)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A folder icon, a tool's logo for files we have one for, or a plain file icon.
struct FileIcon: View {
    let node: FileNode
    var isExpanded = false

    var body: some View {
        Group {
            if node.isDirectory {
                IconView(.folder, size: 14).foregroundStyle(isExpanded ? Theme.accent : Theme.muted)
            } else if let logo = Self.logo(for: node.name) {
                BrandLogoView(logo, size: 13)
            } else {
                IconView(Self.isCode(node.name) ? .fileCode : .file, size: 14).foregroundStyle(Theme.faint)
            }
        }
        .frame(width: 16, height: 16)
    }

    static func logo(for name: String) -> BrandLogo? {
        let lower = name.lowercased()
        switch lower {
        case "package.json", "package-lock.json", ".nvmrc": return .nodejs
        case "dockerfile", "docker-compose.yml", "compose.yaml", ".dockerignore": return .docker
        case ".gitignore", ".gitattributes", ".gitmodules": return .git
        case "claude.md": return .claude
        default: break
        }
        switch (lower as NSString).pathExtension {
        case "swift": return .swift
        case "py": return .python
        case "jsx", "tsx": return .react
        case "js", "mjs", "cjs", "ts": return .nodejs
        case "xcodeproj", "xcworkspace", "xcconfig", "xcassets": return .xcode
        case "sql": return .postgresql
        case "fig": return .figma
        default: return nil
        }
    }

    static func isCode(_ name: String) -> Bool {
        Language.forPath(name) != nil
    }
}
