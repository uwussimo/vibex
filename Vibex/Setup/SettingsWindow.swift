import AppKit
import ServiceManagement
import SwiftUI

/// Preferences that more than one part of the app reads.
enum AppSettings {
    static let terminalFontSizeChanged = Notification.Name("Vibex.terminalFontSizeChanged")

    static var terminalFontSize: Double {
        get {
            let value = UserDefaults.standard.double(forKey: "terminal.fontSize")
            return value == 0 ? 13 : value
        }
        set {
            UserDefaults.standard.set(min(20, max(10, newValue)), forKey: "terminal.fontSize")
            NotificationCenter.default.post(name: terminalFontSizeChanged, object: nil)
        }
    }

    /// A project with no saved tabs opens with Claude Code running in its first terminal.
    static var startProjectsWithClaude: Bool {
        get { UserDefaults.standard.object(forKey: "terminal.startWithClaude") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "terminal.startWithClaude") }
    }
}

/// Vibex › Settings… (⌘,): a sidebar of sections like System Settings. On first launch it opens on
/// Get Started, where one button sets up everything Vibex can set up by itself.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    enum Section: String, CaseIterable, Identifiable {
        case getStarted, general, terminal, devices, keepAwake, claude
        var id: String { rawValue }

        var title: String {
            switch self {
            case .getStarted: "Get Started"
            case .general: "General"
            case .terminal: "Terminal"
            case .devices: "Devices"
            case .keepAwake: "Keep Awake"
            case .claude: "Claude Code & MCP"
            }
        }

        var glyph: String {
            switch self {
            case .getStarted: "ph.rocket-launch"
            case .general: "ph.gear-six"
            case .terminal: "ph.terminal-window"
            case .devices: "ph.device-mobile"
            case .keepAwake: "ph.coffee"
            case .claude: "ph.plugs"
            }
        }
    }

    private let setup = SetupModel()
    private let navigation = SettingsNavigation()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.title = "Vibex Settings"
        window.backgroundColor = Theme.NS.background
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(setup: setup, navigation: navigation))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ section: Section? = nil) {
        if let section { navigation.section = section }
        setup.refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) { setup.markSeen() }
}

@Observable
final class SettingsNavigation {
    var section: SettingsWindowController.Section = .general
}

struct SettingsView: View {
    let setup: SetupModel
    @Bindable var navigation: SettingsNavigation
    /// Off only for rendering a page to an image, which can't see inside a scroll view.
    var scrolls = true

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(navigation.section.title)
                .font(.vibex(size: 22, weight: .semibold))
                .padding(.top, 2)
            page
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.horizontal, 36)
        .padding(.top, 44)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.line).frame(width: 1)
            Group {
                if scrolls {
                    ScrollView { content }.scrollBounceBehavior(.basedOnSize)
                } else {
                    content.frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .background(Theme.background)
        }
        .frame(width: 820, height: 600)
        .foregroundStyle(Theme.text)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsWindowController.Section.allCases) { section in
                SidebarRow(section: section, isSelected: navigation.section == section, badge: badge(for: section)) {
                    navigation.section = section
                }
            }
            Spacer()
            Text("Vibex \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(.vibex(size: 11))
                .foregroundStyle(Theme.faint)
                .padding(.leading, 12)
                .padding(.bottom, 14)
        }
        .padding(.top, 48)
        .padding(.horizontal, 10)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(Theme.surface)
    }

    /// Get Started shows what's left, so an unfinished setup is never out of sight.
    private func badge(for section: SettingsWindowController.Section) -> String? {
        guard section == .getStarted, !setup.isComplete else { return nil }
        let left = setup.totalCount - setup.readyCount
        return left > 0 ? "\(left)" : nil
    }

    @ViewBuilder
    private var page: some View {
        switch navigation.section {
        case .getStarted: GetStartedPage(model: setup)
        case .general: GeneralPage()
        case .terminal: TerminalPage()
        case .devices: DevicesPage()
        case .keepAwake: KeepAwakePage(model: .shared)
        case .claude: ClaudePage(setup: setup)
        }
    }
}

