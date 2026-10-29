import Foundation
import Observation

/// A file or folder in the project tree.
nonisolated struct FileNode: Identifiable, Hashable, Sendable {
    var url: URL
    var name: String
    var isDirectory: Bool
    var id: URL { url }
}

/// The Explorer sidebar: the project's files as a tree, opened folder by folder and kept current with
/// FSEvents, so files Claude creates or deletes show up without a refresh.
@Observable
final class ExplorerModel {
    let root: URL
    private(set) var expanded: Set<URL> = []
    /// Loaded folders' children, folders first.
    private(set) var children: [URL: [FileNode]] = [:]
    /// Paths git ignores, relative to the root ("node_modules/", "build/"), shown dimmed.
    private(set) var ignored: Set<String> = []
    /// The file open in the editor, highlighted in the tree.
    var selection: URL?
    private var watcher: FileWatcher?

    /// Never worth showing.
    nonisolated static let hidden: Set<String> = [".git", ".DS_Store"]

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func start() {
        guard watcher == nil else { return }
        load(root)
        refreshIgnored()
        watcher = FileWatcher(path: root.path, latency: 0.4) { [weak self] in self?.reloadLoaded() }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// The rows the sidebar shows: every node under an expanded folder, depth first.
    var rows: [(node: FileNode, depth: Int)] {
        var result: [(FileNode, Int)] = []
        func walk(_ folder: URL, _ depth: Int) {
            for node in children[folder] ?? [] {
                result.append((node, depth))
                if node.isDirectory, expanded.contains(node.url) { walk(node.url, depth + 1) }
            }
        }
        walk(root, 0)
        return result
    }

    func toggle(_ node: FileNode) {
        guard node.isDirectory else { return }
        if expanded.contains(node.url) {
            expanded.remove(node.url)
        } else {
            expanded.insert(node.url)
            if children[node.url] == nil { load(node.url) }
        }
    }

    func collapseAll() { expanded = [] }

    /// Opens every folder down to `url` and selects it, e.g. for a file opened from elsewhere.
    func reveal(_ url: URL) {
        let url = url.standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { return }
        var folder = url.deletingLastPathComponent()
        var chain: [URL] = []
        while folder.path.count > root.path.count {
            chain.append(folder)
            folder = folder.deletingLastPathComponent()
        }
        for folder in chain.reversed() {
            expanded.insert(folder)
            if children[folder] == nil { load(folder) }
        }
        selection = url
    }

    func isIgnored(_ node: FileNode) -> Bool {
        let path = relativePath(node.url) + (node.isDirectory ? "/" : "")
        return ignored.contains(path) || ignored.contains { $0.hasSuffix("/") && path.hasPrefix($0) }
    }

    func relativePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : path
    }

    private func load(_ folder: URL) {
        children[folder] = Self.list(folder)
    }

    /// Re-lists the folders already open; ones that vanished drop out of the tree.
    private func reloadLoaded() {
        for folder in children.keys {
            if FileManager.default.fileExists(atPath: folder.path) {
                let list = Self.list(folder)
                if list != children[folder] { children[folder] = list }
            } else {
                children[folder] = nil
                expanded.remove(folder)
            }
        }
        refreshIgnored()
    }

    nonisolated static func list(_ folder: URL) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])) ?? []
        return urls.compactMap { url -> FileNode? in
            let name = url.lastPathComponent
            guard !hidden.contains(name) else { return nil }
            // Bundles like .xcodeproj and .app are folders you can open, like in VS Code.
            let isDirectory = (try? url.resourceValues(forKeys: Set(keys)).isDirectory) ?? false
            return FileNode(url: url.standardizedFileURL, name: name, isDirectory: isDirectory)
        }
        .sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func refreshIgnored() {
        let root = root
        Task {
            let paths = await Self.ignoredPaths(root)
            if paths != ignored { ignored = paths }
        }
    }

    /// `git ls-files` lists what .gitignore hides, collapsing ignored folders to one entry.
    @concurrent private static func ignoredPaths(_ root: URL) async -> Set<String> {
        guard let data = try? Shell.run("/usr/bin/git", ["-C", root.path, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory"]),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map(String.init))
    }
}
