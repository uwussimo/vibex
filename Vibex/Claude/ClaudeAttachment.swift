import AppKit
import UniformTypeIdentifiers

/// Something added to the next message: an image Claude sees, or a file it gets the path of.
struct ClaudeAttachment: Identifiable, Equatable {
    nonisolated struct Image: Equatable, Sendable {
        var data: Data
        var mediaType: String
    }

    enum Kind: Equatable {
        case image(Image, name: String?)
        case file(URL)
    }

    let id = UUID()
    var kind: Kind

    /// What Claude's API takes: PNG, JPEG, GIF or WebP, up to about 5 MB and best under 2000 points.
    private static let accepted = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
    private static let maxBytes = 3_500_000
    private static let maxSide: CGFloat = 2000

    /// Images go in as images, anything else by path, so Claude can read it with its own tools.
    init(url: URL) {
        let url = url.standardizedFileURL
        let isImage = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true
        if isImage, let data = try? Data(contentsOf: url), let image = Self.prepared(data, type: Self.accepted[url.pathExtension.lowercased()]) {
            kind = .image(image, name: url.lastPathComponent)
        } else {
            kind = .file(url)
        }
    }

    init?(imageData data: Data) {
        guard let image = Self.prepared(data, type: nil) else { return nil }
        kind = .image(image, name: nil)
    }

    /// Passes a small image in an accepted format through; converts or shrinks anything else to JPEG.
    private static func prepared(_ data: Data, type: String?) -> Image? {
        guard let source = NSBitmapImageRep(data: data) else { return nil }
        let side = CGFloat(max(source.pixelsWide, source.pixelsHigh))
        if let type, data.count <= maxBytes, side <= maxSide { return Image(data: data, mediaType: type) }
        let scale = min(1, maxSide / side)
        let width = Int(CGFloat(source.pixelsWide) * scale), height = Int(CGFloat(source.pixelsHigh) * scale)
        guard let target = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: target) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        source.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = target.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return Image(data: jpeg, mediaType: "image/jpeg")
    }

    /// The clipboard's files or image, if that's what it holds. Plain text is left to the text field.
    static func fromPasteboard(_ pasteboard: NSPasteboard = .general) -> [ClaudeAttachment] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(ClaudeAttachment.init(url:))
        }
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else { return [] }
        return ClaudeAttachment(imageData: data).map { [$0] } ?? []
    }
}
