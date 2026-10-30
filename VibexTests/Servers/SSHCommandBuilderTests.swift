import Foundation
import Testing
@testable import Vibex

@Suite
struct SSHCommandBuilderTests {
    private func profile(
        host: String = "example.com",
        port: Int = 22,
        authentication: AuthenticationKind = .password,
        privateKeyPath: String? = nil
    ) -> SSHConnectionProfile {
        SSHConnectionProfile(
            id: UUID(),
            name: "Test",
            host: host,
            port: port,
            username: "root",
            authentication: authentication,
            privateKeyPath: privateKeyPath
        )
    }

    @Test func `a password login passes separated arguments and never the secret`() throws {
        let launch = try SSHCommandBuilder().build(for: profile(host: "2001:db8::1", port: 2_222))

        #expect(launch.executable == "/usr/bin/ssh")
        #expect(launch.arguments.contains("2001:db8::1"))
        #expect(launch.arguments.contains("2222"))
        #expect(launch.arguments.contains("PubkeyAuthentication=no"))
        #expect(!launch.arguments.joined().localizedCaseInsensitiveContains("password="))
    }

    @Test func `a key login pins the identity and refuses to try any other`() throws {
        let launch = try SSHCommandBuilder().build(
            for: profile(authentication: .privateKey, privateKeyPath: "/dev/null")
        )

        #expect(launch.arguments.contains("/dev/null"))
        #expect(launch.arguments.contains("IdentitiesOnly=yes"))
        #expect(launch.arguments.last == "example.com")
    }

    @Test(arguments: [0, 65_536, -1])
    func `an out of range port is rejected`(port: Int) {
        #expect(throws: SSHCommandBuilderError.invalidPort) {
            try SSHCommandBuilder().build(for: profile(port: port))
        }
    }

    @Test func `an empty host is rejected`() {
        #expect(throws: SSHCommandBuilderError.invalidHost) {
            try SSHCommandBuilder().build(for: profile(host: "   "))
        }
    }

    @Test func `a key login with no key selected is rejected`() {
        #expect(throws: SSHCommandBuilderError.missingPrivateKey) {
            try SSHCommandBuilder().build(for: profile(authentication: .privateKey))
        }
    }
}
