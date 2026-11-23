import AppKit
import SwiftTerm
import UniformTypeIdentifiers

/// The terminal Vibex puts in every tab. On top of SwiftTerm it takes drops, the way Terminal.app
/// does: files and folders arrive as their escaped paths, so Claude Code attaches a dropped image or
/// reads a dropped file. An image dragged out of a browser or a screenshot thumbnail, which has no
/// file yet, is saved to a temporary file first.
class VibexTerminalView: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .png, .tiff, .string])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .URL, .png, .tiff, .string])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.text(for: sender.draggingPasteboard, saveImage: false) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let text = Self.text(for: sender.draggingPasteboard, saveImage: true) else { return false }
        window?.makeFirstResponder(self)
        // A paste, bracketed when the program asked for it, so Claude Code sees one paste rather
        // than keystrokes and attaches a dropped image.
        pasteText(text)
        return true
    }

    /// What a drop types, or nil when the pasteboard holds nothing a terminal can take.
    /// `saveImage` false only checks, without writing a file for image data.
    static func text(for pasteboard: NSPasteboard, saveImage: Bool) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map { escaped($0.path) }.joined(separator: " ") + " "
        }
        if pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil {
            guard saveImage else { return "" }
            guard let url = saveImageData(from: pasteboard) else { return nil }
            return escaped(url.path) + " "
        }
        if let url = pasteboard.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL {
            return url.absoluteString
        }
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return string
        }
        return nil
    }

    /// A path written the way Terminal.app writes a dropped one: shell metacharacters escaped with a
    /// backslash, so it survives a shell and Claude Code reads it as one path.
    static func escaped(_ path: String) -> String {
        let special = Set(" \\'\"`$&|;<>()[]{}*?!#~\t")
        var result = ""
        for character in path {
            if special.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    private static func saveImageData(from pasteboard: NSPasteboard) -> URL? {
        let png: Data?
        if let data = pasteboard.data(forType: .png) {
            png = data
        } else if let tiff = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff) {
            png = bitmap.representation(using: .png, properties: [:])
        } else {
            png = nil
        }
        guard let png else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Vibex Drops", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        let url = folder.appendingPathComponent("Dropped image \(stamp).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
