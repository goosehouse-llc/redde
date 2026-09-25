import Foundation
import Observation
import os

/// A tool approval the agent is waiting on (hermes serve only).
nonisolated struct ApprovalRequest: Identifiable, Equatable, Sendable, Codable {
    var id: String            // request_id
    var command: String
    var description: String?
    var choices: [String]     // once | session | always | deny
}

/// JSON-RPC 2.0 over WebSocket to `hermes serve` (the desktop gateway). One shared connection.
///
/// Auth (remote bind, basic provider): `POST /auth/password-login` sets session cookies,
/// `POST /api/auth/ws-ticket` mints a 30 s single-use ticket, then `ws://…/api/ws?ticket=`.
/// REST calls ride on the same cookie jar.
@Observable
final class HermesServeClient {
    static let shared = HermesServeClient()

    enum State: Equatable { case disconnected, connecting, connected, reconnecting(attempt: Int), failed(String) }
    private(set) var state: State = .disconnected
    /// True after a successful `ensureConnected()` until `disconnect()`; drives auto-reconnect.
    private var wantsConnection = false
    private var reconnectTask: Task<Void, Never>?

    /// Fan-out of server events: (type, session_id, payload).
    typealias Event = (type: String, sessionID: String?, payload: JSONValue)

    private let log = Logger(subsystem: "com.goosehouse.echo", category: "serve")
    /// Rebuilt when the Cloudflare Access headers change; every request and WebSocket
    /// handshake inherits them from the configuration.
    private var session: URLSession
    private var appliedHeaders: [String: String] = [:]
    private let settings: Settings
    private let password: () -> String?
    /// Tests install a stub URLProtocol here; production leaves it empty.
    private let protocolClasses: [AnyClass]

    init(settings: Settings = .shared,
         password: @escaping () -> String? = { Keychain.read(.serveDashboardPassword) },
         protocolClasses: [AnyClass] = []) {
        self.settings = settings
        self.password = password
        self.protocolClasses = protocolClasses
        session = Self.makeSession(headers: [:], protocolClasses: protocolClasses)
    }

    private static func makeSession(headers: [String: String], protocolClasses: [AnyClass]) -> URLSession {
        let config = URLSessionConfiguration.default
        if !protocolClasses.isEmpty { config.protocolClasses = protocolClasses }
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30
        // Fail fast offline; the reconnect loop and the conversation's outbox do the retrying.
        config.waitsForConnectivity = false
        if !headers.isEmpty { config.httpAdditionalHeaders = headers }
        return URLSession(configuration: config)
    }

    /// Apply the current Access headers; drops the socket and cookies if they changed.
    private func syncAccessHeaders() {
        let wanted = settings.accessHeaders
        guard wanted != appliedHeaders else { return }
        appliedHeaders = wanted
        authenticatedAt = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session.invalidateAndCancel()
        session = Self.makeSession(headers: wanted, protocolClasses: protocolClasses)
        log.info("hermes serve session rebuilt (\(wanted.isEmpty ? "no" : "with") Cloudflare Access headers)")
    }
    /// Frame ceiling for every WebSocket we open. A stored transcript arrives in one frame.
    private static let maxFrameBytes = 64 * 1024 * 1024

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var nextID = 1
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var listeners: [UUID: (Event) -> Void] = [:]
    /// stored session id → runtime session id, valid for this connection.
    private var runtimeIDs: [String: String] = [:]

    private var baseURL: URL? { settings.serveBaseURL }

    // MARK: - Connection

    /// The connect attempt in flight, shared by every caller that arrives while it runs.
    private var connectTask: Task<Void, Error>?
    private var connectSerial = 0

    func ensureConnected() async throws {
        if state == .connected, socket != nil { return }
        // A reconnect loop is already working on it: wait for it rather than racing it.
        if case .reconnecting = state, reconnectTask != nil {
            if await waitForConnection(timeout: 30) { return }
            throw TransportError.unreachable("Hermes Dashboard is unreachable")
        }
        // One attempt at a time: a second caller (model warm-up racing the first send) joins
        // the one in flight instead of opening a second socket over the first.
        let task: Task<Void, Error>
        if let connectTask {
            task = connectTask
        } else {
            connectSerial += 1
            let serial = connectSerial
            task = Task { [self] in
                defer { if connectSerial == serial { connectTask = nil } }
                try await connectOnce()
            }
            connectTask = task
        }
        try await task.value
        wantsConnection = true
    }