private struct SidebarRow: View {
    let section: SettingsWindowController.Section
    let isSelected: Bool
    let badge: String?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(isSelected ? section.glyph + ".fill" : section.glyph)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 17, height: 17)
                Text(section.title)
                    .font(.vibex(size: 13, weight: isSelected ? .medium : .regular))
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.vibex(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(Capsule().fill(Theme.orange))
                }
            }
            .foregroundStyle(isSelected ? Theme.text : Theme.muted)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.wash(isSelected ? 0.08 : (isHovering ? 0.045 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Building blocks

/// A titled group of rows on one card, like a section in System Settings.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.vibex(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.muted)
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                        if index > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 16) }
                        subview
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.line))
            if let footer {
                Text(footer)
                    .font(.vibex(size: 11.5))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// A label (with an optional caption) on the left and a control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.vibex(size: 13))
                if let caption {
                    Text(caption)
                        .font(.vibex(size: 11.5))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 48)
    }
}

// MARK: - Get Started

private struct GetStartedPage: View {
    let model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            progress
            SettingsGroup(title: "Permissions") {
                ForEach([SetupItem.ID.fullDiskAccess, .folders, .notifications], id: \.self) { SetupRow(id: $0, model: model) }
            }
            SettingsGroup(title: "Tools", footer: "Optional items can wait. Everything here can be changed later.") {
                ForEach([SetupItem.ID.xcode, .claude, .vibexSkill, .approvalHooks, .commandLine], id: \.self) { SetupRow(id: $0, model: model) }
            }
        }
    }

    /// Where the setup stands, and the one button that does the rest.
    private var progress: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.isComplete ? "You're all set." : "\(model.readyCount) of \(model.totalCount) ready")
                    .font(.vibex(size: 15, weight: .semibold))
                    .contentTransition(.numericText())
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.raised)
                        Capsule().fill(model.isComplete ? Theme.green : Theme.accent)
                            .frame(width: proxy.size.width * CGFloat(model.readyCount) / CGFloat(max(model.totalCount, 1)))
                    }
                }
                .frame(height: 6)
                Text(model.isComplete
                     ? "Open a folder and Claude Code starts in its terminal."
                     : "Vibex installs and turns on what it can. Full Disk Access and Xcode need you once.")
                    .font(.vibex(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            if !model.isComplete {
                Button(model.isSettingUpEverything ? "Setting Up…" : "Set Up Everything", action: model.setUpEverything)
                    .buttonStyle(.primary)
                    .controlSize(.large)
                    .disabled(!model.canSetUpEverything)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Open a Folder…") { NSApp.sendAction(#selector(AppDelegate.openFolder(_:)), to: nil, from: nil) }
                    .buttonStyle(.primary)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.line))
        .animation(.spring(response: 0.35, dampingFraction: 1), value: model.readyCount)
    }
}

// MARK: - General

