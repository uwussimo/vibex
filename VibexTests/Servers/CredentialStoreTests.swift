import Foundation
import Security
import Testing
@testable import Vibex

@MainActor
@Suite(.serialized)
struct CredentialStoreTests {
    private let service = "test.credentials"
    private var stagingService: String { service + ".migration" }
    private let serverID = UUID()

    private func makeStore(
        _ keychain: InMemoryKeychain,
        defaults: UserDefaults = .makeEphemeral()
    ) -> KeychainCredentialStore {
        KeychainCredentialStore(
            service: service, backend: keychain, tier: .legacyKeychain, defaults: defaults
        )
    }

    private func account(_ kind: CredentialKind = .password) -> String {
        "\(serverID.uuidString).\(kind.rawValue)"
    }

    @Test func `a legacy item is rewritten with this device only accessibility`() throws {
        let keychain = InMemoryKeychain()
        keychain.seed(
            service: service, account: account(),
            secret: Data("hunter2".utf8), accessible: kSecAttrAccessibleWhenUnlocked
        )
        try makeStore(keychain).migrateStorage()

        #expect(keychain.accessible(service: service, account: account())
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(keychain.secret(service: service, account: account()) == Data("hunter2".utf8))
        #expect(keychain.keys.allSatisfy { $0.service == service })
    }

    @Test func `an item already at the target accessibility is left untouched`() throws {
        let keychain = InMemoryKeychain()
        keychain.seed(
            service: service, account: account(),
            secret: Data("hunter2".utf8), accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
        keychain.resetCounters()
        try makeStore(keychain).migrateStorage()
        #expect(keychain.addCount == 0)
        #expect(keychain.dataReadCount == 0)
    }

    @Test func `a crash after deleting the original is recovered from staging`() throws {
        let keychain = InMemoryKeychain()
        keychain.seed(
            service: stagingService, account: account(),
            secret: Data("hunter2".utf8), accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
        try makeStore(keychain).migrateStorage()

        #expect(keychain.secret(service: service, account: account()) == Data("hunter2".utf8))
        #expect(keychain.keys.contains { $0.service == stagingService } == false)
    }

    @Test func `a crash before deleting staging leaves no duplicate`() throws {
        let keychain = InMemoryKeychain()
        keychain.seed(
            service: service, account: account(),
            secret: Data("current".utf8), accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
        keychain.seed(
            service: stagingService, account: account(),
            secret: Data("stale".utf8), accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
        try makeStore(keychain).migrateStorage()

        #expect(keychain.secret(service: service, account: account()) == Data("current".utf8))
        #expect(keychain.keys.contains { $0.service == stagingService } == false)
    }

    @Test func `an interrupted re add leaves the staging copy for the next launch`() throws {
        let keychain = InMemoryKeychain()
        keychain.seed(
            service: service, account: account(),
            secret: Data("hunter2".utf8), accessible: kSecAttrAccessibleWhenUnlocked
        )
        // The staging add succeeds; the replacement add fails.
        keychain.scriptedAddStatuses = [errSecSuccess, errSecInternalError]
        let defaults = UserDefaults.makeEphemeral()

        #expect(throws: (any Error).self) { try makeStore(keychain, defaults: defaults).migrateStorage() }
        // Nothing was lost: the secret is still in the Keychain, under the staging service.
        #expect(keychain.secret(service: stagingService, account: account()) == Data("hunter2".utf8))

        try makeStore(keychain, defaults: defaults).migrateStorage()
        #expect(keychain.secret(service: service, account: account()) == Data("hunter2".utf8))
        #expect(keychain.keys.contains { $0.service == stagingService } == false)
    }

    @Test func `migration does not rescan once the schema version is current`() throws {
        let keychain = InMemoryKeychain()
        let defaults = UserDefaults.makeEphemeral()
        keychain.seed(
            service: service, account: account(),
            secret: Data("hunter2".utf8), accessible: kSecAttrAccessibleWhenUnlocked
        )
        try makeStore(keychain, defaults: defaults).migrateStorage()
        keychain.resetCounters()
        try makeStore(keychain, defaults: defaults).migrateStorage()
        #expect(keychain.dataReadCount == 0)
        #expect(keychain.addCount == 0)
    }

    @Test func `writing a credential replaces the item so its accessibility can change`() throws {
        let keychain = InMemoryKeychain()
        keychain.seed(
            service: service, account: account(),
            secret: Data("old".utf8), accessible: kSecAttrAccessibleWhenUnlocked
        )
        keychain.resetCounters()

        let store = makeStore(keychain)
        try store.setCredential(Data("new".utf8), for: serverID, kind: .password)

        #expect(keychain.updateCount == 0)
        #expect(keychain.secret(service: service, account: account()) == Data("new".utf8))
        #expect(keychain.accessible(service: service, account: account())
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    @Test func `the existence check returns no secret bytes`() throws {
        let keychain = InMemoryKeychain()
        let store = makeStore(keychain)
        try store.setCredential(Data("s".utf8), for: serverID, kind: .password)
        keychain.resetCounters()

        #expect(try store.hasCredential(for: serverID, kind: .password))
        #expect(keychain.dataReadCount == 0)
    }

    @Test func `deleting everything clears both the live and the staging service`() throws {
        let keychain = InMemoryKeychain()
        let store = makeStore(keychain)
        try store.setCredential(Data("a".utf8), for: serverID, kind: .password)
        try store.setCredential(Data("b".utf8), for: UUID(), kind: .keyPassphrase)
        keychain.seed(
            service: stagingService, account: "orphan",
            secret: Data("c".utf8), accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )

        try store.deleteEverything()
        #expect(keychain.keys.isEmpty)
    }
}
