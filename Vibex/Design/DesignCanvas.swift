import AppKit
import Observation
import SwiftUI

/// Where the canvas is looking.
@Observable
final class DesignCanvasModel {
    static let zoomRange: ClosedRange<Double> = 0.05...4

    private(set) var zoom = 0.5
    private(set) var offset = CGSize(width: 60, height: 80)
    var viewport = CGSize.zero
    var contentSize = CGSize.zero
    /// Width taken by the panels floating over each side, so fitting keeps everything in the clear.
    var leadingInset = 0.0
    var trailingInset = 0.0
    /// True once the user has moved around, so new screens stop re-framing the view.
    private(set) var hasMoved = false

    func pan(by delta: CGSize) {
        offset.width += delta.width
        offset.height += delta.height
        hasMoved = true
    }

    /// Keeps the point under `anchor` where it is, as maps and Figma do.
    func zoom(by factor: Double, around anchor: CGPoint) {
        let new = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let applied = new / zoom
        offset.width = anchor.x - (anchor.x - offset.width) * applied
        offset.height = anchor.y - (anchor.y - offset.height) * applied
        zoom = new
        hasMoved = true
    }

    func zoomFromCenter(by factor: Double) {
        zoom(by: factor, around: CGPoint(x: viewport.width / 2, y: viewport.height / 2))
    }

    /// Shows everything, leaving room for the toolbar and zoom controls.
    func fit(animated: Bool = true) {
        guard contentSize.width > 0, contentSize.height > 0, viewport.width > 0, viewport.height > 0 else { return }
        let margin = 48.0, top = 64.0
        let available = max(viewport.width - leadingInset - trailingInset, 200)
        let scale = min((available - margin * 2) / contentSize.width, (viewport.height - top - margin) / contentSize.height)
        let new = min(max(scale, Self.zoomRange.lowerBound), 1)
        let apply = { [self] in
            zoom = new
            offset = CGSize(width: leadingInset + max((available - contentSize.width * new) / 2, margin), height: top)
        }
        if animated { withAnimation(.spring(response: 0.4, dampingFraction: 1), apply) } else { apply() }
        hasMoved = false
    }
}

/// Takes the trackpad before SwiftUI can: two fingers pan, a pinch or ⌘-scroll zooms.
final class DesignCanvasHostView<Content: View>: NSHostingView<Content> {
    var canvas: DesignCanvasModel?
    var design: DesignModel?
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }

    /// A click on the canvas picks what's under it, even as the click that brings the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Keys act on the selection only once the canvas was clicked, so typing elsewhere is never taken.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            // Local monitors run on the main thread, with an event that's only ever used there.
            nonisolated(unsafe) let event = event
            nonisolated(unsafe) var result: NSEvent? = event
            MainActor.assumeIsolated {
                if let self { result = self.handle(event) }
            }
            return result
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return event }
        if event.type == .leftMouseDown {
            if bounds.contains(convert(event.locationInWindow, from: nil)), let superview, hitTest(superview.convert(event.locationInWindow, from: nil)) != nil {
                window.makeFirstResponder(self)
            }
            return event
        }
        guard window.firstResponder === self, let design else { return event }
        let command = event.modifierFlags.contains(.command), shift = event.modifierFlags.contains(.shift)
        switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased()) {
        case (_, "z") where command:
            if shift { design.redo() } else { design.undo() }
        case (_, "d") where command:
            design.duplicateSelected()
        case (51, _), (117, _):
            design.deleteSelected()
        case (53, _):
            design.selectParent()
        default:
            return event
        }
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard let canvas else { return super.scrollWheel(with: event) }
        if event.modifierFlags.contains(.command) {
            canvas.zoom(by: 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.05), around: flipped(event))
        } else {
            canvas.pan(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
        }
    }

    override func magnify(with event: NSEvent) {
        guard let canvas else { return super.magnify(with: event) }
        canvas.zoom(by: 1 + event.magnification, around: flipped(event))
    }

    private func flipped(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y)
    }
}

/// Puts the canvas in that hosting view.
struct DesignCanvasContainer: NSViewRepresentable {
    let model: DesignModel

    func makeNSView(context: Context) -> NSView {
        let host = DesignCanvasHostView(rootView: DesignCanvasSurface(model: model))
        host.canvas = model.canvas
        host.design = model
        host.sizingOptions = []
        return host
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// The endless board: every screen, on dots, moved around by the trackpad or by dragging.
struct DesignCanvasSurface: View {
    let model: DesignModel
    @State private var lastDrag = CGSize.zero

    private var canvas: DesignCanvasModel { model.canvas }

    var body: some View {
        // An overlay, so the board can be any size without the canvas growing to match it.
        DesignDots(zoom: canvas.zoom, offset: canvas.offset)
            .contentShape(Rectangle())
            .onTapGesture { model.select(nil) }
            .overlay(alignment: .topLeading) {
                DesignBoard(model: model)
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self, of: \.size) { size in
                        canvas.contentSize = size
                        if !canvas.hasMoved { canvas.fit() }
                    }
                    .scaleEffect(canvas.zoom, anchor: .topLeading)
                    .offset(canvas.offset)
            }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    canvas.pan(by: CGSize(width: value.translation.width - lastDrag.width, height: value.translation.height - lastDrag.height))
                    lastDrag = value.translation
                }
                .onEnded { _ in lastDrag = .zero }
        )
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            canvas.viewport = size
            if !canvas.hasMoved { canvas.fit(animated: false) }
        }
    }
}

