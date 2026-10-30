import SwiftUI

/// A Markdown document split into blocks for reading: front matter, headings, paragraphs, lists,
/// code, quotes, tables and rules. Inline styling (bold, code, links) is left to AttributedString.
nonisolated struct MarkdownDocument: Equatable, Sendable {
    enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        /// One item per entry; `depth` counts indentation, `marker` is "•", "1." or a checkbox.
        case list([ListItem])
        case code(language: String?, text: String)
        case quote(String)
        case table(header: [String], rows: [[String]])
        case rule
    }

    struct ListItem: Equatable, Sendable {
        var depth: Int
        var marker: String
        var text: String
    }

    /// The YAML header of a skill or post (`name`, `description`, …), in file order.
    var frontMatter: [(key: String, value: String)]
    var blocks: [Block]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.blocks == rhs.blocks && lhs.frontMatter.map(\.key) == rhs.frontMatter.map(\.key) && lhs.frontMatter.map(\.value) == rhs.frontMatter.map(\.value)
    }

    init(_ source: String) {
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        frontMatter = Self.takeFrontMatter(&lines)
        blocks = Self.parse(lines)
    }

    private static func takeFrontMatter(_ lines: inout [String]) -> [(key: String, value: String)] {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return [] }
        var pairs: [(key: String, value: String)] = []
        for line in lines[1..<end] {
            if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" { value = String(value.dropFirst().dropLast()) }
                pairs.append((key, value))
            } else if let last = pairs.indices.last {
                // A folded value continues on the next indented lines.
                let more = line.trimmingCharacters(in: .whitespaces)
                guard !more.isEmpty else { continue }
                let current = pairs[last].value
                pairs[last].value = ["", ">", "|", ">-", "|-"].contains(current) ? more : current + " " + more
            }
        }
        lines.removeSubrange(0...end)
        return pairs.map { ($0.key, [">", "|", ">-", "|-"].contains($0.value) ? "" : $0.value) }
    }

    private static func parse(_ lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            // Fenced code
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: code.joined(separator: "\n")))
                i += 1
                continue
            }

            // Headings
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level <= 6, trimmed.dropFirst(level).first == " " {
                    flushParagraph()
                    blocks.append(.heading(level: level, text: trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)))
                    i += 1
                    continue
                }
            }

            // Rules
            if ["---", "***", "___"].contains(where: { trimmed.replacingOccurrences(of: " ", with: "").hasPrefix($0) && Set(trimmed.replacingOccurrences(of: " ", with: "")).count == 1 }), trimmed.count >= 3 {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            // Quotes
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quote.joined(separator: " ")))
                continue
            }

            // Tables: a header row, then a |---| separator.
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // Lists
            if listItem(line) != nil {
                flushParagraph()
                var items: [ListItem] = []
                while i < lines.count {
                    if let item = listItem(lines[i]) {
                        items.append(item)
                    } else if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, lines[i].hasPrefix("  "), !items.isEmpty {
                        // A wrapped line belongs to the item above.
                        items[items.count - 1].text += " " + lines[i].trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.list(items))
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop(while: { $0 == " " || $0 == "\t" })
        var marker: String
        var text: Substring
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            marker = "•"
            text = rest.dropFirst(2)
        } else {
            let digits = rest.prefix(while: \.isNumber)
            guard !digits.isEmpty, digits.count < 4 else { return nil }
            let after = rest.dropFirst(digits.count)
            guard let dot = after.first, dot == "." || dot == ")", after.dropFirst().first == " " else { return nil }
            marker = "\(digits)."
            text = after.dropFirst(2)
        }
        if text.hasPrefix("[ ] ") { marker = "☐"; text = text.dropFirst(4) }
        else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { marker = "☑"; text = text.dropFirst(4) }
        return ListItem(depth: indent / 2, marker: marker, text: String(text))
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.contains("-") && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ row: String) -> [String] {
        var row = row
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// A rendered Markdown document, sized for reading.
struct MarkdownView: View {
    let document: MarkdownDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !document.frontMatter.isEmpty { frontMatter }
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: 760, alignment: .leading)
    }

    /// A skill's name and description read like a title card, the rest as quiet key/value rows.
    private var frontMatter: some View {
        let pairs = document.frontMatter
        let name = pairs.first { $0.key == "name" }?.value
        let description = pairs.first { $0.key == "description" }?.value
        let others = pairs.filter { $0.key != "name" && $0.key != "description" && !$0.value.isEmpty }
        return VStack(alignment: .leading, spacing: 8) {
            if let name { Text(name).font(.vibex(size: 22, weight: .semibold)).foregroundStyle(Theme.text) }
            if let description { Text(inline(description)).font(.vibex(size: 14)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(others.enumerated()), id: \.offset) { _, pair in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(pair.key).font(.vibexCode(size: 11.5)).foregroundStyle(Theme.faint).frame(minWidth: 90, alignment: .leading)
                            Text(pair.value).font(.vibexCode(size: 11.5)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(fill: Theme.card, radius: 12)
    }

    @ViewBuilder
    private func view(for block: MarkdownDocument.Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(.vibex(size: [26, 21, 17, 15, 14, 13][min(level, 6) - 1], weight: level <= 2 ? .semibold : .semibold))
                .foregroundStyle(Theme.text)
                .padding(.top, level <= 2 ? 10 : 4)
            if level <= 2 { Rectangle().fill(Theme.line).frame(height: 1) }
        case let .paragraph(text):
            Text(inline(text)).font(.vibex(size: 14)).foregroundStyle(Theme.text.opacity(0.9)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        case let .list(items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .font(.vibex(size: item.marker.count > 1 && item.marker != "☐" && item.marker != "☑" ? 13 : 14))
                            .foregroundStyle(item.marker == "☑" ? Theme.green : Theme.faint)
                            .monospacedDigit()
                            .frame(minWidth: 16, alignment: .trailing)
                        Text(inline(item.text)).font(.vibex(size: 14)).foregroundStyle(Theme.text.opacity(0.9)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
        case let .code(language, text):
            CodeBlock(language: language, text: text)
        case let .quote(text):
            Text(inline(text))
                .font(.vibex(size: 14))
                .foregroundStyle(Theme.muted)
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.accent.opacity(0.6)).frame(width: 3) }
                .fixedSize(horizontal: false, vertical: true)
        case let .table(header, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell)).font(.vibex(size: 12.5, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 7)
                        }
                    }
                    .background(Theme.raised)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(inline(cell)).font(.vibex(size: 12.5)).foregroundStyle(Theme.text.opacity(0.9)).padding(.horizontal, 10).padding(.vertical, 6)
                            }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        case .rule:
            Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        var attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .vibexCode(size: 12.5)
            attributed[run.range].foregroundColor = Theme.pink
            attributed[run.range].backgroundColor = Theme.raised
        }
        // The app's font doesn't pick up Markdown's bold or italic by itself.
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            attributed[run.range].font = .vibex(size: 14, weight: .semibold)
            attributed[run.range].foregroundColor = Theme.text
        }
        for run in attributed.runs where run.link != nil {
            attributed[run.range].foregroundColor = Theme.accent
        }
        return attributed
    }
}

