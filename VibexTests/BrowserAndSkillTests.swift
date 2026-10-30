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


@MainActor @Suite struct BrowserAddressTests {
    private func address(_ text: String) throws -> String { BrowserTab.address(try #require(URL(string: text))) }

    @Test func `the address bar shows the route, not just the domain`() throws {
        #expect(try address("https://www.acme.com/orders/42?tab=items") == "acme.com/orders/42?tab=items")
        #expect(try address("https://acme.com/") == "acme.com")
        #expect(try address("http://localhost:3000/dashboard/settings") == "localhost:3000/dashboard/settings")
        #expect(try address("http://localhost:5173/#/cart") == "localhost:5173#/cart")
        #expect(try address("https://acme.com/caf%C3%A9") == "acme.com/café")
    }
}

@MainActor @Suite(.serialized) struct BrowserSleepTests {
    private let later = Date.now.addingTimeInterval(BrowserTab.idleLimit + 60)
    private func page(_ title: String, _ body: String = "<p>hi</p>") -> URL {
        URL(string: "data:text/html,<title>\(title)</title>\(body)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)!
    }

    private func pane(tabs: [String] = [], selected: Int = 0) throws -> (BrowserPaneViewController, NSWindow, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-sleep-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = ProjectStore(directory: root.appendingPathComponent("state"))
        let project = Project(url: folder)
        var state = ProjectState()
        state.browserTabURLs = tabs
        state.browserSelectedTab = selected
        store.save(state, for: project)
        let pane = BrowserPaneViewController(session: ProjectSession(project: project, store: store))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = pane
        window.orderFront(nil)
        return (pane, window, root)
    }

    private func until(_ done: () -> Bool) async throws {
        for _ in 0..<50 where !done() { try await Task.sleep(for: .milliseconds(100)) }
    }

    @Test func `an idle tab sleeps and comes back where it was`() async throws {
        let (pane, window, root) = try pane()
        defer { window.close(); try? FileManager.default.removeItem(at: root) }
        let front = try #require(pane.selectedTab)
        let back = pane.openTab(url: page("First"), select: false)
        try await until { back.title == "First" }
        back.load(page("Second"))
        try await until { back.title == "Second" && back.canGoBack }

        pane.sleepIdleTabs(at: .now)
        #expect(!back.isAsleep)
        pane.sleepIdleTabs(at: later)
        #expect(back.isAsleep)
        #expect(!front.isAsleep)
        // Asleep, it still says what it is.
        #expect(back.title == "Second")
        #expect(back.url == page("Second"))

        pane.select(back.id)
        #expect(!back.isAsleep)
        try await until { !back.isWaking && back.canGoBack }
        #expect(back.title == "Second")
        #expect(back.url == page("Second"))
        #expect(back.canGoBack)
        back.webView.goBack()
        try await until { back.title == "First" }
        #expect(back.title == "First")
        // The tab it left behind was just in use, so it gets its full idle time.
        pane.sleepIdleTabs(at: .now)
        #expect(!front.isAsleep)
    }

    @Test func `a tab playing media or holding typed text stays awake`() async throws {
        let (pane, window, root) = try pane()
        defer { window.close(); try? FileManager.default.removeItem(at: root) }
        let typed = pane.openTab(url: page("Form", "<input id=f>"), select: false)
        let playing = pane.openTab(url: page("Film", "<audio id=a></audio>"), select: false)
        try await until { typed.title == "Form" && playing.title == "Film" }

        _ = try await typed.webView.evaluateJavaScript("f.value='x'; f.dispatchEvent(new Event('input', {bubbles: true})); 1")
        try await until { typed.hasUserInput }
        _ = try await playing.webView.evaluateJavaScript("Object.defineProperty(a, 'paused', {value: false}); a.dispatchEvent(new Event('playing')); 1")
        try await until { playing.lastMedia != nil }

        let longAgo = Date.now.addingTimeInterval(-BrowserTab.idleLimit - 60)
        typed.markUsed(at: longAgo)
        playing.markUsed(at: longAgo)
        pane.sleepIdleTabs()
        #expect(!typed.isAsleep)
        #expect(!playing.isAsleep)
        // Long enough without a playback report means it stopped, so it can sleep.
        pane.sleepIdleTabs(at: Date.now.addingTimeInterval(3 * 60))
        #expect(playing.isAsleep)
        #expect(!typed.isAsleep)
    }

    @Test func `restored tabs wait asleep until they're opened`() async throws {
        let (pane, window, root) = try pane(tabs: ["https://example.com/one", "https://example.com/two"], selected: 1)
        defer { window.close(); try? FileManager.default.removeItem(at: root) }
        pane.loadViewIfNeeded()
        #expect(pane.tabs.map(\.isAsleep) == [true, false])
        #expect(pane.tabs[0].url?.absoluteString == "https://example.com/one")
        #expect(pane.tabs[0].title == "example.com")
        pane.prepareForTermination()
        #expect(pane.session.state.browserTabURLs == ["https://example.com/one", "https://example.com/two"])
    }
}
