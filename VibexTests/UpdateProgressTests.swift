import Testing
@testable import Vibex

@Suite struct UpdateProgressTests {
    @Test func `the installer's log says where it has got`() {
        #expect(InstallProgress(log: "") == InstallProgress(step: .downloading))
        let download = InstallProgress(log: "==> Looking up the release\n==> Downloading Vibex 2.2.0\n\r####      12.5%\r########    40.0%")
        #expect(download.step == .downloading)
        #expect(download.fraction == 0.4)
        #expect(InstallProgress(log: "==> Checksum verified").step == .verifying)
        #expect(InstallProgress(log: "==> Checksum verified\n==> Installing to /Applications/Vibex.app").step == .installing)
    }

    @Test func `the installer's error comes through`() {
        let progress = InstallProgress(log: "==> Downloading Vibex 2.2.0\n\u{1B}[31merror:\u{1B}[0m Download failed.")
        #expect(progress.failure == "Download failed.")
    }
}