private struct DesignDots: View {
    let zoom: Double
    let offset: CGSize

    var body: some View {
        Canvas { context, size in
            // Dots thin out as the board shrinks, so they never turn into noise.
            var spacing = 24 * zoom
            while spacing < 14 { spacing *= 2 }
            let startX = offset.width.truncatingRemainder(dividingBy: spacing)
            let startY = offset.height.truncatingRemainder(dividingBy: spacing)
            var dots = Path()
            var x = startX
            while x < size.width {
                var y = startY
                while y < size.height {
                    dots.addEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
                    y += spacing
                }
                x += spacing
            }
            context.fill(dots, with: .color(.white.opacity(0.09)))
        }
        .background(Theme.background)
    }
}

/// Screens in rows by group, in file order.
struct DesignBoard: View {
    let model: DesignModel

    var body: some View {
        let document = model.document
        let theme = DesignTheme(document: document)
        VStack(alignment: .leading, spacing: 110) {
            if !document.kit.isEmpty { DesignKitBoard(document: document, theme: theme, model: model) }
            ForEach(Self.rows(document.screens), id: \.title) { row in
                VStack(alignment: .leading, spacing: 34) {
                    if !row.title.isEmpty {
                        Text(row.title)
                            .font(.vibex(size: 26, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                    }
                    HStack(alignment: .top, spacing: 84) {
                        ForEach(row.screens) { screen in
                            DesignFrame(screen: screen, theme: theme, model: model, isSelected: model.selection == screen.id && model.element == nil, select: { model.select(screen.id) }, fix: { model.fix(screen) })
                                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        }
                    }
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 1), value: document.screens.map(\.id))
    }

    struct Row { var title: String; var screens: [DesignScreen] }

    /// Groups keep the order they first appear in.
    nonisolated static func rows(_ screens: [DesignScreen]) -> [Row] {
        var rows: [Row] = []
        for screen in screens {
            let title = screen.group ?? ""
            if let index = rows.firstIndex(where: { $0.title == title }) {
                rows[index].screens.append(screen)
            } else {
                rows.append(Row(title: title, screens: [screen]))
            }
        }
        return rows
    }
}

/// One screen with its name above it. A click selects it, so the next message is about it.
private struct DesignFrame: View {
    let screen: DesignScreen
    let theme: DesignTheme
    let model: DesignModel
    let isSelected: Bool
    let select: () -> Void
    let fix: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(screen.name)
                .font(.vibex(size: 19, weight: .medium))
                .foregroundStyle(isSelected ? Theme.accent : Theme.muted)
                .lineLimit(1)
            Group {
                if let error = screen.error {
                    failure(error)
                } else {
                    DesignScreenView(screen: screen, theme: theme)
                        .environment(\.designEditing, DesignEditing(model: model, screen: screen.id))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius + 5, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 4)
                    .padding(-5)
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
        }
    }

    private var cornerRadius: CGFloat {
        switch screen.device.chrome {
        case .phone: 56
        case .tablet: 30
        case .android: 38
        case .browser: 12
        case .none: 8
        }
    }

    /// One bad file stays one bad frame, with the way out next to it.
    private func failure(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            IconView(.alert, size: 26).foregroundStyle(Theme.red)
            Text("This screen didn't load").font(.vibex(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
            Text(error).font(.vibex(size: 15)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Button("Ask Claude to Fix It", action: fix).buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(width: 393, alignment: .leading)
        .frame(minHeight: 300, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.red.opacity(0.4)))
    }
}

/// Screens as images, for Claude to look at its own work and for the user to copy.
enum DesignSnapshot {
    /// One screen, or the whole board when `screen` is nil. Waits for pictures first.
    static func image(of document: DesignDocument, screen: String? = nil, scale: CGFloat = 2) async -> NSImage? {
        await DesignImageStore.shared.preload(document)
        let theme = DesignTheme(document: document)
        let renderer: ImageRenderer<AnyView>
        if screen?.lowercased() == "kit" {
            renderer = ImageRenderer(content: AnyView(DesignKitBoard(document: document, theme: theme, model: nil).padding(30).background(Theme.background).fixedSize()))
        } else if let screen, let found = document.screens.first(where: { $0.id == screen || $0.name.lowercased() == screen.lowercased() }) {
            renderer = ImageRenderer(content: AnyView(DesignScreenView(screen: found, theme: theme).padding(16).background(Theme.background).fixedSize()))
        } else {
            renderer = ImageRenderer(content: AnyView(
                HStack(alignment: .top, spacing: 40) {
                    ForEach(document.screens.filter { $0.error == nil }) { DesignScreenView(screen: $0, theme: theme) }
                }
                .padding(30).background(Theme.background).fixedSize()
            ))
        }
        renderer.scale = scale
        return renderer.nsImage
    }

    static func jpeg(_ image: NSImage, maxWidth: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ratio = min(maxWidth / CGFloat(cg.width), 1)
        let width = Int(CGFloat(cg.width) * ratio), height = Int(CGFloat(cg.height) * ratio)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