/// A fenced code block, highlighted when the language is known.
private struct CodeBlock: View {
    let language: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language {
                HStack {
                    Text(language).font(.vibexCode(size: 11)).foregroundStyle(Theme.faint)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: { IconView(.copy, size: 12).foregroundStyle(Theme.muted) }
                        .buttonStyle(.plain)
                        .help("Copy")
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlighted).font(.vibexCode(size: 12.5)).lineSpacing(2).padding(12).fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: 0x101014)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
    }

    private var highlighted: AttributedString {
        let lang = language.flatMap { Language.forPath("x.\(Self.extensionFor($0))") }
        guard let lang else { return AttributedString(text) }
        return CodeHighlight.attributed(text, language: lang)
    }

    private static func extensionFor(_ language: String) -> String {
        switch language.lowercased() {
        case "javascript": "js"
        case "typescript": "ts"
        case "python": "py"
        case "bash", "shell", "console", "zsh": "sh"
        case "rust": "rs"
        case "golang": "go"
        case "ruby": "rb"
        case "kotlin": "kt"
        case "yml": "yaml"
        default: language.lowercased()
        }
    }
}

/// Whole-text highlighting with the diff view's tokenizer, line by line.
enum CodeHighlight {
    static func attributed(_ text: String, language: Language) -> AttributedString {
        let highlighter = SyntaxHighlighter(language: language)
        var state = SyntaxHighlighter.State()
        var result = AttributedString()
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            var piece = AttributedString(line)
            let utf16 = Array(line.utf16)
            for span in highlighter.spans(for: line, state: &state) {
                guard span.start + span.length <= utf16.count else { continue }
                let lower = String(decoding: utf16[0..<span.start], as: UTF16.self).count
                let length = String(decoding: utf16[span.start..<span.start + span.length], as: UTF16.self).count
                let start = piece.index(piece.startIndex, offsetByCharacters: lower)
                let end = piece.index(start, offsetByCharacters: length)
                piece[start..<end].foregroundColor = SyntaxPalette.color(span.token)
            }
            result += piece
            if index < lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }
}
