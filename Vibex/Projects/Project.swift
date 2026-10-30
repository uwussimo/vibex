import CryptoKit
import Foundation

/// A folder opened in Vibex. Identified by a stable hash of its standardized path.
nonisolated struct Project: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let path: String

    init(url: URL) {
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath().path
        path = standardized
        id = Self.identifier(for: standardized)
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var name: String { (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent }

    /// `~/code/app` instead of `/Users/me/code/app`.
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func identifier(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Everything a project window remembers between launches.
nonisolated struct ProjectState: Codable, Equatable, Sendable {
    var terminalDirectories: [String] = []
    var browserTabURLs: [String] = []
    var browserSelectedTab = 0
    var deviceUDID: String?
    var layoutMode: String = LayoutMode.balanced.rawValue
    var manualWidths: [Double]?
    var lastOpened = Date()
    /// Optional so state saved by older versions still decodes.
    var sourceControlVisible: Bool?
    /// Which view the sidebar shows: "sourceControl" or "skills".
    var sidebarPanel: String?
    var sourceControlWidth: Double?
    /// The selected editor tab: "browser", "simulator" or "diff".
    var editorTab: String?
    /// The user closed every tab of the pane; it stays closed until reopened from the activity bar.
    var terminalClosed: Bool?
    /// Claude chat tabs, to reload and resume.
    var claudeChats: [ClaudeChatState]?
    var browserClosed: Bool?
    /// The simulators in the Devices tab, by UDID.
    var matrixDevices: [String]?

    var layout: LayoutMode {
        get { LayoutMode(rawValue: layoutMode) ?? .balanced }
        set { layoutMode = newValue.rawValue }
    }

    /// Saved as [terminal, editor]; versions before 1.2 saved [terminal, simulator, browser].
    var columnWidths: ColumnWidths? {
        get {
            guard let manualWidths else { return nil }
            switch manualWidths.count {
            case 2: return ColumnWidths(terminal: manualWidths[0], editor: manualWidths[1])
            case 3: return ColumnWidths(terminal: manualWidths[0], editor: manualWidths[1] + manualWidths[2])
            default: return nil
            }
        }
        set {
            manualWidths = newValue.map { [Double($0.terminal), Double($0.editor)] }
        }
    }
}

/// A Claude chat tab: its session, the folder it runs in (an agent's worktree, say) and any fixed name.
nonisolated struct ClaudeChatState: Codable, Equatable, Sendable {
    var session: String
    var folder: String
    var name: String?
}
