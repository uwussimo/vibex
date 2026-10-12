import Foundation

/// Subsequence fuzzy matching for the command palette: every query character must appear in order.
/// Matches at word starts and consecutive runs score higher, so "obt" ranks "Open Browser Tab" first.
nonisolated enum FuzzyMatch {
    struct Result: Equatable {
        let score: Int
        /// Indices into the candidate's characters, for highlighting.
        let positions: [Int]
    }

    static func match(_ query: String, in candidate: String) -> Result? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return Result(score: 0, positions: []) }
        let original = Array(candidate)
        let haystack = Array(candidate.lowercased())
        guard haystack.count == original.count else { return simpleMatch(needle, haystack) }

        var positions: [Int] = []
        var score = 0
        var searchFrom = 0
        var previous = -2
        for character in needle {
            // Prefer the next occurrence that starts a word; fall back to the next occurrence.
            var chosen: Int?
            var index = searchFrom
            while index < haystack.count {
                if haystack[index] == character {
                    if chosen == nil { chosen = index }
                    if isWordStart(original, index) { chosen = index; break }
                    if index == previous + 1 { chosen = index; break }
                }
                index += 1
            }
            guard let position = chosen else { return nil }
            score += 1
            if position == previous + 1 { score += 6 }
            if isWordStart(original, position) { score += 8 }
            if position == 0 { score += 4 }
            positions.append(position)
            previous = position
            searchFrom = position + 1
        }
        // Shorter candidates and earlier first matches win ties.
        score -= positions.first ?? 0
        score -= max(0, haystack.count - needle.count) / 8
        return Result(score: score, positions: positions)
    }

    private static func simpleMatch(_ needle: [Character], _ haystack: [Character]) -> Result? {
        var positions: [Int] = []
        var index = 0
        for character in needle {
            while index < haystack.count, haystack[index] != character { index += 1 }
            guard index < haystack.count else { return nil }
            positions.append(index)
            index += 1
        }
        return Result(score: 1, positions: positions)
    }

    private static func isWordStart(_ characters: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        let current = characters[index]
        if !previous.isLetter && !previous.isNumber { return true }
        return previous.isLowercase && current.isUppercase
    }

    /// Ranks candidates by score, keeping only matches. Stable for equal scores.
    static func rank<T>(_ items: [T], query: String, text: (T) -> String) -> [(item: T, result: Result)] {
        items.enumerated()
            .compactMap { offset, item in match(query, in: text(item)).map { (offset, item, $0) } }
            .sorted { $0.2.score != $1.2.score ? $0.2.score > $1.2.score : $0.0 < $1.0 }
            .map { ($0.1, $0.2) }
    }
}
