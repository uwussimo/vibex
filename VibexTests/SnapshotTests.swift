import AppKit
import Testing
@testable import Vibex

@MainActor @Suite struct SnapshotHistoryTests {
    static func png(_ color: NSColor) -> Data {
        let image = NSImage(size: NSSize(width: 40, height: 80), flipped: false) { rect in color.setFill(); rect.fill(); return true }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func `keeps, persists and trims screenshots`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-snapshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = SnapshotHistory(folder: folder)
        #expect(history.latestPair == nil)
        let before = try #require(history.add(png: Self.png(.red), label: "before", device: "iPhone"))
        let after = try #require(history.add(png: Self.png(.blue), label: "after", device: "iPhone"))
        #expect(history.latestPair?.before == before)
        #expect(history.latestPair?.after == after)
        #expect(history.image(of: after) != nil)

        // A new window for the same project sees the same history.
        let reopened = SnapshotHistory(folder: folder)
        #expect(reopened.snapshots.map(\.label) == ["before", "after"])

        for index in 0..<SnapshotHistory.limit { history.add(png: Self.png(.green), label: "\(index)", device: "iPhone") }
        #expect(history.snapshots.count == SnapshotHistory.limit)
        #expect(!FileManager.default.fileExists(atPath: history.url(of: before).path))
        history.remove(history.snapshots[0])
        #expect(history.snapshots.count == SnapshotHistory.limit - 1)
    }

    @Test func `images fit their frame without stretching`() {
        #expect(CompareView.fit(NSSize(width: 100, height: 200), in: CGSize(width: 400, height: 400)) == CGSize(width: 200, height: 400))
        #expect(CompareView.fit(NSSize(width: 400, height: 100), in: CGSize(width: 200, height: 200)) == CGSize(width: 200, height: 50))
    }
}

@MainActor @Suite struct DeviceMatrixTests {
    func device(_ name: String, _ runtime: String = "iOS 26.6") -> SimDevice {
        SimDevice(udid: UUID().uuidString, name: name, runtime: runtime, state: "Shutdown")
    }

    @Test func `presets pick a small phone, a large phone and an iPad`() {
        let devices = [device("iPhone 17 Pro"), device("iPhone 17 Pro Max"), device("iPhone 16e"), device("iPad Air 13-inch (M3)"), device("iPhone SE (3rd generation)", "iOS 18.6")]
        #expect(DeviceMatrixModel.presets(from: devices).map(\.name) == ["iPhone 16e", "iPhone 17 Pro Max", "iPad Air 13-inch (M3)"])
        #expect(DeviceMatrixModel.presets(from: [device("iPhone 17")]).map(\.name) == ["iPhone 17"])
        #expect(DeviceMatrixModel.presets(from: []).isEmpty)
    }
}
