import AppKit
import Foundation
import UserNotifications

/// Tools that change what the user sees: layout, focus, toasts, and terminal tabs.
enum WorkspaceTools {
    static func make() -> [Tool] {
        func window() throws -> MainWindowController { try WindowManager.shared.toolTarget() }
        return [
            Tool(
                name: "vibex_notify",
                description: "Show a toast in the Vibex window (and a system notification if Vibex is in the background). Use it when a long task finishes or needs the user's attention.",
                inputSchema: Schema.object(["title": Schema.string("Short headline"), "message": Schema.string("Optional detail, one or two sentences")], required: ["title"])
            ) { args in
                let title = try args.requireString("title")
                let message = args.string("message")
                try window().toast.show(title: title, message: message)
                if !NSApp.isActive { await Self.postSystemNotification(title: title, message: message) }
                return .text("Shown.")
            },
            Tool(
                name: "vibex_layout",
                description: "Switch the window layout. build: wide terminal, simulator at natural size, small browser. watch: wide browser, simulator hidden. balanced: the user's own divider positions.",
                inputSchema: Schema.object(["mode": Schema.string("Layout mode", enum: ["build", "watch", "balanced"])], required: ["mode"])
            ) { args in
                let raw = try args.requireString("mode")
                guard let mode = LayoutMode(rawValue: raw) else { throw ToolError("unknown mode \(raw)") }
                try window().workspace.apply(mode: mode, animated: true)
                return .text("Layout: \(raw).")
            },
            Tool(
                name: "vibex_focus",
                description: "Give keyboard focus to a pane: terminal, simulator or browser.",
                inputSchema: Schema.object(["pane": Schema.string("Pane", enum: ["terminal", "simulator", "browser"])], required: ["pane"])
            ) { args in
                switch try args.requireString("pane") {
                case "terminal": try window().workspace.focusTerminal(nil)
                case "simulator": try window().workspace.focusSimulator(nil)
                case "browser": try window().workspace.focusBrowser(nil)
                default: throw ToolError("pane must be terminal, simulator or browser")
                }
                return .text("Focused.")
            },
            Tool(
                name: "terminal_run",
                description: "Open a new terminal tab in this project's window and type a command into it, where the user can watch it and stop it. Starts in the project folder unless cwd is given. Good for dev servers and long-running processes. Returns the tab id. Does not capture output.",
                inputSchema: Schema.object(["command": Schema.string("Shell command to run"), "cwd": Schema.string("Directory to start in (optional)")], required: ["command"])
            ) { args in
                let command = try args.requireString("command")
                let target = try window()
                let id = target.workspace.terminalPane.runCommandInNewTab(command, directory: args.string("cwd") ?? target.project.path)
                return .text("Running in terminal tab \(id.uuidString).")
            },
            Tool(
                name: "vibex_projects",
                description: "Projects open in Vibex windows (* marks the window this call acts on) and recent projects.",
                inputSchema: Schema.object()
            ) { _ in
                let manager = WindowManager.shared
                let current = try? manager.toolTarget()
                var lines = ["open:"]
                for window in manager.windows {
                    lines.append("\(window === current ? "*" : " ") \(window.project.name)  \(window.project.path)")
                }
                let openPaths = Set(manager.windows.map(\.project.path))
                let recents = ProjectStore.shared.recents.filter { !openPaths.contains($0.path) }
                if !recents.isEmpty {
                    lines.append("recent:")
                    lines += recents.prefix(10).map { "  \($0.name)  \($0.path)" }
                }
                return .text(lines.joined(separator: "\n"))
            },
            Tool(
                name: "vibex_open_project",
                description: "Open a folder as a project in its own Vibex window, or bring its window to the front if it is already open.",
                inputSchema: Schema.object(["path": Schema.string("Absolute path to the project folder")], required: ["path"])
            ) { args in
                let path = (try args.requireString("path") as NSString).expandingTildeInPath
                guard let window = WindowManager.shared.open(URL(fileURLWithPath: path)) else { throw ToolError("not a folder: \(path)") }
                return .text("Opened \(window.project.name).")
            },
            Tool(
                name: "vibex_run",
                description: "Run the project the way the user's Run button does: iOS apps build for this window's simulator then install and launch; web projects start the dev server and open it in a browser tab; others run their command. Uses .vibex.json or detects from the folder. Returns once started; check vibex_run_status.",
                inputSchema: Schema.object()
            ) { _ in
                let runner = try window().runner
                runner.run()
                return .text("Started: \(runner.config?.summary ?? "nothing to run"). Phase: \(runner.phase.label).")
            },
            Tool(
                name: "vibex_stop",
                description: "Stop the running build, app command or dev server.",
                inputSchema: Schema.object()
            ) { _ in
                try window().runner.stop()
                return .text("Stopped.")
            },
            Tool(
                name: "vibex_run_status",
                description: "Where the current run is (building, launching, serving, failed…), its exit code and the last lines of its output. Poll this after vibex_run.",
                inputSchema: Schema.object(["lines": Schema.integer("How many output lines (default 60)")])
            ) { args in
                let runner = try window().runner
                var lines = [
                    "config: \(runner.config?.summary ?? runner.resolveConfig()?.summary ?? "none")",
                    "phase: \(runner.phase.label)\(runner.phase.isActive ? " (active)" : "")",
                ]
                if let code = runner.lastExitCode { lines.append("exit code: \(code)") }
                let tail = runner.outputTail(lines: min(args.int("lines") ?? 60, 400))
                if !tail.isEmpty { lines.append("--- output ---\n" + tail) }
                return .text(lines.joined(separator: "\n"))
            },
            Tool(
                name: "terminal_tabs",
                description: "List the terminal tabs: id, title and working directory.",
                inputSchema: Schema.object()
            ) { _ in
                let lines = try window().workspace.terminalPane.tabSummaries().map { "\($0.id.uuidString)  \($0.title)  \($0.directory ?? "")" }
                return .text(lines.isEmpty ? "No terminal tabs." : lines.joined(separator: "\n"))
            },
        ]
    }

    private static func postSystemNotification(title: String, message: String?) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let message { content.body = message }
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
