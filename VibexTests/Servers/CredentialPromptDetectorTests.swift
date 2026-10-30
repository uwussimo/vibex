import Foundation
import Testing
@testable import Vibex

@Suite
struct CredentialPromptDetectorTests {
    @Test func `a password prompt split across two reads is still detected`() {
        var detector = CredentialPromptDetector()

        #expect(detector.consume(Array("root@example.com's pass".utf8)[...]) == nil)
        #expect(detector.consume(Array("word: ".utf8)[...]) == .password)
    }

    @Test func `a passphrase prompt wrapped in colour escapes is detected`() {
        var detector = CredentialPromptDetector()
        let prompt = "\u{001B}[33mEnter passphrase for key '/Users/test/.ssh/id_ed25519':\u{001B}[0m "

        #expect(detector.consume(Array(prompt.utf8)[...]) == .keyPassphrase)
    }

    @Test(arguments: [
        "[sudo] password for root: ",
        "Password for the database is stored elsewhere\n",
        "echo 'password:' > /tmp/x\n"
    ])
    func `text that is not an SSH prompt is left alone`(output: String) {
        var detector = CredentialPromptDetector()
        #expect(detector.consume(Array(output.utf8)[...]) == nil)
    }

    @Test func `resetting allows a fresh automatic submission`() {
        var detector = CredentialPromptDetector()
        detector.markSubmittedAutomatically()
        #expect(detector.submittedAutomatically)

        detector.reset()
        #expect(!detector.submittedAutomatically)
    }
}

@Suite struct TerminalPromptLineTests {
    @Test func `the prompt is read from the cursor's row`() {
        #expect(TerminalPromptLine.text(rows: ["Welcome", "me@host's password: "], cursorRow: 1, columns: 80) == "me@host's password: ")
    }

    @Test func `a long key path wrapped by the terminal reads as one line`() {
        let first = "Enter passphrase for key '/Users/me/.ssh"
        let second = "/id_ed25519': "
        let rows = ["unrelated", first, second]
        let line = TerminalPromptLine.text(rows: rows, cursorRow: 2, columns: first.count)
        #expect(line == first + second)
        var detector = CredentialPromptDetector()
        #expect(detector.consume(Array(("\n" + line).utf8)[...]) == .keyPassphrase)
    }

    @Test func `a cursor off the screen reads as nothing`() {
        #expect(TerminalPromptLine.text(rows: ["a"], cursorRow: 5, columns: 80).isEmpty)
    }
}
