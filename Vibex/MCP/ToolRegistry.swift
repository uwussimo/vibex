import AppKit
import Foundation

/// What a tool hands back to the model: text and/or images.
struct ToolResult: Sendable {
    enum Content: Sendable {
        case text(String)
        case image(jpeg: Data)
    }

    var content: [Content]
    var isError = false

    static func text(_ string: String) -> ToolResult { ToolResult(content: [.text(string)]) }
    static func error(_ string: String) -> ToolResult { ToolResult(content: [.text(string)], isError: true) }
    static func image(_ jpeg: Data, caption: String? = nil) -> ToolResult {
        var content: [Content] = []
        if let caption { content.append(.text(caption)) }
        content.append(.image(jpeg: jpeg))
        return ToolResult(content: content)
    }

    var json: JSONObject {
        let items: [JSONObject] = content.map {
            switch $0 {
            case let .text(text): ["type": "text", "text": text]
            case let .image(jpeg): ["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]
            }
        }
        return ["content": items, "isError": isError]
    }
}

struct ToolError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One MCP tool: name, description, JSON schema for its input, and the handler (main actor).
struct Tool {
    let name: String
    let description: String
    let inputSchema: JSONObject
    let handler: (JSONObject) async throws -> ToolResult

    var listing: JSONObject {
        ["name": name, "description": description, "inputSchema": inputSchema]
    }
}

/// Small helpers for building schemas and reading arguments.
enum Schema {
    static func object(_ properties: [String: JSONObject] = [:], required: [String] = []) -> JSONObject {
        var schema: JSONObject = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }
    static func string(_ description: String, enum values: [String]? = nil) -> JSONObject {
        var schema: JSONObject = ["type": "string", "description": description]
        if let values { schema["enum"] = values }
        return schema
    }
    static func number(_ description: String) -> JSONObject { ["type": "number", "description": description] }
    static func integer(_ description: String) -> JSONObject { ["type": "integer", "description": description] }
    static func boolean(_ description: String) -> JSONObject { ["type": "boolean", "description": description] }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func double(_ key: String) -> Double? {
        if let value = self[key] as? Double { return value }
        if let value = self[key] as? Int { return Double(value) }
        if let value = self[key] as? String { return Double(value) }
        return nil
    }
    func int(_ key: String) -> Int? {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? Double { return Int(value) }
        return nil
    }
    func bool(_ key: String) -> Bool? { self[key] as? Bool }

    func requireString(_ key: String) throws -> String {
        guard let value = string(key), !value.isEmpty else { throw ToolError("missing \"\(key)\"") }
        return value
    }
    func requireDouble(_ key: String) throws -> Double {
        guard let value = double(key) else { throw ToolError("missing number \"\(key)\"") }
        return value
    }
}

final class ToolRegistry {
    private(set) var tools: [Tool] = []

    func register(_ tool: Tool) {
        tools.removeAll { $0.name == tool.name }
        tools.append(tool)
    }

    func register(_ list: [Tool]) {
        list.forEach(register)
    }

    func tool(named name: String) -> Tool? {
        tools.first { $0.name == name }
    }
}
