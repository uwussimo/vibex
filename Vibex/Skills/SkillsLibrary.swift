import Foundation

/// A skill Claude Code can load: a folder with a SKILL.md, in ~/.claude/skills (global) or the
/// project's .claude/skills.
nonisolated struct InstalledSkill: Identifiable, Hashable, Sendable {
    enum Scope: String, Sendable { case global, project }

    /// The folder name, which is how Claude Code refers to it.
    var name: String
    var summary: String
    /// The entry in .claude/skills (often a symlink into .agents/skills).
    var folder: URL
    var scope: Scope
    /// owner/repo, when it came from skills.sh or `npx skills`.
    var source: String?

    var id: String { "\(scope.rawValue)|\(name)" }
    var skillFile: URL { folder.appendingPathComponent("SKILL.md") }
}

/// A skill on skills.sh.
nonisolated struct MarketplaceSkill: Identifiable, Hashable, Sendable, Decodable {
    var source: String
    var skillId: String
    var name: String
    var installs: Int

    var id: String { "\(source)/\(skillId)" }
    var page: URL { URL(string: "https://skills.sh/\(source)/\(skillId)")! }

    /// Its SKILL.md on GitHub, trying the layouts skill repos use.
    var document: OpenDocument {
        let base = "https://raw.githubusercontent.com/\(source)/HEAD/"
        let paths = ["skills/\(skillId)/SKILL.md", "\(skillId)/SKILL.md", ".claude/skills/\(skillId)/SKILL.md", "plugins/\(skillId)/SKILL.md", "SKILL.md"]
        return OpenDocument(id: "remote:\(id)", title: "\(name) · SKILL.md", file: nil, remote: paths.compactMap { URL(string: base + $0) })
    }
}

/// What a removal moved to the Trash, so Undo can put it back.
nonisolated struct RemovedSkill: Sendable {
    var skill: InstalledSkill
    var trashed: [(original: URL, trash: URL)]
    var linkDestination: String?
    var lockEntry: Data?
}

nonisolated enum SkillsError: Error, LocalizedError {
    case notFound(String)
    case download(String)

    var errorDescription: String? {
        switch self {
        case let .notFound(name): "Couldn't find a skill named “\(name)” in that repository."
        case let .download(message): "Couldn't download the skill: \(message)"
        }
    }
}