    private func connectOnce() async throws {
        guard let baseURL else { throw TransportError.badURL }
        if case .reconnecting = state {} else { state = .connecting }
        do {
            let ticket = try await authenticate()
            try await openSocket(baseURL: baseURL, ticket: ticket)
            try Task.checkCancellation()   // disconnect() while the handshake ran: don't keep the link
            state = .connected
        } catch {
            // A cancelled attempt was disconnect()'s doing: it already tore down and set the
            // state, and a newer attempt may own the socket by now.
            if Task.isCancelled { throw error }
            teardown()
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func disconnect() {
        wantsConnection = false
        reconnectTask?.cancel(); reconnectTask = nil
        connectTask?.cancel(); connectTask = nil
        teardown()
        // Settings changed or the app asked for a clean slate: the cookie is not to be trusted
        // past this point, whatever the TTL says.
        authenticatedAt = nil
        state = .disconnected
    }

    /// Called when the app returns to the foreground: pick the link back up if we had one.
    func reconnectIfNeeded() {
        guard wantsConnection, state != .connected else { return }
        scheduleReconnect()
    }

    /// Waits until the socket is back (or gives up). Used by a turn that lost its connection.
    func waitForConnection(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state == .connected, socket != nil { return true }
            if !wantsConnection || Task.isCancelled { return false }   // an abandoned turn must not poll for 90 s
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return false }
        }
        return false
    }

    /// Exponential backoff: 1, 2, 4 … 30 s, until connected or `disconnect()`.
    private func scheduleReconnect() {
        guard reconnectTask == nil, wantsConnection else { return }
        reconnectTask = Task { [weak self] in
            var attempt = 0
            var delay: Double = 1
            while let self, wantsConnection, !Task.isCancelled {
                attempt += 1
                state = .reconnecting(attempt: attempt)
                log.info("reconnecting to hermes serve (attempt \(attempt))")
                do {
                    try await connectOnce()
                    log.info("hermes serve reconnected")
                    for l in listeners.values { l(("connection.restored", nil, .null)) }
                    reconnectTask = nil
                    return
                } catch {
                    // disconnect() cancelled this loop: it already reset the state and the
                    // reference, and may have started a newer loop that must not be clobbered.
                    if Task.isCancelled { return }
                    state = .reconnecting(attempt: attempt)
                    try? await Task.sleep(for: .seconds(delay))
                    delay = min(delay * 2, 30)
                }
            }
            if !Task.isCancelled { self?.reconnectTask = nil }
        }
    }

    private func teardown() {
        receiveTask?.cancel(); receiveTask = nil
        pingTask?.cancel(); pingTask = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        runtimeIDs = [:]
        // The request left the socket; whether the host acted on it is unknown, so this is a
        // lost stream, not a malformed reply (the conversation must not report it as one).
        for (_, cont) in pending { cont.resume(throwing: TransportError.streamLost("the connection to Hermes Dashboard closed")) }
        pending = [:]
    }

    /// When the cookie was last proven good. Within the TTL, REST calls skip the login probe
    /// entirely (one round trip instead of two); a 401 clears it and the call retries once.
    private var authenticatedAt: Date?
    private let authTTL: TimeInterval = 10 * 60

