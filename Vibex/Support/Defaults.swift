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

}
