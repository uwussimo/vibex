import AppKit
import Foundation
import Testing
@testable import Vibex

@MainActor
@Suite(.serialized)
struct SessionLockTests {
    /// Clock is injected so grace windows are tested without sleeping.
    private final class Clock {
        let base = ContinuousClock.now
        var offset = Duration.zero
        var now: ContinuousClock.Instant { base.advanced(by: offset) }
    }

    private func makeLock(
        policy: UnlockPolicy = .everyUse
    ) -> (SessionLock, FakeDeviceAuthenticator, Clock) {
        let authenticator = FakeDeviceAuthenticator()
        let lock = SessionLock(authenticator: authenticator, defaults: .makeEphemeral())
        let clock = Clock()
        lock.now = { clock.now }
        lock.policy = policy
        return (lock, authenticator, clock)
    }

    @Test func `a fresh lock starts locked`() {
        let (lock, authenticator, _) = makeLock()
        #expect(!lock.isUnlocked)
        #expect(lock.generation == 0)
        #expect(authenticator.callCount == 0)
    }

    @Test func `the default policy is every use`() {
        let lock = SessionLock(authenticator: FakeDeviceAuthenticator(), defaults: .makeEphemeral())
        #expect(lock.policy == .everyUse)
    }

    @Test func `every use authenticates on every authorization`() async throws {
        let (lock, authenticator, _) = makeLock(policy: .everyUse)
        for _ in 0..<3 { _ = try await lock.authorize(.unlockVault) }
        #expect(authenticator.callCount == 3)
        #expect(!lock.isUnlocked)
    }

    @Test func `a grace policy authenticates once inside its window`() async throws {
        let (lock, authenticator, clock) = makeLock(policy: .fiveMinutes)
        _ = try await lock.authorize(.unlockVault)
        clock.offset = .seconds(60)
        _ = try await lock.authorize(.unlockVault)
        #expect(authenticator.callCount == 1)
        #expect(lock.isUnlocked)
    }

    @Test func `a grace window expires on the injected clock`() async throws {
        let (lock, authenticator, clock) = makeLock(policy: .fiveMinutes)
        _ = try await lock.authorize(.unlockVault)
        clock.offset = .seconds(301)
        #expect(!lock.isUnlocked)
        _ = try await lock.authorize(.unlockVault)
        #expect(authenticator.callCount == 2)
    }

    @Test func `until quit stays unlocked with no deadline`() async throws {
        let (lock, authenticator, clock) = makeLock(policy: .untilQuit)
        _ = try await lock.authorize(.unlockVault)
        clock.offset = .seconds(86_400)
        #expect(lock.isUnlocked)
        _ = try await lock.authorize(.unlockVault)
        #expect(authenticator.callCount == 1)
    }

    @Test func `relocking while already locked still revokes outstanding grants`() {
        let (lock, _, _) = makeLock(policy: .everyUse)
        let before = lock.generation
        lock.relock(.screensDidSleep)
        #expect(lock.generation == before + 1)
        #expect(lock.lastRelockReason == .screensDidSleep)
    }

    @Test func `lock now clears an active grace window`() async throws {
        let (lock, authenticator, _) = makeLock(policy: .fiveMinutes)
        _ = try await lock.authorize(.unlockVault)
        #expect(lock.isUnlocked)
        lock.relock(.manual)
        #expect(!lock.isUnlocked)
        _ = try await lock.authorize(.unlockVault)
        #expect(authenticator.callCount == 2)
    }

    @Test func `changing the policy relocks`() async throws {
        let (lock, _, _) = makeLock(policy: .fifteenMinutes)
        _ = try await lock.authorize(.unlockVault)
        let generation = lock.generation
        lock.policy = .everyUse
        #expect(!lock.isUnlocked)
        #expect(lock.generation == generation + 1)
    }

    @Test func `a relock notifies its observer so live sessions can scrub their grants`() {
        let (lock, _, _) = makeLock()
        var reasons: [RelockReason] = []
        lock.onRelock = { reasons.append($0) }
        lock.relock(.systemWillSleep)
        #expect(reasons == [.systemWillSleep])
    }

    @Test func `a cancelled authentication leaves the lock locked`() async {
        let (lock, authenticator, _) = makeLock(policy: .fiveMinutes)
        let generation = lock.generation
        authenticator.scriptedFailures = [.cancelledByUser]
        await #expect(throws: DeviceAuthError.cancelledByUser) {
            _ = try await lock.authorize(.unlockVault)
        }
        #expect(!lock.isUnlocked)
        #expect(lock.generation == generation)
    }

    @Test func `an unavailable authenticator refuses to authorize`() async {
        let (lock, authenticator, _) = makeLock()
        authenticator.availability = .unavailable
        await #expect(throws: DeviceAuthError.noDeviceOwnerAuthentication) {
            _ = try await lock.authorize(.unlockVault)
        }
        #expect(!lock.isUnlocked)
    }

    /// The screen sleeping while the system panel is open must win, even though the panel then
    /// reports success. Without this the most important re-lock events silently undo themselves.
    @Test func `a relock during authentication is not undone by the success that follows`() async {
        let (lock, authenticator, _) = makeLock(policy: .fiveMinutes)
        authenticator.suspends = true

        async let authorization: UInt64 = lock.authorize(.unlockVault)
        while authenticator.callCount == 0 { await Task.yield() }

        lock.relock(.screensDidSleep)
        authenticator.resumeAll()
        _ = try? await authorization

        #expect(!lock.isUnlocked)
        #expect(lock.lastRelockReason == .screensDidSleep)
    }

    @Test func `two rapid connects share a single system panel`() async throws {
        let (lock, authenticator, _) = makeLock(policy: .fiveMinutes)
        authenticator.suspends = true

        async let first: UInt64 = lock.authorize(.unlockVault)
        while authenticator.callCount == 0 { await Task.yield() }
        async let second: UInt64 = lock.authorize(.unlockVault)
        await Task.yield()
        authenticator.resumeAll()

        _ = try await first
        _ = try await second
        #expect(authenticator.callCount == 1)
    }

    @Test func `the policy survives a new lock over the same defaults`() {
        let defaults = UserDefaults.makeEphemeral()
        let first = SessionLock(authenticator: FakeDeviceAuthenticator(), defaults: defaults)
        first.policy = .fiveMinutes

        let second = SessionLock(authenticator: FakeDeviceAuthenticator(), defaults: defaults)
        #expect(second.policy == .fiveMinutes)
        // A launch always starts locked; the unlocked state is never persisted.
        #expect(!second.isUnlocked)
    }

    @Test func `each observed system event relocks exactly once`() {
        let (lock, _, _) = makeLock()
        let workspace = NotificationCenter()
        let application = NotificationCenter()
        let distributed = NotificationCenter()
        lock.startObserving(workspace: workspace, application: application, distributed: distributed)
        defer { lock.stopObserving() }

        let before = lock.generation
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(lock.generation == before + 1)
        #expect(lock.lastRelockReason == .screensDidSleep)

        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(lock.generation == before + 2)
        #expect(lock.lastRelockReason == .systemWillSleep)
    }
}
