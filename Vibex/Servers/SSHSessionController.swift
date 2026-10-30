import AppKit
import Foundation
import Observation
import os
import SwiftTerm
import SwiftUI

struct CredentialChallenge: Equatable, Sendable {
    let kind: CredentialKind
    let wasAutomaticCredentialRejected: Bool
    /// The stored credential existed but the app had re-locked before the prompt arrived, so it
    /// was deliberately not typed.
    let storedCredentialWithheld: Bool
}

/// One SSH connection in a terminal tab. It watches the terminal's output for `ssh`'s own prompts,
/// and is the only place a saved secret meets the pseudo-terminal.
@MainActor
@Observable
final class SSHSessionController {
    let profile: SSHConnectionProfile
    let terminalView: ManagedTerminalView

    private(set) var credentialChallenge: CredentialChallenge?
    private var promptDetector = CredentialPromptDetector()
    private var grant: CredentialGrant?

    /// Injected so the controller never has to know about `SessionLock`.
    @ObservationIgnored private let isGrantAuthorized: @MainActor (CredentialGrant) -> Bool

    init(
        profile: SSHConnectionProfile,
        terminalView: ManagedTerminalView,
        isGrantAuthorized: @escaping @MainActor (CredentialGrant) -> Bool
    ) {
        self.profile = profile
        self.terminalView = terminalView
        self.isGrantAuthorized = isGrantAuthorized
        terminalView.sessionController = self
    }

    var isRunning: Bool { terminalView.process?.running == true }

    var expectedCredentialKind: CredentialKind {
        profile.authentication == .password ? .password : .keyPassphrase
    }

    /// Throws if the profile can't make a valid `ssh` command, before anything has started.
    func start(grant: CredentialGrant?, builder: SSHCommandBuilder = SSHCommandBuilder()) throws {
        promptDetector.reset()
        self.grant?.discard()
        self.grant = grant
        credentialChallenge = nil
        do {
            let launch = try builder.build(for: profile)
            terminalView.startWatchingOutput()
            terminalView.startProcess(executable: launch.executable, args: launch.arguments, environment: launch.environment)
        } catch {
            discardGrant()
            throw error
        }
    }

    /// Called when the app re-locks. The grant is checked lazily at prompt time, but a session
    /// that never gets prompted — key auth succeeded, DNS is hanging, a host key is awaiting
    /// confirmation — would otherwise hold plaintext for its whole life while the owner is away.
    func discardGrant() {
        grant?.discard()
        grant = nil
    }

    func submitCredential(_ credential: Data) -> Bool {
        guard credentialChallenge != nil, isRunning else { return false }
        credentialChallenge = nil
        SecretBox(credential).consume { terminalView.process.send(data: $0) }
        return true
    }

    func receiveOutput(_ bytes: ArraySlice<UInt8>) {
        guard isRunning else { return }
        guard let detectedKind = promptDetector.consume(bytes) else { return }

        switch AutoSubmitPolicy.decide(
            hasGrant: grant != nil,
            grantIsStillAuthorized: grant.map(isGrantAuthorized) ?? false,
            alreadySubmittedAutomatically: promptDetector.submittedAutomatically,
            detectedKind: detectedKind,
            expectedKind: expectedCredentialKind,
            isRunning: isRunning
        ) {
        case .ignore:
            return

        case .submitStoredSecret:
            guard let grant else { return }
            promptDetector.markSubmittedAutomatically()
            self.grant = nil
            grant.secret.consume { terminalView.process.send(data: $0) }

        case .promptUser(let rejected, let withheld):
            discardGrant()
            credentialChallenge = CredentialChallenge(
                kind: detectedKind,
                wasAutomaticCredentialRejected: rejected,
                storedCredentialWithheld: withheld
            )
        }
    }

    func processDidTerminate() {
        discardGrant()
        credentialChallenge = nil
    }
}

/// The line `ssh` would be prompting on: the cursor's row, with the rows it wrapped from.
enum TerminalPromptLine {
    /// A row filled to the last column is taken as continuing on the next, which is how a long key
    /// path reads once the terminal wraps it. Rows hold their text without trailing blanks.
    static func text(rows: [String], cursorRow: Int, columns: Int) -> String {
        guard rows.indices.contains(cursorRow) else { return "" }
        var line = rows[cursorRow]
        var row = cursorRow - 1
        while row >= 0, rows[row].count >= columns {
            line = rows[row] + line
            row -= 1
        }
        return line
    }
}

/// A terminal that tells its SSH session what it's prompting for.
///
/// SwiftTerm parses output on its own thread and doesn't hand the bytes over, so this reads the
/// screen after each batch instead, through the copies SwiftTerm makes for this purpose.
final class ManagedTerminalView: LocalProcessTerminalView {
    /// `ssh` prompts while connecting. Past this, a "Password:" on screen belongs to the remote
    /// machine, not to `ssh`, and no saved secret should go anywhere near it.
    static let watchLimit: Duration = .seconds(120)

    weak var sessionController: SSHSessionController?
    private var watchStarted = ContinuousClock.now
    /// Where the last prompt was seen. The same text on a new row is a new prompt, which is how a
    /// rejected password reads; on the same row it's the one already answered.
    private var lastLine: (row: Int, text: String)?

    func startWatchingOutput() {
        watchStarted = .now
        lastLine = nil
        let scheduled = OSAllocatedUnfairLock(initialState: false)
        setProcessOutputHandler { [weak self] in
            // Runs on SwiftTerm's thread for every batch: one look at the screen per burst.
            guard scheduled.withLock({ pending in
                defer { pending = true }
                return !pending
            }) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                scheduled.withLock { $0 = false }
                MainActor.assumeIsolated { self?.checkForPrompt() }
            }
        }
    }

    func stopWatchingOutput() { setProcessOutputHandler(nil) }

    private func checkForPrompt() {
        guard ContinuousClock.now - watchStarted < Self.watchLimit else {
            stopWatchingOutput()
            return
        }
        let screen = terminalStateSnapshot()
        let text = TerminalPromptLine.text(rows: screen.visibleRows.map(\.text), cursorRow: screen.cursor.row, columns: screen.dimensions.cols)
        let row = screen.viewportRow + screen.cursor.row
        if let lastLine, lastLine.row == row, lastLine.text == text { return }
        lastLine = (row, text)
        // The detector reads the last line of what it's given, so a newline makes this a whole line.
        sessionController?.receiveOutput(Array(("\n" + text).utf8)[...])
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        stopWatchingOutput()
        sessionController?.processDidTerminate()
        super.processTerminated(source, exitCode: exitCode)
    }
}

/// A terminal with the password prompt laid over it only while one is open. The overlay is added
/// and removed rather than hidden behind an empty hosting view, which would take the terminal's clicks.
final class SSHTerminalContainer: NSView {
    private let session: SSHSessionController
    private let credentials: CredentialAccess
    private var overlay: NSView?

    init(session: SSHSessionController, credentials: CredentialAccess) {
        self.session = session
        self.credentials = credentials
        super.init(frame: .zero)
        let terminal = session.terminalView
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
        observe()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func observe() {
        withObservationTracking {
            _ = session.credentialChallenge
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        overlay?.removeFromSuperview()
        overlay = nil
        guard let challenge = session.credentialChallenge else { return }
        let host = NSHostingView(rootView: CredentialPromptBar(session: session, challenge: challenge, credentials: credentials))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        overlay = host
    }
}
