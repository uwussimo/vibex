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

    /// What just happened, shown under the commit box with the natural next step.
    enum Notice: Equatable {
        case committed(hash: String, branch: String)
        case pushed(to: String)
        case discarded(summary: String)
    }

    private(set) var state: State = .loading
    private(set) var status = GitStatus()
    private(set) var selection: GitChange?
    private(set) var diff: FileDiff?
    /// Syntax colours for the open diff, by line id.
    private(set) var highlights: [Int: [SyntaxSpan]] = [:]
    private(set) var isDiffLoading = false
    private(set) var busy: String?
    var commitMessage = ""
    var diffStyle: DiffStyle = .split
    /// Shown in the sidebar until the next action or until dismissed.
    var problem: GitProblem?
    private(set) var notice: Notice?
    /// Remotes, looked up only while the branch has no upstream (to offer Publish Branch).
    private(set) var remotes: [String] = []

    /// The project's own folder.
    let projectFolder: URL
    /// The checkout shown: the project, or a parallel agent's worktree being reviewed.
    private(set) var folder: URL
    /// The agent being reviewed, by name; nil for the project's own checkout.
    private(set) var reviewingAgent: String?
    private var repository: GitRepository?
    private var watcher: FileWatcher?
    private var refreshTask: Task<Void, Never>?
    private var refreshQueued = false
    private var discardBackup: DiscardBackup?
    private var noticeToken = 0
    private var expiringNoticeToken: Int?

    init(folder: URL) {
        projectFolder = folder
        self.folder = folder
    }

    /// Switches every list, diff and the commit box to another checkout (an agent's worktree), or
    /// back to the project when `folder` is nil.
    func show(checkout: URL?, agent: String? = nil) {
        let target = checkout ?? projectFolder
        guard target.standardizedFileURL != folder.standardizedFileURL else { return }
        stop()
        folder = target
        reviewingAgent = checkout == nil ? nil : agent
        repository = nil
        status = GitStatus()
        selection = nil
        diff = nil
        highlights = [:]
        problem = nil
        commitMessage = ""
        dismissNotice()
        state = .loading
        start()
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
            let nextRemotes = next.upstream == nil && next.branch != nil ? await repository.remotes() : []
            if next != status { status = next }
            if nextRemotes != remotes { remotes = nextRemotes }
            state = .ready
            if case .committed = notice, !hasPushWork { expireNotice(after: 6) }
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
        highlights = [:]
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
                problem = GitProblem.explain(error)
                result = FileDiff()
            }
            let spans = await Self.highlight(result, path: change.path)
            guard selection?.id == change.id else { return }
            if result != diff {
                diff = result
                highlights = spans
            }
            isDiffLoading = false
        }
    }

    @concurrent private static func highlight(_ diff: FileDiff, path: String) async -> [Int: [SyntaxSpan]] {
        DiffHighlighter.highlight(diff, path: path)
    }

    // MARK: - Navigation

    /// Every change in the order the sidebar lists them.
    var orderedChanges: [GitChange] { status.conflicted + status.staged + status.unstaged }

    /// Opens the next (or previous) change after the open one, or the first (or last) when none is open.
    func selectAdjacent(_ offset: Int) {
        let all = orderedChanges
        guard !all.isEmpty else { return }
        guard let current = selection, let index = all.firstIndex(where: { $0.id == current.id }) else {
            select(offset > 0 ? all.first : all.last)
            return
        }
        let target = index + offset
        guard all.indices.contains(target) else { return }
        select(all[target])
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

    /// Stages (or unstages) the open file and opens the next one in its group, so reviewing a set of
    /// changes never needs a trip back to the list.
    func toggleStageAndAdvance(_ change: GitChange) {
        let group = change.area == .staged ? status.staged : (change.area == .conflicted ? status.conflicted : status.unstaged)
        var next: GitChange?
        if let index = group.firstIndex(where: { $0.id == change.id }) {
            next = group.indices.contains(index + 1) ? group[index + 1] : (index > 0 ? group[index - 1] : nil)
        }
        let paths = [change.path]
        let work: (GitRepository) async throws -> Void = change.area == .staged
            ? { try await $0.unstage(paths) }
            : { try await $0.stage(paths) }
        perform(change.area == .staged ? "Unstaging…" : "Staging…", work) { [weak self] in
            if let next { self?.select(next) }
        }
    }

    /// One file goes straight away (Undo puts it back); several ask first.
    func discard(_ changes: [GitChange], in window: NSWindow?) {
        guard !changes.isEmpty else { return }
        guard changes.count > 1 else {
            performDiscard(changes)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Discard changes to \(changes.count) files?"
        alert.informativeText = changes.contains { $0.kind == .untracked }
            ? "Untracked files move to the Trash. You can undo this from the sidebar."
            : "You can undo this from the sidebar."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performDiscard(changes)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
    }

    private func performDiscard(_ changes: [GitChange]) {
        let summary = changes.count == 1 ? "Discarded “\(changes[0].fileName)”" : "Discarded \(changes.count) files"
        perform("Discarding…") { try await $0.discard(changes) } onSuccess: { [weak self] backup in
            self?.discardBackup = backup
            self?.show(.discarded(summary: summary))
        }
    }

    var canUndoDiscard: Bool { discardBackup != nil }

    func undoDiscard() {
        guard let backup = discardBackup else { return }
        perform("Restoring…", clearsNotice: false) { try await $0.restore(backup) } onSuccess: { [weak self] in
            self?.discardBackup = nil
            self?.dismissNotice()
        }
    }

    /// Commits what is staged; with nothing staged, stages everything first (like VS Code's smart commit).
    func commit() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        let stageEverything = status.staged.isEmpty
        let paths = (status.unstaged + status.conflicted).map(\.path)
        let branch = branchLabel
        perform("Committing…") { repository in
            if stageEverything { try await repository.stage(paths) }
            return try await repository.commit(message: message)
        } onSuccess: { [weak self] hash in
            self?.commitMessage = ""
            self?.show(.committed(hash: hash, branch: branch))
        }
    }

    var canCommit: Bool {
        busy == nil && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !status.isClean
    }

    /// The branch has no upstream but there is a remote to publish it to.
    var canPublish: Bool { status.upstream == nil && status.branch != nil && !remotes.isEmpty }

    /// Commits are waiting to go to the remote.
    var hasPushWork: Bool { canPublish || (status.upstream != nil && status.ahead > 0) }

    func push() {
        guard status.upstream != nil else { return publish() }
        let upstream = status.upstream ?? "the remote"
        perform("Pushing…") { try await $0.push() } onSuccess: { [weak self] in
            self?.show(.pushed(to: upstream), for: 4)
        }
    }

    func publish() {
        let branch = branchLabel
        perform("Publishing…") { try await $0.publish() } onSuccess: { [weak self] remote in
            self?.show(.pushed(to: "\(remote)/\(branch)"), for: 4)
        }
    }

    func pull() { perform("Pulling…") { try await $0.pull() } }

    func fix(_ fix: GitProblem.Fix) {
        switch fix {
        case .pull: pull()
        case .publish: publish()
        }
    }

    func initializeRepository() {
        busy = "Creating repository…"
        Task {
            do {
                try await GitRepository.initialize(at: folder)
                repository = nil
                problem = nil
            } catch {
                problem = GitProblem.explain(error)
            }
            busy = nil
            refresh()
        }
    }

    // MARK: - Notices

    func dismissNotice() {
        notice = nil
        noticeToken += 1
    }

    private func show(_ notice: Notice, for seconds: Double? = nil) {
        self.notice = notice
        noticeToken += 1
        expiringNoticeToken = nil
        if let seconds { expireNotice(after: seconds) }
    }

    private func expireNotice(after seconds: Double) {
        let token = noticeToken
        guard expiringNoticeToken != token else { return }
        expiringNoticeToken = token
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if noticeToken == token { dismissNotice() }
        }
    }

    // MARK: - Running

    private func perform<Value>(
        _ activity: String,
        clearsNotice: Bool = true,
        _ work: @escaping (GitRepository) async throws -> Value,
        onSuccess: ((Value) -> Void)? = nil
    ) {
        guard let repository, busy == nil else { return }
        busy = activity
        problem = nil
        if clearsNotice {
            dismissNotice()
            discardBackup = nil
        }
        Task {
            do {
                let value = try await work(repository)
                onSuccess?(value)
            } catch {
                problem = GitProblem.explain(error)
                Log.app.error("git: \(error.localizedDescription, privacy: .public)")
            }
            busy = nil
            refresh()
        }
    }
}
