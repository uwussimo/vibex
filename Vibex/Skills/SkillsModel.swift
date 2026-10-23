import AppKit
import Observation

/// Skills for one project window: what Claude Code loads globally and for this project, and the
/// skills.sh marketplace to add more.
@Observable
final class SkillsModel {
    private(set) var global: [InstalledSkill] = []
    private(set) var project: [InstalledSkill] = []
    private(set) var results: [MarketplaceSkill] = []
    private(set) var isSearching = false
    private(set) var installing: Set<String> = []
    private(set) var removed: RemovedSkill?
    var problem: String?
    var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }

    let folder: URL
    var projectName: String { folder.lastPathComponent }
    private var searchTask: Task<Void, Never>?
    private var leaderboard: [MarketplaceSkill]?

    init(folder: URL) {
        self.folder = folder
    }

    func refresh() {
        let folder = folder
        Task {
            let (global, project) = await Self.load(folder)
            if global != self.global { self.global = global }
            if project != self.project { self.project = project }
        }
    }

    @concurrent private static func load(_ folder: URL) async -> ([InstalledSkill], [InstalledSkill]) {
        (SkillsLibrary.list(.global, project: folder), SkillsLibrary.list(.project, project: folder))
    }

    // MARK: - Marketplace

    /// Where `skillId` is installed already, matched by folder name.
    func scopes(of skill: MarketplaceSkill) -> Set<InstalledSkill.Scope> {
        var scopes = Set<InstalledSkill.Scope>()
        if global.contains(where: { $0.name == skill.skillId }) { scopes.insert(.global) }
        if project.contains(where: { $0.name == skill.skillId }) { scopes.insert(.project) }
        return scopes
    }

    func loadMarketplace() {
        if results.isEmpty { scheduleSearch(immediately: true) }
    }

    private func scheduleSearch(immediately: Bool = false) {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        searchTask = Task {
            if !immediately { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            do {
                let found: [MarketplaceSkill]
                if text.count >= 2 {
                    found = try await SkillsMarketplace.search(text)
                } else if let leaderboard {
                    found = leaderboard
                } else {
                    found = try await SkillsMarketplace.leaderboard()
                    leaderboard = found
                }
                guard !Task.isCancelled else { return }
                results = found
                problem = nil
            } catch {
                guard !Task.isCancelled else { return }
                problem = "Couldn't reach skills.sh. Check your connection and try again."
            }
        }
    }

    func install(_ skill: MarketplaceSkill, scope: InstalledSkill.Scope) {
        let key = skill.id + scope.rawValue
        guard !installing.contains(key) else { return }
        installing.insert(key)
        problem = nil
        let folder = folder
        Task {
            do {
                try await SkillsLibrary.install(skill, scope: scope, project: folder)
            } catch {
                problem = error.localizedDescription
            }
            installing.remove(key)
            refresh()
        }
    }

    func isInstalling(_ skill: MarketplaceSkill) -> Bool {
        installing.contains(skill.id + InstalledSkill.Scope.global.rawValue) || installing.contains(skill.id + InstalledSkill.Scope.project.rawValue)
    }

    // MARK: - Installed skills

    func remove(_ skill: InstalledSkill) {
        do {
            removed = try SkillsLibrary.remove(skill, project: folder)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        refresh()
    }

    func undoRemove() {
        guard let removed else { return }
        do {
            try SkillsLibrary.restore(removed)
            self.removed = nil
        } catch {
            problem = error.localizedDescription
        }
        refresh()
    }

    func dismissRemoved() { removed = nil }

    func open(_ skill: InstalledSkill) { NSWorkspace.shared.open(skill.skillFile) }
    func reveal(_ skill: InstalledSkill) { NSWorkspace.shared.activateFileViewerSelecting([skill.folder]) }
}
