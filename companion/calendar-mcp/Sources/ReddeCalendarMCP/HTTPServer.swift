import Foundation
import Network

/// A deliberately small HTTP/1.1 server for MCP's Streamable HTTP transport: one request per
/// connection, JSON responses, no server-initiated stream (GET answers 405).
final class HTTPServer {
    let port: UInt16
    let token: String
    let handler: MCPHandler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.goosehouse.redde-calendar-mcp.http", attributes: .concurrent)
    static let maxBody = 1 << 20

    init(port: UInt16, token: String, handler: MCPHandler) {
        self.port = port; self.token = token; self.handler = handler
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let port = self.port
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: Log.info("listening on port \(port)")
            case let .failed(error):
                let inUse = (error == .posix(.EADDRINUSE))
                Log.info(inUse ? "port \(port) is already in use (is the background copy already running?)" : "listener failed: \(error)")
                exit(1)
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Tailnet (100.64.0.0/10, fd7a:115c:a1e0::/48) and loopback only.
    static func isAllowed(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case let .ipv4(address):
            let b = [UInt8](address.rawValue)
            return b[0] == 127 || (b[0] == 100 && (b[1] & 0xC0) == 64)
        case let .ipv6(address):
            let b = [UInt8](address.rawValue)
            if address == .loopback { return true }
            if b[0 ..< 6] == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0][...] { return true }
            // IPv4-mapped (::ffff:a.b.c.d)
            if b[0 ..< 10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
                return b[12] == 127 || (b[12] == 100 && (b[13] & 0xC0) == 64)
            }
            return false
        default:
            return false
        }
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isAllowed(connection.endpoint) else {
            Log.info("refused connection from \(connection.endpoint)")
            connection.cancel(); return
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > Self.maxBody + 16 * 1024 { self.send(connection, status: 413, body: nil); return }
            if let request = Request.parse(buffer) {
                self.respond(connection, request)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, _ request: Request) {
        guard let auth = request.headers["authorization"], !auth.isEmpty else {
            Log.info("unauthorized \(request.method) from \(connection.endpoint): no Authorization header")
            send(connection, status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8), extra: ["WWW-Authenticate": "Bearer"])
            return
        }
        // "Bearer <token>" is standard; a bare token is accepted too, since it's the same secret.
        let hasScheme = auth.lowercased().hasPrefix("bearer ")
        let presented = (hasScheme ? String(auth.dropFirst(7)) : auth).trimmingCharacters(in: .whitespaces)
        guard constantTimeEquals(presented, token) else {
            Log.info("unauthorized \(request.method) from \(connection.endpoint): token mismatch (\(hasScheme ? "Bearer scheme" : "no scheme"), \(presented.count) characters, expected \(token.count))")
            send(connection, status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8), extra: ["WWW-Authenticate": "Bearer"])
            return
        }
        guard request.path == "/mcp" || request.path == "/" else { send(connection, status: 404, body: nil); return }
        switch request.method {
        case "POST":
            Log.info("POST from \(connection.endpoint)")
            let reply = handler.handle(body: request.body)
            send(connection, status: reply.status, body: reply.body, extra: reply.headers)
        case "HEAD":
            send(connection, status: 405, body: nil, extra: ["Allow": "POST, DELETE"])
        case "GET":
            send(connection, status: 405, body: nil, extra: ["Allow": "POST, DELETE"])
        case "DELETE":
            send(connection, status: 200, body: nil)
        default:
            send(connection, status: 405, body: nil, extra: ["Allow": "POST, DELETE"])
        }
    }

    private func send(_ connection: NWConnection, status: Int, body: Data?, extra: [String: String] = [:]) {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                      405: "Method Not Allowed", 413: "Payload Too Large"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body?.count ?? 0)\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        connection.send(content: data, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data

        /// A complete request, or nil while more bytes are needed.
        static func parse(_ data: Data) -> Request? {
            guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ")
            guard requestLine.count >= 2 else { return Request(method: "BAD", path: "", headers: [:], body: Data()) }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let bodyStart = headerEnd.upperBound
            let length = Int(headers["content-length"] ?? "0") ?? 0
            if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                guard let body = dechunk(data[bodyStart...]) else { return nil }
                return Request(method: String(requestLine[0]), path: String(requestLine[1].split(separator: "?")[0]), headers: headers, body: body)
            }
            guard length <= maxBody, data.count - bodyStart >= length else { return nil }
            return Request(method: String(requestLine[0]), path: String(requestLine[1].split(separator: "?")[0]),
                           headers: headers, body: Data(data[bodyStart ..< bodyStart + length]))
        }

        /// Decodes a chunked body; nil until the terminating zero-length chunk has arrived.
        static func dechunk(_ data: Data) -> Data? {
            var out = Data()
            var index = data.startIndex
            while true {
                guard let lineEnd = data[index...].range(of: Data("\r\n".utf8)) else { return nil }
                let sizeText = String(decoding: data[index ..< lineEnd.lowerBound], as: UTF8.self).split(separator: ";")[0]
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
                let chunkStart = lineEnd.upperBound
                if size == 0 { return out }
                guard data.endIndex - chunkStart >= size + 2 else { return nil }
                out.append(data[chunkStart ..< chunkStart + size])
                index = chunkStart + size + 2
                if out.count > maxBody { return out }
            }
        }
    }
}
