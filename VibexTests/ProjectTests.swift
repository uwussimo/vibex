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

@Suite struct RunDetectorTests {
    private func folder(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-run-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test func `xcodegen iOS project builds after generating`() throws {
        let dir = try folder(["project.yml": "name: Shop\ntargets:\n  Shop:\n    platform: iOS\n"])
        let config = try #require(RunDetector.detect(in: dir))
        #expect(config.kind == .ios)
        #expect(config.scheme == "Shop")
        #expect(config.project == "Shop.xcodeproj")
        #expect(config.prepare == "xcodegen generate")
    }

    @Test func `macOS-only xcodegen project runs as a Mac app`() throws {
        let dir = try folder(["project.yml": "name: Vibex\ntargets:\n  Vibex:\n    platform: macOS\n  VibexTests:\n    platform: macOS\n"])
        #expect(RunDetector.detect(in: dir)?.kind == .macos)
    }

    @Test func `vite project with pnpm`() throws {
        let dir = try folder([
            "package.json": #"{"scripts":{"dev":"vite"},"devDependencies":{"vite":"^6"}}"#,
            "pnpm-lock.yaml": "",
        ])
        let config = try #require(RunDetector.detect(in: dir))
        #expect(config.kind == .web)
        #expect(config.command == "pnpm dev")
        #expect(config.url == "http://localhost:5173")
    }

    @Test func `explicit port flag wins`() {
        #expect(RunDetector.guessPort(deps: ["next": "15"], script: "next dev -p 4000") == 4000)
        #expect(RunDetector.guessPort(deps: [:], script: "node server.js") == 3000)
    }

    @Test func `swift package and vibex json`() throws {
        let dir = try folder(["Package.swift": "// swift-tools-version:6.0"])
        #expect(RunDetector.detect(in: dir)?.command == "swift run")
        try RunConfig(kind: .web, command: "bun dev", url: "http://localhost:3001").write(to: dir)
        #expect(RunConfig.load(from: dir)?.url == "http://localhost:3001")
    }

    @Test func `transcripts lose their escape codes`() {
        #expect(Runner.stripANSI("\u{04}\u{08}\u{08}\u{1B}[31mred\u{1B}[0m\r\nok\r") == "red\nok")
        #expect(Runner.quote("it's") == "'it'\\''s'")
    }
}
