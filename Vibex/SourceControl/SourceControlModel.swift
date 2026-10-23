import AppKit
import Observation
import os

/// Git state for one project window: the changed files, the selected file's diff, and the
/// stage / unstage / discard / commit / push actions. Refreshes itself as files change on disk.
@Observable
final class SourceControlModel {
    enum State: Equatable {
        case loading
        case notRepository
        case ready
        case failed(String)
    }

    enum DiffStyle: String { case split, unified }

    private(set) var state: State = .loading
    private(set) var status = GitStatus()
    private(set) var selection: GitChange?
    private(set) var diff: FileDiff?
    private(set) var isDiffLoading = false
    private(set) var busy: String?
    var commitMessage = ""
    var diffStyle: DiffStyle = .split
    /// Mirrors the window's sidebar so the titlebar button can show it as pressed.
    var isSidebarVisible = false
    /// Shown in the sidebar until the next action; git's own wording is usually the clearest.
    var error: String?

    let folder: URL
    private var repository: GitRepository?
    private var watcher: FileWatcher?
    private var refreshTask: Task<Void, Never>?
    private var refreshQueued = false

    init(folder: URL) {
        self.folder = folder
    }

    var branchLabel: String { status.branch ?? "Detached HEAD" }

    /// Begins watching. Called when the window opens; cheap enough to run for every project.
    func start() {
        guard watcher == nil else { return }
        watcher = FileWatcher(path: folder.path) { [weak self] in self?.refresh() }
        refresh()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    func refresh() {
        // One refresh at a time; changes that land meanwhile get one more pass afterwards.
        guard refreshTask == nil else {
            refreshQueued = true
            return
        }
        refreshTask = Task {
            await reload()
            refreshTask = nil
            if refreshQueued {
                refreshQueued = false
                refresh()
            }
        }
    }

    private func reload() async {
        if repository == nil {
            repository = await GitRepository.find(containing: folder)
            if repository == nil {
                state = .notRepository
                status = GitStatus()
                return
            }
        }
        guard let repository else { return }
        do {
            let next = try await repository.status()
            if next != status { status = next }
            state = .ready
            reconcileSelection()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Keeps the open diff pointing at the same file as it moves between Changes and Staged.
    private func reconcileSelection() {
        guard let current = selection else { return }
        let all = status.staged + status.unstaged + status.conflicted
        if let same = all.first(where: { $0.id == current.id }) {
            selection = same
        } else if let moved = all.first(where: { $0.path == current.path }) {
            selection = moved
        } else {
            selection = nil
            diff = nil
            return
        }
        loadDiff()
    }

    // MARK: - Diff

    func select(_ change: GitChange?) {
        guard change != selection else { return }
        selection = change
        diff = nil
        loadDiff()
    }

    private func loadDiff() {
        guard let change = selection, let repository else { return }
        isDiffLoading = diff == nil
        Task {
            let result: FileDiff
            do {
                result = try await repository.diff(for: change)
            } catch {
                self.error = error.localizedDescription
                result = FileDiff()
            }
            guard selection?.id == change.id else { return }
            if result != diff { diff = result }
            isDiffLoading = false
        }
    }

    // MARK: - Actions

    func stage(_ changes: [GitChange]) {
        perform("Staging…") { try await $0.stage(changes.map(\.path)) }
    }

    func unstage(_ changes: [GitChange]) {
        perform("Unstaging…") { try await $0.unstage(changes.map(\.path)) }
    }

    func stageAll() { stage(status.unstaged + status.conflicted) }
    func unstageAll() { unstage(status.staged) }

    /// Discarding can't be undone, so it always asks first.
    func discard(_ changes: [GitChange], in window: NSWindow?) {
        guard !changes.isEmpty else { return }
        let alert = NSAlert()
        let deletes = changes.contains { $0.kind == .untracked }
        alert.messageText = changes.count == 1
            ? "Discard changes to “\(changes[0].fileName)”?"
            : "Discard changes to \(changes.count) files?"
        alert.informativeText = deletes
            ? "Untracked files will be deleted. This can't be undone."
            : "Your edits will be lost. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: deletes ? "Delete" : "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.perform("Discarding…") { try await $0.discard(changes) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
    }

    /// Commits what is staged; with nothing staged, stages everything first (like VS Code's smart commit).
    func commit() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        let stageEverything = status.staged.isEmpty
        let paths = (status.unstaged + status.conflicted).map(\.path)
        perform("Committing…") { repository in
            if stageEverything { try await repository.stage(paths) }
            try await repository.commit(message: message)
        } onSuccess: { [weak self] in
            self?.commitMessage = ""
        }
    }

    var canCommit: Bool {
        busy == nil && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !status.isClean
    }

    func push() { perform("Pushing…") { try await $0.push() } }
    func pull() { perform("Pulling…") { try await $0.pull() } }

    func initializeRepository() {
        busy = "Creating repository…"
        Task {
            do {
                try await GitRepository.initialize(at: folder)
                repository = nil
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            busy = nil
            refresh()
        }
    }

    private func perform(_ activity: String, _ work: @escaping (GitRepository) async throws -> Void, onSuccess: (() -> Void)? = nil) {
        guard let repository, busy == nil else { return }
        busy = activity
        error = nil
        Task {
            do {
                try await work(repository)
                onSuccess?()
            } catch {
                self.error = error.localizedDescription
                Log.app.error("git: \(error.localizedDescription, privacy: .public)")
            }
            busy = nil
            refresh()
        }
    }
}
