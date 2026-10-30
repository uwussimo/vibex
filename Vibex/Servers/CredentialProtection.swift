import Foundation
import Security
import os

/// Every `SecItem*` call in the app goes through here, so migration and probing are testable
/// without touching the real keychain.
protocol KeychainBackend: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any], _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func update(_ query: [String: Any], _ attributesToUpdate: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

/// `[String: Any]` in a `Sendable` protocol is safe here: every method is synchronous and
/// nonisolated, so no dictionary ever crosses an isolation boundary.
struct SecItemBackend: KeychainBackend {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func copyMatching(_ query: [String: Any], _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, result)
    }

    func update(_ query: [String: Any], _ attributesToUpdate: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// How strongly macOS itself protects the stored secret — as opposed to how strongly this app
/// gates access to it.
enum CredentialProtectionTier: Int, Comparable, Sendable, Codable {
    /// File-based login keychain. macOS attaches no lock of its own; the app's presence gate is
    /// the only thing enforcing authentication.
    case legacyKeychain = 0
    /// Data-protection keychain: readable only by apps carrying this signing identity.
    case dataProtection = 1
    /// Data-protection keychain plus a user-presence ACL on the item, so macOS enforces
    /// authentication whether or not this app asks.
    case userPresence = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var usesDataProtectionKeychain: Bool { self >= .dataProtection }
}

/// Walks down from the strongest available protection so the app upgrades itself automatically
/// if it is ever distributed with a provisioning profile. On a personal, ad-hoc-signed build
/// both strong forms return `errSecMissingEntitlement` (-34018) and it settles on tier 0.
struct CredentialProtectionProbe: Sendable {
    struct Result: Sendable, Codable, Equatable {
        var tier: CredentialProtectionTier
        var diagnostics: [String]
    }

    let backend: any KeychainBackend
    let service: String
    private let account = "protection-probe"

    init(backend: any KeychainBackend, service: String) {
        self.backend = backend
        self.service = service
    }

    /// Writes a throwaway one-byte item — never a real secret — and deletes it again.
    func detect() -> Result {
        var diagnostics: [String] = []
        cleanUp()

        if let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil
        ) {
            var item = probeItem()
            item[kSecUseDataProtectionKeychain as String] = true
            item[kSecAttrAccessControl as String] = access
            let status = backend.add(item)
            if status == errSecSuccess {
                cleanUp()
                return Result(tier: .userPresence, diagnostics: diagnostics)
            }
            diagnostics.append("User-presence lock unavailable: \(Self.describe(status))")
        } else {
            diagnostics.append("User-presence lock unavailable: the access-control object could not be created.")
        }

        var item = probeItem()
        item[kSecUseDataProtectionKeychain as String] = true
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = backend.add(item)
        if status == errSecSuccess {
            cleanUp()
            return Result(tier: .dataProtection, diagnostics: diagnostics)
        }
        diagnostics.append("Data-protection keychain unavailable: \(Self.describe(status))")

        cleanUp()
        return Result(tier: .legacyKeychain, diagnostics: diagnostics)
    }

    private func probeItem() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: Data([0])
        ]
    }

    /// Both keychains, because a probe that succeeded at tier 1 or 2 left its item in the
    /// data-protection one, where a legacy query cannot see it.
    private func cleanUp() {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
        _ = backend.delete(base)
        var dataProtection = base
        dataProtection[kSecUseDataProtectionKeychain as String] = true
        _ = backend.delete(dataProtection)
    }

    static func describe(_ status: OSStatus) -> String {
        if status == errSecMissingEntitlement {
            return "errSecMissingEntitlement (-34018) — this build carries no provisioning profile."
        }
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "\(text) (\(status))"
    }
}

/// Caches the probe result against the binary's signing identity, so a re-probe happens exactly
/// when it could change its answer: the day the app is signed differently.
@MainActor
enum CredentialProtection {
    private static let resultKey = "servers.protectionProbe.result"
    private static let fingerprintKey = "servers.protectionProbe.fingerprint"
    private static let log = Logger(subsystem: "com.yusuf.Vibex", category: "protection")

    static func current(
        backend: any KeychainBackend = SecItemBackend(),
        service: String,
        defaults: UserDefaults = .standard
    ) -> CredentialProtectionProbe.Result {
        let fingerprint = signingFingerprint()
        if defaults.string(forKey: fingerprintKey) == fingerprint,
           let data = defaults.data(forKey: resultKey),
           let cached = try? JSONDecoder().decode(CredentialProtectionProbe.Result.self, from: data) {
            return cached
        }

        let result = CredentialProtectionProbe(backend: backend, service: service).detect()
        if let encoded = try? JSONEncoder().encode(result) {
            defaults.set(encoded, forKey: resultKey)
            defaults.set(fingerprint, forKey: fingerprintKey)
        }
        log.notice("credential protection tier: \(result.tier.rawValue, privacy: .public)")
        return result
    }

    /// Ad-hoc signing yields no team identifier, so this is stable across rebuilds (no pointless
    /// re-probes) and changes the moment a real team is attached.
    private static func signingFingerprint() -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "unsigned" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return "unsigned"
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info
        ) == errSecSuccess, let dictionary = info as? [String: Any] else { return "unsigned" }

        let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String ?? "-"
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String ?? "-"
        return "\(identifier)|\(team)"
    }
}
