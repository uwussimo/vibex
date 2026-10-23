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
    var sourceControlWidth: Double?

    var layout: LayoutMode {
        get { LayoutMode(rawValue: layoutMode) ?? .balanced }
        set { layoutMode = newValue.rawValue }
    }

    var columnWidths: ColumnWidths? {
        get {
            guard let manualWidths, manualWidths.count == 3 else { return nil }
            return ColumnWidths(terminal: manualWidths[0], simulator: manualWidths[1], browser: manualWidths[2])
        }
        set {
            manualWidths = newValue.map { [Double($0.terminal), Double($0.simulator), Double($0.browser)] }
        }
    }
}