    private func login(baseURL: URL) async throws {
        syncAccessHeaders()
        if let at = authenticatedAt, Date.now.timeIntervalSince(at) < authTTL { return }
        // Cookie may still be live from an earlier session: cheap probe before a real login.
        guard var comps = URLComponents(url: baseURL.appending(path: "api/sessions"), resolvingAgainstBaseURL: false) else { throw TransportError.badURL }
        comps.queryItems = [.init(name: "limit", value: "1")]
        if let probeURL = comps.url, let (_, r) = try? await session.data(for: URLRequest(url: probeURL)),
           (r as? HTTPURLResponse)?.statusCode == 200 {
            authenticatedAt = .now
            return
        }

        let username = settings.serveUsername
        guard !username.isEmpty, let password = password(), !password.isEmpty else {
            throw TransportError.malformed("Hermes Dashboard username/password not set in Settings")
        }
        struct Body: Encodable { var provider = "basic"; var username: String; var password: String }
        var request = URLRequest(url: baseURL.appending(path: "auth/password-login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(username: username, password: password))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw TransportError.http(status: status, body: status == 401 ? "login rejected" : String(decoding: data.prefix(200), as: UTF8.self))
        }
        authenticatedAt = .now
        log.info("hermes serve login ok")
    }

    /// Proves the cookie (logging in if needed) and mints a single-use WebSocket ticket.
    func authenticate() async throws -> String {
        guard let baseURL else { throw TransportError.badURL }
        try await login(baseURL: baseURL)
        return try await mintTicket(baseURL: baseURL)
    }

    private func mintTicket(baseURL: URL) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "api/auth/ws-ticket"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        var (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401, authenticatedAt != nil {
            // The cookie the TTL vouched for is dead (gateway restart, password change): log in
            // again and retry once, as rest() does, instead of trusting it for the rest of the TTL.
            authenticatedAt = nil
            try await login(baseURL: baseURL)
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw TransportError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: "ws-ticket")
        }
        guard let ticket = try JSONValue.parse(data)["ticket"]?.string else {
            throw TransportError.malformed("no ws ticket")
        }
        return ticket
    }

    /// Opens a WebSocket to a dashboard plugin path (e.g. `api/plugins/kanban/events`) after
    /// logging in and minting a ticket. The caller owns the task.
    func openPluginSocket(path: String, query: [URLQueryItem]) async throws -> URLSessionWebSocketTask {
        guard let baseURL else { throw TransportError.badURL }
        let ticket = try await authenticate()
        guard var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else { throw TransportError.badURL }
        comps.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        comps.queryItems = query + [.init(name: "ticket", value: ticket)]
        guard let url = comps.url else { throw TransportError.badURL }
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = Self.maxFrameBytes
        task.resume()
        return task
    }

