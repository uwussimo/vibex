import Foundation

/// One open project: its folder, its mutable state, and debounced saving. Shared by the window's panes.
final class ProjectSession {
    let project: Project
    /// Stable per-window id, also exported to terminals as VIBEX_WINDOW.
    let windowID = UUID().uuidString
    private(set) var state: ProjectState
    private let store: ProjectStore
    private var saveWork: DispatchWorkItem?

    init(project: Project, store: ProjectStore = .shared) {
        self.project = project
        self.store = store
        state = store.state(for: project)
        state.lastOpened = Date()
    }

    func update(_ change: (inout ProjectState) -> Void) {
        let before = state
        change(&state)
        guard state != before else { return }
        scheduleSave()
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        store.save(state, for: project)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Environment every terminal in this window gets, on top of the app-wide MCP variables.
    var terminalEnvironment: [String: String] {
        ["VIBEX_PROJECT": project.path, "VIBEX_WINDOW": windowID]
    }
}
