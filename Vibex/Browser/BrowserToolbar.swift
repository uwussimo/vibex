import SwiftUI

@Observable
final class BrowserToolbarModel {
    var urlText = ""
    /// What the field shows when it isn't being edited: where the page is, without the scheme.
    var address = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var isSecure = true
    /// Bumped by the controller when ⌘L is pressed so the field can grab focus.
    var focusRequest = 0
    /// The selected tab; switching tabs drops a half-typed address and shows the new tab's.
    var tabID: UUID?
}

struct BrowserToolbarActions {
    var back: () -> Void
    var forward: () -> Void
    var reloadOrStop: () -> Void
    var home: () -> Void
    var navigate: (String) -> Void
    var focusWebView: () -> Void
}

struct BrowserToolbar: View {
    let model: BrowserToolbarModel
    let actions: BrowserToolbarActions

    @State private var draft = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(spacing: 4) {
            ToolbarIconButton(icon: .chevronLeft, help: "Back", isEnabled: model.canGoBack, action: actions.back)
            ToolbarIconButton(icon: .chevronRight, help: "Forward", isEnabled: model.canGoForward, action: actions.forward)
            ToolbarIconButton(
                icon: model.isLoading ? .close : .refresh,
                help: model.isLoading ? "Stop" : "Reload",
                action: actions.reloadOrStop
            )
            urlField
                .padding(.horizontal, 4)
            ToolbarIconButton(icon: .tv, help: "Netflix", action: actions.home)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(Theme.surface)
        .onChange(of: model.focusRequest) { _, _ in
            draft = model.urlText
            isEditing = true
        }
    }

    private var urlField: some View {
        HStack(spacing: 6) {
            IconView(model.isSecure ? .lock : .globe, size: 12)
                .foregroundStyle(Theme.muted)
            TextField("Search or enter website", text: $draft)
                .textFieldStyle(.plain)
                .font(.vibex(size: 12.5))
                .focused($isEditing)
                .onSubmit {
                    actions.navigate(draft)
                    isEditing = false
                    actions.focusWebView()
                }
                .onExitCommand {
                    draft = model.urlText
                    isEditing = false
                    actions.focusWebView()
                }
                .onChange(of: isEditing) { _, editing in
                    if editing { draft = model.urlText } else { draft = model.address }
                }
                .onChange(of: model.address) { _, address in
                    if !isEditing { draft = address }
                }
                .onChange(of: model.tabID) { _, _ in
                    isEditing = false
                    draft = model.address
                }
                .onAppear { draft = model.address }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isEditing ? 0.08 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isEditing ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .animation(.spring(response: 0.25, dampingFraction: 1), value: isEditing)
    }
}
