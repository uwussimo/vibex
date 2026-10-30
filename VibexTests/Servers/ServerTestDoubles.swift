import Foundation
import LocalAuthentication
import Security
@testable import Vibex

@MainActor
final class FakeDeviceAuthenticator: DeviceAuthenticating {
    var availability = DeviceAuthAvailability(
        method: .biometric, canAuthenticate: true, biometryName: "Touch ID", biometryHint: nil
    )
    /// Popped per call; an empty list means "succeed".
    var scriptedFailures: [DeviceAuthError] = []
    /// When set, `authenticate` parks until `resumeAll()` is called, so a test can act while an
    /// authorization is genuinely in flight.
    var suspends = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var intents: [DeviceAuthIntent] = []
    private(set) var refreshCount = 0

    var callCount: Int { intents.count }

    func refreshAvailability() { refreshCount += 1 }

    func resumeAll() {
        let parked = waiters
        waiters.removeAll()
        parked.forEach { $0.resume() }
    }

    func authenticate(_ intent: DeviceAuthIntent) async throws(DeviceAuthError) {
        intents.append(intent)
        if suspends {
            await withCheckedContinuation { waiters.append($0) }
        }
        guard availability.canAuthenticate else { throw .noDeviceOwnerAuthentication }
        if !scriptedFailures.isEmpty { throw scriptedFailures.removeFirst() }
    }
}

/// A dictionary standing in for `SecItem*`. Honours the subset of the query language this app
/// actually uses: service + account matching, both match limits, attribute and data returns.
final class InMemoryKeychain: KeychainBackend, @unchecked Sendable {
    struct Key: Hashable {
        let service: String
        let account: String
    }

    private let mutex = NSLock()
    private var items: [Key: [String: Any]] = [:]
    private(set) var addCount = 0
    private(set) var readCount = 0
    private(set) var dataReadCount = 0
    private(set) var updateCount = 0
    private(set) var deleteCount = 0
    /// Popped per `add`, so a test can simulate `-34018` or a crash point.
    var scriptedAddStatuses: [OSStatus] = []

    // MARK: KeychainBackend

    func add(_ attributes: [String: Any]) -> OSStatus {
        mutex.lock()
        defer { mutex.unlock() }
        addCount += 1
        if !scriptedAddStatuses.isEmpty {
            let status = scriptedAddStatuses.removeFirst()
            // A scripted *failure* short-circuits; a scripted success still has to store, or the
            // next step of a multi-stage write has nothing to find.
            if status != errSecSuccess { return status }
        }
        guard let key = key(from: attributes) else { return errSecParam }
        if items[key] != nil { return errSecDuplicateItem }
        items[key] = attributes
        return errSecSuccess
    }

    func copyMatching(_ query: [String: Any], _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        mutex.lock()
        defer { mutex.unlock() }
        readCount += 1
        let wantsData = query[kSecReturnData as String] as? Bool ?? false
        let wantsAttributes = query[kSecReturnAttributes as String] as? Bool ?? false
        if wantsData { dataReadCount += 1 }

        let service = query[kSecAttrService as String] as? String
        let account = query[kSecAttrAccount as String] as? String
        let matches = items
            .filter { service == nil || $0.key.service == service }
            .filter { account == nil || $0.key.account == account }
            .sorted { $0.key.account < $1.key.account }

        guard !matches.isEmpty else { return errSecItemNotFound }

        let all = (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String)
        if all {
            result?.pointee = matches.map { attributes(of: $0.value, includingData: wantsData) } as CFArray
            return errSecSuccess
        }

        guard let first = matches.first else { return errSecItemNotFound }
        if wantsData && !wantsAttributes {
            result?.pointee = (first.value[kSecValueData as String] as? Data) as CFTypeRef?
        } else {
            result?.pointee = attributes(of: first.value, includingData: wantsData) as CFDictionary
        }
        return errSecSuccess
    }

    func update(_ query: [String: Any], _ attributesToUpdate: [String: Any]) -> OSStatus {
        mutex.lock()
        defer { mutex.unlock() }
        updateCount += 1
        guard let key = key(from: query), var item = items[key] else { return errSecItemNotFound }
        item.merge(attributesToUpdate) { _, new in new }
        items[key] = item
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        mutex.lock()
        defer { mutex.unlock() }
        deleteCount += 1
        let service = query[kSecAttrService as String] as? String
        let account = query[kSecAttrAccount as String] as? String
        let victims = items.keys
            .filter { service == nil || $0.service == service }
            .filter { account == nil || $0.account == account }
        guard !victims.isEmpty else { return errSecItemNotFound }
        victims.forEach { items.removeValue(forKey: $0) }
        return errSecSuccess
    }

    // MARK: Test helpers

    func seed(service: String, account: String, secret: Data, accessible: CFString) {
        mutex.lock()
        defer { mutex.unlock() }
        items[Key(service: service, account: account)] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: accessible as String,
            kSecValueData as String: secret
        ]
    }

    func accessible(service: String, account: String) -> String? {
        mutex.lock()
        defer { mutex.unlock() }
        return items[Key(service: service, account: account)]?[kSecAttrAccessible as String] as? String
    }

    func secret(service: String, account: String) -> Data? {
        mutex.lock()
        defer { mutex.unlock() }
        return items[Key(service: service, account: account)]?[kSecValueData as String] as? Data
    }

    var keys: [Key] {
        mutex.lock()
        defer { mutex.unlock() }
        return Array(items.keys)
    }

    func resetCounters() {
        mutex.lock()
        defer { mutex.unlock() }
        addCount = 0
        readCount = 0
        dataReadCount = 0
        updateCount = 0
        deleteCount = 0
    }

    private func key(from attributes: [String: Any]) -> Key? {
        guard let service = attributes[kSecAttrService as String] as? String,
              let account = attributes[kSecAttrAccount as String] as? String else { return nil }
        return Key(service: service, account: account)
    }

    private func attributes(of item: [String: Any], includingData: Bool) -> [String: Any] {
        var copy = item
        if !includingData { copy.removeValue(forKey: kSecValueData as String) }
        return copy
    }
}

extension UserDefaults {
    /// A throwaway suite so a test never reads or writes the user's real defaults.
    static func makeEphemeral(_ name: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