    private func openSocket(baseURL: URL, ticket: String) async throws {
        guard var comps = URLComponents(url: baseURL.appending(path: "api/ws"), resolvingAgainstBaseURL: false) else {
            throw TransportError.badURL
        }
        comps.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        comps.queryItems = [.init(name: "ticket", value: ticket)]
        guard let wsURL = comps.url else { throw TransportError.badURL }
        let task = session.webSocketTask(with: wsURL)
        // URLSession defaults to a 1 MiB frame ceiling and kills the socket when a reply
        // is bigger. Resuming a long session sends the whole transcript in one frame.
        task.maximumMessageSize = Self.maxFrameBytes
        task.resume()
        // Never stack a second link on a first: the old loops would keep the old socket alive.
        receiveTask?.cancel(); pingTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = task
        // Wait for gateway.ready (or the first frame) so callers know the link is live; a host
        // that completes the handshake and then goes quiet must not hang ensureConnected() forever.
        let first = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask { try await Task.sleep(for: .seconds(10)); throw TransportError.unreachable("Hermes Dashboard didn't answer the WebSocket handshake") }
            let frame = try await group.next()!
            group.cancelAll()
            return frame
        }
        if let json = Self.decode(first) { handle(json) }
        // Frames are parsed off the main actor; only the finished value hops over. At token
        // rate this is the difference between a smooth transcript and a UI thread full of JSON.
        receiveTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    let frame = try await task.receive()
                    guard let json = Self.decode(frame) else { continue }
                    await self?.handle(json)
                } catch {
                    await self?.socketClosed(task, error: error)
                    return
                }
            }
        }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self else { return }
                do {
                    _ = try await call("gateway.ping", params: .object([:]), timeout: 10)
                } catch {
                    // Half-open socket: nobody answered. Drop it so the receive loop reconnects.
                    log.warning("ping failed (\(error.localizedDescription)); resetting socket")
                    socket?.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
    }

    private func socketClosed(_ task: URLSessionWebSocketTask, error: Error) {
        log.error("socket closed: \(error.localizedDescription)")
        guard socket === task else { return }
        teardown()
        state = .disconnected
        for l in listeners.values { l(("connection.lost", nil, .null)) }
        scheduleReconnect()
    }

    private nonisolated static func decode(_ frame: URLSessionWebSocketTask.Message) -> JSONValue? {
        let data: Data
        switch frame {
        case let .string(text): data = Data(text.utf8)
        case let .data(bytes): data = bytes
        @unknown default: return nil
        }
        return try? JSONValue.parse(data)
    }

    private func handle(_ json: JSONValue) {
        if let id = json["id"], !id.isNull, json["method"] == nil {
            let key = id.string ?? id.int.map(String.init) ?? ""
            guard let cont = pending.removeValue(forKey: key) else { return }
            if let error = json["error"] {
                let code = error["code"]?.int ?? 0
                cont.resume(throwing: RPCError(code: code, message: error["message"]?.string ?? "rpc error"))
            } else {
                cont.resume(returning: json["result"] ?? .null)
            }
            return
        }
        if json["method"]?.string == "event", let params = json["params"] {
            let event: Event = (params["type"]?.string ?? "", params["session_id"]?.string, params["payload"] ?? .null)
            for l in listeners.values { l(event) }
            return
        }
        // Host request we can't serve (terminal, file dialogs): decline politely.
        if let id = json["id"], json["method"] != nil {
            let reply = JSONValue.object(["jsonrpc": .string("2.0"), "id": id,
                                          "error": .object(["code": .number(-32601), "message": .string("Method not supported on Redde")])])
            send(reply)
        }
    }

    // MARK: - RPC

    nonisolated struct RPCError: LocalizedError, Sendable {
        var code: Int
        var message: String
        var errorDescription: String? { "\(message) (\(code))" }
    }

    private static let encoder = JSONEncoder()

    /// Cancelling the calling task fails the call with `CancellationError` at once; a turn that
    /// was stopped must not sit out the reply (or the timeout) of a request it no longer wants.
    @discardableResult
    func call(_ method: String, params: JSONValue, timeout: TimeInterval = 60) async throws -> JSONValue {
        try Task.checkCancellation()
        // No socket means the request never left the phone: safe for the caller to send again.
        guard socket != nil else { throw TransportError.unreachable("not connected to Hermes Dashboard") }
        let id = "echo-\(nextID)"
        nextID += 1
        let frame = JSONValue.object(["jsonrpc": .string("2.0"), "id": .string(id),
                                      "method": .string(method), "params": params])
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, let cont = pending.removeValue(forKey: id) else { return }
            cont.resume(throwing: TransportError.malformed("\(method) timed out"))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                pending[id] = cont
                send(frame, forCall: id)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    /// A failed send fails its RPC immediately — otherwise the pending continuation would sit
    /// out the full timeout waiting for a reply to a request that never left the socket.
    private func send(_ frame: JSONValue, forCall id: String? = nil) {
        guard let socket, let data = try? Self.encoder.encode(frame) else {
            if let id, let cont = pending.removeValue(forKey: id) {
                cont.resume(throwing: TransportError.unreachable("not connected to Hermes Dashboard"))
            }
            return
        }
        socket.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self else { return }
                self.log.error("send failed: \(error.localizedDescription)")
                if let id, let cont = self.pending.removeValue(forKey: id) {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func addListener(_ listener: @escaping (Event) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    func removeListener(_ id: UUID) { listeners[id] = nil }

    // MARK: - Sessions

    /// Runtime session id for a stored session (resuming it), or a fresh session when nil.
    /// Returns (runtime id, stored id).
    func openSession(stored: String?, model: String? = nil, provider: String? = nil, reasoningEffort: String? = nil)
        async throws -> (runtime: String, stored: String) {
        if let stored, let runtime = runtimeIDs[stored] { return (runtime, stored) }
        if let stored {
            let result = try await call("session.resume", params: .object(["session_id": .string(stored), "omit_messages": .bool(true)]))
            guard let runtime = result["session_id"]?.string else { throw TransportError.malformed("resume: no session id") }
            runtimeIDs[stored] = runtime
            return (runtime, stored)
        }
        // "desktop", not "mobile": the source picks the platform hint in the agent's system
        // prompt, and hermes has no hint for "mobile" — the agent was told nothing about this
        // surface and would refuse to send images. The desktop hint teaches what Redde actually
        // renders: full GitHub markdown, and files delivered as MEDIA:/path tags, which the app
        // fetches via resolveServeMedia. (Desktop-only tools like terminal.read fail gracefully:
        // an unanswered server→client request returns empty.) Existing sessions keep their
        // stored source; only new conversations pick this up.
        var params: [String: JSONValue] = ["source": .string("desktop"), "close_on_disconnect": .bool(false)]
        if let model, !model.isEmpty { params["model"] = .string(model) }
        if let provider, !provider.isEmpty { params["provider"] = .string(provider) }
        if let reasoningEffort, !reasoningEffort.isEmpty { params["reasoning_effort"] = .string(reasoningEffort) }
        let result = try await call("session.create", params: .object(params))
        guard let runtime = result["session_id"]?.string else { throw TransportError.malformed("create: no session id") }
        let storedID = result["stored_session_id"]?.string ?? runtime
        runtimeIDs[storedID] = runtime
        return (runtime, storedID)
    }

    /// Re-attaches to a stored session after a reconnect. Returns the raw resume payload
    /// (`session_id`, `running`, `messages` when requested) and refreshes the runtime id map.
    func resume(stored: String, withMessages: Bool) async throws -> JSONValue {
        let result = try await call("session.resume", params: .object(["session_id": .string(stored), "omit_messages": .bool(!withMessages)]))
        if let runtime = result["session_id"]?.string { runtimeIDs[stored] = runtime }
        return result
    }

    func history(stored: String) async throws -> [JSONValue] {
        // The socket may have dropped since the list was fetched; opening a session must not
        // fail just because nothing has used the link in a while. A long transcript also takes
        // the host a while to assemble, so this one gets more than the default minute.
        try await ensureConnected()
        let result = try await call("session.resume",
                                    params: .object(["session_id": .string(stored), "omit_messages": .bool(false)]),
                                    timeout: 180)
        if let runtime = result["session_id"]?.string { runtimeIDs[stored] = runtime }
        return result["messages"]?.array ?? []
    }

    // MARK: - Projects (sessions grouped by working directory / repo)

    nonisolated struct Project: Identifiable, Sendable, Equatable {
        var id: String
        var label: String
        var path: String?
        var isHome: Bool
        var sessionCount: Int
        var lastActive: Date?
        var totalCost: Double
        var lanes: [Lane]

        nonisolated struct Lane: Identifiable, Sendable, Equatable {
            var id: String
            var label: String
            var repoLabel: String?
            var sessions: [HermesSessionsAPI.SessionSummary]
        }

        init?(_ j: JSONValue) {
            guard let id = j["id"]?.string else { return nil }
            self.id = id
            label = j["label"]?.string ?? id
            path = j["path"]?.string
            isHome = j["isNoProject"]?.bool ?? (id == "__no_project__")
            sessionCount = j["sessionCount"]?.int ?? 0
            lastActive = j["lastActive"]?.number.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            totalCost = j["totalCostUsd"]?.number ?? 0
            var lanes: [Lane] = []
            for repo in j["repos"]?.array ?? [] {
                let repoLabel = repo["label"]?.string
                for g in repo["groups"]?.array ?? [] {
                    guard let gid = g["id"]?.string else { continue }
                    // One encode/decode per lane, not per row.
                    let rows: [HermesSessionsAPI.SessionSummary] = (g["sessions"]).flatMap { sessions in
                        (try? JSONEncoder().encode(sessions)).flatMap { try? JSONDecoder().decode([HermesSessionsAPI.SessionSummary].self, from: $0) }
                    } ?? []
                    lanes.append(Lane(id: gid, label: g["label"]?.string ?? "main", repoLabel: repoLabel, sessions: rows))
                }
            }
            self.lanes = lanes
        }
    }

    /// Project overview: counts and a few previews per project, no session rows in lanes.
    func projectTree() async throws -> [Project] {
        try await ensureConnected()
        let result = try await call("projects.tree", params: .object(["preview_limit": .number(0)]))
        return (result["projects"]?.array ?? []).compactMap(Project.init)
    }

    /// One project with every lane's sessions.
    func projectSessions(_ projectID: String) async throws -> Project? {
        try await ensureConnected()
        let result = try await call("projects.project_sessions", params: .object(["project_id": .string(projectID)]))
        return result["project"].flatMap(Project.init)
    }

    /// A REST call: the cookie is enough, no need to bring the WebSocket up for a list.
    func listSessions(limit: Int = 100) async throws -> [HermesSessionsAPI.SessionSummary] {
        let data = try await rest("GET", "api/sessions?limit=\(limit)&offset=0&order=recent", body: nil as Data?)
        struct Envelope: Decodable { var sessions: [HermesSessionsAPI.SessionSummary]? ; var data: [HermesSessionsAPI.SessionSummary]? }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return env.sessions ?? env.data ?? []
    }

    // MARK: - Skills (dashboard REST, cookie-authenticated)

    nonisolated struct DashboardSkill: Decodable, Identifiable, Sendable {
        var name: String
        var description: String?
        var category: String?
        var enabled: Bool?
        var provenance: String?
        var id: String { name }
    }

    /// Logs in (cookies) without opening the WebSocket; enough for REST.
    func ensureLoggedIn() async throws {
        guard let baseURL else { throw TransportError.badURL }
        try await login(baseURL: baseURL)
    }

    func dashboardSkills() async throws -> [DashboardSkill] {
        let data = try await rest("GET", "api/skills", body: nil as Data?)
        if let list = try? JSONDecoder().decode([DashboardSkill].self, from: data) { return list }
        struct Envelope: Decodable { var skills: [DashboardSkill]? ; var data: [DashboardSkill]? }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return env.skills ?? env.data ?? []
    }

    /// Same shape the API server's /v1/toolsets returns, from the dashboard's own endpoint.
    func dashboardToolsets() async throws -> [HermesSessionsAPI.Toolset] {
        let data = try await rest("GET", "api/tools/toolsets", body: nil as Data?)
        return try JSONDecoder().decode([HermesSessionsAPI.Toolset].self, from: data)
    }

    /// Enable/disable a toolset for its configuration platform, as the dashboard does.
    func toggleToolset(name: String, enabled: Bool) async throws {
        struct Body: Encodable { var enabled: Bool }
        _ = try await rest("PUT", "api/tools/toolsets/\(name)", body: try JSONEncoder().encode(Body(enabled: enabled)))
    }

    /// True when a dashboard login is configured (username + stored password).
    var hasCredentials: Bool {
        !settings.serveUsername.isEmpty && password() != nil
    }

    func skillContent(name: String) async throws -> String {
        var comps = URLComponents()
        comps.path = "api/skills/content"
        comps.queryItems = [.init(name: "name", value: name)]
        let data = try await rest("GET", comps.string ?? "api/skills/content", body: nil as Data?)
        struct Envelope: Decodable { var content: String }
        return try JSONDecoder().decode(Envelope.self, from: data).content
    }

    func createSkill(name: String, content: String, category: String?) async throws {
        struct Body: Encodable { var name: String; var content: String; var category: String? }
        _ = try await rest("POST", "api/skills", body: try JSONEncoder().encode(Body(name: name, content: content, category: category?.nilIfEmpty)))
    }

    func updateSkill(name: String, content: String) async throws {
        struct Body: Encodable { var name: String; var content: String }
        _ = try await rest("PUT", "api/skills/content", body: try JSONEncoder().encode(Body(name: name, content: content)))
    }

    func toggleSkill(name: String, enabled: Bool) async throws {
        struct Body: Encodable { var name: String; var enabled: Bool }
        _ = try await rest("PUT", "api/skills/toggle", body: try JSONEncoder().encode(Body(name: name, enabled: enabled)))
    }

    // MARK: - Context files (SOUL.md, ENVIRONMENT.md) via the dashboard file API

    /// Reads a text file on the gateway host. `~` expands server-side. Nil when the file is missing.
    func readText(path: String) async throws -> String? {
        var comps = URLComponents()
        comps.path = "api/fs/read-text"
        comps.queryItems = [.init(name: "path", value: path)]
        do {
            let data = try await rest("GET", comps.string ?? "api/fs/read-text", body: nil as Data?)
            struct Envelope: Decodable { var text: String; var truncated: Bool? }
            return try JSONDecoder().decode(Envelope.self, from: data).text
        } catch let TransportError.http(status, _) where status == 404 {
            return nil
        }
    }

    /// Switch a live session's model (`config.set key=model`). A bare model name resolves
    /// within the current provider's catalog; the swap is deferred if a turn is streaming.
    func setSessionModel(runtimeSession: String, model: String) async throws {
        let result = try await call("config.set", params: .object([
            "session_id": .string(runtimeSession), "key": .string("model"), "value": .string(model)]))
        if result["confirm_required"]?.bool == true {
            throw TransportError.malformed(result["confirm_message"]?.string ?? "The backend wants confirmation for this model.")
        }
    }

    /// Reads a file on the gateway host as a `data:` URL (`/api/fs/read-data-url`). Nil when the
    /// file is missing or over the server's size cap.
    func readDataURL(path: String) async throws -> String? {
        var comps = URLComponents()
        comps.path = "api/fs/read-data-url"
        comps.queryItems = [.init(name: "path", value: path)]
        do {
            let data = try await rest("GET", comps.string ?? "api/fs/read-data-url", body: nil as Data?)
            struct Envelope: Decodable { var dataUrl: String }
            return try JSONDecoder().decode(Envelope.self, from: data).dataUrl
        } catch let TransportError.http(status, _) where status == 404 || status == 413 {
            return nil
        }
    }

    func writeText(path: String, content: String) async throws {
        struct Body: Encodable { var path: String; var content: String }
        _ = try await rest("POST", "api/fs/write-text", body: try JSONEncoder().encode(Body(path: path, content: content)))
    }

    /// Dashboard REST returning JSON; `path` is relative to the serve base (query string allowed).
    func restJSON(_ method: String, _ path: String, body: JSONValue? = nil, timeout: TimeInterval = 30) async throws -> JSONValue {
        let data = try await rest(method, path, body: body.map { try Self.encoder.encode($0) }, timeout: timeout)
        if data.isEmpty { return .null }
        return try JSONValue.parse(data)
    }

    private func rest(_ method: String, _ path: String, body: Data?, timeout: TimeInterval = 30) async throws -> Data {
        guard let baseURL else { throw TransportError.badURL }
        try await login(baseURL: baseURL)
        guard let url = URL(string: path, relativeTo: baseURL.appending(path: "/"))?.absoluteURL else { throw TransportError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        var (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401, authenticatedAt != nil {
            // Cookie expired under us: log in again and retry this one call.
            authenticatedAt = nil
            try await login(baseURL: baseURL)
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw TransportError.malformed("not HTTP") }
        guard (200 ..< 300).contains(http.statusCode) else {
            struct Detail: Decodable { var detail: String? }
            let detail = (try? JSONDecoder().decode(Detail.self, from: data))?.detail
            throw TransportError.http(status: http.statusCode, body: detail ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
        return data
    }

    /// One entry of the slash-command menu: `text` is what goes into the draft.
    nonisolated struct SlashCompletion: Identifiable, Equatable, Sendable {
        var text: String
        var display: String
        var meta: String
        var kind: String
        var id: String { text }
    }

    /// Completions for a draft that starts with "/": built-in commands, skills and bundles,
    /// ranked by the gateway. `replaceFrom` is where in the draft the chosen text goes.
    func completeSlash(_ text: String) async throws -> (items: [SlashCompletion], replaceFrom: Int) {
        try await ensureConnected()
        let result = try await call("complete.slash", params: .object(["text": .string(text)]), timeout: 10)
        let items = (result["items"]?.array ?? []).compactMap { item -> SlashCompletion? in
            guard let text = item["text"]?.string, !text.isEmpty else { return nil }
            return SlashCompletion(text: text, display: item["display"]?.string ?? text,
                                   meta: item["meta"]?.string ?? "", kind: item["kind"]?.string ?? "command")
        }
        return (items, result["replace_from"]?.int ?? 1)
    }

    /// Models the desktop gateway can route to (`model.options`).
    func modelOptions() async throws -> [ModelChoice] {
        try await ensureConnected()
        let result = try await call("model.options", params: .object(["explicit_only": .bool(true)]))
        return HermesSessionsAPI.parseModelOptions(result)
    }

    func respondApproval(runtimeSession: String, requestID: String, choice: String) async throws {
        try await call("approval.respond", params: .object(["session_id": .string(runtimeSession),
                                                             "request_id": .string(requestID), "choice": .string(choice)]))
    }

    /// Single-question clarify: `answer`. Batched: one call per `question_id`.
    func respondClarify(runtimeSession: String, requestID: String, questionID: String?, answer: String) async throws {
        var params: [String: JSONValue] = ["session_id": .string(runtimeSession), "request_id": .string(requestID), "answer": .string(answer)]
        if let questionID, !questionID.isEmpty { params["question_id"] = .string(questionID) }
        try await call("clarify.respond", params: .object(params))
    }

    func respondSudo(runtimeSession: String, requestID: String, password: String) async throws {
        try await call("sudo.respond", params: .object(["session_id": .string(runtimeSession), "request_id": .string(requestID), "password": .string(password)]))
    }

    /// Empty value = skip; the gateway records the secret as not provided.
    func respondSecret(runtimeSession: String, requestID: String, value: String) async throws {
        try await call("secret.respond", params: .object(["session_id": .string(runtimeSession), "request_id": .string(requestID), "value": .string(value)]))
    }

    /// Rename / pin / archive through the dashboard's PATCH.
    func updateSession(stored: String, title: String? = nil, pinned: Bool? = nil, archived: Bool? = nil) async throws {
        struct Body: Encodable { var title: String?; var pinned: Bool?; var archived: Bool? }
        _ = try await rest("PATCH", "api/sessions/\(stored)", body: try JSONEncoder().encode(Body(title: title, pinned: pinned, archived: archived)))
    }

    /// Branch a session (`session.branch`). Needs the session open on this connection.
    func deleteSession(stored: String) async throws {
        try await call("session.delete", params: .object(["session_id": .string(stored)]))
    }

    func branchSession(stored: String, title: String?) async throws -> String? {
        let (runtime, _) = try await openSession(stored: stored)
        var params: [String: JSONValue] = ["session_id": .string(runtime)]
        if let title, !title.isEmpty { params["name"] = .string(title) }
        let result = try await call("session.branch", params: .object(params))
        return result["stored_session_id"]?.string ?? result["session_key"]?.string ?? result["session_id"]?.string
    }

    /// `session.steer` → queued (true) or rejected (false). 4010 = this agent can't be steered.
    func steer(stored: String, text: String) async throws -> Bool {
        guard let runtime = runtimeIDs[stored] else { throw TransportError.malformed("session isn't open on this connection") }
        do {
            let result = try await call("session.steer", params: .object(["session_id": .string(runtime), "text": .string(text)]))
            return result["status"]?.string == "queued"
        } catch let error as RPCError where error.code == 4010 {
            return false
        }
    }

    /// Opens a stored session for watching only (no agent attached). The gateway mirrors a
    /// running child's activity onto this runtime id as ordinary stream events.
    func resumeLazy(stored: String) async throws -> (runtime: String, running: Bool, messages: [JSONValue]) {
        try await ensureConnected()
        let result = try await call("session.resume", params: .object([
            "session_id": .string(stored), "lazy": .bool(true), "omit_messages": .bool(false)]))
        guard let runtime = result["session_id"]?.string else { throw TransportError.malformed("no session id") }
        return (runtime, result["running"]?.bool ?? false, result["messages"]?.array ?? [])
    }

    func subagentSteer(id: String, text: String) async throws -> Bool {
        let result = try await call("subagent.steer", params: .object(["subagent_id": .string(id), "text": .string(text)]))
        return result["status"]?.string == "queued"
    }

    func subagentInterrupt(id: String) async throws -> Bool {
        let result = try await call("subagent.interrupt", params: .object(["subagent_id": .string(id)]))
        return result["found"]?.bool ?? false
    }

    func interrupt(runtimeSession: String) {
        Task { try? await call("session.interrupt", params: .object(["session_id": .string(runtimeSession)])) }
    }
}
