import Foundation

struct SSHLaunchConfiguration: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String]
}

enum SSHCommandBuilderError: LocalizedError, Equatable {
    case invalidHost
    case invalidUsername
    case invalidPort
    case missingPrivateKey
    case privateKeyNotReadable

    var errorDescription: String? {
        switch self {
        case .invalidHost: "The hostname or IP address is empty."
        case .invalidUsername: "The SSH username is empty."
        case .invalidPort: "The SSH port must be between 1 and 65535."
        case .missingPrivateKey: "No private key was selected."
        case .privateKeyNotReadable: "The selected private key cannot be read."
        }
    }
}

struct SSHCommandBuilder: Sendable {
    /// More `ssh` arguments, placed before the host.
    var extraArguments: [String] = []

    func build(for profile: SSHConnectionProfile) throws -> SSHLaunchConfiguration {
        let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw SSHCommandBuilderError.invalidHost }
        guard !username.isEmpty else { throw SSHCommandBuilderError.invalidUsername }
        guard (1...65_535).contains(profile.port) else { throw SSHCommandBuilderError.invalidPort }

        var arguments = [
            "-tt",
            "-p", String(profile.port),
            "-l", username,
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3"
        ]

        switch profile.authentication {
        case .password:
            arguments += [
                "-o", "PubkeyAuthentication=no",
                "-o", "PreferredAuthentications=keyboard-interactive,password"
            ]
        case .privateKey:
            guard let rawPath = profile.privateKeyPath, !rawPath.isEmpty else {
                throw SSHCommandBuilderError.missingPrivateKey
            }
            let path = (rawPath as NSString).expandingTildeInPath
            guard FileManager.default.isReadableFile(atPath: path) else {
                throw SSHCommandBuilderError.privateKeyNotReadable
            }
            arguments += [
                "-i", path,
                "-o", "IdentitiesOnly=yes",
                "-o", "PreferredAuthentications=publickey"
            ]
        }

        arguments += extraArguments
        arguments.append(host)

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LC_ALL"] = "C"
        let environmentArray = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()

        return SSHLaunchConfiguration(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            environment: environmentArray
        )
    }
}
