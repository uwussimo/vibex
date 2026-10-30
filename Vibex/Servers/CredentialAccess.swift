import Foundation
import Observation

/// Owns a secret's bytes for the short window between the Keychain and the pseudo-terminal.
///
/// A `Data` cannot be scrubbed: it is copy-on-write, so zeroing one view copies the buffer and
/// zeroes the copy while the original lives on. `SecretBox` owns a uniquely-referenced `[UInt8]`,
/// hands it to the writer exactly once without ever returning it, and wipes on the way out — and
/// again in `deinit`, so an abandoned grant does not leave plaintext in the heap.
nonisolated final class SecretBox {
    private var bytes: [UInt8]
    private(set) var isConsumed = false

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var isEmpty: Bool { bytes.isEmpty }

    /// Calls `body` once with the secret followed by a newline, then wipes both buffers.
    /// Returns `nil` if the box was already consumed or wiped.
    @discardableResult
    func consume<T>(_ body: (ArraySlice<UInt8>) -> T) -> T? {
        guard !isConsumed, !bytes.isEmpty else { return nil }
        isConsumed = true
        var line = bytes
        line.append(0x0A)
        defer {
            Self.wipe(&line)
            wipe()
        }
        return body(line[...])
    }

    func wipe() {
        Self.wipe(&bytes)
        bytes.removeAll(keepingCapacity: false)
    }

    deinit { wipe() }

    private static func wipe(_ buffer: inout [UInt8]) {
        buffer.withUnsafeMutableBytes { raw in
            guard let address = raw.baseAddress else { return }
            memset_s(address, raw.count, 0, raw.count)
        }
    }
}

/// A secret plus proof of when, and under which lock generation, its use was authorised.
struct CredentialGrant {
    let secret: SecretBox
    let generation: UInt64
    let issuedAt: ContinuousClock.Instant

    func discard() { secret.wipe() }
}

/// What to do when `ssh` prints a credential prompt. Extracted as a pure function so it is
/// testable without a pseudo-terminal or an `NSView`.
enum AutoSubmitDecision: Equatable, Sendable {
    case submitStoredSecret
    case promptUser(automaticCredentialRejected: Bool, storedCredentialWithheld: Bool)
    case ignore
}

enum AutoSubmitPolicy {
    static func decide(
        hasGrant: Bool,
        grantIsStillAuthorized: Bool,
        alreadySubmittedAutomatically: Bool,
        detectedKind: CredentialKind,
        expectedKind: CredentialKind,
        isRunning: Bool
    ) -> AutoSubmitDecision {
        guard isRunning, detectedKind == expectedKind else { return .ignore }
        if alreadySubmittedAutomatically {
            return .promptUser(automaticCredentialRejected: true, storedCredentialWithheld: false)
        }
        guard hasGrant else {
            return .promptUser(automaticCredentialRejected: false, storedCredentialWithheld: false)
        }
        guard grantIsStillAuthorized else {
            // Locked between retrieval and the prompt. Refuse to type it; ask the human.
            return .promptUser(automaticCredentialRejected: false, storedCredentialWithheld: true)
        }
        return .submitStoredSecret
    }
}

/// The single door to a stored secret.
///
/// Views are given a `CredentialAccess`, never a `CredentialStoring`, and the only method that
/// returns secret bytes begins by awaiting the presence gate. A tenth call site added in six
/// months cannot bypass it, because there is no ungated read to call.
@MainActor
@Observable
final class CredentialAccess {
    /// Retrieval and use are not simultaneous: DNS, `ConnectTimeout=15`, a host-key confirmation
    /// or a slow PAM stack can sit between them. Past this age the grant is refused even if the
    /// lock never moved.
    static let maxGrantAge = Duration.seconds(120)

    @ObservationIgnored private let store: any CredentialStoring
    @ObservationIgnored private let lock: SessionLock
    /// Injected so grant expiry is testable without sleeping.
    @ObservationIgnored var now: @MainActor () -> ContinuousClock.Instant = { .now }

    init(store: any CredentialStoring, lock: SessionLock) {
        self.store = store
        self.lock = lock
    }

    /// Returns `nil` — without prompting — when nothing is stored, so a passphrase-less private
    /// key connects with no friction at all.
    func grant(for serverID: UUID, kind: CredentialKind, intent: DeviceAuthIntent) async throws -> CredentialGrant? {
        guard try store.hasCredential(for: serverID, kind: kind) else { return nil }

        // The gate runs before the read, and the grant is stamped with the generation
        // `authorize` returned — never re-read from the lock afterwards, which would validate a
        // re-lock away.
        let generation = try await lock.authorize(intent)

        guard var secret = try store.credential(for: serverID, kind: kind) else { return nil }
        defer { secret.securelyClear() }
        return CredentialGrant(secret: SecretBox(secret), generation: generation, issuedAt: now())
    }

    func isAuthorized(_ grant: CredentialGrant) -> Bool {
        guard grant.generation == lock.generation else { return false }
        return grant.issuedAt.duration(to: now()) <= Self.maxGrantAge
    }

    // Storing and destroying are deliberately ungated. Typing a secret *is* the presence proof,
    // and putting an authentication prompt in front of deletion only trains people to approve
    // prompts reflexively — deleting a secret makes the world safer.

    func hasCredential(for serverID: UUID, kind: CredentialKind) throws -> Bool {
        try store.hasCredential(for: serverID, kind: kind)
    }

    func store(_ secret: Data, for serverID: UUID, kind: CredentialKind) throws {
        try store.setCredential(secret, for: serverID, kind: kind)
    }

    func delete(for serverID: UUID, kind: CredentialKind) throws {
        try store.deleteCredential(for: serverID, kind: kind)
    }

    func deleteAll(for serverID: UUID) throws {
        try store.deleteAllCredentials(for: serverID)
    }

    func deleteEverything() throws {
        try store.deleteEverything()
    }
}
