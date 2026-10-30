import Foundation
import LocalAuthentication
import Observation
import os

// MARK: - Intent

/// Why we are asking. Determines the copy macOS renders in its own panel.
enum DeviceAuthIntent: Equatable, Sendable {
    case connect(server: String)
    case unlockVault

    /// Completes "Vibex is trying to ___." — lowercase verb phrase, no trailing period.
    var localizedReason: String {
        switch self {
        case .connect(let server): "use the saved credential for \(server)"
        case .unlockVault: "unlock your saved SSH credentials"
        }
    }

    /// Safe for logs: never a secret, never a hostname.
    var logLabel: String {
        switch self {
        case .connect: "connect"
        case .unlockVault: "unlockVault"
        }
    }
}

// MARK: - Availability

struct DeviceAuthAvailability: Equatable, Sendable {
    enum Method: Equatable, Sendable { case biometric, password, none }

    var method: Method
    var canAuthenticate: Bool
    /// The biometric's own name ("Touch ID"), when one is usable.
    var biometryName: String?
    /// Set when biometric hardware exists but cannot be used right now. Shown verbatim, so the
    /// UI never claims Touch ID that this Mac will not actually offer.
    var biometryHint: String?

    var headline: String {
        switch method {
        case .biometric: "\(biometryName ?? "Biometrics") or your Mac login password"
        case .password: "Your Mac login password"
        case .none: "Unavailable"
        }
    }

    var symbolName: String {
        switch method {
        case .biometric: "touchid"
        case .password: "key.fill"
        case .none: "exclamationmark.shield"
        }
    }

    static let unavailable = DeviceAuthAvailability(
        method: .none, canAuthenticate: false, biometryName: nil, biometryHint: nil
    )
}

// MARK: - Errors

nonisolated enum BiometryUnavailability: Equatable, Sendable {
    case notPaired, disconnected, notEnrolled, notAvailable
}

nonisolated enum DeviceAuthError: Error, Equatable, Sendable {
    case cancelledByUser
    case cancelledBySystem
    case fallbackRequested
    case authenticationFailed
    case lockedOut
    case biometryUnavailable(BiometryUnavailability)
    /// The account has no login password, so `.deviceOwnerAuthentication` cannot run at all.
    case noDeviceOwnerAuthentication
    case notInteractive
    case unknown(code: Int, message: String)
}

nonisolated enum DeviceAuthRecovery: Equatable, Sendable {
    /// The user chose to stop. Say nothing — nagging trains people to click through.
    case dismissSilently
    /// Show the message; the action stays available.
    case retry
    /// Presence cannot be proven on this Mac. Show the message and steer to manual entry.
    case blocked
}

nonisolated extension DeviceAuthError {
    init(_ error: (any Error)?) {
        guard let error = error as NSError?, error.domain == LAErrorDomain else {
            let nsError = error as NSError?
            self = .unknown(
                code: nsError?.code ?? -1,
                message: nsError?.localizedDescription ?? "Authentication failed."
            )
            return
        }
        switch LAError.Code(rawValue: error.code) {
        case .userCancel, .appCancel: self = .cancelledByUser
        case .systemCancel: self = .cancelledBySystem
        case .userFallback: self = .fallbackRequested
        case .authenticationFailed: self = .authenticationFailed
        case .biometryLockout: self = .lockedOut
        case .biometryNotPaired: self = .biometryUnavailable(.notPaired)
        case .biometryDisconnected: self = .biometryUnavailable(.disconnected)
        case .biometryNotEnrolled: self = .biometryUnavailable(.notEnrolled)
        case .biometryNotAvailable: self = .biometryUnavailable(.notAvailable)
        case .passcodeNotSet: self = .noDeviceOwnerAuthentication
        case .notInteractive: self = .notInteractive
        default: self = .unknown(code: error.code, message: error.localizedDescription)
        }
    }

    var recovery: DeviceAuthRecovery {
        switch self {
        case .cancelledByUser: .dismissSilently
        case .cancelledBySystem, .fallbackRequested, .authenticationFailed,
             .lockedOut, .biometryUnavailable, .unknown: .retry
        case .noDeviceOwnerAuthentication, .notInteractive: .blocked
        }
    }

    /// `nil` means "say nothing".
    var message: String? {
        switch self {
        case .cancelledByUser:
            nil
        case .cancelledBySystem:
            "Authentication was interrupted. Try connecting again."
        case .fallbackRequested:
            "Enter your Mac login password to continue."
        case .authenticationFailed:
            "That didn't match. Try again, or type this server's password by hand."
        case .lockedOut:
            "Touch ID is locked. Vibex will ask for your Mac login password instead."
        case .biometryUnavailable(.notPaired), .biometryUnavailable(.disconnected):
            "Your Touch ID keyboard isn't connected. Vibex will ask for your Mac login password instead."
        case .biometryUnavailable(.notEnrolled):
            "No fingerprints are enrolled. Vibex will ask for your Mac login password instead."
        case .biometryUnavailable(.notAvailable):
            "Touch ID isn't available on this Mac. Vibex will ask for your Mac login password instead."
        case .noDeviceOwnerAuthentication:
            """
            This Mac has no login password, so Vibex can't confirm it's you. \
            Set a login password in System Settings › Users & Groups, or type each server's password by hand.
            """
        case .notInteractive:
            "Vibex couldn't show the authentication prompt."
        case .unknown(let code, _):
            "macOS couldn't confirm it's you (error \(code))."
        }
    }

    var diagnostic: String {
        switch self {
        case .unknown(let code, _): "unknown(\(code))"
        default: String(describing: self)
        }
    }
}

