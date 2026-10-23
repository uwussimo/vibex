import Foundation

enum SimulatorTools {
    private static func auto() throws -> SimulatorAutomation { try WindowManager.shared.toolTarget().simulatorAutomation }
    private static func model() throws -> SimulatorModel { try WindowManager.shared.toolTarget().workspace.simulatorPane.model }

    static func make() -> [Tool] {
        return [
            Tool(name: "simulator_list", description: "List available simulators with state, and which one Vibex shows.", inputSchema: Schema.object()) { _ in
                let model = try model()
                await model.refresh()
                let lines = model.devices.map { device in
                    let marker = device.udid == model.selectedUDID ? "*" : " "
                    let slim = model.slimInfo[device.udid].map { $0.isSlim ? " slim" : "" } ?? ""
                    return "\(marker) \(device.name)  \(device.runtime)  \(device.state)\(slim)  \(device.udid)"
                }
                return .text(lines.isEmpty ? "No simulators." : lines.joined(separator: "\n"))
            },
            Tool(name: "simulator_info", description: "The live device: name, udid, screen size in points and pixels, slim state.", inputSchema: Schema.object()) { _ in
                .text(try auto().describeInfo())
            },
            Tool(name: "simulator_boot", description: "Boot a simulator (slim via simslim when enabled) and show it in Vibex. Waits until it is booted. Omit udid to boot the selected device.", inputSchema: Schema.object(["udid": Schema.string("Device UDID from simulator_list")])) { args in
                if let udid = args.string("udid") { try model().selectedUDID = udid }
                try await model().bootSelected()
                if let error = try model().errorMessage { throw ToolError(error) }
                return .text("Booted \(try model().selectedDevice?.name ?? "device"). The screen appears in Vibex within a few seconds.")
            },
            Tool(name: "simulator_shutdown", description: "Shut down the selected simulator.", inputSchema: Schema.object()) { _ in
                try await model().shutdownSelected()
                if let error = try model().errorMessage { throw ToolError(error) }
                return .text("Shut down.")
            },
            Tool(name: "simulator_screenshot", description: "JPEG of the live simulator screen, downscaled. Coordinates for simulator_tap are in points (see simulator_info), not in this image's pixels.", inputSchema: Schema.object(["maxWidth": Schema.integer("Max image width in pixels (default 600)")])) { args in
                let png = try auto().screenshot(maxWidth: args.int("maxWidth") ?? 600)
                return .image(png, caption: try auto().describeInfo().split(separator: "\n").dropFirst().first.map(String.init))
            },
            Tool(name: "simulator_snapshot", description: "Save the current simulator screen in Vibex's screenshot history under a label (e.g. \"before\" and \"after\" a UI change), and open the Compare tab so the user can drag between them. Returns the image too.", inputSchema: Schema.object(["label": Schema.string("Short label, e.g. before or after")], required: ["label"])) { args in
                let window = try WindowManager.shared.toolTarget()
                guard let snapshot = await window.workspace.simulatorPane.captureSnapshot(label: try args.requireString("label")) else {
                    throw ToolError("Couldn't take a screenshot. Is a simulator booted?")
                }
                if window.workspace.simulatorPane.snapshots.snapshots.count >= 2 { window.workspace.editor.openCompare() }
                let png = try Data(contentsOf: window.workspace.simulatorPane.snapshots.url(of: snapshot))
                return .image(png, caption: "Saved \"\(snapshot.label)\". \(window.workspace.simulatorPane.snapshots.snapshots.count) screenshots in Compare.")
            },
            Tool(name: "simulator_screenshot_all", description: "One image of every simulator in Vibex's Devices tab, side by side (e.g. a small phone, a large phone and an iPad), to check a layout on all screen sizes at once. Opens the tab; add devices there or ask the user to.", inputSchema: Schema.object()) { _ in
                let window = try WindowManager.shared.toolTarget()
                window.showDevices(nil)
                let matrix = window.deviceMatrix
                await matrix.refresh()
                guard !matrix.shown.isEmpty else { throw ToolError("The Devices tab has no simulators yet. Add some there (or boot them with simulator_boot and add them).") }
                guard let image = await DeviceMatrixViewController.combinedScreenshot(of: matrix.shown) else {
                    throw ToolError("None of the Devices tab's simulators are booted.")
                }
                return .image(image, caption: matrix.shown.filter(\.isBooted).map(\.name).joined(separator: " · "))
            },
            Tool(name: "simulator_tap", description: "Tap at a point (screen points, origin top-left).", inputSchema: Schema.object(["x": Schema.number("X in points"), "y": Schema.number("Y in points")], required: ["x", "y"])) { args in
                try await auto().tap(x: try args.requireDouble("x"), y: try args.requireDouble("y"))
                return .text("Tapped.")
            },
            Tool(name: "simulator_long_press", description: "Press and hold at a point.", inputSchema: Schema.object(["x": Schema.number("X in points"), "y": Schema.number("Y in points"), "seconds": Schema.number("Hold duration (default 1)")], required: ["x", "y"])) { args in
                try await auto().longPress(x: try args.requireDouble("x"), y: try args.requireDouble("y"), seconds: args.double("seconds") ?? 1)
                return .text("Long-pressed.")
            },
            Tool(name: "simulator_swipe", description: "Swipe from one point to another (scrolling, paging, pull to refresh, dismiss).", inputSchema: Schema.object(["fromX": Schema.number("Start X"), "fromY": Schema.number("Start Y"), "toX": Schema.number("End X"), "toY": Schema.number("End Y"), "seconds": Schema.number("Duration (default 0.3)")], required: ["fromX", "fromY", "toX", "toY"])) { args in
                try await auto().swipe(fromX: try args.requireDouble("fromX"), fromY: try args.requireDouble("fromY"), toX: try args.requireDouble("toX"), toY: try args.requireDouble("toY"), seconds: args.double("seconds") ?? 0.3)
                return .text("Swiped.")
            },
            Tool(name: "simulator_type", description: "Type text into the focused field (tap it first). US keyboard layout; use \\n for Return.", inputSchema: Schema.object(["text": Schema.string("Text to type")], required: ["text"])) { args in
                .text(try await auto().type(try args.requireString("text")))
            },
            Tool(name: "simulator_press_key", description: "Press a key: return, tab, backspace, escape, space, up, down, left, right, or a single character.", inputSchema: Schema.object(["key": Schema.string("Key name")], required: ["key"])) { args in
                .text(try await auto().pressKey(try args.requireString("key")))
            },
            Tool(name: "simulator_button", description: "Press a hardware button: home or lock.", inputSchema: Schema.object(["button": Schema.string("home or lock", enum: ["home", "lock"])], required: ["button"])) { args in
                .text(try auto().button(try args.requireString("button")))
            },
            Tool(name: "simulator_describe", description: "Accessibility tree of the frontmost app: roles, labels, values, identifiers, frames in points and refs like [ref=r12]. The reliable way to find what to tap; pair with simulator_tap_element.", inputSchema: Schema.object()) { _ in
                .text(try await auto().describe())
            },
            Tool(name: "simulator_find", description: "Find elements by label (also matches value) or accessibility identifier, case-insensitive substring. Returns refs usable with simulator_tap_element.", inputSchema: Schema.object(["label": Schema.string("Text to match in label or value"), "identifier": Schema.string("Accessibility identifier substring")])) { args in
                guard args.string("label") != nil || args.string("identifier") != nil else { throw ToolError("give label or identifier") }
                return .text(try await auto().find(label: args.string("label"), identifier: args.string("identifier")))
            },
            Tool(name: "simulator_tap_element", description: "Tap the centre of an element by ref (from simulator_describe/find) or by label.", inputSchema: Schema.object(["ref": Schema.string("Element ref, e.g. r12 or f1"), "label": Schema.string("Label to search for when no ref is given")])) { args in
                .text(try await auto().tapElement(ref: args.string("ref"), label: args.string("label")))
            },
            Tool(name: "simulator_element_at", description: "The accessibility element under a point (screen points).", inputSchema: Schema.object(["x": Schema.number("X in points"), "y": Schema.number("Y in points")], required: ["x", "y"])) { args in
                .text(try await auto().elementAt(x: try args.requireDouble("x"), y: try args.requireDouble("y")))
            },
            Tool(name: "simulator_open_url", description: "Open a URL or deep link in the simulator.", inputSchema: Schema.object(["url": Schema.string("URL, e.g. https://… or myapp://…")], required: ["url"])) { args in
                .text(try await auto().openURL(try args.requireString("url")))
            },
            Tool(name: "simulator_install_app", description: "Install a built .app bundle (e.g. from DerivedData) on the booted simulator.", inputSchema: Schema.object(["path": Schema.string("Absolute path to the .app")], required: ["path"])) { args in
                .text(try await auto().install(appPath: try args.requireString("path")))
            },
            Tool(name: "simulator_launch_app", description: "Launch an installed app by bundle id (restarts it if running).", inputSchema: Schema.object(["bundleId": Schema.string("Bundle identifier"), "args": ["type": "array", "items": ["type": "string"], "description": "Launch arguments"]], required: ["bundleId"])) { args in
                .text(try await auto().launch(bundleID: try args.requireString("bundleId"), arguments: args["args"] as? [String] ?? []))
            },
            Tool(name: "simulator_terminate_app", description: "Terminate a running app by bundle id.", inputSchema: Schema.object(["bundleId": Schema.string("Bundle identifier")], required: ["bundleId"])) { args in
                .text(try await auto().terminate(bundleID: try args.requireString("bundleId")))
            },
            Tool(name: "simulator_list_apps", description: "Installed user apps on the booted simulator (bundle id and name).", inputSchema: Schema.object()) { _ in
                .text(try await auto().listApps())
            },
            Tool(name: "simulator_logs", description: "Unified log lines from inside the simulator for the last N seconds, filtered by bundle id or a custom NSPredicate.", inputSchema: Schema.object(["bundleId": Schema.string("App bundle id to filter by"), "seconds": Schema.integer("Window in seconds (default 30)"), "filter": Schema.string("Raw log predicate, overrides bundleId")])) { args in
                .text(try await auto().logs(bundleID: args.string("bundleId"), seconds: min(args.int("seconds") ?? 30, 600), filter: args.string("filter")))
            },
        ]
    }
}
