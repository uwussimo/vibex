import Foundation

typealias JSONObject = [String: Any]

/// A JSON-RPC 2.0 message as the MCP transport sees it. Parsing is `nonisolated` so the HTTP layer
/// can reject malformed input before hopping to the main actor.
nonisolated enum JSONRPC {
    struct Request {
        let id: Any?          // String, Int, or nil for notifications
        let method: String
        let params: JSONObject
        var isNotification: Bool { id == nil }
    }

    struct Failure: Error {
        let code: Int
        let message: String
        nonisolated(unsafe) let data: Any?

        init(code: Int, message: String, data: Any? = nil) {
            self.code = code
            self.message = message
            self.data = data
        }

        static let parseError = Failure(code: -32700, message: "Parse error")
        static func invalidRequest(_ why: String) -> Failure { Failure(code: -32600, message: "Invalid request: \(why)") }
        static func methodNotFound(_ method: String) -> Failure { Failure(code: -32601, message: "Method not found: \(method)") }
        static func invalidParams(_ why: String) -> Failure { Failure(code: -32602, message: "Invalid params: \(why)") }
        static func internalError(_ why: String) -> Failure { Failure(code: -32603, message: why) }
    }

    static func parse(_ data: Data) throws -> Request {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Failure.parseError
        }
        if json is [Any] { throw Failure.invalidRequest("batches are not supported") }
        guard let object = json as? JSONObject else { throw Failure.invalidRequest("not an object") }
        guard (object["jsonrpc"] as? String) == "2.0" else { throw Failure.invalidRequest("jsonrpc must be \"2.0\"") }
        guard let method = object["method"] as? String, !method.isEmpty else { throw Failure.invalidRequest("missing method") }
        let id: Any? = object["id"].flatMap { $0 is NSNull ? nil : $0 }
        let params = object["params"] as? JSONObject ?? [:]
        return Request(id: id, method: method, params: params)
    }

    static func response(id: Any?, result: Any) -> Data {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    static func errorResponse(id: Any?, _ failure: Failure) -> Data {
        var error: JSONObject = ["code": failure.code, "message": failure.message]
        if let data = failure.data { error["data"] = data }
        return encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": error])
    }

    static func encode(_ object: JSONObject) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
