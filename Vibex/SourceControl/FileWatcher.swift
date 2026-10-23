import CoreServices
import Foundation

/// Watches a folder tree with FSEvents and calls `onChange` on the main actor, coalesced so a build
/// writing thousands of files triggers one refresh rather than thousands.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let box: Box

    /// Paths under `.git` that matter: the index (staging), HEAD (branch switches) and refs (commits).
    nonisolated private static let gitSignals = ["/.git/index", "/.git/HEAD", "/.git/refs/", "/.git/MERGE_HEAD"]

    private final class Box {
        let onChange: () -> Void
        init(_ onChange: @escaping () -> Void) { self.onChange = onChange }
    }

    init(path: String, latency: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        box = Box(onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            // Object writes, logs and lock files inside .git change nothing the sidebar shows.
            let relevant = list.prefix(count).contains { path in
                guard path.contains("/.git/") || path.hasSuffix("/.git") else { return true }
                return FileWatcher.gitSignals.contains { path.contains($0) }
            }
            guard relevant else { return }
            MainActor.assumeIsolated { box.onChange() }
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// The stream points at `box` unretained, so it must stop before the box goes away.
    isolated deinit { stop() }
}
