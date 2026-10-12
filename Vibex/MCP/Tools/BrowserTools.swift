import Foundation
import WebKit

enum BrowserTools {
    static func make() -> [Tool] {
        func auto() throws -> BrowserAutomation { try WindowManager.shared.toolTarget().browserAutomation }
        let tabArg = ["tab": Schema.integer("Tab number from browser_tabs; defaults to the selected tab")]

        return [
            Tool(name: "browser_tabs", description: "List the side browser's tabs with their numbers, titles and URLs. The selected tab is marked with *.", inputSchema: Schema.object()) { _ in
                .text(try auto().describeTabs())
            },
            Tool(name: "browser_new_tab", description: "Open a new tab (and select it). Use this instead of navigating the user's tab, which may be playing video.", inputSchema: Schema.object(["url": Schema.string("URL to load; omit for an empty tab")])) { args in
                let url = args.string("url").flatMap(WebViewFactory.url(forInput:))
                let tab = try auto().newTab(url: url)
                let status = url == nil ? "empty" : try await auto().waitForLoad(tab, timeout: 15)
                return .text("Opened tab #\(tab.number): \(status)")
            },
            Tool(name: "browser_close_tab", description: "Close a tab.", inputSchema: Schema.object(["tab": Schema.integer("Tab number")], required: ["tab"])) { args in
                try auto().close(try auto().tab(args.int("tab")))
                return .text("Closed.")
            },
            Tool(name: "browser_select_tab", description: "Bring a tab to the front.", inputSchema: Schema.object(["tab": Schema.integer("Tab number")], required: ["tab"])) { args in
                try auto().select(try auto().tab(args.int("tab")))
                return .text("Selected.")
            },
            Tool(name: "browser_navigate", description: "Load a URL (or search text) in a tab and wait for it to finish loading.", inputSchema: Schema.object(["url": Schema.string("URL or search query")].merging(tabArg) { a, _ in a }, required: ["url"])) { args in
                guard let url = WebViewFactory.url(forInput: try args.requireString("url")) else { throw ToolError("bad url") }
                return .text(try await auto().navigate(url, in: try auto().tab(args.int("tab"))))
            },
            Tool(name: "browser_back", description: "Go back in a tab's history.", inputSchema: Schema.object(tabArg)) { args in
                let tab = try auto().tab(args.int("tab")); tab.webView.goBack(); return .text(try await auto().waitForLoad(tab, timeout: 10))
            },
            Tool(name: "browser_forward", description: "Go forward in a tab's history.", inputSchema: Schema.object(tabArg)) { args in
                let tab = try auto().tab(args.int("tab")); tab.webView.goForward(); return .text(try await auto().waitForLoad(tab, timeout: 10))
            },
            Tool(name: "browser_reload", description: "Reload a tab.", inputSchema: Schema.object(tabArg)) { args in
                let tab = try auto().tab(args.int("tab")); tab.webView.reload(); return .text(try await auto().waitForLoad(tab, timeout: 15))
            },
            Tool(name: "browser_snapshot", description: "Compact accessibility-style tree of the page: roles, names, states and element refs like [ref=e12]. Call it before clicking or typing, and again after the page changes; refs are invalidated by each snapshot.", inputSchema: Schema.object(tabArg)) { args in
                .text(try await auto().snapshot(try auto().tab(args.int("tab"))))
            },
            Tool(name: "browser_click", description: "Click an element by ref from browser_snapshot.", inputSchema: Schema.object(["ref": Schema.string("Element ref, e.g. e12")].merging(tabArg) { a, _ in a }, required: ["ref"])) { args in
                .text(try await auto().click(ref: try args.requireString("ref"), in: try auto().tab(args.int("tab"))))
            },
            Tool(name: "browser_type", description: "Type into a text field or editable element by ref. Replaces the current value. Set submit to press Enter afterwards.", inputSchema: Schema.object(["ref": Schema.string("Element ref"), "text": Schema.string("Text to enter"), "submit": Schema.boolean("Press Enter after typing")].merging(tabArg) { a, _ in a }, required: ["ref", "text"])) { args in
                .text(try await auto().type(ref: try args.requireString("ref"), text: args.string("text") ?? "", submit: args.bool("submit") ?? false, in: try auto().tab(args.int("tab"))))
            },
            Tool(name: "browser_press", description: "Press a key on the focused element: Enter, Escape, Tab, Backspace, ArrowDown… or a single character.", inputSchema: Schema.object(["key": Schema.string("Key name")].merging(tabArg) { a, _ in a }, required: ["key"])) { args in
                .text(try await auto().press(key: try args.requireString("key"), in: try auto().tab(args.int("tab"))))
            },
            Tool(name: "browser_scroll", description: "Scroll the page (or a scrollable element by ref) by dx, dy pixels.", inputSchema: Schema.object(["ref": Schema.string("Optional element ref"), "dx": Schema.number("Horizontal pixels"), "dy": Schema.number("Vertical pixels, positive = down")].merging(tabArg) { a, _ in a })) { args in
                .text(try await auto().scroll(ref: args.string("ref"), dx: args.double("dx") ?? 0, dy: args.double("dy") ?? 600, in: try auto().tab(args.int("tab"))))
            },
            Tool(name: "browser_text", description: "The page's visible text (innerText), for reading articles or results without a snapshot.", inputSchema: Schema.object(tabArg)) { args in
                .text(try await auto().pageText(try auto().tab(args.int("tab"))))
            },
            Tool(name: "browser_screenshot", description: "JPEG screenshot of a tab, downscaled. Use when layout or images matter; prefer browser_snapshot for structure.", inputSchema: Schema.object(["maxWidth": Schema.integer("Max image width in pixels (default 1024)")].merging(tabArg) { a, _ in a })) { args in
                .image(try await auto().screenshot(try auto().tab(args.int("tab")), maxWidth: args.int("maxWidth") ?? 1024))
            },
            Tool(name: "browser_evaluate", description: "Run JavaScript in the page and return the result as JSON. Promises are awaited. Powerful; prefer the ref-based tools for normal interaction.", inputSchema: Schema.object(["js": Schema.string("JavaScript expression or statements")].merging(tabArg) { a, _ in a }, required: ["js"])) { args in
                .text(try await auto().run(javaScript: try args.requireString("js"), in: try auto().tab(args.int("tab"))))
            },
            Tool(name: "browser_console", description: "Console messages and uncaught errors the tab logged (newest last).", inputSchema: Schema.object(["clear": Schema.boolean("Clear the buffer after reading"), "level": Schema.string("Only this level: log, info, warn, error")].merging(tabArg) { a, _ in a })) { args in
                let tab = try auto().tab(args.int("tab"))
                let level = args.string("level")
                let entries = tab.console.filter { level == nil || $0.level == level }
                if args.bool("clear") == true { tab.clearConsole() }
                let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
                let lines = entries.suffix(200).map { "\(formatter.string(from: $0.date)) [\($0.level)] \($0.text)" }
                return .text(lines.isEmpty ? "No console output." : lines.joined(separator: "\n"))
            },
            Tool(name: "browser_requests", description: "Recent fetch/XHR requests the page made: method, URL, status, duration.", inputSchema: Schema.object(["clear": Schema.boolean("Clear the buffer after reading"), "failedOnly": Schema.boolean("Only non-2xx or failed requests")].merging(tabArg) { a, _ in a })) { args in
                let tab = try auto().tab(args.int("tab"))
                let failedOnly = args.bool("failedOnly") ?? false
                let entries = tab.requests.filter { !failedOnly || $0.status == 0 || $0.status >= 400 }
                if args.bool("clear") == true { tab.clearRequests() }
                let lines = entries.suffix(200).map { "\($0.method) \($0.url) → \($0.status == 0 ? ($0.error ?? "failed") : String($0.status)) \($0.milliseconds)ms" }
                return .text(lines.isEmpty ? "No requests recorded." : lines.joined(separator: "\n"))
            },
            Tool(name: "browser_wait", description: "Wait for milliseconds, for a CSS selector to appear, or for text to appear on the page.", inputSchema: Schema.object(["ms": Schema.integer("Milliseconds to wait"), "selector": Schema.string("CSS selector to wait for"), "text": Schema.string("Text to wait for"), "timeout": Schema.number("Seconds before giving up (default 15)")].merging(tabArg) { a, _ in a })) { args in
                .text(try await auto().wait(ms: args.int("ms"), selector: args.string("selector"), text: args.string("text"), in: try auto().tab(args.int("tab")), timeout: args.double("timeout") ?? 15))
            },
        ]
    }
}
