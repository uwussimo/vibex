import Foundation

/// Typed access to the handful of things Vibex remembers between launches.
enum Defaults {
    private static let store = UserDefaults.standard

    private enum Key {
        static let lastURL = "browser.lastURL"
        static let selectedDevice = "simulator.selectedUDID"
        static let layoutMode = "layout.mode"
        static let manualWidths = "layout.manualWidths"
        static let terminalTabs = "terminal.tabDirectories"
        static let slimPreferred = "simulator.slimPreferred"
        static let browserTabs = "browser.tabURLs"
        static let mcpToken = "mcp.token"
        static let mcpPort = "mcp.port"
        static let browserSelectedTab = "browser.selectedTab"
        static let setupVersion = "setup.version"
        static let foldersRequested = "setup.foldersRequested"
        static let notificationsRequested = "setup.notificationsRequested"
        static let agentsPeriodDays = "agents.periodDays"
    }

    /// Boot simulators through simslim when it is installed. On by default.
    static var slimPreferred: Bool {
        get { store.object(forKey: Key.slimPreferred) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.slimPreferred) }
    }

    /// Bearer token for the local MCP server, generated once.
    static var mcpToken: String {
        if let token = store.string(forKey: Key.mcpToken), !token.isEmpty { return token }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        store.set(token, forKey: Key.mcpToken)
        return token
    }

    static func resetMCPToken() { store.removeObject(forKey: Key.mcpToken) }

    static var mcpPort: Int {
        get { store.integer(forKey: Key.mcpPort) }
        set { store.set(newValue, forKey: Key.mcpPort) }
    }

    /// The setup window version the user last finished; 0 before the first launch.
    static var setupVersion: Int {
        get { store.integer(forKey: Key.setupVersion) }
        set { store.set(newValue, forKey: Key.setupVersion) }
    }

    /// Whether setup has listed Desktop, Documents and Downloads (which is what makes macOS ask).
    static var foldersRequested: Bool {
        get { store.bool(forKey: Key.foldersRequested) }
        set { store.set(newValue, forKey: Key.foldersRequested) }
    }

    /// Whether the notification prompt has been shown; after that only System Settings can change it.
    static var notificationsRequested: Bool {
        get { store.bool(forKey: Key.notificationsRequested) }
        set { store.set(newValue, forKey: Key.notificationsRequested) }
    }

    /// The AI Agents dashboard's spending period: 7, 30 or 90 days.
    static var agentsPeriodDays: Int {
        get { [7, 30, 90].contains(store.integer(forKey: Key.agentsPeriodDays)) ? store.integer(forKey: Key.agentsPeriodDays) : 30 }
        set { store.set(newValue, forKey: Key.agentsPeriodDays) }
    }
}
