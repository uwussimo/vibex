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

    static var lastURL: URL? {
        get { store.url(forKey: Key.lastURL) }
        set { store.set(newValue, forKey: Key.lastURL) }
    }

    static var selectedDeviceUDID: String? {
        get { store.string(forKey: Key.selectedDevice) }
        set { store.set(newValue, forKey: Key.selectedDevice) }
    }

    static var layoutMode: LayoutMode {
        get { store.string(forKey: Key.layoutMode).flatMap(LayoutMode.init(rawValue:)) ?? .balanced }
        set { store.set(newValue.rawValue, forKey: Key.layoutMode) }
    }

    static var manualWidths: ColumnWidths? {
        get {
            guard let values = store.array(forKey: Key.manualWidths) as? [Double], values.count == 3 else { return nil }
            return ColumnWidths(terminal: values[0], simulator: values[1], browser: values[2])
        }
        set {
            let values = newValue.map { [Double($0.terminal), Double($0.simulator), Double($0.browser)] }
            store.set(values, forKey: Key.manualWidths)
        }
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

    static var browserTabURLs: [String] {
        get { store.stringArray(forKey: Key.browserTabs) ?? [] }
        set { store.set(newValue, forKey: Key.browserTabs) }
    }

    static var browserSelectedTab: Int {
        get { store.integer(forKey: Key.browserSelectedTab) }
        set { store.set(newValue, forKey: Key.browserSelectedTab) }
    }

    static var terminalTabDirectories: [String] {
        get { store.stringArray(forKey: Key.terminalTabs) ?? [] }
        set { store.set(newValue, forKey: Key.terminalTabs) }
    }
}
