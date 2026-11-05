import Foundation

/// Tools for the QA agent: the devices tests run on, running flows across them, and trying steps.
enum QATools {
    static func make() -> [Tool] {
        func qa() throws -> QAModel { try WindowManager.shared.toolTarget().qaModelForTools() }
        func list(_ args: [String: Any], _ key: String) -> [String]? {
            if let many = args[key] as? [String], !many.isEmpty { return many }
            return args.string(key).map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        }
        return [
            Tool(
                name: "qa_devices",
                description: "The simulators in Vibex's Devices grid, which QA runs use: name, runtime, whether each is booted, and udid. Pass `add` to put more simulators in the grid, by name or udid; they boot.",
                inputSchema: Schema.object(["add": Schema.string("Simulators to add to the grid, comma-separated names or udids (optional)")])
            ) { args in
                let model = try qa()
                var note = ""
                if let wanted = list(args, "add") {
                    let added = await model.addDevices(wanted)
                    note = added.isEmpty ? "None of \(wanted.joined(separator: ", ")) is a simulator on this Mac. Create it with `xcrun simctl create` first.\n" : "Added \(added.joined(separator: ", ")).\n"
                }
                await model.matrix.refresh()
                guard !model.devices.isEmpty else { return .text("The Devices grid is empty. Ask the user to add devices in the QA tab.") }
                return .text(note + model.devices.map { "\($0.name)  \($0.runtime)  \($0.state)  \($0.udid)" }.joined(separator: "\n"))
            },
            Tool(
                name: "qa_run",
                description: "Run test flows from vibex-qa/flows on every device in the grid at once, and wait for them. Returns what passed and failed, each failing step with its message, and a screenshot of each failure. Installs the app the last Run built on each device first.",
                inputSchema: Schema.object([
                    "flows": Schema.string("Flow files or names to run, comma-separated (optional, all by default)"),
                    "devices": Schema.string("Device names or udids, comma-separated (optional, the whole grid by default)"),
                ])
            ) { args in
                let model = try qa()
                try WindowManager.shared.toolTarget().showQA(nil)
                guard let run = await model.runFlows(list(args, "flows"), on: list(args, "devices")) else {
                    throw ToolError(model.problem ?? (model.isRunning ? "A run is already going." : "Nothing ran."))
                }
                var lines = [run.summary + (run.isFinished ? "." : ", stopped early.")]
                for result in run.results {
                    let mark = result.status == .passed ? "✓" : (result.status == .failed ? "✗" : "·")
                    var line = "\(mark) \(result.flowName) on \(result.deviceName) (\(String(format: "%.0f", result.seconds))s)"
                    if let failure = result.failure { line += "\n    step \(failure.index) \"\(failure.title)\": \(failure.message ?? "")" }
                    lines.append(line)
                }
                lines.append("Screenshots: \(model.runsFolder.appendingPathComponent(run.id).path)")
                var content: [ToolResult.Content] = [.text(lines.joined(separator: "\n"))]
                for result in run.results where result.status == .failed {
                    guard let url = model.screenshot(result.failure?.screenshot), let data = try? Data(contentsOf: url) else { continue }
                    content.append(.text("\(result.flowName) on \(result.deviceName), after step \(result.failure?.index ?? 0). On screen:\n\(result.screenText?.prefix(2500) ?? "")"))
                    content.append(.image(jpeg: data))
                    if content.count > 9 { break }
                }
                return ToolResult(content: content)
            },
            Tool(
                name: "qa_try",
                description: "Run a few Maestro-style steps on one device, then see its screen and every element on it with labels and ids. With no steps it only looks. For exploring the app and checking selectors before writing a flow.",
                inputSchema: Schema.object([
                    "steps": Schema.string("YAML list of steps, e.g. \"- tapOn: Sign in\\n- inputText: me@example.com\" (optional)"),
                    "device": Schema.string("Device name or udid from qa_devices (optional, the first in the grid)"),
                    "appId": Schema.string("Bundle id for launchApp (optional)"),
                ])
            ) { args in
                let model = try qa()
                let tried = try await model.tryCommands(args.string("steps"), appId: args.string("appId"), on: args.string("device"))
                var lines = tried.result.steps.map { "\($0.status == .passed ? "✓" : "✗") \($0.title)\($0.message.map { ": \($0)" } ?? "")" }
                lines.append("Screen on \(tried.result.deviceName):\n\(tried.screen)")
                var content: [ToolResult.Content] = [.text(lines.joined(separator: "\n"))]
                if let jpeg = tried.jpeg { content.append(.image(jpeg: jpeg)) }
                return ToolResult(content: content, isError: tried.result.status == .failed)
            },
        ]
    }
}
