import Foundation

/// How a project runs. Read from `.vibex.json` in the project root, or detected.
///
/// ```json
/// { "run": { "kind": "ios", "project": "MyApp.xcodeproj", "scheme": "MyApp" } }
/// { "run": { "kind": "web", "command": "npm run dev", "url": "http://localhost:5173" } }
/// { "run": { "kind": "command", "command": "swift run" } }
/// ```
nonisolated struct RunConfig: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Build for the window's simulator, install and launch.
        case ios
        /// Build a Mac app and open it.
        case macos
        /// Start a dev server and open its URL in a browser tab.
        case web
        /// Any command, shown in the Run tab.
        case command
    }

    var kind: Kind
    /// .xcodeproj or .xcworkspace, relative to the project root (ios, macos).
    var project: String?
    var scheme: String?
    /// Shell command (web, command), or a step before building (ios, macos), e.g. "xcodegen generate".
    var command: String?
    var prepare: String?
    /// Page to open once the dev server answers (web).
    var url: String?

    static let fileName = ".vibex.json"

    private struct File: Codable { var run: RunConfig }

    static func load(from folder: URL) -> RunConfig? {
        let file = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data).run
    }

    func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(File(run: self)).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    var summary: String {
        switch kind {
        case .ios: "iOS · \(scheme ?? "?")"
        case .macos: "macOS · \(scheme ?? "?")"
        case .web: command ?? "web"
        case .command: command ?? "command"
        }
    }
}

/// Guesses a run configuration from what is in a folder. Pure file inspection, no subprocesses.
nonisolated enum RunDetector {
    static func detect(in folder: URL, fileManager: FileManager = .default) -> RunConfig? {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        let has = { (name: String) in names.contains(name) }

        // Xcode: a workspace wins over a project; XcodeGen projects are generated first.
        let workspace = names.first { $0.hasSuffix(".xcworkspace") }
        let xcodeProject = names.first { $0.hasSuffix(".xcodeproj") }
        if has("project.yml") || workspace != nil || xcodeProject != nil {
            let spec = (try? String(contentsOf: folder.appendingPathComponent("project.yml"), encoding: .utf8)) ?? ""
            let pbxproj = xcodeProject.flatMap {
                try? String(contentsOf: folder.appendingPathComponent($0).appendingPathComponent("project.pbxproj"), encoding: .utf8)
            } ?? ""
            let name = specName(spec) ?? (workspace ?? xcodeProject).map { ($0 as NSString).deletingPathExtension } ?? folder.lastPathComponent
            let container = workspace ?? xcodeProject ?? "\(name).xcodeproj"
            let isMac = isMacOnly(spec: spec, pbxproj: pbxproj)
            return RunConfig(
                kind: isMac ? .macos : .ios,
                project: container,
                scheme: name,
                prepare: has("project.yml") ? "xcodegen generate" : nil
            )
        }

        if has("package.json"), let data = fileManager.contents(atPath: folder.appendingPathComponent("package.json").path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let scripts = json["scripts"] as? [String: String] ?? [:]
            let script = ["dev", "start", "serve"].first { scripts[$0] != nil }
            if let script {
                let runner = has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : (has("bun.lockb") || has("bun.lock")) ? "bun" : "npm"
                let command = runner == "npm" ? "npm run \(script)" : "\(runner) \(script)"
                let deps = (json["dependencies"] as? [String: Any] ?? [:]).merging(json["devDependencies"] as? [String: Any] ?? [:]) { a, _ in a }
                return RunConfig(kind: .web, command: command, url: "http://localhost:\(guessPort(deps: deps, script: scripts[script] ?? ""))")
            }
        }

        if has("Package.swift") { return RunConfig(kind: .command, command: "swift run") }
        if has("Cargo.toml") { return RunConfig(kind: .command, command: "cargo run") }
        if has("go.mod") { return RunConfig(kind: .command, command: "go run .") }
        if has("Makefile"), let makefile = try? String(contentsOf: folder.appendingPathComponent("Makefile"), encoding: .utf8),
           makefile.contains("\nrun:") || makefile.hasPrefix("run:") {
            return RunConfig(kind: .command, command: "make run")
        }
        return nil
    }

    /// `name: Foo` at the top level of an XcodeGen spec.
    static func specName(_ spec: String) -> String? {
        for line in spec.split(separator: "\n") where line.hasPrefix("name:") {
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func isMacOnly(spec: String, pbxproj: String) -> Bool {
        if !spec.isEmpty {
            let platforms = spec.split(separator: "\n").compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("platform:") ? String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces) : nil
            }
            return !platforms.isEmpty && platforms.allSatisfy { $0 == "macOS" }
        }
        return pbxproj.contains("SDKROOT = macosx") && !pbxproj.contains("SDKROOT = iphoneos")
    }

    static func guessPort(deps: [String: Any], script: String) -> Int {
        if let range = script.range(of: #"(--port|-p)[ =](\d{2,5})"#, options: .regularExpression) {
            let digits = script[range].filter(\.isNumber)
            if let port = Int(digits) { return port }
        }
        if deps["vite"] != nil || script.contains("vite") { return 5173 }
        if deps["astro"] != nil { return 4321 }
        if deps["@sveltejs/kit"] != nil { return 5173 }
        if deps["@angular/core"] != nil { return 4200 }
        return 3000
    }
}
