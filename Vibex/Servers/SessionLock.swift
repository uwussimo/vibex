import AppKit
import Foundation
import Observation
import os

/// How often the person at the keyboard must prove presence before a saved credential is used.
enum UnlockPolicy: String, CaseIterable, Identifiable, Sendable {
    case everyUse
    case oneMinute
    case fiveMinutes
    case fifteenMinutes
    case untilQuit

    static let `default`: UnlockPolicy = .everyUse
    var id: Self { self }

    var title: String {
        switch self {
        case .everyUse: "Every time (recommended)"
        case .oneMinute: "Once per minute"
        case .fiveMinutes: "Once every 5 minutes"
        case .fifteenMinutes: "Once every 15 minutes"
        case .untilQuit: "Once per launch"
        }
    }

    var detail: String {
        switch self {
        case .everyUse:
            "Ask before every use of a saved credential."
        case .untilQuit:
            "Ask once, then not again until Vibex quits, the Mac sleeps, or the screen locks."
        default:
            "Ask again after the window ends, or sooner if the Mac sleeps or the screen locks."
        }
    }

    /// `.zero` means no window at all. `nil` means no time limit — a re-lock event is still required.
    var grace: Duration? {
        switch self {
        case .everyUse: .zero
        case .oneMinute: .seconds(60)
        case .fiveMinutes: .seconds(300)
        case .fifteenMinutes: .seconds(900)
        case .untilQuit: nil
        }
    }
}

enum LockState: Equatable, Sendable {
    case locked
    case unlocked(until: ContinuousClock.Instant?)
}

enum RelockReason: String, Sendable {
    case launch, manual, policyChanged, graceExpired
    case systemWillSleep, screensDidSleep, screenLocked, sessionResigned, didWake, willTerminate
}

/// Owns "has the owner proved they are here, recently enough to use a saved secret?"
///
/// `generation` is the revocation handle. It increments on *every* re-lock, whether or not the
/// state was already `.locked`, so a `CredentialGrant` stamped with generation *n* is dead the
/// moment the counter moves. That is what makes screen sleep meaningful under `.everyUse`,
/// where there is no `.unlocked` state to clear.
@MainActor
@Observable
final class SessionLock {
    private(set) var state: LockState = .locked
    private(set) var generation: UInt64 = 0
    private(set) var isAuthenticating = false
    private(set) var lastRelockReason: RelockReason = .launch

    var policy: UnlockPolicy {
        didSet {
            guard policy != oldValue else { return }
            defaults.set(policy.rawValue, forKey: Self.policyKey)
            // Any policy change re-locks: the user never has to reason about whether a tighter
            // setting applies retroactively.
            relock(.policyChanged)
        }
    }

    /// Injected so grace behaviour is testable without sleeping.
    @ObservationIgnored var now: @MainActor () -> ContinuousClock.Instant = { .now }
    /// Called on every re-lock so holders of outstanding grants can scrub them immediately
    /// rather than waiting to discover they are stale.
    @ObservationIgnored var onRelock: (@MainActor (RelockReason) -> Void)?

    @ObservationIgnored private let authenticator: any DeviceAuthenticating
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let log = Logger(subsystem: "com.yusuf.Vibex", category: "lock")
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var inFlight: Task<UInt64, any Error>?
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    static let policyKey = "servers.unlockPolicy"

    init(authenticator: any DeviceAuthenticating, defaults: UserDefaults = .standard) {
        self.authenticator = authenticator
        self.defaults = defaults
        self.policy = defaults.string(forKey: Self.policyKey)
            .flatMap(UnlockPolicy.init(rawValue:)) ?? .default
    }

    var availability: DeviceAuthAvailability { authenticator.availability }

    func refreshAvailability() { authenticator.refreshAvailability() }

    var isUnlocked: Bool {
        switch state {
        case .locked: false
        case .unlocked(let until): until.map { now() < $0 } ?? true
        }
    }

    // MARK: Authorization

