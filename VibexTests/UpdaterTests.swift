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
