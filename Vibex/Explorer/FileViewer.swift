import AppKit
import Observation
import SwiftUI

/// Something the editor area can show as a file tab: a file in the project, or a skill's SKILL.md
/// fetched from GitHub before installing it.
nonisolated struct OpenDocument: Hashable, Sendable {
    /// The tab's identity: a file path, or "remote:owner/repo/skill".
    var id: String
    var title: String
    var file: URL?
    /// Tried in order until one loads.
    var remote: [URL] = []

    static func file(_ url: URL) -> OpenDocument {
        OpenDocument(id: url.standardizedFileURL.path, title: url.lastPathComponent, file: url.standardizedFileURL)
    }
}

/// What a file turned out to be once read.
nonisolated enum FileContent: Equatable, Sendable {
    case loading
    case text(String)
    case image(Data)
    case binary(Int)
    case tooLarge(Int)
    case missing(String)

    static let textLimit = 4_000_000

    @concurrent static func load(_ document: OpenDocument) async -> FileContent {
        if let file = document.file { return read(file) }
        for url in document.remote {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) {
                return .text(text)
            }
        }
        return .missing("Couldn't find this skill's SKILL.md on GitHub.")
    }

    static func read(_ url: URL) -> FileContent {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return .missing("This file no longer exists.")
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico", "icns", "pdf"].contains(ext) {
            return size < 30_000_000 ? ((try? Data(contentsOf: url)).map(FileContent.image) ?? .binary(size)) : .tooLarge(size)
        }
        guard size <= textLimit else { return .tooLarge(size) }
        guard let data = try? Data(contentsOf: url) else { return .missing("Vibex can't read this file.") }
        // A NUL byte early on means binary, like git decides.
        if data.prefix(8000).contains(0) { return .binary(size) }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return .binary(size) }
        return .text(text)
    }
}

/// One file tab: a header with the path and actions, then the code, the rendered Markdown, the image
/// or a note about why it can't be shown. Follows the file on disk, so Claude's edits appear live.
struct FileTabView: View {
    let document: OpenDocument
    let projectRoot: URL
    /// Opens another file in a tab (a skill's sibling files).
    let open: (URL) -> Void
    @State private var content: FileContent = .loading
    @State private var showSource = false
    @State private var watcher: FileWatcher?
    @State private var modified: Date?

