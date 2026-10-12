import CoreGraphics

/// Where the device screen sits inside the view, and how view points map to screen ratios.
nonisolated enum SimulatorDisplayGeometry {
    /// Aspect-fits `screen` (any unit) into `container` (view coordinates), centered.
    static func fitRect(screen: CGSize, in container: CGRect, inset: CGFloat = 0) -> CGRect {
        let box = container.insetBy(dx: inset, dy: inset)
        guard screen.width > 0, screen.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let scale = min(box.width / screen.width, box.height / screen.height)
        let size = CGSize(width: (screen.width * scale).rounded(), height: (screen.height * scale).rounded())
        return CGRect(
            x: (box.midX - size.width / 2).rounded(),
            y: (box.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }

    /// 0…1 ratio from the top-left of the screen for a point in a top-left-origin (flipped) view.
    static func ratio(for point: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGPoint(
            x: min(max((point.x - rect.minX) / rect.width, 0), 1),
            y: min(max((point.y - rect.minY) / rect.height, 0), 1)
        )
    }

    /// Column width that shows the screen at full height.
    static func preferredWidth(screen: CGSize, height: CGFloat, gutter: CGFloat, minimum: CGFloat) -> CGFloat {
        guard screen.height > 0, height > 0 else { return minimum }
        return max(minimum, (height * screen.width / screen.height + gutter * 2).rounded())
    }
}
