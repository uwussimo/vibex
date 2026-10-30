import AppKit
import SwiftUI

struct ServerEditorView: View {
    let isEditing: Bool
    let onSave: (ServerDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ServerDraft
    @State private var hasEdited = false
    @FocusState private var nameFocused: Bool

    init(profile: ServerProfile?, onSave: @escaping (ServerDraft) -> Void) {
        isEditing = profile != nil
        self.onSave = onSave
        _draft = State(initialValue: profile.map(ServerDraft.init(profile:)) ?? ServerDraft())
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Server") {
                    TextField("Name", text: $draft.name, prompt: Text("Production API"))
                        .focused($nameFocused)
                    TextField("Hostname or IP", text: $draft.host, prompt: Text("203.0.113.10"))
                    HStack {
                        TextField("Username", text: $draft.username)
                        TextField("Port", value: $draft.port, format: .number)
                            .frame(width: 110)
                    }
                }

                Section("Authentication") {
                    Picker("Method", selection: $draft.authentication) {
                        ForEach(AuthenticationKind.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)

                    if draft.authentication == .privateKey {
                        HStack {
                            TextField("Private key", text: $draft.privateKeyPath)
                                .textFieldStyle(.roundedBorder)
                                // A key path's tail is what identifies it.
                                .truncationMode(.head)
                            Button("Choose…", action: choosePrivateKey)
                        }
                        
                    }

                    SecureField(
                        draft.authentication == .password ? "Password" : "Key passphrase (optional)",
                        text: $draft.secret
                    )
                    Toggle("Save this secret in Keychain", isOn: $draft.saveSecret)

                    if isEditing {
                        Text("Leave the secret empty to keep the existing Keychain value.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Notes") {
                    TextField("Optional notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack(spacing: 10) {
                // A reserved slot: guidance appearing must not shove the buttons the user is
                // already reaching for.
                Group {
                    if let message = draft.validationMessage {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            // Guidance, not an accusation — the disabled Save button already
                            // carries the state.
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                .frame(height: 16, alignment: .leading)
                .animation(.easeOut(duration: 0.16), value: draft.validationMessage)

                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add Server") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.validationMessage != nil)
            }
            .padding(16)
        }
        .frame(width: 520, height: 570)
        .onChange(of: draft) { _, _ in hasEdited = true }
        .onAppear { nameFocused = true }
    }

    private func choosePrivateKey() {
        let panel = NSOpenPanel()
        panel.title = "Choose an SSH Private Key"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            draft.privateKeyPath = url.path
        }
    }
}
