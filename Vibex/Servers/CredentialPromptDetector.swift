import Foundation

struct CredentialPromptDetector: Sendable {
    private(set) var submittedAutomatically = false
    private var rollingText = ""

    mutating func reset() {
        submittedAutomatically = false
        rollingText = ""
    }

    mutating func markSubmittedAutomatically() {
        submittedAutomatically = true
    }

    mutating func consume(_ bytes: ArraySlice<UInt8>) -> CredentialKind? {
        let decoded = String(decoding: bytes, as: UTF8.self)
        rollingText.append(decoded)
        if rollingText.count > 1_024 {
            rollingText = String(rollingText.suffix(1_024))
        }

        let normalized = Self.removingANSI(from: rollingText)
            .lowercased()
            .replacingOccurrences(of: "\r", with: "\n")
        let currentLine = normalized.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? normalized

        if currentLine.range(of: #"enter passphrase for key ['\"].*['\"]:\s*$"#, options: .regularExpression) != nil {
            rollingText = ""
            return .keyPassphrase
        }
        if currentLine.range(of: #"(^|.*@.*'s )password:\s*$"#, options: .regularExpression) != nil {
            rollingText = ""
            return .password
        }
        return nil
    }

    private static func removingANSI(from value: String) -> String {
        value.replacingOccurrences(
            of: "\u{001B}(?:\\[[0-?]*[ -/]*[@-~]|\\][^\u{0007}]*(?:\u{0007}|\u{001B}\\\\))",
            with: "",
            options: .regularExpression
        )
    }
}
