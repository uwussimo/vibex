import AppKit

/// Thin hairline dividers that read correctly next to the terminal, the transparent slot and the video.
final class WorkspaceSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 1 }
    override var dividerColor: NSColor { NSColor.separatorColor.withAlphaComponent(0.6) }
}
