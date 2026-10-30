import Foundation
import Security
import Testing
@testable import Vibex

@MainActor
@Suite(.serialized)
struct CredentialAccessTests {
    private let service = "test.credentials"
    private let serverID = UUID()

    private final class Clock {
        let base = ContinuousClock.now
        var offset = Duration.zero
        var now: ContinuousClock.Instant { base.advanced(by: offset) }
    }

    private func makeAccess(
        policy: UnlockPolicy = .everyUse
    ) -> (CredentialAccess, SessionLock, FakeDeviceAuthenticator, InMemoryKeychain, Clock) {
        let keychain = InMemoryKeychain()
        let authenticator = FakeDeviceAuthenticator()
        let lock = SessionLock(authenticator: authenticator, defaults: .makeEphemeral())
        lock.policy = policy
        let store = KeychainCredentialStore(
            service: service, backend: keychain, tier: .legacyKeychain, defaults: .makeEphemeral()
        )
        let access = CredentialAccess(store: store, lock: lock)
        let clock = Clock()
        access.now = { clock.now }
        return (access, lock, authenticator, keychain, clock)
    }

    private func account(_ kind: CredentialKind) -> String {
        "\(serverID.uuidString).\(kind.rawValue)"
    }

    @Test func `a stored secret is never read before the gate is passed`() async {
        let (access, _, authenticator, keychain, _) = makeAccess()
        keychain.seed(
            service: service, account: account(.password),
            secret: Data("hunter2".utf8), accessible: kSecAttrAccessibleWhenUnlocked
        )
        authenticator.scriptedFailures = [.cancelledByUser]
        keychain.resetCounters()

        await #expect(throws: DeviceAuthError.cancelledByUser) {
            _ = try await access.grant(for: serverID, kind: .password, intent: .unlockVault)
        }
        // The existence probe may run; the secret itself must not have been fetched.
        #expect(keychain.dataReadCount == 0)
    }

    @Test func `an authorized read returns the stored bytes`() async throws {
        let (access, _, authenticator, keychain, _) = makeAccess()
        keychain.seed(
            service: service, account: account(.password),
            secret: Data("hunter2".utf8), accessible: kSecAttrAccessibleWhenUnlocked
        )

        let grant = try #require(await access.grant(for: serverID, kind: .password, intent: .unlockVault))
        #expect(authenticator.callCount == 1)
        let sent = grant.secret.consume { Array($0) }
        #expect(sent == Array("hunter2\n".utf8))
    }

    @Test func `a missing credential never prompts`() async throws {
        let (access, _, authenticator, _, _) = makeAccess()
        let grant = try await access.grant(for: serverID, kind: .password, intent: .unlockVault)
        #expect(grant == nil)
        #expect(authenticator.callCount == 0)
    }

    @Test func `storing and deleting never prompt`() async throws {
        let (access, _, authenticator, _, _) = makeAccess()
        try access.store(Data("s3cret".utf8), for: serverID, kind: .password)
        #expect(try access.hasCredential(for: serverID, kind: .password))
        try access.deleteAll(for: serverID)
        #expect(try !access.hasCredential(for: serverID, kind: .password))
        #expect(authenticator.callCount == 0)
    }

    @Test func `a grant carries the lock generation it was issued under`() async throws {
        let (access, lock, _, keychain, _) = makeAccess()
        keychain.seed(
            service: service, account: account(.password),
            secret: Data("x".utf8), accessible: kSecAttrAccessibleWhenUnlocked
        )
        let grant = try #require(await access.grant(for: serverID, kind: .password, intent: .unlockVault))
        #expect(grant.generation == lock.generation)
        #expect(access.isAuthorized(grant))
    }

    @Test func `a grant issued before a relock is no longer authorized`() async throws {
        let (access, lock, _, keychain, _) = makeAccess()
        keychain.seed(
            service: service, account: account(.password),
            secret: Data("x".utf8), accessible: kSecAttrAccessibleWhenUnlocked
        )
        let grant = try #require(await access.grant(for: serverID, kind: .password, intent: .unlockVault))
        lock.relock(.screensDidSleep)
        #expect(!access.isAuthorized(grant))
    }

    @Test func `a grant older than the maximum age is no longer authorized`() async throws {
        let (access, _, _, keychain, clock) = makeAccess(policy: .untilQuit)
        keychain.seed(
            service: service, account: account(.password),
            secret: Data("x".utf8), accessible: kSecAttrAccessibleWhenUnlocked
        )
        let grant = try #require(await access.grant(for: serverID, kind: .password, intent: .unlockVault))
        clock.offset = .seconds(119)
        #expect(access.isAuthorized(grant))
        clock.offset = .seconds(121)
        #expect(!access.isAuthorized(grant))
    }

    @Test func `a secret box hands over its bytes exactly once and then wipes`() {
        let box = SecretBox(Data("abc".utf8))
        #expect(box.consume { Array($0) } == Array("abc\n".utf8))
        #expect(box.consume { Array($0) } == nil)
        #expect(box.isEmpty)
    }
}
