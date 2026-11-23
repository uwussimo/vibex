import AppKit
import Testing
@testable import Vibex

@MainActor
struct TerminalDropTests {
    @Test func escapesPathsLikeTerminalApp() {
        #expect(VibexTerminalView.escaped("/Users/me/Screen Shot (1).png") == #"/Users/me/Screen\ Shot\ \(1\).png"#)
        #expect(VibexTerminalView.escaped("/tmp/plain.txt") == "/tmp/plain.txt")
        #expect(VibexTerminalView.escaped("/tmp/it's & $x") == #"/tmp/it\'s\ \&\ \$x"#)
    }

    @Test func droppedFilesBecomePathsSeparatedBySpaces() {
        let pasteboard = NSPasteboard(name: .init("vibex-drop-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a b.png") as NSURL, URL(fileURLWithPath: "/tmp/c.swift") as NSURL])
        #expect(VibexTerminalView.text(for: pasteboard, saveImage: false) == #"/tmp/a\ b.png /tmp/c.swift "#)
    }

    @Test func imageDataIsSavedToAFile() throws {
        let pasteboard = NSPasteboard(name: .init("vibex-drop-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        pasteboard.setData(image.tiffRepresentation, forType: .tiff)
        let text = try #require(VibexTerminalView.text(for: pasteboard, saveImage: true))
        let path = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "")
        #expect(path.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: path))
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test func emptyPasteboardIsRefused() {
        let pasteboard = NSPasteboard(name: .init("vibex-drop-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(VibexTerminalView.text(for: pasteboard, saveImage: false) == nil)
    }
}
