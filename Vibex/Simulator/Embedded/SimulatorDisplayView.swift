import AppKit
import IOSurface
import QuartzCore

/// Draws a simulator's framebuffer and turns mouse and keyboard input into touches and key events.
final class SimulatorDisplayView: NSView {
    var screenSize: CGSize = CGSize(width: 1179, height: 2556) {
        didSet { needsLayout = true }
    }
    var input: SimulatorInput?
    var isPaused = false

    private let screenLayer = CALayer()
    private var surface: IOSurface?
    private var screenRect: CGRect = .zero
    private var isTouching = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        screenLayer.contentsGravity = .resize
        screenLayer.minificationFilter = .trilinear
        screenLayer.magnificationFilter = .linear
        screenLayer.backgroundColor = NSColor.black.cgColor
        screenLayer.masksToBounds = true
        screenLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull()]
        screenLayer.isHidden = true
        layer?.addSublayer(screenLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    // MARK: - Surface

    func setSurface(_ newSurface: IOSurface?) {
        surface = newSurface
        screenLayer.contents = newSurface
        // No device: hide the black screen so the empty state stands alone.
        screenLayer.isHidden = newSurface == nil
        if let newSurface {
            screenSize = CGSize(width: IOSurfaceGetWidth(newSurface), height: IOSurfaceGetHeight(newSurface))
        }
    }

    /// Called once per main-loop pass when the guest rendered a frame. Re-assigning the contents is
    /// how CoreAnimation learns the surface changed; it is zero-copy.
    func frameDidRender() {
        guard !isPaused, let surface, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        screenLayer.contents = nil
        screenLayer.contents = surface
    }

    override func layout() {
        super.layout()
        screenRect = SimulatorDisplayGeometry.fitRect(screen: screenSize, in: bounds, inset: 8)
        screenLayer.frame = screenRect
        // iPhone screens are ~13% of their width in corner radius; the masked surface already has
        // transparent corners, so this only matters as a safety net.
        screenLayer.cornerRadius = (screenRect.width * 0.13).rounded()
        screenLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard window?.firstResponder === self, !screenRect.isEmpty else { return }
        let ring = NSBezierPath(roundedRect: screenRect.insetBy(dx: -3, dy: -3), xRadius: screenLayer.cornerRadius + 3, yRadius: screenLayer.cornerRadius + 3)
        ring.lineWidth = 2
        NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
        ring.stroke()
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    // MARK: - Mouse → touch

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard screenRect.contains(point) else { return }
        isTouching = true
        input?.touch(ratio: SimulatorDisplayGeometry.ratio(for: point, in: screenRect), down: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTouching else { return }
        let point = convert(event.locationInWindow, from: nil)
        input?.touch(ratio: SimulatorDisplayGeometry.ratio(for: point, in: screenRect), down: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard isTouching else { return }
        isTouching = false
        let point = convert(event.locationInWindow, from: nil)
        input?.touch(ratio: SimulatorDisplayGeometry.ratio(for: point, in: screenRect), down: false)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        input?.key(event)
    }

    override func keyUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyUp(with: event)
            return
        }
        input?.key(event)
    }

    override func flagsChanged(with event: NSEvent) {
        input?.key(event)
    }
}