/// Lists, installs and removes skills using the same layout as `npx skills`: the files live in
/// .agents/skills/<name>, and .claude/skills/<name> links to them.
nonisolated enum SkillsLibrary {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func claudeFolder(_ scope: InstalledSkill.Scope, project: URL) -> URL {
        (scope == .global ? home : project).appendingPathComponent(".claude/skills")
    }

    static func agentsFolder(_ scope: InstalledSkill.Scope, project: URL) -> URL {
        (scope == .global ? home : project).appendingPathComponent(".agents/skills")
    }

    static var lockURL: URL { home.appendingPathComponent(".agents/.skill-lock.json") }

    // MARK: - Listing

    static func list(_ scope: InstalledSkill.Scope, project: URL) -> [InstalledSkill] {
        let folder = claudeFolder(scope, project: project)
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let sources = scope == .global ? lockSources() : [:]
        return entries.compactMap { url -> InstalledSkill? in
            let file = url.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let name = url.lastPathComponent
            let front = frontmatter(text)
            return InstalledSkill(name: name, summary: front["description"] ?? "", folder: url, scope: scope, source: sources[name])
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `name:` and `description:` from a SKILL.md's YAML front matter, including folded (`>`) values.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var values: [String: String] = [:]
        var key: String?
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if let first = line.first, first == " " || first == "\t" {
                // Continuation of a multi-line value.
                if let key { values[key, default: ""] += (values[key]!.isEmpty ? "" : " ") + line.trimmingCharacters(in: .whitespaces) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { key = nil; continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-"].contains(value) { value = "" }
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            key = name
            values[name] = value
        }
        return values
    }

    // MARK: - Installing

    /// Downloads the repository from GitHub, finds the skill in it, and installs it.
    @concurrent static func install(_ skill: MarketplaceSkill, scope: InstalledSkill.Scope, project: URL) async throws {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("vibex-skill-\(UUID().uuidString)")
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        guard let archiveURL = URL(string: "https://codeload.github.com/\(skill.source)/tar.gz/HEAD") else { throw SkillsError.download("bad source") }
        let (download, response) = try await URLSession.shared.download(from: archiveURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SkillsError.download("GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(skill.source)")
        }
        let archive = work.appendingPathComponent("repo.tar.gz")
        try fileManager.moveItem(at: download, to: archive)
        let extracted = work.appendingPathComponent("repo")
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
        _ = try Shell.run("/usr/bin/tar", ["-xzf", archive.path, "-C", extracted.path])

        guard let found = locate(skill.skillId, in: extracted) else { throw SkillsError.notFound(skill.skillId) }
        let name = skill.skillId
        let destination = agentsFolder(scope, project: project).appendingPathComponent(name)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.trashItem(at: destination, resultingItemURL: nil) }
        try fileManager.copyItem(at: found, to: destination)

        let link = claudeFolder(scope, project: project).appendingPathComponent(name)
        try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? link.checkResourceIsReachable()) == true || isSymlink(link) {
            if isSymlink(link) { try fileManager.removeItem(at: link) } else { try fileManager.trashItem(at: link, resultingItemURL: nil) }
        }
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: "../../.agents/skills/\(name)")

        if scope == .global {
            // Path inside the repository, without the archive's "repo-<sha>/" folder.
            let relative = found.appendingPathComponent("SKILL.md").path.replacingOccurrences(of: extracted.path + "/", with: "")
            let skillPath = relative.split(separator: "/").dropFirst().joined(separator: "/")
            let now = ISO8601DateFormatter().string(from: Date())
            updateLock { skills in
                skills[name] = [
                    "source": skill.source,
                    "sourceType": "github",
                    "sourceUrl": "https://github.com/\(skill.source).git",
                    "skillPath": skillPath,
                    "installedAt": now,
                    "updatedAt": now,
                ]
            }
        }
    }

    /// The folder holding the skill: one named after it, or whose SKILL.md declares that name.
    static func locate(_ name: String, in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        var byName: URL?
        var byFolder: URL?
        for case let url as URL in enumerator where url.lastPathComponent == "SKILL.md" {
            let folder = url.deletingLastPathComponent()
            if folder.lastPathComponent == name, byFolder == nil { byFolder = folder }
            if byName == nil, let text = try? String(contentsOf: url, encoding: .utf8), frontmatter(text)["name"] == name { byName = folder }
        }
        return byFolder ?? byName
    }

    // MARK: - Removing

    /// Moves the skill to the Trash: the link in .claude/skills and the files it points to.
    static func remove(_ skill: InstalledSkill, project: URL) throws -> RemovedSkill {
        let fileManager = FileManager.default
        var removed = RemovedSkill(skill: skill, trashed: [], linkDestination: nil, lockEntry: nil)
        if isSymlink(skill.folder) {
            let destination = try fileManager.destinationOfSymbolicLink(atPath: skill.folder.path)
            removed.linkDestination = destination
            let target = URL(fileURLWithPath: destination, relativeTo: skill.folder.deletingLastPathComponent()).standardizedFileURL
            try fileManager.removeItem(at: skill.folder)
            // Only trash the files when they live in our .agents folder, not somewhere the user keeps them.
            if target.path.hasPrefix(agentsFolder(skill.scope, project: project).standardizedFileURL.path) {
                var trash: NSURL?
                try fileManager.trashItem(at: target, resultingItemURL: &trash)
                if let trash { removed.trashed.append((target, trash as URL)) }
            }
        } else {
            var trash: NSURL?
            try fileManager.trashItem(at: skill.folder, resultingItemURL: &trash)
            if let trash { removed.trashed.append((skill.folder, trash as URL)) }
        }
        if skill.scope == .global {
            updateLock { skills in
                if let entry = skills.removeValue(forKey: skill.name) {
                    removed.lockEntry = try? JSONSerialization.data(withJSONObject: entry)
                }
            }
        }
        return removed
    }

    static func restore(_ removed: RemovedSkill) throws {
        let fileManager = FileManager.default
        for (original, trash) in removed.trashed where !fileManager.fileExists(atPath: original.path) {
            try fileManager.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: trash, to: original)
        }
        if let destination = removed.linkDestination, !isSymlink(removed.skill.folder) {
            try fileManager.createSymbolicLink(atPath: removed.skill.folder.path, withDestinationPath: destination)
        }
        if let data = removed.lockEntry, let entry = try? JSONSerialization.jsonObject(with: data) {
            updateLock { $0[removed.skill.name] = entry }
        }
    }

    // MARK: - Helpers

    /// Asks the file system each time; URL caches resource values, which go stale after a removal.
    static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private static func lockSources() -> [String: String] {
        guard let data = try? Data(contentsOf: lockURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skills = object["skills"] as? [String: [String: Any]] else { return [:] }
        return skills.compactMapValues { $0["source"] as? String }
    }

    /// Edits `npx skills`' lock file in place, keeping every field it doesn't touch.
    private static func updateLock(_ change: (inout [String: Any]) -> Void) {
        var object = (try? Data(contentsOf: lockURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? ["version": 3]
        var skills = object["skills"] as? [String: Any] ?? [:]
        change(&skills)
        object["skills"] = skills
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: lockURL, options: .atomic)
    }
}

/// skills.sh: search, plus the all-time leaderboard from its home page.
nonisolated enum SkillsMarketplace {
    private struct SearchResponse: Decodable { var skills: [MarketplaceSkill] }

    @concurrent static func search(_ query: String) async throws -> [MarketplaceSkill] {
        var components = URLComponents(string: "https://skills.sh/api/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "50")]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try JSONDecoder().decode(SearchResponse.self, from: data).skills
    }

    /// The home page embeds its leaderboard as escaped JSON; pull the records out of it.
    @concurrent static func leaderboard() async throws -> [MarketplaceSkill] {
        var request = URLRequest(url: URL(string: "https://skills.sh/")!)
        request.setValue("Mozilla/5.0 (Macintosh) Vibex", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let page = String(decoding: data, as: UTF8.self).replacingOccurrences(of: #"\""#, with: "\"")
        let pattern = try NSRegularExpression(pattern: #"\{"source":"([^"]+)","skillId":"([^"]+)","name":"([^"]*)","installs":(\d+)"#)
        var seen = Set<String>()
        return pattern.matches(in: page, range: NSRange(page.startIndex..., in: page)).compactMap { match in
            func group(_ index: Int) -> String { Range(match.range(at: index), in: page).map { String(page[$0]) } ?? "" }
            let skill = MarketplaceSkill(source: group(1), skillId: group(2), name: group(3), installs: Int(group(4)) ?? 0)
            return seen.insert(skill.id).inserted ? skill : nil
        }
    }
}
