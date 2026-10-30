import Foundation

/// One tool call in a Claude session, with its input flattened for showing.
nonisolated struct ClaudeToolUse: Equatable, Sendable {
    var id: String
    var name: String
    /// String values as they are; anything else as JSON.
    var input: [String: String]
}

nonisolated struct ClaudeToolResult: Equatable, Sendable {
    var toolUseID: String
    var text: String
    var images: [Data]
    var isError: Bool
}

/// Claude asking to use a tool. `AskUserQuestion` and `ExitPlanMode` arrive this way too.
nonisolated struct ClaudePermissionRequest: Equatable, Sendable, Identifiable {
    var id: String
    var tool: ClaudeToolUse
    /// The input exactly as sent, because the answer has to echo it.
    var rawInput: Data
    /// What "always allow" means here, as Claude Code suggested it.
    var suggestions: Data?
}

/// What `claude -p --output-format stream-json` says, and what its transcript files hold.
nonisolated enum ClaudeEvent: Equatable, Sendable {
    case started(sessionID: String, model: String?, slashCommands: [String])
    case textDelta(String)
    case text(String)
    case toolUse(ClaudeToolUse)
    case toolResult(ClaudeToolResult)
    case userText(String)
    case userImages([Data])
    case permission(ClaudePermissionRequest)
    case permissionCancelled(String)
    case turnEnded(seconds: Double, isError: Bool, message: String?)

    static func parse(_ line: String) -> [ClaudeEvent] {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        // A subagent's own steps stay inside its Agent card.
        if object["parent_tool_use_id"] is String || object["isSidechain"] as? Bool == true { return [] }
        switch type {
        case "system":
            guard object["subtype"] as? String == "init", let session = object["session_id"] as? String else { return [] }
            return [.started(sessionID: session, model: object["model"] as? String, slashCommands: object["slash_commands"] as? [String] ?? [])]
        case "stream_event":
            guard let event = object["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return [] }
            return [.textDelta(text)]
        case "assistant":
            return blocks(of: object).compactMap(assistantEvent)
        case "user":
            if object["isMeta"] as? Bool == true { return [] }
            if let text = (object["message"] as? [String: Any])?["content"] as? String { return userEvent(text) }
            return blocks(of: object).flatMap(userEvents)
        case "control_request":
            guard let id = object["request_id"] as? String, let request = object["request"] as? [String: Any],
                  request["subtype"] as? String == "can_use_tool", let name = request["tool_name"] as? String else { return [] }
            let input = request["input"] as? [String: Any] ?? [:]
            let tool = ClaudeToolUse(id: request["tool_use_id"] as? String ?? id, name: name, input: flatten(input))
            let suggestions = (request["permission_suggestions"] as? [Any]).flatMap { $0.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: $0) }
            return [.permission(ClaudePermissionRequest(id: id, tool: tool, rawInput: (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8), suggestions: suggestions))]
        case "control_cancel_request":
            return (object["request_id"] as? String).map { [.permissionCancelled($0)] } ?? []
        case "result":
            let isError = object["is_error"] as? Bool ?? false
            return [.turnEnded(seconds: (object["duration_ms"] as? Double ?? 0) / 1000, isError: isError, message: isError ? object["result"] as? String : nil)]
        default:
            return []
        }
    }

    private static func blocks(of object: [String: Any]) -> [[String: Any]] {
        (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    }

    private static func assistantEvent(_ block: [String: Any]) -> ClaudeEvent? {
        switch block["type"] as? String {
        case "text":
            return (block["text"] as? String).map { .text($0) }
        case "tool_use":
            guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
            return .toolUse(ClaudeToolUse(id: id, name: name, input: flatten(block["input"] as? [String: Any] ?? [:])))
        default:
            return nil
        }
    }

    private static func userEvents(_ block: [String: Any]) -> [ClaudeEvent] {
        switch block["type"] as? String {
        case "text":
            return userEvent(block["text"] as? String ?? "")
        case "image":
            guard let source = block["source"] as? [String: Any], let base64 = source["data"] as? String,
                  let data = Data(base64Encoded: base64) else { return [] }
            return [.userImages([data])]
        case "tool_result":
            guard let id = block["tool_use_id"] as? String else { return [] }
            var text = block["content"] as? String ?? ""
            var images: [Data] = []
            for part in block["content"] as? [[String: Any]] ?? [] {
                if let piece = part["text"] as? String { text += (text.isEmpty ? "" : "\n") + piece }
                if let source = part["source"] as? [String: Any], let base64 = source["data"] as? String, let data = Data(base64Encoded: base64) {
                    images.append(data)
                }
            }
            return [.toolResult(ClaudeToolResult(toolUseID: id, text: text, images: images, isError: block["is_error"] as? Bool ?? false))]
        default:
            return []
        }
    }

    /// Slash command plumbing and system reminders in a transcript aren't something the user typed.
    private static func userEvent(_ text: String) -> [ClaudeEvent] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("[Request interrupted") else { return [] }
        return [.userText(trimmed)]
    }

    private static func flatten(_ input: [String: Any]) -> [String: String] {
        input.mapValues { value in
            if let text = value as? String { return text }
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) {
                return String(decoding: data, as: UTF8.self)
            }
            return "\(value)"
        }
    }
}

