import AppKit
import Foundation
import Observation
import os

/// The saved servers, and the one presence gate in front of their credentials. There's one of these
/// for the whole app: a server isn't part of a project, and every window must share one lock.
@Observable
final class ServersModel {
    static let shared = ServersModel(
        file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Vibex/servers.json")
    )

    private(set) var servers: [ServerProfile] = []
    var problem: String?
    let lock: SessionLock
    let credentials: CredentialAccess

    @ObservationIgnored private let file: URL
    /// Open sessions, so a re-lock can scrub any secret they're still holding.
    @ObservationIgnored private var sessions: [SSHSessionController] = []
    @ObservationIgnored private var connectedByFirstClick: UUID?

    init(file: URL, store: (any CredentialStoring)? = nil, authenticator: any DeviceAuthenticating = DeviceAuthenticator()) {
        self.file = file
        let lock = SessionLock(authenticator: authenticator)
        self.lock = lock
        credentials = CredentialAccess(store: store ?? Self.keychain(), lock: lock)
        servers = Self.load(file)
        lock.onRelock = { [weak self] _ in self?.discardGrants() }
        lock.startObserving()
    }

    private static func keychain() -> KeychainCredentialStore {
        let service = "com.yusuf.Vibex.ssh-credentials"
        let store = KeychainCredentialStore(service: service, tier: CredentialProtection.current(service: service).tier)
        do {
            try store.migrateStorage()
        } catch {
            Log.app.error("server credential migration: \(error.localizedDescription, privacy: .public)")
        }
        return store
    }

    // MARK: Saved servers

    var sorted: [ServerProfile] {
        servers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func matching(_ query: String) -> [ServerProfile] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sorted }
        return sorted.filter { server in
            [server.name, server.host, server.username, server.notes].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// Saves the server first: a Keychain failure mustn't lose everything else that was typed.
    @discardableResult
    func save(_ draft: ServerDraft, editing existing: ServerProfile?) -> ServerProfile {
        let profile = draft.applied(to: existing)
        if let index = servers.firstIndex(where: { $0.id == profile.id }) {
            servers[index] = profile
        } else {
            servers.append(profile)
        }
        write()

        do {
            // A method that changed leaves the other kind of secret behind, unusable.
            if let existing, existing.expectedCredentialKind != profile.expectedCredentialKind {
                try credentials.delete(for: profile.id, kind: existing.expectedCredentialKind)
            }
            if draft.saveSecret, !draft.secret.isEmpty {
                var secret = Data(draft.secret.utf8)
                defer { secret.securelyClear() }
                try credentials.store(secret, for: profile.id, kind: profile.expectedCredentialKind)
            } else if !draft.saveSecret {
                try credentials.delete(for: profile.id, kind: profile.expectedCredentialKind)
            }
        } catch {
            problem = error.localizedDescription
        }
        return profile
    }

    func delete(_ server: ServerProfile) {
        servers.removeAll { $0.id == server.id }
        write()
        do {
            try credentials.deleteAll(for: server.id)
        } catch {
            problem = error.localizedDescription
        }
    }

    func forgetSecret(of server: ServerProfile) {
        do {
            try credentials.deleteAll(for: server.id)
        } catch {
            problem = error.localizedDescription
        }
    }

    func hasSecret(_ server: ServerProfile) -> Bool {
        (try? credentials.hasCredential(for: server.id, kind: server.expectedCredentialKind)) ?? false
    }

    private static func load(_ file: URL) -> [ServerProfile] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        do {
            return try JSONDecoder().decode([ServerProfile].self, from: data)
        } catch {
            Log.app.error("couldn't read servers: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(servers).write(to: file, options: .atomic)
            // Hostnames and usernames aren't secrets, but they're nobody else's business.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            problem = "Couldn't save your servers: \(error.localizedDescription)"
        }
    }

    // MARK: Connecting

    enum ServerClick: Equatable { case focus, connect, nothing }

    /// One click goes to the server's tab, or connects if it has none. A double-click opens another,
    /// unless its first click just opened the only one: that's one tab, and one Touch ID.
    func click(on id: UUID, count: Int, hasOpenTab: Bool) -> ServerClick {
        switch count {
        case 1:
            connectedByFirstClick = hasOpenTab ? nil : id
            return hasOpenTab ? .focus : .connect
        case 2:
            return connectedByFirstClick == id ? .nothing : .connect
        default:
            return .nothing
        }
    }

    /// The only path from a saved secret to a live SSH session, and it opens with the presence
    /// gate: nothing reaches the tab until Touch ID or the login password says it's the owner.
    func connect(_ server: ServerProfile, opening open: (SSHConnectionProfile) -> SSHSessionController?) async {
        do {
            let grant = try await credentials.grant(for: server.id, kind: server.expectedCredentialKind, intent: .connect(server: server.name))
            guard let session = open(SSHConnectionProfile(profile: server)) else {
                grant?.discard()
                return
            }
            sessions.removeAll { !$0.isRunning }
            sessions.append(session)
            try session.start(grant: grant)
            if let index = servers.firstIndex(where: { $0.id == server.id }) {
                servers[index].lastConnectedAt = .now
                write()
            }
        } catch let error as DeviceAuthError {
            if error.recovery != .dismissSilently { problem = error.message }
        } catch {
            problem = error.localizedDescription
        }
    }

    func isGrantAuthorized(_ grant: CredentialGrant) -> Bool { credentials.isAuthorized(grant) }

    /// Locking never touches a live pseudo-terminal: the shell was opened by the authenticated
    /// owner and killing it protects nothing. But every unused secret is scrubbed at once.
    private func discardGrants() {
        sessions.forEach { $0.discardGrant() }
    }
}
