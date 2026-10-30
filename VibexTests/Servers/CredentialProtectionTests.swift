import Foundation
import Security
import Testing
@testable import Vibex

@Suite
struct CredentialProtectionTests {
    private let service = "test.probe"

    @Test func `the probe reports the legacy tier when every strong write is refused`() {
        let keychain = InMemoryKeychain()
        keychain.scriptedAddStatuses = [errSecMissingEntitlement, errSecMissingEntitlement]
        let result = CredentialProtectionProbe(backend: keychain, service: service).detect()

        #expect(result.tier == .legacyKeychain)
        #expect(result.diagnostics.contains { $0.contains("-34018") })
        #expect(keychain.keys.isEmpty)
    }

    @Test func `the probe reports the data protection tier when only the presence lock is refused`() {
        let keychain = InMemoryKeychain()
        keychain.scriptedAddStatuses = [errSecMissingEntitlement, errSecSuccess]
        let result = CredentialProtectionProbe(backend: keychain, service: service).detect()

        #expect(result.tier == .dataProtection)
        #expect(result.diagnostics.count == 1)
    }

    @Test func `the probe reports the user presence tier when the strongest write succeeds`() {
        let keychain = InMemoryKeychain()
        let result = CredentialProtectionProbe(backend: keychain, service: service).detect()

        #expect(result.tier == .userPresence)
        #expect(result.diagnostics.isEmpty)
    }

    @Test(arguments: [
        [errSecMissingEntitlement, errSecMissingEntitlement],
        [errSecMissingEntitlement, errSecSuccess],
        [errSecSuccess]
    ])
    func `the probe leaves no item behind`(script: [OSStatus]) {
        let keychain = InMemoryKeychain()
        keychain.scriptedAddStatuses = script
        _ = CredentialProtectionProbe(backend: keychain, service: service).detect()
        #expect(keychain.keys.isEmpty)
    }

    @Test func `only the data protection tiers use the data protection keychain`() {
        #expect(!CredentialProtectionTier.legacyKeychain.usesDataProtectionKeychain)
        #expect(CredentialProtectionTier.dataProtection.usesDataProtectionKeychain)
        #expect(CredentialProtectionTier.userPresence.usesDataProtectionKeychain)
    }
}