    /// Untyped `throws`: a `Task`'s failure type cannot yet be a typed error, and a `Task` is
    /// what coalesces concurrent authorizations into a single system panel. Callers pattern
    /// match `catch let error as DeviceAuthError`.
    @discardableResult
    func authorize(_ intent: DeviceAuthIntent) async throws -> UInt64 {
        if isUnlocked { return generation }

        // Two rapid Connect clicks must not stack two system panels.
        if let inFlight { return try await inFlight.value }

        // Captured before the panel opens: if anything re-locks while the user is authenticating
        // — screen sleep, lid close, ⌃⌘L — the success that lands afterwards must not silently
        // undo it.
        let entryGeneration = generation
        let task = Task<UInt64, any Error> { [authenticator] in
            try await authenticator.authenticate(intent)
            guard self.generation == entryGeneration else { throw DeviceAuthError.cancelledBySystem }
            return self.commitUnlock()
        }
        inFlight = task
        isAuthenticating = true
        defer {
            inFlight = nil
            isAuthenticating = false
        }
        return try await task.value
    }

    private func commitUnlock() -> UInt64 {
        guard let grace = policy.grace else {
            state = .unlocked(until: nil)
            scheduleExpiry(nil)
            return generation
        }
        guard grace > .zero else {
            // `.everyUse`: presence authorises this single grant and nothing more.
            state = .locked
            scheduleExpiry(nil)
            return generation
        }
        state = .unlocked(until: now().advanced(by: grace))
        scheduleExpiry(grace)
        return generation
    }

    // MARK: Re-locking

    func relock(_ reason: RelockReason) {
        expiryTask?.cancel()
        expiryTask = nil
        inFlight?.cancel()          // dismisses any open panel via LAContext.invalidate()
        state = .locked
        generation &+= 1            // revokes every outstanding CredentialGrant
        lastRelockReason = reason
        log.notice("relocked: \(reason.rawValue, privacy: .public)")
        onRelock?(reason)
    }

    private func scheduleExpiry(_ grace: Duration?) {
        expiryTask?.cancel()
        guard let grace, grace > .zero else {
            expiryTask = nil
            return
        }
        expiryTask = Task { [weak self] in
            // ContinuousClock keeps advancing while the Mac is asleep, matching the deadline
            // arithmetic in `isUnlocked`. SuspendingClock would silently extend the window
            // across a sleep, which is the opposite of what this is for.
            try? await Task.sleep(for: grace, clock: ContinuousClock())
            guard !Task.isCancelled else { return }
            self?.relock(.graceExpired)
        }
    }

    // MARK: Observation

    func startObserving(
        workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
        application: NotificationCenter = .default,
        distributed: NotificationCenter = DistributedNotificationCenter.default()
    ) {
        observe(NSWorkspace.willSleepNotification, on: workspace, reason: .systemWillSleep)
        observe(NSWorkspace.screensDidSleepNotification, on: workspace, reason: .screensDidSleep)
        observe(NSWorkspace.sessionDidResignActiveNotification, on: workspace, reason: .sessionResigned)
        observe(NSWorkspace.didWakeNotification, on: workspace, reason: .didWake)
        observe(NSApplication.willTerminateNotification, on: application, reason: .willTerminate)
        // Best effort: `com.apple.screenIsLocked` is undocumented but long stable, and is
        // delivered only to non-sandboxed apps — which this is. `screensDidSleep` is the
        // guaranteed signal; this one just makes ⌃⌘Q feel instant.
        observe(Notification.Name("com.apple.screenIsLocked"), on: distributed, reason: .screenLocked)
        //
        // Deliberately NOT observed: `NSApplication.didResignActiveNotification`. The
        // LocalAuthentication panel itself resigns the app active, so locking on it would
        // deadlock the unlock flow — and Command-Tabbing to a browser is not a security event.
    }

    func stopObserving() {
        for entry in observers { entry.center.removeObserver(entry.token) }
        observers.removeAll()
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter, reason: RelockReason) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // `queue: .main` guarantees main-thread delivery, so `assumeIsolated` asserts rather
            // than hops: a future change that moves delivery off-main traps loudly instead of
            // racing silently.
            MainActor.assumeIsolated { self?.relock(reason) }
        }
        observers.append((center, token))
    }
}
