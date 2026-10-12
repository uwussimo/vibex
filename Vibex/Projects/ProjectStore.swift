import Foundation
import os

/// Project state on disk and the recent-projects list.
/// State lives in `~/Library/Application Support/Vibex/Projects/<id>.json`.
final class ProjectStore {
    static let shared = ProjectStore()

    private let directory: URL
    private let defaults = UserDefaults.standard
    private static let recentsKey = "projects.recent"
    private static let openKey = "projects.open"
    static let recentLimit = 20

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vibex/Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: - State

    func state(for project: Project) -> ProjectState {
        let file = stateURL(for: project)
        if let data = try? Data(contentsOf: file), let state = try? JSONDecoder.iso.decode(ProjectState.self, from: data) {
            return state
        }
        return migratedLegacyStateIfFirstProject() ?? ProjectState()
    }

    func save(_ state: ProjectState, for project: Project) {
        do {
            let data = try JSONEncoder.iso.encode(state)
            try data.write(to: stateURL(for: project), options: .atomic)
        } catch {
            Log.app.error("could not save project state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stateURL(for project: Project) -> URL {
        directory.appendingPathComponent("\(project.id).json")
    }

    /// The single-window builds kept browser tabs, device and layout in global defaults.
    /// The first project opened after upgrading inherits them once.
    private func migratedLegacyStateIfFirstProject() -> ProjectState? {
        guard !defaults.bool(forKey: "projects.migrated") else { return nil }
        defaults.set(true, forKey: "projects.migrated")
        var state = ProjectState()
        // Terminal folders are not migrated: a project's terminals start in the project.
        state.browserTabURLs = defaults.stringArray(forKey: "browser.tabURLs") ?? []
        state.browserSelectedTab = defaults.integer(forKey: "browser.selectedTab")
        state.deviceUDID = defaults.string(forKey: "simulator.selectedUDID")
        state.layoutMode = defaults.string(forKey: "layout.mode") ?? LayoutMode.balanced.rawValue
        state.manualWidths = defaults.array(forKey: "layout.manualWidths") as? [Double]
        if state.browserTabURLs.isEmpty {
            state.browserTabURLs = [WebViewFactory.homeURL.absoluteString]
        }
        return state
    }

    // MARK: - Recents and open set

    var recents: [Project] {
        let paths = defaults.stringArray(forKey: Self.recentsKey) ?? []
        return paths.map { Project(url: URL(fileURLWithPath: $0)) }
    }

    func noteOpened(_ project: Project) {
        var paths = defaults.stringArray(forKey: Self.recentsKey) ?? []
        paths.removeAll { $0 == project.path }
        paths.insert(project.path, at: 0)
        defaults.set(Array(paths.prefix(Self.recentLimit)), forKey: Self.recentsKey)
    }

    func removeRecent(_ project: Project) {
        var paths = defaults.stringArray(forKey: Self.recentsKey) ?? []
        paths.removeAll { $0 == project.path }
        defaults.set(paths, forKey: Self.recentsKey)
    }

    func clearRecents() {
        defaults.removeObject(forKey: Self.recentsKey)
    }

    /// Projects whose windows were open at last quit, for restoring.
    var lastOpen: [Project] {
        get { (defaults.stringArray(forKey: Self.openKey) ?? []).map { Project(url: URL(fileURLWithPath: $0)) } }
        set { defaults.set(newValue.map(\.path), forKey: Self.openKey) }
    }
}

extension JSONEncoder {
    nonisolated static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    nonisolated static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
