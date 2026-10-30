import Foundation
import LocalAuthentication
import Testing
@testable import Vibex

@Suite
struct DeviceAuthErrorTests {
    private func error(_ code: LAError.Code) -> DeviceAuthError {
        DeviceAuthError(NSError(domain: LAErrorDomain, code: code.rawValue))
    }

    @Test(arguments: [
        (LAError.Code.userCancel, DeviceAuthError.cancelledByUser, DeviceAuthRecovery.dismissSilently),
        (.appCancel, .cancelledByUser, .dismissSilently),
        (.systemCancel, .cancelledBySystem, .retry),
        (.userFallback, .fallbackRequested, .retry),
        (.authenticationFailed, .authenticationFailed, .retry),
        (.biometryLockout, .lockedOut, .retry),
        (.passcodeNotSet, .noDeviceOwnerAuthentication, .blocked),
        (.notInteractive, .notInteractive, .blocked)
    ])
    func `LocalAuthentication codes map to the documented error and recovery`(
        code: LAError.Code, expected: DeviceAuthError, recovery: DeviceAuthRecovery
    ) {
        #expect(error(code) == expected)
        #expect(error(code).recovery == recovery)
    }

    /// The exact state of this machine: a Touch ID keyboard that is not currently paired. It must
    /// never be reported as blocking, because `.deviceOwnerAuthentication` still works via the
    /// login password.
    @Test func `an unpaired biometric accessory falls back to the login password`() throws {
        let mapped = error(.biometryNotPaired)
        #expect(mapped == .biometryUnavailable(.notPaired))
        #expect(mapped.recovery == .retry)
        let message = try #require(mapped.message)
        #expect(message.contains("login password"))
    }

    @Test func `a user cancel produces no user facing message`() {
        #expect(DeviceAuthError.cancelledByUser.message == nil)
    }

    @Test func `a non LocalAuthentication error falls through to unknown`() {
        let mapped = DeviceAuthError(NSError(domain: "test", code: 7))
        #expect(mapped.recovery == .retry)
        guard case .unknown(let code, _) = mapped else {
            Issue.record("expected an unknown error")
            return
        }
        #expect(code == 7)
    }

    @Test func `an unavailable device reports no method and cannot authenticate`() {
        #expect(!DeviceAuthAvailability.unavailable.canAuthenticate)
        #expect(DeviceAuthAvailability.unavailable.headline == "Unavailable")
    }
}
