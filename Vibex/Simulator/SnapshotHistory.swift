import AppKit
import Observation
import os

/// Simulator screenshots kept per project, for comparing a screen before and after a change. Taken by
/// the simulator header's camera, after every app launch from Run, and by Claude with `simulator_snapshot`.
@Observable
final class SnapshotHistory {
    struct Snapshot: Codable, Identifiable, Equatable, Sendable {
        var id: UUID
        var date: Date
        var label: String
        var device: String
        var file: String
    }

    private(set) var snapshots: [Snapshot] = []
    let folder: URL

    /// Older ones are deleted beyond this.
    static let limit = 40

    convenience init(projectID: String) {
        self.init(folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vibex/Snapshots/\(projectID)", isDirectory: true))
    }

    init(folder: URL) {
        self.folder = folder
        snapshots = (try? JSONDecoder.snapshots.decode([Snapshot].self, from: Data(contentsOf: indexURL))) ?? []
    }

    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    func url(of snapshot: Snapshot) -> URL { folder.appendingPathComponent(snapshot.file) }

    func image(of snapshot: Snapshot) -> NSImage? { NSImage(contentsOf: url(of: snapshot)) }

    /// The pair the Compare tab starts with: the two newest.
    var latestPair: (before: Snapshot, after: Snapshot)? {
        guard snapshots.count >= 2 else { return nil }
        return (snapshots[snapshots.count - 2], snapshots[snapshots.count - 1])
    }

    @discardableResult
    func add(png: Data, label: String, device: String) -> Snapshot? {
        let snapshot = Snapshot(id: UUID(), date: Date(), label: label, device: device, file: "\(UUID().uuidString).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url(of: snapshot), options: .atomic)
        } catch {
            Log.simulator.error("could not save snapshot: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        snapshots.append(snapshot)
        while snapshots.count > Self.limit {
            let old = snapshots.removeFirst()
            try? FileManager.default.removeItem(at: url(of: old))
        }
        save()
        return snapshot
    }

    func remove(_ snapshot: Snapshot) {
        snapshots.removeAll { $0.id == snapshot.id }
        try? FileManager.default.removeItem(at: url(of: snapshot))
        save()
    }

    private func save() {
        try? JSONEncoder.snapshots.encode(snapshots).write(to: indexURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static let snapshots: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let snapshots: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