    private var isMarkdown: Bool {
        let name = (document.file?.lastPathComponent ?? document.title).lowercased()
        return name.hasSuffix(".md") || name.hasSuffix(".markdown") || name.hasSuffix(".mdx") || document.file == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            contentView
        }
        .background(Theme.background)
        .task(id: document) { await reload(); watch() }
        .onDisappear { watcher?.stop(); watcher = nil }
    }

    private var header: some View {
        HStack(spacing: 8) {
            IconView(document.file == nil ? .globe : .fileCode, size: 13).foregroundStyle(Theme.faint)
            Text(breadcrumb)
                .font(.vibex(size: 12))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .truncationMode(.head)
                .help(document.file?.path ?? document.remote.first?.absoluteString ?? "")
            Spacer(minLength: 8)
            if isMarkdown, case .text = content {
                Picker("View", selection: $showSource) {
                    Text("Preview").tag(false)
                    Text("Source").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
            if let file = document.file {
                ToolbarIconButton(icon: .copy, help: "Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
                ToolbarIconButton(icon: .folder, help: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                ToolbarIconButton(icon: .external, help: "Open in Default App") { NSWorkspace.shared.open(file) }
            } else if let url = document.remote.first {
                ToolbarIconButton(icon: .external, help: "Open on GitHub") { NSWorkspace.shared.open(url) }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Theme.surface)
    }

    /// "Vibex › Support › Markdown.swift", relative to the project when it's inside it.
    private var breadcrumb: String {
        guard let file = document.file else { return document.title }
        let root = projectRoot.standardizedFileURL.path
        let path = file.path
        let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : (path as NSString).abbreviatingWithTildeInPath
        return relative.split(separator: "/").joined(separator: "  ›  ")
    }

    @ViewBuilder
    private var contentView: some View {
        switch content {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .text(text):
            if isMarkdown, !showSource {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let siblings = skillFiles, !siblings.isEmpty { siblingsBar(siblings) }
                        MarkdownView(document: MarkdownDocument(text))
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 26)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.automatic)
            } else {
                CodeView(text: text, language: Language.forPath(document.file?.path ?? "SKILL.md"))
            }
        case let .image(data):
            if let image = NSImage(data: data) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(maxWidth: min(image.size.width, 1400), maxHeight: min(image.size.height, 1400))
                        .padding(24)
                }
                .background(Theme.surface)
            } else {
                note(.image, "Vibex can't preview this image.")
            }
        case let .binary(size):
            note(.file, "A binary file (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))).", action: true)
        case let .tooLarge(size):
            note(.file, "Too large to show here (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))).", action: true)
        case let .missing(message):
            note(.alert, message)
        }
    }

    private func note(_ icon: Icon, _ message: String, action: Bool = false) -> some View {
        VStack(spacing: 10) {
            IconView(icon, size: 26).foregroundStyle(Theme.faint)
            Text(message).font(.vibex(size: 13)).foregroundStyle(Theme.muted)
            if action, let file = document.file {
                Button("Open in Default App") { NSWorkspace.shared.open(file) }.buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A skill is a folder: show its other files (scripts, references) above SKILL.md.
    private var skillFiles: [URL]? {
        guard let file = document.file, file.lastPathComponent == "SKILL.md" else { return nil }
        // Installed skills are often symlinks into .agents/skills; walk the real folder.
        let folder = file.deletingLastPathComponent().resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return nil }
        var files: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent != "SKILL.md" {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(url) }
            if files.count >= 30 { break }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func siblingsBar(_ files: [URL]) -> some View {
        let folder = document.file!.deletingLastPathComponent().resolvingSymlinksInPath().path
        return VStack(alignment: .leading, spacing: 8) {
            Text("FILES IN THIS SKILL").font(.vibex(size: 10.5, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.faint)
            FlowLayout(spacing: 6) {
                ForEach(files, id: \.self) { url in
                    Button { open(url) } label: {
                        HStack(spacing: 5) {
                            IconView(.fileCode, size: 12)
                            Text(String(url.path.dropFirst(folder.count + 1)))
                        }
                        .font(.vibexCode(size: 11.5))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.raised))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private func reload() async {
        content = await FileContent.load(document)
        if let file = document.file { modified = Self.modificationDate(file) }
    }

    /// FSEvents on the folder; reload only when this file's date actually changed.
    private func watch() {
        guard watcher == nil, let file = document.file else { return }
        watcher = FileWatcher(path: file.deletingLastPathComponent().path, latency: 0.25) {
            let date = Self.modificationDate(file)
            guard date != modified else { return }
            Task { await reload() }
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// Wraps tags onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Code

/// Read-only, selectable, searchable (⌘F) code with line numbers and syntax highlighting.
struct CodeView: NSViewRepresentable {
    let text: String
    let language: Language?

    /// Highlighting a huge file would stall the main thread for little gain.
    static let highlightLimit = 600_000

    func makeNSView(context: Context) -> CodeContainerView {
        let view = CodeContainerView()
        apply(to: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: CodeContainerView, context: Context) {
        apply(to: view, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: String?
    }

    private func apply(to view: CodeContainerView, coordinator: Coordinator) {
        guard coordinator.shown != text else { return }
        let textView = view.textView
        let keepScroll = coordinator.shown != nil ? view.scroll.contentView.bounds.origin : nil
        coordinator.shown = text
        let font = NSFont(name: "GoogleSansCode-Regular", size: 12.5) ?? .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.2
        let storage = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: Theme.NS.text, .paragraphStyle: paragraph,
        ])
        if let language, text.utf16.count <= Self.highlightLimit {
            let highlighter = SyntaxHighlighter(language: language)
            var state = SyntaxHighlighter.State()
            let ns = text as NSString
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
                let line = ns.substring(with: lineRange)
                for span in highlighter.spans(for: line, state: &state) where span.start + span.length <= lineRange.length {
                    storage.addAttribute(.foregroundColor, value: SyntaxPalette.nsColor(span.token), range: NSRange(location: lineRange.location + span.start, length: span.length))
                }
            }
        }
        textView.textStorage?.setAttributedString(storage)
        view.gutter.needsDisplay = true
        if let keepScroll { view.scroll.contentView.scroll(to: keepScroll) }
    }
}

/// A line-number gutter beside a scrolling text view. The gutter sits outside the scroll view, so it
/// stays put when the code scrolls sideways.
final class CodeContainerView: NSView {
    let scroll = NSScrollView()
    let textView = NSTextView(usingTextLayoutManager: false)
    let gutter = LineNumberGutter()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.NS.background
        textView.textContainerInset = NSSize(width: 6, height: 10)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.selectedTextAttributes = [.backgroundColor: Theme.NS.accent.withAlphaComponent(0.3)]

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.NS.background
        scroll.contentView.postsBoundsChangedNotifications = true
        gutter.textView = textView
        addSubview(gutter)
        addSubview(scroll)
        NotificationCenter.default.addObserver(gutter, selector: #selector(LineNumberGutter.refresh), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let lines = max(textView.string.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }, 100)
        let width = CGFloat(String(lines).count) * 7.5 + 22
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scroll.frame = NSRect(x: width, y: 0, width: max(bounds.width - width, 0), height: bounds.height)
        if textView.frame.width < scroll.contentSize.width || textView.frame.height < scroll.contentSize.height {
            textView.minSize = NSSize(width: scroll.contentSize.width, height: scroll.contentSize.height)
        }
    }
}

/// Draws the line numbers for the text view's visible lines.
final class LineNumberGutter: NSView {
    weak var textView: NSTextView?
    override var isFlipped: Bool { true }

    @objc func refresh() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.NS.background.setFill()
        bounds.fill()
        Theme.NS.line.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer,
              let clip = textView.enclosingScrollView?.contentView else { return }
        let text = textView.string as NSString
        guard text.length > 0 else { return }
        let font = NSFont(name: "GoogleSansCode-Regular", size: 11) ?? .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.NS.faint]
        let visible = clip.bounds
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // Count the lines above the visible part once, then walk the visible ones.
        var line = 1
        if characters.location > 0 {
            text.enumerateSubstrings(in: NSRange(location: 0, length: characters.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
            if text.character(at: characters.location - 1) != 10 { line -= 1 }
        }
        var index = characters.location
        let end = min(NSMaxRange(characters), text.length)
        repeat {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: lineRange.location)
            let fragment = layout.lineFragmentRect(forGlyphAt: min(glyph, max(layout.numberOfGlyphs - 1, 0)), effectiveRange: nil)
            let y = fragment.minY + textView.textContainerInset.height - visible.minY
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: bounds.width - size.width - 10, y: y + (fragment.height - size.height) / 2), withAttributes: attributes)
            line += 1
            index = NSMaxRange(lineRange)
        } while index < end
    }
}
