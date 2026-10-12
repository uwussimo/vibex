import Foundation

/// Where Vibex finds Xcode and the command-line tools it ships with.
nonisolated enum Toolchain {
    /// The active Xcode's Developer folder: $DEVELOPER_DIR, then `xcode-select -p` (ignoring the
    /// Command Line Tools, which have no simulators), then the default Xcode location.
    static let developerDir: String = {
        let fileManager = FileManager.default
        func isXcode(_ path: String) -> Bool {
            fileManager.fileExists(atPath: "\(path)/Library/PrivateFrameworks/SimulatorKit.framework")
        }
        if let env = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], isXcode(env) { return env }
        if let data = try? Shell.run("/usr/bin/xcode-select", ["-p"]),
           let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           isXcode(path) {
            return path
        }
        let fallback = "/Applications/Xcode.app/Contents/Developer"
        if isXcode(fallback) { return fallback }
        // Any Xcode*.app in /Applications (betas, renamed copies).
        let apps = (try? fileManager.contentsOfDirectory(atPath: "/Applications")) ?? []
        for app in apps.sorted() where app.hasPrefix("Xcode") && app.hasSuffix(".app") {
            let path = "/Applications/\(app)/Contents/Developer"
            if isXcode(path) { return path }
        }
        return fallback
    }()

    /// `Vibex.app/Contents/Resources/tools/bin`: simslim and XcodeGen bundled with release builds.
    static var bundledBin: String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let bin = resources.appendingPathComponent("tools/bin").path
        return FileManager.default.fileExists(atPath: bin) ? bin : nil
    }

    /// A bundled tool, used only when the user has not installed their own.
    static func bundled(_ name: String) -> String? {
        bundledBin.map { "\($0)/\(name)" }.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    /// PATH for shells and commands Vibex starts: the user's PATH first, the bundled tools last.
    static func path(appending base: String?) -> String {
        let current = base ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        guard let bundledBin, !current.split(separator: ":").contains(Substring(bundledBin)) else { return current }
        return current + ":" + bundledBin
    }
}
