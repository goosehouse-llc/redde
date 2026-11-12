import Foundation
import os

/// Where an ACP agent is: a Redde bridge (`companion/redde-bridge`) and one of its agents, or a
/// server that speaks remote ACP itself (`goose serve`, at its own `/acp`).
nonisolated struct AcpEndpoint: Hashable, Sendable {
    /// `ws(s)://host:port/acp/<agent>`, or the server's own path.
    var socketURL: URL
    /// The bridge's list of agents (`/agents`), when the address is a bridge's.
    var agentsURL: URL?
    var token: String?
    /// The folder new chats work in, on the host; nil leaves it to the bridge.
    var folder: String?

    /// From what the person typed: `host:8765`, `ws://…`, `https://…` (taken as `wss://`). An
    /// address with a path of its own is used as it is (`ws://127.0.0.1:3284/acp`).
    static func make(address: String, agent: String, token: String?, folder: String?) -> AcpEndpoint? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "ws://" + text }
        guard var parts = URLComponents(string: text), let host = parts.host, !host.isEmpty else { return nil }
        switch parts.scheme?.lowercased() {
        case "http", "ws": parts.scheme = "ws"
        case "https", "wss": parts.scheme = "wss"
        default: return nil
        }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        var agents: URL?
        if path.isEmpty {
            let agent = agent.trimmingCharacters(in: .whitespacesAndNewlines)
            parts.path = agent.isEmpty ? "/acp" : "/acp/" + agent
            var list = parts
            list.scheme = parts.scheme == "wss" ? "https" : "http"
            list.path = "/agents"
            agents = list.url
        } else {
            parts.path = path
        }
        guard let socket = parts.url else { return nil }
        let token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AcpEndpoint(socketURL: socket, agentsURL: agents, token: token?.isEmpty == false ? token : nil,
                           folder: folder?.isEmpty == false ? folder : nil)
    }

    /// One of the bridge's agents.
    nonisolated struct Agent: Identifiable, Hashable, Sendable {
        var id: String
        var name: String
    }

    /// The bridge's agents, for Settings to pick from.
    func agents() async throws -> [Agent] {
        guard let agentsURL else { return [] }
        var request = URLRequest(url: agentsURL)
        request.timeoutInterval = 15
        authorize(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw TransportError.http(status: status, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        let json = try JSONValue.parse(data)
        return (json["agents"]?.array ?? []).compactMap { row in
            row["id"]?.string.map { Agent(id: $0, name: row["name"]?.string ?? $0) }
        }
    }

    /// The token as a bearer, and as `X-Secret-Key` for `goose serve`.
    func authorize(_ request: inout URLRequest) {
        guard let token else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Secret-Key")
    }
}

/// An error an ACP agent answered with.
nonisolated struct AcpError: LocalizedError, Sendable {
    var code: Int
    var message: String
    /// The bridge won't load a session's history while a turn runs in it.
    var isBusy: Bool { code == -32002 && message.contains("under way") }
    var errorDescription: String? { message }
}

/// The phone's link to one ACP agent: a WebSocket carrying JSON-RPC 2.0, one message a frame.
/// Shared by every conversation with that agent (`client(for:)`). It speaks ACP version 1 as a
/// client that offers no files or terminal of its own, and knows the bridge's extras
/// (`_redde/attach`, `_redde/turn_ended`, `_redde/request_resolved`) where the bridge is there.
@MainActor
final class AcpClient {
    /// What the agent said about itself on `initialize`.
    nonisolated struct Info: Sendable, Equatable {
        var name: String
        var version: String?
        /// The bridge's version, when the agent is reached through one.
        var bridge: String?
        /// The bridge's own folder for new chats.
        var folder: String?
        var canLoad: Bool
        var canList: Bool
        var canDelete: Bool
        var canResume: Bool
        var takesImages: Bool
        var takesSystemPrompt: Bool
    }

    enum Event {
        case update(session: String, update: JSONValue, seq: Int?)
        /// The agent waits on the person: a permission (`session/request_permission`).
        case request(id: String, session: String?, approval: ApprovalRequest)
        /// Another device answered it, or the agent stopped waiting.
        case resolved(id: String)
        case turnEnded(session: String, stopReason: String?)
        case lost
    }

    /// What `_redde/attach` says about a session.
    nonisolated struct Attached: Sendable {
        var running: Bool
        var prompt: String
        var stopReason: String?
        var updates: [(update: JSONValue, seq: Int?)]
        var requests: [(id: String, approval: ApprovalRequest)]
    }

    private static var clients: [AcpEndpoint: AcpClient] = [:]

    static func client(for endpoint: AcpEndpoint) -> AcpClient {
        if let client = clients[endpoint] { return client }
        let client = AcpClient(endpoint: endpoint)
        clients[endpoint] = client
        return client
    }

    /// The active server's agent, when it is set up as one.
    static func current(_ settings: Settings = .shared) -> AcpClient? {
        settings.acpEndpoint.map(client(for:))
    }

    /// Closes every link (a server switch, Settings changed).
    static func closeAll() {
        for client in clients.values { client.close() }
        clients = [:]
    }

    let endpoint: AcpEndpoint
    private(set) var info: Info?
    /// Each session's config options (the model picker's), as last said.
    private(set) var configOptions: [String: [JSONValue]] = [:]
    /// The options of the last session heard from, for a chat that has none yet.
    private(set) var lastConfigOptions: [JSONValue] = []

    private let log = Logger(subsystem: "com.goosehouse.echo", category: "acp")
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var connecting: Task<Void, Error>?
    private var nextID = 1
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var listeners: [UUID: (Event) -> Void] = [:]
    /// Questions of the agent's waiting on an answer: their JSON-RPC id and the options' ids.
    private var openRequests: [String: (raw: JSONValue, options: [String: String])] = [:]
    /// Sessions being loaded: their replayed history, gathered rather than heard as a turn.
    private var loading: [String: [JSONValue]] = [:]

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": "Redde/\(Bundle.main.shortVersion) iOS"]
        return URLSession(configuration: config)
    }()

    private init(endpoint: AcpEndpoint) { self.endpoint = endpoint }

    var isConnected: Bool { socket != nil && info != nil }

    // MARK: Link

    func ensureConnected() async throws {
        if isConnected { return }
        if let connecting { return try await connecting.value }
        let task = Task { @MainActor in try await self.connect() }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    private func connect() async throws {
        var request = URLRequest(url: endpoint.socketURL)
        request.timeoutInterval = 20
        endpoint.authorize(&request)
        let task = Self.session.webSocketTask(with: request)
        task.maximumMessageSize = 64 * 1024 * 1024
        task.resume()
        socket = task
        receiveTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    let frame = try await task.receive()
                    guard let json = Self.decode(frame) else { continue }
                    await self?.handle(json)
                } catch {
                    await self?.closed(task, error: error)
                    return
                }
            }
        }
        do {
            // The bridge may start the agent now: an `npx` agent's first start can take a while.
            let result = try await call("initialize", [
                "protocolVersion": .number(1),
                "clientCapabilities": .object([
                    "fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]),
                    "terminal": .bool(false),
                ]),
                "clientInfo": .object(["name": .string("redde"), "title": .string("Redde"), "version": .string(Bundle.main.shortVersion)]),
            ], timeout: 180)
            info = Self.info(result)
        } catch {
            close()
            if let error = error as? AcpError { throw error }
            if case TransportError.unreachable = error { throw error }
            throw TransportError.unreachable(String(localized: "Redde couldn't reach the agent at \(endpoint.socketURL.host() ?? ""): \(error.localizedDescription)",
                                                    comment: "An ACP connection that failed to open"))
        }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, let socket = self.socket else { return }
                let alive = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                    socket.sendPing { error in done.resume(returning: error == nil) }
                }
                if !alive {
                    self.log.warning("ping went unanswered; closing")
                    self.closed(socket, error: TransportError.unreachable("ping"))
                    return
                }
            }
        }
    }

    nonisolated static func info(_ result: JSONValue) -> Info {
        let caps = result["agentCapabilities"] ?? .null
        let sessions = caps["sessionCapabilities"] ?? .null
        let redde = result["_meta"]?["redde"]
        func has(_ value: JSONValue?) -> Bool { value.map { !$0.isNull } ?? false }
        return Info(name: result["agentInfo"]?["title"]?.string ?? redde?["name"]?.string ?? result["agentInfo"]?["name"]?.string ?? "Agent",
                    version: result["agentInfo"]?["version"]?.string,
                    bridge: redde?["bridge"]?.string, folder: redde?["cwd"]?.string,
                    canLoad: caps["loadSession"]?.bool ?? false, canList: has(sessions["list"]),
                    canDelete: has(sessions["delete"]), canResume: has(sessions["resume"]),
                    takesImages: caps["promptCapabilities"]?["image"]?.bool ?? false,
                    takesSystemPrompt: has(sessions["systemPrompt"]))
    }

    func close() {
        receiveTask?.cancel(); pingTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        info = nil
        failPending(TransportError.unreachable(String(localized: "the connection to the agent closed", comment: "ACP")))
    }

    private func closed(_ task: URLSessionWebSocketTask, error: Error) {
        guard socket === task else { return }
        log.error("socket closed: \(error.localizedDescription)")
        receiveTask?.cancel(); pingTask?.cancel()
        socket = nil
        info = nil
        failPending(TransportError.streamLost(error.localizedDescription))
        for listener in listeners.values { listener(.lost) }
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending = [:]
        for cont in waiting.values { cont.resume(throwing: error) }
        loading = [:]
    }

    func addListener(_ listener: @escaping (Event) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    func removeListener(_ id: UUID) { listeners[id] = nil }

    // MARK: JSON-RPC

    @discardableResult
    func call(_ method: String, _ params: [String: JSONValue], timeout: TimeInterval? = 60) async throws -> JSONValue {
        try Task.checkCancellation()
        guard let socket else { throw TransportError.unreachable(String(localized: "not connected to the agent", comment: "ACP")) }
        let id = "redde-\(nextID)"
        nextID += 1
        let frame = JSONValue.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": .object(params)])
        let timer: Task<Void, Never>? = timeout.map { seconds in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self, let cont = self.pending.removeValue(forKey: id) else { return }
                cont.resume(throwing: TransportError.malformed("\(method) timed out"))
            }
        }
        defer { timer?.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                pending[id] = cont
                send(frame, socket: socket, call: id)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }

    func notify(_ method: String, _ params: [String: JSONValue]) {
        guard let socket else { return }
        send(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params)]), socket: socket, call: nil)
    }

    private func reply(to raw: JSONValue, result: JSONValue) {
        guard let socket else { return }
        send(.object(["jsonrpc": .string("2.0"), "id": raw, "result": result]), socket: socket, call: nil)
    }

    private func send(_ frame: JSONValue, socket: URLSessionWebSocketTask, call id: String?) {
        guard let data = try? JSONEncoder().encode(frame) else { return }
        socket.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self else { return }
                if let id, let cont = self.pending.removeValue(forKey: id) {
                    cont.resume(throwing: TransportError.unreachable(String(localized: "the connection to the agent dropped", comment: "ACP")))
                }
                self.closed(socket, error: error)
            }
        }
    }

    private nonisolated static func decode(_ frame: URLSessionWebSocketTask.Message) -> JSONValue? {
        switch frame {
        case let .string(text): try? JSONValue.parse(Data(text.utf8))
        case let .data(data): try? JSONValue.parse(data)
        @unknown default: nil
        }
    }

    private nonisolated static func key(_ id: JSONValue?) -> String? {
        id?.string ?? id?.int.map(String.init)
    }

    private func handle(_ json: JSONValue) {
        let method = json["method"]?.string
        if method == nil, let key = Self.key(json["id"]) {
            guard let cont = pending.removeValue(forKey: key) else { return }
            if let error = json["error"], !error.isNull {
                cont.resume(throwing: AcpError(code: error["code"]?.int ?? 0, message: error["message"]?.string ?? "error"))
            } else {
                cont.resume(returning: json["result"] ?? .null)
            }
            return
        }
        guard let method else { return }
        let params = json["params"] ?? .null
        if let raw = json["id"], !raw.isNull {
            asked(method, raw: raw, params: params)
            return
        }
        switch method {
        case "session/update":
            guard let session = params["sessionId"]?.string, let update = params["update"] else { return }
            note(update, session: session)
            if loading[session] != nil {
                loading[session]?.append(update)
                return
            }
            let seq = params["_meta"]?["redde"]?["seq"]?.int
            for listener in listeners.values { listener(.update(session: session, update: update, seq: seq)) }
        case "_redde/turn_ended":
            guard let session = params["sessionId"]?.string else { return }
            for listener in listeners.values { listener(.turnEnded(session: session, stopReason: params["stopReason"]?.string)) }
        case "_redde/request_resolved":
            guard let id = params["id"]?.string else { return }
            openRequests[id] = nil
            for listener in listeners.values { listener(.resolved(id: id)) }
        default:
            break
        }
    }

    /// A request of the agent's. Permissions become approval cards; a form (`elicitation`) isn't
    /// offered yet and is turned down; files and terminals were never offered.
    private func asked(_ method: String, raw: JSONValue, params: JSONValue) {
        guard let key = Self.key(raw) else { return }
        switch method {
        case "session/request_permission":
            let (approval, options) = AcpPermission.approval(id: key, params: params)
            openRequests[key] = (raw, options)
            for listener in listeners.values { listener(.request(id: key, session: params["sessionId"]?.string, approval: approval)) }
        case "elicitation/create":
            reply(to: raw, result: .object(["action": .string("decline")]))
        default:
            guard let socket else { return }
            send(.object(["jsonrpc": .string("2.0"), "id": raw,
                          "error": .object(["code": .number(-32601), "message": .string("Redde doesn't offer \(method)")])]), socket: socket, call: nil)
        }
    }

    /// Keeps what a session says about itself between turns: its config options.
    private func note(_ update: JSONValue, session: String) {
        if update["sessionUpdate"]?.string == "config_option_update", let options = update["configOptions"]?.array {
            configOptions[session] = options
            lastConfigOptions = options
        }
    }

    private func noteOptions(_ result: JSONValue, session: String) {
        guard let options = result["configOptions"]?.array else { return }
        configOptions[session] = options
        lastConfigOptions = options
    }

    // MARK: ACP

    /// The folder a new chat works in: the server's setting, else the bridge's own.
    private var folder: JSONValue { .string(endpoint.folder ?? info?.folder ?? "") }

    func newSession(instructions: String? = nil) async throws -> String {
        try await ensureConnected()
        var params: [String: JSONValue] = ["cwd": folder, "mcpServers": .array([])]
        if let instructions, !instructions.isEmpty, info?.takesSystemPrompt == true {
            params["systemPrompt"] = .object(["mode": .string("append"),
                                              "content": .array([.object(["type": .string("text"), "text": .string(instructions)])])])
        }
        let result = try await call("session/new", params, timeout: 120)
        guard let id = result["sessionId"]?.string else { throw TransportError.malformed("session/new gave no sessionId") }
        noteOptions(result, session: id)
        return id
    }

    /// A session's history, replayed by the agent (`session/load`).
    func load(_ session: String) async throws -> [JSONValue] {
        try await ensureConnected()
        guard info?.canLoad == true else { return [] }
        loading[session] = []
        defer { loading[session] = nil }
        let result = try await call("session/load", ["sessionId": .string(session), "cwd": folder, "mcpServers": .array([])], timeout: 120)
        noteOptions(result, session: session)
        return loading[session] ?? []
    }

    func listSessions() async throws -> [JSONValue] {
        try await ensureConnected()
        guard info?.canList == true else { return [] }
        var rows: [JSONValue] = []
        var cursor: String?
        repeat {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await call("session/list", params)
            rows += page["sessions"]?.array ?? []
            cursor = page["nextCursor"]?.string
        } while cursor != nil && rows.count < 2000
        return rows
    }

    func prompt(_ session: String, blocks: [JSONValue]) async throws -> JSONValue {
        try await call("session/prompt", ["sessionId": .string(session), "prompt": .array(blocks)], timeout: nil)
    }

    func cancel(_ session: String) {
        notify("session/cancel", ["sessionId": .string(session)])
    }

    /// The turn under way in a session, through the bridge; nil without one.
    func attach(_ session: String) async throws -> Attached? {
        try await ensureConnected()
        guard info?.bridge != nil else { return nil }
        let result = try await call("_redde/attach", ["sessionId": .string(session)])
        let prompt = (result["prompt"]?.array ?? []).compactMap { AcpTurnMapper.text($0) }.joined(separator: "\n")
        let updates = (result["updates"]?.array ?? []).compactMap { params -> (JSONValue, Int?)? in
            params["update"].map { ($0, params["_meta"]?["redde"]?["seq"]?.int) }
        }
        let requests = (result["requests"]?.array ?? []).compactMap { message -> (String, ApprovalRequest)? in
            guard message["method"]?.string == "session/request_permission", let raw = message["id"], let key = Self.key(raw) else { return nil }
            let (approval, options) = AcpPermission.approval(id: key, params: message["params"] ?? .null)
            openRequests[key] = (raw, options)
            return (key, approval)
        }
        return Attached(running: result["running"]?.bool ?? false, prompt: prompt, stopReason: result["stopReason"]?.string,
                        updates: updates, requests: requests)
    }

    /// Answers an approval card with one of its choices (once, session, always, deny).
    func answer(request id: String, choice: String) {
        guard let open = openRequests.removeValue(forKey: id) else { return }
        reply(to: open.raw, result: AcpPermission.reply(choice: choice, options: open.options))
    }

    func hasOpenRequest(_ id: String) -> Bool { openRequests[id] != nil }

    /// Picks a model for a session, when it offers one and it isn't the current one.
    func setModel(_ session: String, value: String) async throws {
        let options = configOptions[session] ?? []
        guard let option = AcpModels.option(options), let config = option["id"]?.string,
              option["currentValue"]?.string != value else { return }
        let result = try await call("session/set_config_option",
                                    ["sessionId": .string(session), "configId": .string(config), "value": .string(value)])
        noteOptions(result, session: session)
    }

    func deleteSession(_ session: String) async throws {
        try await ensureConnected()
        guard info?.canDelete == true else { throw AcpError(code: -32601, message: String(localized: "This agent can't delete its chats.", comment: "ACP")) }
        try await call("session/delete", ["sessionId": .string(session)])
        configOptions[session] = nil
    }

    func modelChoices(session: String?) -> [ModelChoice] {
        AcpModels.choices(session.flatMap { configOptions[$0] } ?? lastConfigOptions)
    }
}
