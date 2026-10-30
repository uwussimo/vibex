import SwiftUI

/// The highest-stakes surface in the app. Every decision here is subordinate to three things:
/// the user must know **which host** is asking, **what** it wants, and that **their keystrokes
/// are going to this field** rather than into the live pseudo-terminal behind it.
struct CredentialPromptBar: View {
    let session: SSHSessionController
    let challenge: CredentialChallenge
    let credentials: CredentialAccess

    @State private var secret = ""
    @State private var saveInKeychain = true
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(challenge.wasAutomaticCredentialRejected ? Color.orange : Color.secondary)
                Text(headline)
                    .font(.callout.weight(.medium))
                    // Never .secondary on a security prompt: over a translucent surface, flat
                    // grey is the first thing to become unreadable.
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(destination)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                SecureField(challenge.kind.promptTitle, text: $secret)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(submit)
                Toggle("Save in Keychain", isOn: $saveInKeychain)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                Button("Continue", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(secret.isEmpty)
            }

            // A reserved slot: an error appearing must not shove the field the user is typing
            // into. The blur masks the crossfade between the two states.
            Text(errorMessage ?? " ")
                .font(.caption)
                .foregroundStyle(.red)
                .opacity(errorMessage == nil ? 0 : 1)
                .blur(radius: errorMessage == nil ? 2 : 0)
                .animation(.easeOut(duration: 0.18), value: errorMessage)
                .frame(minHeight: 15, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(errorMessage == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                // Thick, not regular: terminal text must not read through a password prompt.
                .fill(.thickMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                }
        }
        // A bigger surface over busy text reads as thicker, and needs a deeper shadow to separate.
        .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        .padding(12)
        .onAppear(perform: takeKeyboard)
        .onDisappear {
            session.terminalView.window?.makeFirstResponder(session.terminalView)
        }
        .accessibilityAddTraits(.isModal)
    }

    private var headline: String {
        if challenge.storedCredentialWithheld {
            return "Vibex locked before this prompt arrived."
        }
        if challenge.wasAutomaticCredentialRejected {
            return "The saved \(challenge.kind.promptTitle.lowercased()) was rejected."
        }
        return "\(challenge.kind.promptTitle) required."
    }

    private var destination: String {
        session.profile.endpointDescription
    }

    /// `@FocusState` alone does not make AppKit give up a first responder held by the terminal's
    /// `NSView`, and the very next keystroke would be the password — typed into the pty. Drop the
    /// terminal explicitly, then focus the field on the following turn, once it exists.
    private func takeKeyboard() {
        session.terminalView.window?.makeFirstResponder(nil)
        Task { @MainActor in fieldFocused = true }

        // A rejected saved credential is proven wrong. Leaving it in the Keychain means it is
        // replayed on every future connect until the user happens to notice.
        if challenge.wasAutomaticCredentialRejected {
            try? credentials.delete(for: session.profile.id, kind: challenge.kind)
        }
    }

    private func submit() {
        guard !secret.isEmpty else { return }
        var data = Data(secret.utf8)
        defer {
            data.securelyClear()
            secret = ""
        }

        // Send first, persist second. If the write fails, the user has still been logged in and
        // is told about the Keychain separately — the reverse order silently drops the password
        // they just typed and leaves the SSH prompt hanging.
        guard session.submitCredential(data) else {
            errorMessage = "The SSH session ended before the credential could be sent."
            return
        }

        if saveInKeychain {
            do {
                try credentials.store(data, for: session.profile.id, kind: challenge.kind)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        errorMessage = nil
    }
}
