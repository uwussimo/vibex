import Foundation
import Testing
@testable import Vibex

@Suite struct ProjectTests {
    @Test func `same folder gives the same id however it is spelled`() {
        let a = Project(url: URL(fileURLWithPath: "/tmp/../tmp/vibex-test"))
        let b = Project(url: URL(fileURLWithPath: "/tmp/vibex-test/"))
        #expect(a.id == b.id)
        #expect(a.name == "vibex-test")
        #expect(a.id.count == 16)
    }

    @Test func `home paths display with a tilde`() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let project = Project(url: home.appendingPathComponent("code/app"))
        #expect(project.displayPath == "~/code/app")
    }

    @Test func `state round-trips through JSON`() throws {
        var state = ProjectState()
        state.terminalDirectories = ["/a", "/b"]
        state.browserTabURLs = ["https://example.com"]
        state.browserSelectedTab = 1
        state.deviceUDID = "UDID"
        state.layout = .watch
        state.columnWidths = ColumnWidths(terminal: 900, simulator: 400, browser: 600)
        state.lastOpened = Date(timeIntervalSince1970: 1_760_000_000) // ISO 8601 keeps whole seconds
        let data = try JSONEncoder.iso.encode(state)
        let decoded = try JSONDecoder.iso.decode(ProjectState.self, from: data)
        #expect(decoded == state)
        #expect(decoded.layout == .watch)
        #expect(decoded.columnWidths?.simulator == 400)
    }
}

@MainActor
@Suite struct ProjectStoreTests {
    private func makeStore() -> (ProjectStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-store-\(UUID().uuidString)")
        return (ProjectStore(directory: dir), dir)
    }

    @Test func `saves and loads state per project`() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = Project(url: URL(fileURLWithPath: "/tmp/vibex-a"))
        var state = ProjectState()
        state.deviceUDID = "ABC"
        store.save(state, for: project)
        #expect(store.state(for: project).deviceUDID == "ABC")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(project.id).json").path))
    }

    @Test func `session debounces and saves on demand`() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = Project(url: URL(fileURLWithPath: "/tmp/vibex-b"))
        store.save(ProjectState(), for: project)
        let session = ProjectSession(project: project, store: store)
        session.update { $0.browserTabURLs = ["https://a.dev"] }
        session.saveNow()
        #expect(store.state(for: project).browserTabURLs == ["https://a.dev"])
        #expect(session.terminalEnvironment["VIBEX_PROJECT"] == project.path)
    }
}