/// The lines Vibex writes to Claude's stdin.
nonisolated enum ClaudeMessage {
    static func user(_ text: String, images: [ClaudeAttachment.Image] = []) -> String {
        guard !images.isEmpty else { return json(["type": "user", "message": ["role": "user", "content": text]]) }
        var content: [[String: Any]] = images.map { image in
            ["type": "image", "source": ["type": "base64", "media_type": image.mediaType, "data": image.data.base64EncodedString()]]
        }
        if !text.isEmpty { content.append(["type": "text", "text": text]) }
        return json(["type": "user", "message": ["role": "user", "content": content]])
    }

    static func allow(requestID: String, input: Data, permissions: Data? = nil) -> String {
        var response: [String: Any] = ["behavior": "allow", "updatedInput": object(input) ?? [:]]
        if let permissions, let list = object(permissions) { response["updatedPermissions"] = list }
        return reply(requestID, response)
    }

    static func deny(requestID: String, message: String) -> String {
        reply(requestID, ["behavior": "deny", "message": message])
    }

    /// A question answered: AskUserQuestion takes the answers in its input.
    static func answer(requestID: String, input: Data, answers: [String: String]) -> String {
        var updated = (object(input) as? [String: Any]) ?? [:]
        updated["answers"] = answers
        return reply(requestID, ["behavior": "allow", "updatedInput": updated])
    }

    static func control(_ subtype: String, _ fields: [String: Any] = [:]) -> String {
        json(["type": "control_request", "request_id": UUID().uuidString, "request": fields.merging(["subtype": subtype]) { $1 }])
    }

    private static func reply(_ id: String, _ response: [String: Any]) -> String {
        json(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response]])
    }

    private static func object(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }

    private static func json(_ value: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), as: UTF8.self)
    }
}

/// Claude Code keeps each session's transcript as JSON lines under ~/.claude/projects/<folder>/.
nonisolated enum ClaudeTranscript {
    static func file(session: String, folder: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let slug = String(folder.map { $0.isLetter && $0.isASCII || $0.isNumber ? $0 : "-" })
        return home.appendingPathComponent(".claude/projects/\(slug)/\(session).jsonl")
    }

    /// The newest session in a folder, to pick an agent's conversation back up.
    @concurrent static func latestSession(folder: String) async -> String? {
        let directory = file(session: "x", folder: folder).deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "jsonl" }
            .max { a, b in
                let dates = [a, b].map { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
                return dates[0] < dates[1]
            }?
            .deletingPathExtension().lastPathComponent
    }

    @concurrent static func load(session: String, folder: String) async -> [ClaudeEvent] {
        guard let text = try? String(contentsOf: file(session: session, folder: folder), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").flatMap { ClaudeEvent.parse(String($0)) }
    }
}