// MARK: - Protocol seam

/// Proves that the person at the keyboard is the device owner. A protocol so tests can
/// substitute a deterministic implementation — this is the only thing standing between a
/// stored SSH secret and an SSH session.
@MainActor
protocol DeviceAuthenticating: AnyObject {
    var availability: DeviceAuthAvailability { get }
    func refreshAvailability()
    func authenticate(_ intent: DeviceAuthIntent) async throws(DeviceAuthError)
}

// MARK: - Live implementation

@MainActor
@Observable
final class DeviceAuthenticator: DeviceAuthenticating {
    private(set) var availability: DeviceAuthAvailability

    @ObservationIgnored
    private let log = Logger(subsystem: "com.yusuf.Vibex", category: "device-auth")
    /// `canEvaluatePolicy` is an XPC round-trip to `biometrickitd`; two of them on the main
    /// thread per Connect click is a stall nobody asked for.
    @ObservationIgnored private var lastProbe: ContinuousClock.Instant?
    private static let probeInterval = Duration.seconds(5)

    init() { availability = Self.probeAvailability() }

    func refreshAvailability() {
        lastProbe = .now
        availability = Self.probeAvailability()
    }

    /// Hardware state changes while the app runs — a Touch ID keyboard is paired, a lid closes.
    private func refreshAvailabilityIfStale() {
        if let lastProbe, lastProbe.duration(to: .now) < Self.probeInterval { return }
        refreshAvailability()
    }

    func authenticate(_ intent: DeviceAuthIntent) async throws(DeviceAuthError) {
        refreshAvailabilityIfStale()
        guard availability.canAuthenticate else { throw .noDeviceOwnerAuthentication }

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        // `localizedFallbackTitle` stays nil: with `.deviceOwnerAuthentication` the system
        // presents and handles the login-password fallback inside its own panel. Setting it to
        // "" would hide the very path this requirement depends on.
        //
        // The reuse duration stays 0. An LAContext caches a success for its own lifetime, and
        // this would add a second, invisible grace window that `SessionLock` cannot expire on
        // screen sleep or revoke from "Lock Now". One grace mechanism, and it is ours.
        context.touchIDAuthenticationAllowableReuseDuration = 0

        do {
            try await Self.evaluate(LAContextBox(context), reason: intent.localizedReason)
            log.notice("device auth succeeded (\(intent.logLabel, privacy: .public))")
        } catch {
            log.error("""
                device auth failed (\(intent.logLabel, privacy: .public)): \
                \(error.diagnostic, privacy: .public)
                """)
            throw error
        }
    }

    // MARK: Bridging evaluatePolicy

    /// `evaluatePolicy` is a completion-handler API whose reply arrives on a private queue.
    /// Three hazards, all handled here:
    ///  1. `CheckedContinuation` traps on a second resume — `ResumeGuard` makes it a no-op.
    ///  2. An `LAContext` invalidates itself when released, and its guaranteed lifetime would
    ///     otherwise end at the `evaluatePolicy` call — the box holds it past the suspension.
    ///  3. Task cancellation must dismiss the panel — `invalidate()` makes LocalAuthentication
    ///     deliver `.appCancel` through the same reply block, resuming exactly once.
    ///  4. Vibex's code is main-actor by default, and a reply block inferred as main-actor would
    ///     trap on that private queue. So this function, and all it uses, opts out.
    nonisolated private static func evaluate(_ box: LAContextBox, reason: String) async throws(DeviceAuthError) {
        let resumeGuard = ResumeGuard()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    box.context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                        withExtendedLifetime(box) {}
                        guard resumeGuard.claim() else { return }
                        if success {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: DeviceAuthError(error))
                        }
                    }
                }
            } onCancel: {
                box.context.invalidate()
            }
        } catch let error as DeviceAuthError {
            throw error
        } catch {
            throw DeviceAuthError(error)
        }
    }

    private static func probeAvailability() -> DeviceAuthAvailability {
        let context = LAContext()
        defer { context.invalidate() }

        var anyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &anyError) else {
            return .unavailable
        }

        var biometryError: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometryError) {
            return .init(
                method: .biometric,
                canAuthenticate: true,
                biometryName: context.biometryType.displayName,
                biometryHint: nil
            )
        }

        // Biometric hardware may exist but be unusable. Surface why, honestly, rather than
        // promising a fingerprint prompt that will never appear.
        return .init(
            method: .password,
            canAuthenticate: true,
            biometryName: nil,
            biometryHint: biometryError.flatMap { DeviceAuthError($0).message }
        )
    }
}

/// `LAContext` is not `Sendable`, but `withTaskCancellationHandler`'s `onCancel` is. The box
/// confines it: it never crosses an isolation boundary, both users are on the main actor, and
/// `invalidate()` is documented as safe to call from any thread.
nonisolated private final class LAContextBox: @unchecked Sendable {
    let context: LAContext
    init(_ context: LAContext) { self.context = context }
}

/// `Synchronization.Mutex` is macOS 15+; this app targets macOS 14.
private nonisolated final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

private extension LABiometryType {
    var displayName: String {
        switch self {
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .faceID: "Face ID"
        default: "Biometrics"
        }
    }
}
