import Foundation
import Testing
@testable import Vibex

@Suite
struct EndpointDescriptionTests {
    /// Interpolating an `Int` into a `Text` runs it through the user's locale, so port 2222
    /// renders as "2 222" or "2,222" in most of the world. A port is an identifier.
    @Test(arguments: [22, 2_222, 65_535, 8_080])
    func `a port is written as digits, never grouped`(port: Int) {
        let profile = SSHConnectionProfile(
            id: UUID(), name: "Test", host: "203.0.113.10", port: port,
            username: "deploy", authentication: .password, privateKeyPath: nil
        )
        #expect(profile.endpointDescription == "deploy@203.0.113.10:\(String(port))")
        #expect(!profile.endpointDescription.contains(","))
        #expect(!profile.endpointDescription.contains("\u{202F}"))
        #expect(!profile.endpointDescription.contains(" "))
    }

    @Test func `a server profile describes the same endpoint as its connection profile`() {
        let server = ServerProfile(name: "Staging", host: "198.51.100.24", port: 2_222, username: "ubuntu")
        #expect(server.endpointDescription == "ubuntu@198.51.100.24:2222")
        #expect(SSHConnectionProfile(profile: server).endpointDescription == server.endpointDescription)
    }
}
