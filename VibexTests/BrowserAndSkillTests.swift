import AppKit
import Foundation
import Testing
import WebKit
@testable import Vibex

@Suite struct NewTabPageTests {
    @Test func `dev servers come from lsof, without system ports`() {
        let output = "p123\ncnode\nn*:5173\nn[::1]:5173\np456\ncControlCe\nn*:7000\np789\ncpython3.12\nn127.0.0.1:8000\np10\ncnode\nn*:80\n"
        let listeners = NewTabPage.parseLsof(output)
        #expect(listeners.map(\.server) == [.init(port: 5173, process: "node"), .init(port: 8000, process: "python3.12")])
        #expect(listeners.map(\.pid) == [123, 789])
        #expect(listeners.first?.server.url == "http://localhost:5173")
    }

    @Test func `only dev servers are listed`() {
        #expect(NewTabPage.isDevServer(command: "node", path: "/Users/me/.nvm/versions/node/v22/bin/node"))
        #expect(NewTabPage.isDevServer(command: "python3.12", path: "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"))
        #expect(NewTabPage.isDevServer(command: "habits-api", path: "/Users/me/habits/.build/debug/habits-api"))
        #expect(!NewTabPage.isDevServer(command: "Spotify", path: "/Applications/Spotify.app/Contents/MacOS/Spotify"))
        #expect(!NewTabPage.isDevServer(command: "rapportd", path: "/usr/libexec/rapportd"))
    }

    @Test func `ps paths identify app helpers`() {
        let paths = NewTabPage.parsePs("  123 /opt/homebrew/bin/node\n 456 /Applications/Spotify.app/Contents/MacOS/Spotify\n")
        #expect(paths[123] == "/opt/homebrew/bin/node")
        #expect(paths[456]?.contains(".app/") == true)
    }

    @Test func `local hosts open over http, everything else over https`() {
        #expect(WebViewFactory.url(forInput: "localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(WebViewFactory.url(forInput: "127.0.0.1:8080/api")?.absoluteString == "http://127.0.0.1:8080/api")
        #expect(WebViewFactory.url(forInput: "myapp.test")?.absoluteString == "http://myapp.test")
        #expect(WebViewFactory.url(forInput: "github.com")?.absoluteString == "https://github.com")
    }
}

@Suite struct VibexSkillTests {
    @Test func `the bundled skill is versioned and marked`() throws {
        let text = try #require(VibexSkill.bundledText(version: "9.9.9"))
        #expect(text.hasPrefix("---\nname: vibex\n"))
        #expect(text.contains(VibexSkill.marker + "9.9.9."))
        #expect(!text.contains("{{VERSION}}"))
    }

    @Test func `installs into a skills folder and then reads as current`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-skill-\(UUID().uuidString)/vibex")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        #expect(VibexSkill.status(in: folder) == .missing)
        try VibexSkill.install(into: folder)
        #expect(VibexSkill.status(in: folder) == .current)
        try "# my notes".write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        #expect(VibexSkill.status(in: folder) == .userOwned)
    }

    @Test func `updates its own copy and leaves the user's alone`() {
        let bundled = "x \(VibexSkill.marker)2.0. y"
        #expect(VibexSkill.status(of: nil, bundled: bundled) == .missing)
        #expect(VibexSkill.status(of: bundled, bundled: bundled) == .current)
        #expect(VibexSkill.status(of: "x \(VibexSkill.marker)1.0. y", bundled: bundled) == .outdated)
        #expect(VibexSkill.status(of: "my own vibex notes", bundled: bundled) == .userOwned)
    }
}

@Suite struct TerminalShellTests {
    @Test func `terminals use the login shell`() throws {
        let account = try #require(getpwuid(getuid())?.pointee.pw_shell).map { String(cString: $0) }
        #expect(TerminalSession.preferredShell() == account)
    }
}

@MainActor @Suite(.serialized) struct BrowserTabTests {
    @Test func `a tab opened later still updates its title`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-browser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(directory: root.appendingPathComponent("state"))
        let project = Project(url: root)
        store.save(ProjectState(), for: project)
        let pane = BrowserPaneViewController(session: ProjectSession(project: project, store: store))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = pane
        window.orderFront(nil)
        var titles: [String] = []
        pane.onTabsChange = { titles = pane.tabs.map(\.title) }

        try await Task.sleep(for: .seconds(1.5))
        // The start page is the new-tab page, and it finishes loading.
        let first = try #require(pane.tabs.first)
        #expect(NewTabPage.isNewTab(first.url))
        #expect(!first.isLoading)
        #expect(first.title == "New Tab")

        let second = pane.openTab(url: nil)
        try await Task.sleep(for: .seconds(1))
        second.webView.loadHTMLString("<title>Second page</title><p>hi</p>", baseURL: URL(string: "http://localhost:4321/"))
        try await Task.sleep(for: .seconds(1.5))
        #expect(second.title == "Second page")
        #expect(titles.contains("Second page"))
        window.orderOut(nil)
    }
}
