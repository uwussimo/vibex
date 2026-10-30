import Testing
@testable import Vibex

@Suite
struct AutoSubmitPolicyTests {
    private func decide(
        hasGrant: Bool = true,
        authorized: Bool = true,
        alreadySubmitted: Bool = false,
        detected: CredentialKind = .password,
        expected: CredentialKind = .password,
        isRunning: Bool = true
    ) -> AutoSubmitDecision {
        AutoSubmitPolicy.decide(
            hasGrant: hasGrant,
            grantIsStillAuthorized: authorized,
            alreadySubmittedAutomatically: alreadySubmitted,
            detectedKind: detected,
            expectedKind: expected,
            isRunning: isRunning
        )
    }

    @Test func `a fresh grant is submitted automatically`() {
        #expect(decide() == .submitStoredSecret)
    }

    @Test func `a grant revoked by a relock is withheld and the user is asked`() {
        #expect(decide(authorized: false)
                == .promptUser(automaticCredentialRejected: false, storedCredentialWithheld: true))
    }

    @Test func `a rejected automatic credential prompts without claiming it was withheld`() {
        #expect(decide(alreadySubmitted: true)
                == .promptUser(automaticCredentialRejected: true, storedCredentialWithheld: false))
    }

    @Test func `no stored credential prompts the user`() {
        #expect(decide(hasGrant: false, authorized: false)
                == .promptUser(automaticCredentialRejected: false, storedCredentialWithheld: false))
    }

    @Test func `a prompt for the other credential kind is ignored`() {
        #expect(decide(detected: .keyPassphrase, expected: .password) == .ignore)
    }

    @Test func `a dead process is ignored`() {
        #expect(decide(isRunning: false) == .ignore)
    }
}