private struct GeneralPage: View {
    @State private var appearance = AppearanceChoice.current
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Appearance") {
                HStack(spacing: 14) {
                    ForEach(AppearanceChoice.allCases) { choice in
                        AppearanceCard(choice: choice, isSelected: appearance == choice) {
                            appearance = choice
                            AppearanceChoice.current = choice
                        }
                    }
                }
                .padding(16)
            }
            SettingsGroup(title: "Startup", footer: loginMessage) {
                SettingsRow(title: "Open Vibex at login", caption: "It starts in the menu bar, ready for vibex . and Keep Awake.") {
                    Toggle("", isOn: $opensAtLogin).labelsHidden().toggleStyle(.switch)
                        .onChange(of: opensAtLogin) { _, on in
                            do {
                                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                loginMessage = nil
                            } catch {
                                loginMessage = error.localizedDescription
                                opensAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                }
            }
            SettingsGroup(title: "Updates") {
                SettingsRow(title: "Vibex checks for updates on its own", caption: "You choose when to install one.") {
                    Button("Check Now") { NSApp.sendAction(#selector(AppDelegate.checkForUpdates(_:)), to: nil, from: nil) }
                }
            }
        }
    }
}

/// A small picture of the window in each appearance, so the choice is seen, not read.
private struct AppearanceCard: View {
    let choice: AppearanceChoice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                    .frame(height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isSelected ? Theme.accent : Theme.line, lineWidth: isSelected ? 2 : 1)
                    )
                Text(choice.title)
                    .font(.vibex(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.text : Theme.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var preview: some View {
        switch choice {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            HStack(spacing: 0) {
                MiniWindow(dark: false)
                MiniWindow(dark: true)
            }
        }
    }
}

private struct MiniWindow: View {
    let dark: Bool

    var body: some View {
        let paper = Color(hex: dark ? 0x1D1D20 : 0xF4F3F0)
        let sheet = Color(hex: dark ? 0x161618 : 0xFBFBF9)
        let ink = Color(hex: dark ? 0xF1F0EC : 0x17171A)
        HStack(spacing: 0) {
            paper.frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                ForEach([0.75, 0.5, 0.62], id: \.self) { width in
                    GeometryReader { proxy in
                        Capsule().fill(ink.opacity(0.22)).frame(width: proxy.size.width * width, height: 4)
                    }
                    .frame(height: 4)
                }
                Spacer()
                RoundedRectangle(cornerRadius: 2).fill(ink).frame(width: 26, height: 9)
            }
            .padding(9)
            .frame(maxWidth: .infinity)
            .background(sheet)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Terminal

private struct TerminalPage: View {
    @State private var fontSize = AppSettings.terminalFontSize
    @State private var startWithClaude = AppSettings.startProjectsWithClaude

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Text") {
                SettingsRow(title: "Font size", caption: "Google Sans Code at \(Int(fontSize)) pt.") {
                    Stepper(value: $fontSize, in: 10...20, step: 1) {
                        Text("\(Int(fontSize))").font(.vibexCode(size: 13)).monospacedDigit().frame(width: 24)
                    }
                    .onChange(of: fontSize) { _, size in AppSettings.terminalFontSize = size }
                }
                Text("claude ~/projects/trails")
                    .font(.vibexCode(size: fontSize))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Theme.code)
            }
            SettingsGroup(title: "New projects", footer: "In Claude Code, run /theme and choose Auto so its colours follow Light and Dark with Vibex.") {
                SettingsRow(title: "Start Claude Code in the first terminal", caption: "A folder opened for the first time starts with claude running, or a shell when Claude Code isn't installed.") {
                    Toggle("", isOn: $startWithClaude).labelsHidden().toggleStyle(.switch)
                        .onChange(of: startWithClaude) { _, on in AppSettings.startProjectsWithClaude = on }
                }
            }
            SettingsGroup(title: "Shortcuts") {
                SettingsRow(title: "New terminal tab") { ShortcutLabel("⌘T") }
                SettingsRow(title: "Another tab like this one", caption: "Double-click a tab, or the Terminal button in the activity bar.") { ShortcutLabel("Double-click") }
                SettingsRow(title: "Show the terminal") { ShortcutLabel("⌘1") }
            }
        }
    }
}

private struct ShortcutLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.vibex(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous).fill(Theme.raised))
    }
}

// MARK: - Devices

private struct DevicesPage: View {
    @State private var slim = Defaults.slimPreferred
    @State private var sdk = AndroidSDK.location?.path ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "iOS Simulator") {
                SettingsRow(title: "Boot simulators slim", caption: Simslim.isInstalled
                    ? "simslim turns off background services, so each simulator uses far less memory."
                    : "Needs simslim, which ships inside Vibex releases.") {
                    Toggle("", isOn: $slim).labelsHidden().toggleStyle(.switch)
                        .disabled(!Simslim.isInstalled)
                        .onChange(of: slim) { _, on in Defaults.slimPreferred = on }
                }
            }
            SettingsGroup(title: "Android Emulator", footer: "Vibex looks in $ANDROID_HOME and ~/Library/Android/sdk. Make emulators in Android Studio's Device Manager; they show up in the Simulator tab.") {
                SettingsRow(title: "Android SDK", caption: sdk.isEmpty ? "Not found. Install Android Studio, or choose the SDK folder." : (sdk as NSString).abbreviatingWithTildeInPath) {
                    Button("Choose…", action: choose)
                }
                SettingsRow(title: "Emulators", caption: AndroidSDK.avds().isEmpty ? "None yet." : AndroidSDK.avds().joined(separator: ", ")) {
                    EmptyView()
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the Android SDK folder (it holds emulator and platform-tools)."
        panel.directoryURL = AndroidSDK.location ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AndroidSDK.customLocation = url
        sdk = AndroidSDK.location?.path ?? ""
    }
}

// MARK: - Claude Code & MCP

private struct ClaudePage: View {
    let setup: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Connection", footer: "Claude Code and Codex reach the simulator, the browser and the terminals through this server. Vibex registers it with both when it starts.") {
                SettingsRow(title: "Vibex MCP server", caption: "http://127.0.0.1:\(Defaults.mcpPort)/mcp") {
                    Button("Copy Config") { NSApp.sendAction(#selector(AppDelegate.copyMCPConfig(_:)), to: nil, from: nil) }
                }
            }
            SettingsGroup(title: "Claude Code") {
                ForEach([SetupItem.ID.claude, .vibexSkill, .approvalHooks, .commandLine], id: \.self) { SetupRow(id: $0, model: setup) }
            }
        }
    }
}
