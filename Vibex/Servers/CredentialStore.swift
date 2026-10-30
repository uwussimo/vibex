import Foundation
import Security
import os

/// Reading a secret out of this store is *not* gated — `CredentialAccess` is the only type that
/// may call it, and it is what enforces presence. Views never see a `CredentialStoring`.
@MainActor
protocol CredentialStoring: AnyObject {
    func credential(for serverID: UUID, kind: CredentialKind) throws -> Data?
    /// Attributes-only existence check: returns no secret bytes, so a passphrase-less key can
    /// connect without an authentication prompt it does not need.
    func hasCredential(for serverID: UUID, kind: CredentialKind) throws -> Bool
    func setCredential(_ credential: Data, for serverID: UUID, kind: CredentialKind) throws
    func deleteCredential(for serverID: UUID, kind: CredentialKind) throws
    func deleteAllCredentials(for serverID: UUID) throws
    /// Removes every secret this app has stored, for every server.
    func deleteEverything() throws
    /// Idempotent. Safe to call on every launch.
    func migrateStorage() throws
}

enum CredentialStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            if status == errSecAuthFailed {
                return """
                    macOS denied Keychain access. If Vibex was just rebuilt, quit the app \
                    completely, reopen it, and try saving the credential again.
                    """
            }
            if status == errSecInteractionNotAllowed {
                return "Keychain is locked or unavailable. Unlock your Mac, then try again."
            }
            if status == errSecUserCanceled {
                return "Keychain access was canceled. Your SSH credential was not saved."
            }
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
            return "Keychain error: \(message) (\(status))"
        }
    }
}

@MainActor
final class KeychainCredentialStore: CredentialStoring {
    private static let schemaVersion = 2
    private static let schemaVersionKey = "servers.credentialSchemaVersion"

    private let service: String
    private let backend: any KeychainBackend
    /// Raised once the launch-time probe reports what this build's signature actually allows.
    var tier: CredentialProtectionTier
    private let defaults: UserDefaults
    private let log = Logger(subsystem: "com.yusuf.Vibex", category: "credential-store")

    init(
        service: String = "com.yusuf.Vibex.ssh-credentials",
        backend: any KeychainBackend = SecItemBackend(),
        tier: CredentialProtectionTier = .legacyKeychain,
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.backend = backend
        self.tier = tier
        self.defaults = defaults
    }

    // MARK: Reads

    func credential(for serverID: UUID, kind: CredentialKind) throws -> Data? {
        var query = baseQuery(account: account(serverID, kind))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = backend.copyMatching(query, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        return result as? Data
    }

    func hasCredential(for serverID: UUID, kind: CredentialKind) throws -> Bool {
        var query = baseQuery(account: account(serverID, kind))
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = backend.copyMatching(query, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        return true
    }

    // MARK: Writes

    func setCredential(_ credential: Data, for serverID: UUID, kind: CredentialKind) throws {
        // Replace rather than update: `SecItemUpdate` cannot reliably change
        // `kSecAttrAccessible`, and silently succeeding would pin an item created by an older
        // build at its old accessibility forever.
        try write(credential, account: account(serverID, kind), service: service)
    }

    func deleteCredential(for serverID: UUID, kind: CredentialKind) throws {
        let status = backend.delete(baseQuery(account: account(serverID, kind)))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    func deleteAllCredentials(for serverID: UUID) throws {
        try deleteCredential(for: serverID, kind: .password)
        try deleteCredential(for: serverID, kind: .keyPassphrase)
    }

    func deleteEverything() throws {
        for service in [service, stagingService] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrSynchronizable as String: false
            ]
            if tier.usesDataProtectionKeychain {
                query[kSecUseDataProtectionKeychain as String] = true
            }
            let status = backend.delete(query)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialStoreError.keychain(status)
            }
        }
    }

    // MARK: Migration

    private var stagingService: String { service + ".migration" }

    /// Upgrades items written by an older build to `ThisDeviceOnly` accessibility.
    ///
    /// `SecItemUpdate` cannot change `kSecAttrAccessible`, so this is a replace. The secret never
    /// leaves the Keychain during the replace — the staging copy is another Keychain item — and
    /// every intermediate state is recoverable on the next launch.
    func migrateStorage() throws {
        // Always recover first: a crash on a previous run may have left a staging copy behind.
        try recoverStagedItems()

        guard defaults.integer(forKey: Self.schemaVersionKey) < Self.schemaVersion else { return }

        for item in try allItems(in: service) {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            let accessible = item[kSecAttrAccessible as String] as? String
            // Attributes-only so far: reading every secret at launch would fire an interactive
            // Keychain panel per item on the first run after any rebuild.
            if accessible == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String) { continue }

            var query = baseQuery(account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard backend.copyMatching(query, &result) == errSecSuccess,
                  var secret = result as? Data else { continue }
            defer { secret.securelyClear() }

            try replaceViaStaging(account: account, secret: secret)
            log.notice("migrated a stored credential to ThisDeviceOnly accessibility")
        }

        defaults.set(Self.schemaVersion, forKey: Self.schemaVersionKey)
    }

