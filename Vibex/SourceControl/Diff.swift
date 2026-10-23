import Foundation

/// A unified diff for one file, parsed into hunks of numbered lines.
nonisolated struct FileDiff: Equatable, Sendable {
    var hunks: [DiffHunk] = []
    var isBinary = false
    var isTruncated = false

    var isEmpty: Bool { hunks.isEmpty && !isBinary }
    var additions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .added } } }
    var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .removed } } }
}

nonisolated struct DiffHunk: Equatable, Sendable, Identifiable {
    let id: Int
    /// The text after the second `@@`, usually the enclosing function or type.
    let context: String
    var lines: [DiffLine]

    /// Pairs removed and added lines side by side, the way a split diff shows them.
    var splitRows: [SplitRow] {
        var rows: [SplitRow] = []
        var removed: [DiffLine] = []
        var added: [DiffLine] = []
        func flush() {
            for index in 0..<max(removed.count, added.count) {
                rows.append(SplitRow(
                    id: rows.count,
                    left: index < removed.count ? removed[index] : nil,
                    right: index < added.count ? added[index] : nil
                ))
            }
            removed.removeAll()
            added.removeAll()
        }
        for line in lines {
            switch line.kind {
            case .removed: removed.append(line)
            case .added: added.append(line)
            case .context:
                flush()
                rows.append(SplitRow(id: rows.count, left: line, right: line))
            }
        }
        flush()
        return rows
    }
}

nonisolated struct DiffLine: Equatable, Sendable, Identifiable {
    enum Kind: Sendable { case context, added, removed }

    let id: Int
    let kind: Kind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
    /// "\ No newline at end of file" followed this line.
    var missingNewline = false
}

nonisolated struct SplitRow: Equatable, Sendable, Identifiable {
    let id: Int
    let left: DiffLine?
    let right: DiffLine?

    /// The part of each side that differs, for word-level highlighting of a changed line.
    var changedRanges: (left: Range<String.Index>, right: Range<String.Index>)? {
        guard let left, let right, left.kind == .removed, right.kind == .added else { return nil }
        return DiffParser.changedRanges(left.text, right.text)
    }

    static func == (lhs: SplitRow, rhs: SplitRow) -> Bool {
        lhs.id == rhs.id && lhs.left == rhs.left && lhs.right == rhs.right
    }
}

nonisolated enum DiffParser {
    static func parse(_ text: String) -> FileDiff {
        var diff = FileDiff()
        var current: DiffHunk?
        var oldLine = 0
        var newLine = 0
        var lineID = 0

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                if let current { diff.hunks.append(current) }
                let (old, new, context) = parseHeader(line)
                oldLine = old
                newLine = new
                current = DiffHunk(id: diff.hunks.count, context: context, lines: [])
                continue
            }
            guard current != nil else {
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { diff.isBinary = true }
                continue
            }
            guard let marker = line.first else { continue }
            let body = String(line.dropFirst())
            switch marker {
            case "+":
                current?.lines.append(DiffLine(id: lineID, kind: .added, text: body, oldNumber: nil, newNumber: newLine))
                newLine += 1
            case "-":
                current?.lines.append(DiffLine(id: lineID, kind: .removed, text: body, oldNumber: oldLine, newNumber: nil))
                oldLine += 1
            case " ":
                current?.lines.append(DiffLine(id: lineID, kind: .context, text: body, oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            case "\\":
                if let last = current?.lines.indices.last { current?.lines[last].missingNewline = true }
            default:
                continue
            }
            lineID += 1
        }
        if let current { diff.hunks.append(current) }
        return diff
    }

    /// `@@ -12,7 +12,9 @@ func render()` → (12, 12, "func render()").
    static func parseHeader(_ line: String) -> (old: Int, new: Int, context: String) {
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        func start(_ part: Substring?) -> Int {
            guard let part else { return 0 }
            return Int(part.dropFirst().split(separator: ",").first ?? "") ?? 0
        }
        let old = parts.count > 1 ? start(parts[1]) : 0
        let new = parts.count > 2 ? start(parts[2]) : 0
        var context = ""
        if let close = line.range(of: "@@", range: line.index(line.startIndex, offsetBy: 2)..<line.endIndex) {
            context = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        return (old, new, context)
    }

    /// The middle of two lines once their common prefix and suffix are removed.
    static func changedRanges(_ old: String, _ new: String) -> (left: Range<String.Index>, right: Range<String.Index>)? {
        let a = Array(old)
        let b = Array(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        // Nothing in common means the whole line changed; highlighting all of it adds nothing.
        guard prefix + suffix > 0 else { return nil }
        let left = old.index(old.startIndex, offsetBy: prefix)..<old.index(old.endIndex, offsetBy: -suffix)
        let right = new.index(new.startIndex, offsetBy: prefix)..<new.index(new.endIndex, offsetBy: -suffix)
        return (left, right)
    }
}
