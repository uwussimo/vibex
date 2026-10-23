import AppKit
import SwiftUI

/// The selected file's changes, split (old | new) or unified, with line numbers and word-level
/// highlights on edited lines. Floats over the simulator and browser; Esc closes it.
struct DiffView: View {
    @Bindable var model: SourceControlModel
    let close: () -> Void

    /// Beyond this many rows the diff renders on request, so a huge lockfile can't stall the UI.
    private static let rowBudget = 4000
    /// Narrower than this, side by side wraps every line; show the diff inline instead, like VS Code.
    static let splitMinimumWidth: CGFloat = 760
    @State private var showEverything = false
    @State private var width: CGFloat = 1000
    /// A narrow area keeps the file name readable by dropping the stats and the layout picker.
    private var isCompact: Bool { width < 600 }

    var body: some View {
        VStack(spacing: 0) {
            if let change = model.selection {
                header(change)
                Divider()
                content(change)
            }
        }
        .background(Theme.background)
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onChange(of: model.selection?.path) { showEverything = false }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    // MARK: - Header

    private func header(_ change: GitChange) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(change.fileName)
                        .font(.vibex(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(change.kind.label)
                        .font(.vibex(size: 10.5, weight: .semibold))
                        .fixedSize()
                        .foregroundStyle(change.kind.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(change.kind.color.opacity(0.14)))
                    if change.area == .staged {
                        Text("Staged")
                            .font(.vibex(size: 10.5, weight: .semibold))
                            .fixedSize()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                Text(change.originalPath.map { "\($0) → \(change.path)" } ?? change.path)
                    .font(.vibex(size: 11))
                    .layoutPriority(-1)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if !isCompact, let diff = model.diff, !diff.isBinary {
                HStack(spacing: 6) {
                    Text("+\(diff.additions)").foregroundStyle(DiffPalette.addedText)
                    Text("−\(diff.deletions)").foregroundStyle(DiffPalette.removedText)
                }
                .font(.vibexCode(size: 12, weight: .semibold))
            }
            if !isCompact {
            Picker("Layout", selection: $model.diffStyle) {
                Image(systemName: "rectangle.split.2x1").help("Side by Side").tag(SourceControlModel.DiffStyle.split)
                Image(systemName: "rectangle").help("Unified").tag(SourceControlModel.DiffStyle.unified)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Side by side needs at least \(Int(Self.splitMinimumWidth)) points; narrower diffs show inline.")
            }
            ToolbarIconButton(icon: .chevronUp, help: "Previous Change (⌥⌘↑)", isEnabled: neighbor(-1)) { model.selectAdjacent(-1) }
            ToolbarIconButton(icon: .chevronDown, help: "Next Change (⌥⌘↓)", isEnabled: neighbor(1)) { model.selectAdjacent(1) }
            ToolbarIconButton(icon: .file, help: "Open File") {
                NSWorkspace.shared.open(model.folder.appendingPathComponent(change.path))
            }
            stageButton(change)
                .padding(.leading, 4)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 52)
    }

    /// The diff's one main action. It moves on to the next file in the same group afterwards.
    private func stageButton(_ change: GitChange) -> some View {
        let title = switch change.area {
        case .unstaged: "Stage"
        case .staged: "Unstage"
        case .conflicted: "Mark Resolved"
        }
        return Button { model.toggleStageAndAdvance(change) } label: {
            Text(title).font(.vibex(size: 12.5, weight: .medium))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(model.busy != nil)
        .help("\(title) and open the next change")
        .fixedSize()
    }

    private func neighbor(_ offset: Int) -> Bool {
        let all = model.orderedChanges
        guard let current = model.selection, let index = all.firstIndex(where: { $0.id == current.id }) else { return false }
        return all.indices.contains(index + offset)
    }

    // MARK: - Body

    @ViewBuilder
    private func content(_ change: GitChange) -> some View {
        if let diff = model.diff {
            if diff.isBinary {
                message(.package, "Binary file", "Vibex can't show changes inside binary files.")
            } else if diff.isEmpty {
                message(.info, "No text changes", change.kind == .renamed ? "The file was renamed without edits." : "Only the file mode or whitespace changed.")
            } else {
                GeometryReader { geometry in
                let style = geometry.size.width < Self.splitMinimumWidth ? .unified : model.diffStyle
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if diff.isTruncated {
                            banner("This diff is very large; only the beginning is shown.")
                        }
                        ForEach(visibleHunks(diff)) { hunk in
                            HunkHeader(hunk: hunk)
                            switch style {
                            case .split:
                                ForEach(hunk.splitRows) { SplitRowView(row: $0, spans: model.highlights) }
                            case .unified:
                                ForEach(hunk.lines) { UnifiedRowView(line: $0, spans: model.highlights[$0.id] ?? []) }
                            }
                        }
                        if !showEverything, rowCount(diff) > Self.rowBudget {
                            Button("Show All \(rowCount(diff)) Lines") { showEverything = true }
                                .font(.vibex(size: 12.5, weight: .medium))
                                .padding(16)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.automatic)
                }
            }
        } else if model.isDiffLoading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }

    private func rowCount(_ diff: FileDiff) -> Int { diff.hunks.reduce(0) { $0 + $1.lines.count } }

    private func visibleHunks(_ diff: FileDiff) -> [DiffHunk] {
        guard !showEverything else { return diff.hunks }
        var budget = Self.rowBudget
        var hunks: [DiffHunk] = []
        for hunk in diff.hunks where budget > 0 {
            hunks.append(hunk)
            budget -= hunk.lines.count
        }
        return hunks
    }

    private func message(_ icon: Icon, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            IconView(icon, size: 26)
                .foregroundStyle(Theme.faint)
            Text(title).font(.vibex(size: 13.5, weight: .medium))
            Text(detail).font(.vibex(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func banner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.vibex(size: 12))
            .foregroundStyle(.orange)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1))
    }
}

// MARK: - Rows

enum DiffPalette {
    static let added = Color(nsColor: .systemGreen).opacity(0.13)
    static let removed = Color(nsColor: .systemRed).opacity(0.13)
    static let addedWord = Color(nsColor: .systemGreen).opacity(0.34)
    static let removedWord = Color(nsColor: .systemRed).opacity(0.34)
    static let addedText = Color(nsColor: .systemGreen)
    static let removedText = Color(nsColor: .systemRed)
    static let filler = Color.primary.opacity(0.03)
    static let gutter = Color.primary.opacity(0.025)
    static let codeSize: CGFloat = 12
}

private struct HunkHeader: View {
    let hunk: DiffHunk

    var body: some View {
        HStack(spacing: 8) {
            IconView(.dots, size: 11.5)
                .foregroundStyle(.tertiary)
            Text(hunk.context.isEmpty ? "Line \(hunk.lines.first?.newNumber ?? hunk.lines.first?.oldNumber ?? 1)" : hunk.context)
                .font(.vibexCode(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color.accentColor.opacity(0.07))
    }
}

private struct SplitRowView: View {
    let row: SplitRow
    let spans: [Int: [SyntaxSpan]]

    var body: some View {
        let ranges = row.changedRanges
        HStack(spacing: 0) {
            side(row.left, number: row.left?.oldNumber, highlight: ranges?.left, isLeft: true)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
            side(row.right, number: row.right?.newNumber, highlight: ranges?.right, isLeft: false)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func side(_ line: DiffLine?, number: Int?, highlight: Range<String.Index>?, isLeft: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            LineNumber(number: number)
            if let line {
                CodeText(line: line, highlight: highlight, spans: spans[line.id] ?? [])
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background(line))
    }

    private func background(_ line: DiffLine?) -> Color {
        switch line?.kind {
        case .added: DiffPalette.added
        case .removed: DiffPalette.removed
        case .context: .clear
        case nil: DiffPalette.filler
        }
    }
}

private struct UnifiedRowView: View {
    let line: DiffLine
    let spans: [SyntaxSpan]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            LineNumber(number: line.oldNumber)
            LineNumber(number: line.newNumber)
            Text(marker)
                .font(.vibexCode(size: DiffPalette.codeSize, weight: .semibold))
                .foregroundStyle(markerColor)
                .frame(width: 16)
                .padding(.vertical, 1.5)
            CodeText(line: line, highlight: nil, spans: spans)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(background)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context: ""
        }
    }

    private var markerColor: Color {
        line.kind == .added ? DiffPalette.addedText : DiffPalette.removedText
    }

    private var background: Color {
        switch line.kind {
        case .added: DiffPalette.added
        case .removed: DiffPalette.removed
        case .context: .clear
        }
    }
}

private struct LineNumber: View {
    let number: Int?

    var body: some View {
        Text(number.map(String.init) ?? "")
            .font(.vibexCode(size: 11))
            .foregroundStyle(.tertiary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 8)
            .padding(.vertical, 1.5)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(DiffPalette.gutter)
    }
}

private struct CodeText: View {
    let line: DiffLine
    let highlight: Range<String.Index>?
    let spans: [SyntaxSpan]

    var body: some View {
        Text(attributed)
            .font(.vibexCode(size: DiffPalette.codeSize))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 1.5)
    }

    private var attributed: AttributedString {
        let raw = line.text
        guard !raw.isEmpty else { return AttributedString(" ") }
        // Tabs display as four spaces; every UTF-16 offset into the raw line moves by 3 per tab before it.
        let units = Array(raw.utf16)
        var shift = [Int](repeating: 0, count: units.count + 1)
        for index in units.indices { shift[index + 1] = shift[index] + (units[index] == 0x09 ? 3 : 0) }
        let text = raw.replacingOccurrences(of: "\t", with: "    ")
        var string = AttributedString(text)

        func range(_ start: Int, _ end: Int) -> Range<AttributedString.Index>? {
            let start = min(start, units.count), end = min(end, units.count)
            guard end > start else { return nil }
            let lower = String.Index(utf16Offset: start + shift[start], in: text)
            let upper = String.Index(utf16Offset: end + shift[end], in: text)
            return Range(lower..<upper, in: string)
        }

        for span in spans {
            if let range = range(span.start, span.start + span.length) {
                string[range].foregroundColor = SyntaxPalette.color(span.token)
            }
        }
        if let highlight, !highlight.isEmpty {
            let start = highlight.lowerBound.utf16Offset(in: raw)
            let end = highlight.upperBound.utf16Offset(in: raw)
            if let range = range(start, end) {
                string[range].backgroundColor = line.kind == .added ? DiffPalette.addedWord : DiffPalette.removedWord
            }
        }
        if line.missingNewline {
            var marker = AttributedString("  no newline at end of file")
            marker.foregroundColor = .secondary
            string += marker
        }
        return string
    }
}
