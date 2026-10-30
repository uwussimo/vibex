import Foundation

enum AuthenticationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case privateKey

    var id: Self { self }

    var title: String {
        switch self {
        case .password: "Password"
        case .privateKey: "Private Key"
        }
    }
}

enum CredentialKind: String, Sendable {
    case password
    case keyPassphrase

    var promptTitle: String {
        switch self {
        case .password: "SSH Password"
        case .keyPassphrase: "Key Passphrase"
        }
    }
}

/// A saved server. No secrets here: this is written to a plain file, and passwords and key
/// passphrases live only in the Keychain.
struct ServerProfile: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var host: String
    var port = 22
    var username = "root"
    var authentication = AuthenticationKind.password
    var privateKeyPath: String?
    var notes = ""
    var lastConnectedAt: Date?

    var expectedCredentialKind: CredentialKind { authentication == .password ? .password : .keyPassphrase }
}

struct ServerDraft: Equatable, Sendable {
    var name = ""
    var host = ""
    var port = 22
    var username = "root"
    var authentication: AuthenticationKind = .password
    var privateKeyPath = ""
    var notes = ""
    var secret = ""
    var saveSecret = true

    init() {}

    init(profile: ServerProfile) {
        name = profile.name
        host = profile.host
        port = profile.port
        username = profile.username
        authentication = profile.authentication
        privateKeyPath = profile.privateKeyPath ?? ""
        notes = profile.notes
        saveSecret = true
    }

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a name for this server."
        }
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a hostname or IP address."
        }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter an SSH username."
        }
        if !(1...65_535).contains(port) {
            return "Port must be between 1 and 65535."
        }
        if authentication == .privateKey,
           privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Choose a private key file."
        }
        return nil
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedKeyPath: String? {
        let value = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : (value as NSString).expandingTildeInPath
    }

    /// The draft's fields on a new or existing profile, leaving its identity and history alone.
    func applied(to profile: ServerProfile?) -> ServerProfile {
        var result = profile ?? ServerProfile(name: trimmedName, host: trimmedHost)
        result.name = trimmedName
        result.host = trimmedHost
        result.port = port
        result.username = trimmedUsername
        result.authentication = authentication
        result.privateKeyPath = authentication == .privateKey ? trimmedKeyPath : nil
        result.notes = notes
        return result
    }
}

struct SSHConnectionProfile: Equatable, Sendable {
    let id: UUID
    let name: String
    let host: String
    let port: Int
    let username: String
    let authentication: AuthenticationKind
    let privateKeyPath: String?

    init(
        id: UUID,
        name: String,
        host: String,
        port: Int,
        username: String,
        authentication: AuthenticationKind,
        privateKeyPath: String?
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.privateKeyPath = privateKeyPath
    }

    init(profile: ServerProfile) {
        id = profile.id
        name = profile.name
        host = profile.host
        port = profile.port
        username = profile.username
        authentication = profile.authentication
        privateKeyPath = profile.privateKeyPath
    }
}

/// `user@host:port`, with the port written as digits.
///
/// Interpolating an `Int` into a `Text` runs it through the user's locale, so port 2222 renders
/// as "2 222" or "2,222" in most of the world. A port is an identifier, not a quantity.
protocol SSHEndpointDescribing {
    var username: String { get }
    var host: String { get }
    var port: Int { get }
}

extension SSHEndpointDescribing {
    var endpointDescription: String { "\(username)@\(host):\(String(port))" }
}

extension ServerProfile: SSHEndpointDescribing {}
extension SSHConnectionProfile: SSHEndpointDescribing {}
