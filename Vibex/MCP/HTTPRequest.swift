import Foundation

/// A parsed HTTP/1.1 request. Just enough for JSON-RPC over localhost.
nonisolated struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]   // lower-cased keys
    let body: Data

    var contentLength: Int { Int(headers["content-length"] ?? "") ?? 0 }
    var bearerToken: String? {
        guard let auth = headers["authorization"], auth.lowercased().hasPrefix("bearer ") else { return nil }
        return String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
    }
    var wantsKeepAlive: Bool { headers["connection"]?.lowercased() != "close" }
}

/// Incremental parser: feed bytes, take complete requests out.
nonisolated struct HTTPRequestParser: Sendable {
    private var buffer = Data()
    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 16 * 1024 * 1024

    enum Failure: Error { case malformed, tooLarge }

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete request, or nil when more bytes are needed.
    mutating func next() throws -> HTTPRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maxHeaderBytes { throw Failure.tooLarge }
            return nil
        }
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { throw Failure.malformed }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw Failure.malformed }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { throw Failure.malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length <= Self.maxBodyBytes else { throw Failure.tooLarge }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return nil }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        buffer.removeSubrange(buffer.startIndex..<(bodyStart + length))
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body)
    }
}

nonisolated enum HTTPResponse {
    static func make(status: Int, reason: String, body: Data = Data(), contentType: String = "application/json", keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}
