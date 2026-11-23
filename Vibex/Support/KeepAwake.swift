import AppKit
import IOKit.pwr_mgt
import Observation

/// Keeps the Mac awake: for a set time, until a time, until turned off, or on its own while Claude
/// Code is in the middle of a turn in any Vibex terminal. Uses the same power assertions as
/// `caffeinate`, so it never changes a system setting; the one exception is "with the lid closed",
/// which needs `pmset disablesleep` and asks for an administrator password each way.
@MainActor @Observable
final class KeepAwake {
    static let shared = KeepAwake()

    enum Length: Hashable, Identifiable {
        case minutes(Int)
        case indefinitely
        case until(Date)

        var id: String {
            switch self {
            case let .minutes(m): "m\(m)"
            case .indefinitely: "inf"
            case let .until(date): "u\(date.timeIntervalSince1970)"
            }
        }

        /// The chip's label: 15m, 1h, ∞.
        var label: String {
            switch self {
            case let .minutes(m): m < 60 ? "\(m)m" : "\(m / 60)h"
            case .indefinitely: "∞"
            case let .until(date): date.formatted(date: .omitted, time: .shortened)
            }
        }
    }

    static let presets: [Length] = [.minutes(15), .minutes(30), .minutes(60), .minutes(120), .minutes(240), .minutes(480), .indefinitely]

    /// The session the user started, if any.
    private(set) var length: Length?
    private(set) var endsAt: Date?
    /// Claude Code is working in some tab and `whileClaudeWorks` is on.
    private(set) var isHeldForClaude = false
    /// `pmset disablesleep` is on (read from the system, so it survives a relaunch).
    private(set) var isLidModeOn = false
    /// Set while the administrator prompt for lid mode is up, or after it failed.
    private(set) var lidModeMessage: String?

    var isActive: Bool { length != nil || isHeldForClaude }

    var allowDisplaySleep: Bool {
        didSet {
            UserDefaults.standard.set(allowDisplaySleep, forKey: Keys.allowDisplaySleep)
            reassert()
        }
    }

    var startWithVibex: Bool {
        didSet { UserDefaults.standard.set(startWithVibex, forKey: Keys.startWithVibex) }
    }

    var whileClaudeWorks: Bool {
        didSet {
            UserDefaults.standard.set(whileClaudeWorks, forKey: Keys.whileClaudeWorks)
            updateClaudeHold()
        }
    }

    private enum Keys {
        static let allowDisplaySleep = "keepAwake.allowDisplaySleep"
        static let startWithVibex = "keepAwake.startWithVibex"
        static let whileClaudeWorks = "keepAwake.whileClaudeWorks"
    }

    private var assertion: IOPMAssertionID = 0
    private var assertionType: String?
    private var timer: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.whileClaudeWorks: true])
        allowDisplaySleep = defaults.bool(forKey: Keys.allowDisplaySleep)
        startWithVibex = defaults.bool(forKey: Keys.startWithVibex)
        whileClaudeWorks = defaults.bool(forKey: Keys.whileClaudeWorks)
        isLidModeOn = Self.readSleepDisabled()
    }

    /// Called once at launch.
    func start() {
        if startWithVibex { begin(.indefinitely) }
        observeClaude()
    }

    // MARK: - Sessions

    /// A chip was clicked: starts that length, or stops when it's the one already running.
    func toggle(_ length: Length) {
        if self.length == length { stop() } else { begin(length) }
    }

    func begin(_ length: Length) {
        self.length = length
        switch length {
        case let .minutes(m): endsAt = Date().addingTimeInterval(TimeInterval(m * 60))
        case .indefinitely: endsAt = nil
        case let .until(date): endsAt = date > Date() ? date : Calendar.current.date(byAdding: .day, value: 1, to: date)
        }
        scheduleEnd()
        reassert()
    }

    func stop() {
        length = nil
        endsAt = nil
        timer?.cancel()
        timer = nil
        reassert()
        if isLidModeOn, !isHeldForClaude { setLidMode(false) }
    }

    /// What the status line says: "Until you turn it off", "Until 5:30 PM", "While Claude works".
    var summary: String {
        if let endsAt { return "Until \(endsAt.formatted(date: .omitted, time: .shortened))" }
        if length != nil { return "Until you turn it off" }
        if isHeldForClaude { return "While Claude Code works" }
        return "Off"
    }

    private func scheduleEnd() {
        timer?.cancel()
        guard let endsAt else { timer = nil; return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, endsAt.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    // MARK: - Claude

    private func observeClaude() {
        withObservationTracking {
            _ = AttentionCenter.shared.working
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateClaudeHold()
                self?.observeClaude()
            }
        }
        updateClaudeHold()
    }

    private func updateClaudeHold() {
        let hold = whileClaudeWorks && !AttentionCenter.shared.working.isEmpty
        guard hold != isHeldForClaude else { return }
        isHeldForClaude = hold
        reassert()
    }

    // MARK: - Power assertion

    /// One assertion at a time, of the type the options call for.
    private func reassert() {
        let wanted: String? = isActive
            ? (allowDisplaySleep ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep)
            : nil
        guard wanted != assertionType else { return }
        if assertionType != nil {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        assertionType = nil
        guard let wanted else { return }
        let reason = isHeldForClaude && length == nil ? "Claude Code is working in Vibex" : "Vibex Keep Awake"
        if IOPMAssertionCreateWithName(wanted as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &assertion) == kIOReturnSuccess {
            assertionType = wanted
        }
    }

    // MARK: - Lid closed

    /// Turns `pmset disablesleep` on or off. macOS asks for an administrator password.
    func setLidMode(_ on: Bool) {
        lidModeMessage = on ? "Waiting for your password…" : nil
        Task {
            let result = await Self.runPrivileged("/usr/bin/pmset -a disablesleep \(on ? 1 : 0)")
            isLidModeOn = Self.readSleepDisabled()
            lidModeMessage = result
            if on, isLidModeOn, !isActive { begin(.indefinitely) }
        }
    }

    /// Before quitting: never leave the Mac unable to sleep behind the user's back.
    func prepareToQuit() {
        if assertionType != nil { IOPMAssertionRelease(assertion) }
        if isLidModeOn {
            _ = Self.runPrivilegedSync("/usr/bin/pmset -a disablesleep 0")
        }
    }

    nonisolated private static func readSleepDisabled() -> Bool {
        guard let data = try? Shell.run("/usr/bin/pmset", ["-g"]), let text = String(data: data, encoding: .utf8) else { return false }
        return text.split(separator: "\n").contains { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            return parts.first == "SleepDisabled" && parts.last == "1"
        }
    }

    @concurrent nonisolated private static func runPrivileged(_ command: String) async -> String? {
        runPrivilegedSync(command)
    }

    /// Nil on success, otherwise a sentence for the settings row.
    nonisolated private static func runPrivilegedSync(_ command: String) -> String? {
        let script = "do shell script \"\(command)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        return process.terminationStatus == 0 ? nil : "Not changed: the password prompt was cancelled."
    }
}
