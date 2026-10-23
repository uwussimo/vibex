import Foundation
import Testing
@testable import Vibex

@Suite struct UpdaterTests {
    @Test(arguments: [
        ("1.1.0", "1.0.0", true),
        ("1.10.0", "1.9.3", true),
        ("2.0", "1.99.99", true),
        ("1.0.0", "1.0.0", false),
        ("1.0.0", "1.1.0", false),
    ])
    func `versions compare numerically`(candidate: String, current: String, newer: Bool) {
        #expect(Updater.isNewer(candidate, than: current) == newer)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIBEX_OFFLINE"] == nil))
    func `reads the latest release from GitHub`() async throws {
        let version = try await Updater.latestVersion()
        #expect(!version.hasPrefix("v"))
        #expect(version.split(separator: ".").count >= 2)
    }
}

@Suite struct UpdatePromptTests {
    @Test func `release notes become a short plain list`() {
        let notes = "**New**\n- **AI Agents** dashboard (⌃⇧A)\n- `Skills` sidebar\n\n**Fixed**\n- Blank diffs\n- One\n- Two\n- Three"
        let summary = Updater.summary(ofNotes: notes)
        #expect(summary.hasPrefix("• AI Agents dashboard (⌃⇧A)\n• Skills sidebar\n• Blank diffs"))
        #expect(summary.split(separator: "\n").count == 5)
        #expect(Updater.summary(ofNotes: "No bullets here.").isEmpty)
    }
}

@Suite struct TerminalTitleTests {
    @Test func `abbreviated paths show the folder name`() {
        #expect(TerminalPaneViewController.displayTitle("~/D/e/vibex") == "vibex")
        #expect(TerminalPaneViewController.displayTitle("claude ~/D/e/vibex") == "claude · vibex")
        #expect(TerminalPaneViewController.displayTitle("~") == "~")
        #expect(TerminalPaneViewController.displayTitle("npm run dev") == "npm run dev")
    }
}
