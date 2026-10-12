import Foundation

enum ShellError: Error, LocalizedError {
    case failed(command: String, status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case let .failed(command, status, message):
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\((command as NSString).lastPathComponent) exited with \(status)\(text.isEmpty ? "" : ": \(text)")"
        }
    }
}

/// Runs a command to completion and returns stdout. Blocking; call from `@concurrent` code.
nonisolated enum Shell {
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
            throw ShellError.failed(command: ([executable] + arguments).joined(separator: " "), status: process.terminationStatus, message: message)
        }
        return data
    }

    /// First executable found among the candidates.
    static func find(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
