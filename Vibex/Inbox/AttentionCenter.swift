import AppKit
import Observation
import os
import UserNotifications

/// The approval inbox: which Claude Code sessions in Vibex's terminal tabs are waiting for the user,
/// fed by Claude Code's hooks (see ClaudeHooks). Waiting tabs get an orange dot, their window's
/// Terminal button a count, and the menu bar a list; a notification goes out when the user isn't
/// looking at that tab.
@Observable
final class AttentionCenter {
    static let shared = AttentionCenter()

    struct Item: Identifiable, Equatable {
        enum Kind: Equatable { case permission, question }

        var tabID: UUID
        var windowID: String
        var kind: Kind
        /// What Claude is asking, in one line: "Allow Bash: npm test" or its own question.
        var message: String
        var since: Date
        var id: UUID { tabID }
    }

    /// One hook event, decoded from the JSON Claude Code passes on stdin.
    nonisolated struct Event: Equatable, Sendable {
        enum Name: String, Sendable {
            case permissionRequest = "PermissionRequest"
            case notification = "Notification"
            case userPromptSubmit = "UserPromptSubmit"
            case postToolUse = "PostToolUse"
            case stop = "Stop"
            case sessionEnd = "SessionEnd"
        }

        var name: Name
        var message: String?
        var tool: String?
        var toolDetail: String?

        static func parse(_ body: Data) -> Event? {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let name = (object["hook_event_name"] as? String).flatMap(Name.init(rawValue:)) else { return nil }
            let input = object["tool_input"] as? [String: Any]
            let detail = (input?["command"] ?? input?["file_path"] ?? input?["url"] ?? input?["pattern"]) as? String
            return Event(name: name, message: object["message"] as? String, tool: object["tool_name"] as? String, toolDetail: detail)
        }

        /// A request in a native Claude chat, in the terms a hook would have used.
        init(chatRequest request: ClaudePermissionRequest) {
            let input = request.tool.input
            switch request.tool.name {
            case "AskUserQuestion":
                let questions = input["questions"].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [[String: Any]]
                self.init(name: .notification, message: questions?.first?["question"] as? String ?? "Claude has a question for you")
            case "ExitPlanMode":
                self.init(name: .notification, message: "Claude's plan is ready for you to review")
            default:
                self.init(name: .permissionRequest, tool: request.tool.name, toolDetail: input["command"] ?? input["file_path"] ?? input["url"] ?? input["pattern"])
            }
        }

        init(name: Name, message: String? = nil, tool: String? = nil, toolDetail: String? = nil) {
            self.name = name
            self.message = message
            self.tool = tool
            self.toolDetail = toolDetail
        }

        /// The line shown in the inbox for a waiting event, or nil for events that end the wait.
        var waitingMessage: (Item.Kind, String)? {
            switch name {
            case .permissionRequest:
                let tool = tool.map(Self.friendlyTool) ?? "a tool"
                let detail = toolDetail.map { ": " + Self.oneLine($0, limit: 80) } ?? ""
                return (.permission, "Allow \(tool)\(detail)?")
            case .notification:
                return (.question, Self.oneLine(message ?? "Claude is waiting for you", limit: 110))
            case .userPromptSubmit, .postToolUse, .stop, .sessionEnd:
                return nil
            }
        }

        /// "mcp__vibex__simulator_tap" → "simulator_tap"
        static func friendlyTool(_ name: String) -> String {
            name.hasPrefix("mcp__") ? String(name.split(separator: "__").last ?? Substring(name)) : name
        }

        static func oneLine(_ text: String, limit: Int) -> String {
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
        }
    }

    private(set) var waiting: [UUID: Item] = [:]
    /// Tabs whose Claude session just finished a turn, briefly, for "done" notifications.
    private var notified: Set<UUID> = []

    var all: [Item] { waiting.values.sorted { $0.since < $1.since } }
    func count(windowID: String) -> Int { waiting.values.filter { $0.windowID == windowID }.count }
    func isWaiting(tab: UUID) -> Bool { waiting[tab] != nil }

    // MARK: - Events

    func handle(_ event: Event, tabID: UUID, windowID: String) {
        if let (kind, message) = event.waitingMessage {
            // A Notification right after a PermissionRequest repeats it; keep the more specific one.
            if event.name == .notification, waiting[tabID]?.kind == .permission { return }
            let item = Item(tabID: tabID, windowID: windowID, kind: kind, message: message, since: waiting[tabID]?.since ?? Date())
            let isNew = waiting[tabID] == nil
            waiting[tabID] = item
            if isNew { notify(item) }
        } else {
            clear(tabID)
        }
    }

    func clear(_ tabID: UUID) {
        guard waiting.removeValue(forKey: tabID) != nil else { return }
        notified.remove(tabID)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [tabID.uuidString])
    }

    /// Tabs that closed can't be waiting.
    func forget(tabs: Set<UUID>, inWindow windowID: String) {
        for item in waiting.values where item.windowID == windowID && !tabs.contains(item.tabID) {
            clear(item.tabID)
        }
    }

    // MARK: - Jumping

    /// Brings the waiting tab forward: its window, the terminal column, the tab, keyboard focus.
    func jump(to tabID: UUID) {
        guard let item = waiting[tabID] ?? waiting.values.first(where: { $0.tabID == tabID }),
              let window = WindowManager.shared.windows.first(where: { $0.session.windowID == item.windowID }) else { return }
        NSApp.activate()
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
        window.workspace.showTerminalTab(tabID)
    }

    // MARK: - Notifications

    private func notify(_ item: Item) {
        guard let window = WindowManager.shared.windows.first(where: { $0.session.windowID == item.windowID }) else { return }
        // Looking at that tab already: the dot is enough.
        let isVisible = NSApp.isActive && window.window?.isKeyWindow == true && window.workspace.terminalPane.selectedTabID == item.tabID
        guard !isVisible, !notified.contains(item.tabID) else { return }
        notified.insert(item.tabID)
        let content = UNMutableNotificationContent()
        content.title = item.kind == .permission ? "Claude needs your approval" : "Claude is waiting for you"
        content.subtitle = window.project.name
        content.body = item.message
        content.sound = .default
        content.userInfo = ["tab": item.tabID.uuidString]
        content.threadIdentifier = "vibex.attention"
        let request = UNNotificationRequest(identifier: item.tabID.uuidString, content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
}
