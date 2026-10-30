import AppKit

/// One row in the command palette.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    var icon: String
    var shortcut: String?
    let perform: () -> Void
}

/// Everything the palette can do in a window, snapshotted when it opens (so menu validation still
/// sees the pane that had focus).
enum CommandCatalog {
    static func items(for window: MainWindowController) -> [PaletteItem] {
        // Order matters for an empty query: the things you reach for first.
        let commands = menuCommands()
        let appMenu = commands.filter { $0.subtitle == "Vibex" }
        let rest = commands.filter { $0.subtitle != "Vibex" }
        let order = ["View", "Simulator", "Browser", "File", "Window", "Edit"]
        let sorted = rest.enumerated().sorted { a, b in
            let ia = order.firstIndex { a.element.subtitle?.hasPrefix($0) == true } ?? order.count
            let ib = order.firstIndex { b.element.subtitle?.hasPrefix($0) == true } ?? order.count
            return ia != ib ? ia < ib : a.offset < b.offset
        }.map(\.element)
        return projectItems(current: window) + sorted + tabItems(window) + deviceItems(window) + appMenu
    }

    /// Rows that depend on what was typed: open a URL, search, or run a shell command.
    static func dynamicItems(for query: String, window: MainWindowController) -> [PaletteItem] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        var items: [PaletteItem] = []
        if text.hasPrefix("$") || text.hasPrefix(">") {
            let command = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            if !command.isEmpty {
                items.append(PaletteItem(id: "run-shell", title: "Run in a new terminal tab: \(command)", icon: "terminal") {
                    window.workspace.terminalPane.runCommandInNewTab(command, directory: window.project.path)
                })
            }
            return items
        }
        let looksLikeURL = !text.contains(" ") && (text.contains(".") || text.hasPrefix("localhost") || text.contains("://"))
        if looksLikeURL, let url = WebViewFactory.url(forInput: text) {
            items.append(PaletteItem(id: "open-url", title: "Open \(url.absoluteString)", subtitle: "New browser tab", icon: "globe") {
                window.workspace.browserPane.openTab(url: url)
            })
        }
        // Quick open: the best few files in the project, by name or path.
        let root = window.explorer.root
        for match in FuzzyMatch.rank(window.explorer.fileIndex, query: text, text: { $0 }).prefix(6) {
            let path = match.item
            items.append(PaletteItem(id: "file-\(path)", title: (path as NSString).lastPathComponent, subtitle: (path as NSString).deletingLastPathComponent, icon: "doc.text") {
                window.openFile(root.appendingPathComponent(path), keep: true)
            })
        }
        return items
    }

    // MARK: - Menu commands

    private static let skippedActions: Set<Selector> = [
        #selector(AppDelegate.openRecent(_:)),
        Selector(("undo:")), Selector(("redo:")),
        #selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:)),
        #selector(MainWindowController.showCommandPalette(_:)),
    ]

    private static func menuCommands() -> [PaletteItem] {
        guard let mainMenu = NSApp.mainMenu else { return [] }
        var items: [PaletteItem] = []
        for top in mainMenu.items {
            guard let menu = top.submenu else { continue }
            collect(menu, path: menu.title, into: &items)
        }
        return items
    }

    private static func collect(_ menu: NSMenu, path: String, into items: inout [PaletteItem]) {
        menu.update()
        for item in menu.items where !item.isSeparatorItem && !item.isHidden && !item.isAlternate {
            if let submenu = item.submenu {
                if submenu.delegate == nil { collect(submenu, path: "\(path) › \(item.title)", into: &items) }
                continue
            }
            guard let action = item.action, !skippedActions.contains(action) else { continue }
            guard let target = NSApp.target(forAction: action, to: item.target, from: item) else { continue }
            if let validator = target as? NSMenuItemValidation, !validator.validateMenuItem(item) { continue }
            let captured = item
            items.append(PaletteItem(
                id: "menu-\(path)-\(item.title)",
                title: item.title.replacingOccurrences(of: "…", with: ""),
                subtitle: path,
                icon: icon(for: path),
                shortcut: shortcutGlyphs(item)
            ) {
                NSApp.sendAction(action, to: captured.target, from: captured)
            })
        }
    }

    private static func icon(for menuPath: String) -> String {
        switch menuPath.split(separator: " ").first.map(String.init) ?? "" {
        case "File": "doc"
        case "View": "rectangle.split.3x1"
        case "Browser": "globe"
        case "Simulator": "iphone"
        case "Window": "macwindow"
        default: "command"
        }
    }

    static func shortcutGlyphs(_ item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        let mask = item.keyEquivalentModifierMask
        var glyphs = ""
        if mask.contains(.control) { glyphs += "⌃" }
        if mask.contains(.option) { glyphs += "⌥" }
        if mask.contains(.shift) || item.keyEquivalent != item.keyEquivalent.lowercased() { glyphs += "⇧" }
        if mask.contains(.command) { glyphs += "⌘" }
        let key = item.keyEquivalent.uppercased()
        switch key {
        case "\r": glyphs += "↩"
        case "\u{1B}": glyphs += "⎋"
        case " ": glyphs += "Space"
        default: glyphs += key
        }
        return glyphs
    }

    // MARK: - Projects, tabs, devices

    private static func projectItems(current: MainWindowController) -> [PaletteItem] {
        let manager = WindowManager.shared
        var items: [PaletteItem] = []
        for window in manager.windows where window !== current {
            items.append(PaletteItem(id: "project-\(window.project.id)", title: "Switch to \(window.project.name)", subtitle: window.project.displayPath, icon: "macwindow.on.rectangle") {
                window.showWindow(nil)
                window.window?.makeKeyAndOrderFront(nil)
            })
        }
        let open = Set(manager.windows.map(\.project.path))
        for project in ProjectStore.shared.recents where !open.contains(project.path) && project.exists {
            items.append(PaletteItem(id: "recent-\(project.id)", title: "Open \(project.name)", subtitle: project.displayPath, icon: "folder") {
                manager.open(project.url)
            })
        }
        return items
    }

    private static func tabItems(_ window: MainWindowController) -> [PaletteItem] {
        var items: [PaletteItem] = []
        let terminal = window.workspace.terminalPane
        for tab in terminal.tabSummaries() {
            items.append(PaletteItem(id: "term-\(tab.id)", title: "Terminal: \(tab.title)", subtitle: tab.directory, icon: "terminal") {
                terminal.selectTab(tab.id)
                window.workspace.focusTerminal(nil)
            })
        }
        let browser = window.workspace.browserPane
        for tab in browser.tabs {
            items.append(PaletteItem(id: "browser-\(tab.id)", title: "Tab: \(tab.title)", subtitle: tab.url?.host(), icon: "globe") {
                browser.select(tab.id)
                browser.focusWebView()
            })
        }
        return items
    }

    private static func deviceItems(_ window: MainWindowController) -> [PaletteItem] {
        let model = window.workspace.simulatorPane.model
        return model.devices.map { device in
            PaletteItem(
                id: "device-\(device.udid)",
                title: "Use \(device.name)",
                subtitle: "\(device.runtime)\(device.isBooted ? " · booted" : "")",
                icon: device.isBooted ? "iphone.gen3.radiowaves.left.and.right" : "iphone"
            ) {
                model.selectedUDID = device.udid
            }
        }
    }
}