    /// Intermediate states, all recoverable:
    ///   after 1: staging + primary present -> recover deletes staging, primary wins
    ///   after 2: staging only              -> recover re-adds primary from staging
    ///   after 3: staging + primary present -> recover deletes staging, primary wins
    private func replaceViaStaging(account: String, secret: Data) throws {
        try write(secret, account: account, service: stagingService, replacingExisting: true)   // 1

        let deleteOriginal = backend.delete(baseQuery(account: account))                        // 2
        guard deleteOriginal == errSecSuccess || deleteOriginal == errSecItemNotFound else {
            throw CredentialStoreError.keychain(deleteOriginal)
        }

        do {
            try write(secret, account: account, service: service, replacingExisting: false)     // 3
        } catch {
            // Leave staging in place; the next launch's recovery restores it.
            throw error
        }

        _ = backend.delete(baseQuery(account: account, service: stagingService))                // 4
    }

    /// One query against a service that is normally empty, and the reason a crash mid-migration
    /// cannot lose a secret. Runs on every launch regardless of schema version.
    private func recoverStagedItems() throws {
        for item in try allItems(in: stagingService) {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }

            var primaryQuery = baseQuery(account: account)
            primaryQuery[kSecReturnAttributes as String] = true
            primaryQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            var primary: CFTypeRef?
            let primaryStatus = backend.copyMatching(primaryQuery, &primary)

            if primaryStatus == errSecItemNotFound {
                var stagedQuery = baseQuery(account: account, service: stagingService)
                stagedQuery[kSecReturnData as String] = true
                stagedQuery[kSecMatchLimit as String] = kSecMatchLimitOne
                var staged: CFTypeRef?
                guard backend.copyMatching(stagedQuery, &staged) == errSecSuccess,
                      var secret = staged as? Data else { continue }
                defer { secret.securelyClear() }
                try write(secret, account: account, service: service, replacingExisting: false)
                log.notice("recovered a staged credential after an interrupted migration")
            }

            _ = backend.delete(baseQuery(account: account, service: stagingService))
        }
    }

    // MARK: Queries

    private func account(_ serverID: UUID, _ kind: CredentialKind) -> String {
        "\(serverID.uuidString).\(kind.rawValue)"
    }

    /// The data-protection flag must be threaded through *every* query. A write that lands in one
    /// keychain and a read that queries the other returns `errSecItemNotFound` for everything.
    private func baseQuery(account: String, service: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service ?? self.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
        if tier.usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is documented for the data-protection
    /// keychain. On the legacy keychain it is accepted and stored but has no observable
    /// protective effect — it is set because it costs nothing, because ThisDeviceOnly semantics
    /// are right for an SSH secret regardless, and because it is the correct value if this app is
    /// ever distributed with a provisioning profile. It is deliberately *not* quoted in the UI as
    /// a protection the user currently has.
    private var hardenedAttributes: [String: Any] {
        [
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: "Vibex — SSH credential",
            kSecAttrDescription as String: "SSH password or key passphrase"
        ]
    }

    private func write(
        _ secret: Data,
        account: String,
        service: String,
        replacingExisting: Bool = true
    ) throws {
        if replacingExisting {
            let status = backend.delete(baseQuery(account: account, service: service))
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialStoreError.keychain(status)
            }
        }
        var item = baseQuery(account: account, service: service)
        item.merge(hardenedAttributes) { _, new in new }
        item[kSecValueData as String] = secret
        let status = backend.add(item)
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
    }

    private func allItems(in service: String) throws -> [[String: Any]] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        if tier.usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }

        var result: CFTypeRef?
        let status = backend.copyMatching(query, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        return result as? [[String: Any]] ?? []
    }
}

extension Data {
    /// Best effort: `Data` is copy-on-write, so this releases *our* view of the bytes. Secrets
    /// that must not linger are held in `SecretBox`, which owns a uniquely-referenced buffer.
    mutating func securelyClear() {
        withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            memset_s(address, buffer.count, 0, buffer.count)
        }
        removeAll(keepingCapacity: false)
    }
}
