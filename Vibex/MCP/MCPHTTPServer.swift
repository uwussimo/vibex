import Foundation
import Network
import os

/// Localhost HTTP server for the MCP Streamable HTTP transport. One endpoint: `/mcp`.
/// Bytes are handled on a private queue; each request body is handed to `handler`, which decides
/// where to run (the MCP server hops to the main actor).
nonisolated final class MCPHTTPServer: Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> (status: Int, reason: String, body: Data)

    let port: UInt16
    private let token: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.yusuf.vibex.mcp.http", qos: .userInitiated)
    private let listener: NWListener

    init(port: UInt16, token: String, handler: @escaping Handler) throws {
        self.port = port
        self.token = token
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: Log.mcp.info("MCP listening on 127.0.0.1:\(self.port)")
            case let .failed(error): Log.mcp.error("MCP listener failed: \(error.localizedDescription, privacy: .public)")
            default: break
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    /// First free TCP port at or above `preferred` on the loopback interface.
    nonisolated static func freePort(preferring preferred: UInt16, attempts: Int = 100) -> UInt16 {
        for offset in 0..<attempts {
            let candidate = preferred &+ UInt16(offset)
            let socketFD = socket(AF_INET, SOCK_STREAM, 0)
            guard socketFD >= 0 else { continue }
            defer { close(socketFD) }
            // The listener binds with address reuse, so a port in TIME_WAIT from a previous run is still ours.
            var reuse: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = candidate.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if bound == 0 { return candidate }
        }
        return preferred
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, parser: HTTPRequestParser())
    }

    private func receive(on connection: NWConnection, parser: HTTPRequestParser) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var parser = parser
            if let data, !data.isEmpty { parser.append(data) }
            if error != nil || (isComplete && data == nil) {
                connection.cancel()
                return
            }
            do {
                if let request = try parser.next() {
                    Task { [parser] in
                        await self.respond(to: request, on: connection, parser: parser)
                    }
                    return
                }
            } catch {
                let response = HTTPResponse.make(status: 400, reason: "Bad Request", keepAlive: false)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if isComplete {
                connection.cancel()
            } else {
                self.receive(on: connection, parser: parser)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection, parser: HTTPRequestParser) async {
        let keepAlive = request.wantsKeepAlive
        let response: Data
        if request.path != "/mcp" && request.path != "/mcp/" {
            response = HTTPResponse.make(status: 404, reason: "Not Found", keepAlive: keepAlive)
        } else if request.bearerToken != token {
            response = HTTPResponse.make(status: 401, reason: "Unauthorized", body: Data(#"{"error":"missing or wrong bearer token"}"#.utf8), keepAlive: keepAlive)
        } else {
            switch request.method {
            case "POST":
                var request = request
                if case let .hostPort(_, port) = connection.endpoint { request.clientPort = port.rawValue }
                let result = await handler(request)
                response = HTTPResponse.make(status: result.status, reason: result.reason, body: result.body, keepAlive: keepAlive)
            case "DELETE":
                response = HTTPResponse.make(status: 200, reason: "OK", keepAlive: keepAlive)
            case "GET":
                response = HTTPResponse.make(status: 405, reason: "Method Not Allowed", keepAlive: keepAlive)
            default:
                response = HTTPResponse.make(status: 405, reason: "Method Not Allowed", keepAlive: keepAlive)
            }
        }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            if keepAlive, let self {
                self.receive(on: connection, parser: parser)
            } else {
                connection.cancel()
            }
        })
    }
}
