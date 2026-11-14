import Foundation
import Observation
import os

/// Where a Dashboard client connects and as whom. The phone's `Settings` is one; the watch
/// builds one from the connection the phone hands over.
@MainActor
protocol ServeEndpoint: AnyObject {
    var serveBaseURL: URL? { get }
    var serveUsername: String { get }
    var profileName: String? { get }
    var accessHeaders: [String: String] { get }
    /// The server was set up as a Dashboard with no sign-in (`HermesServer.serveOpenAccess`).
    var serveOpenAccess: Bool { get }
}

extension ServeEndpoint {
    var serveOpenAccess: Bool { false }
}

/// JSON-RPC 2.0 over WebSocket to `hermes serve` (the desktop gateway). One shared connection.
///
/// Auth (remote bind, basic provider): `POST /auth/password-login` sets session cookies,
/// `POST /api/auth/ws-ticket` mints a 30 s single-use ticket, then `ws://…/api/ws?ticket=`.
/// REST calls ride on the same cookie jar. A Dashboard that signs people in some other way
/// (Google or another OIDC provider) has no password to send: there the person signs in through
/// a browser (`signIn`, `DashboardSignIn`) and every request carries the bearer token instead.
///
/// A Dashboard with no sign-in at all (asked 2026-10-30, after Hermex: bound to 127.0.0.1 with no
/// `dashboard.public_url`, reached through `tailscale serve` or another proxy on that machine)
/// says `auth_required: false` and hands its session token to whoever loads its page at `/`, as
/// the desktop app reads it (`SessionPage`). With no login stored, that is the login: REST calls
/// carry it as `X-Hermes-Session-Token`, the WebSocket as `?token=` (the ticket route refuses this
/// mode). It is held in memory only, never stored: a restart of the host makes a new one, and a
/// 401 or a refused upgrade reads the page again, once.
@Observable
final class HermesServeClient {
    #if !os(watchOS)
    static let shared = HermesServeClient(settings: Settings.shared)
    #endif

    enum State: Equatable { case disconnected, connecting, connected, reconnecting(attempt: Int), failed(String) }
    private(set) var state: State = .disconnected {
        // Connected anew: Hermes may have been started again with Redde's plugin put in or updated.
        didSet { if state == .connected, oldValue != .connected { turnNotesRefusedAt = [:] } }
    }
    /// When this Hermes last didn't take a turn's notes (`TurnNotes`): no plugin, or an older one.
    /// By the session's profile ("" for the selected one): a bot answers with its own copy of
    /// the plugin, which can be older than the main agent's, or missing.
    @ObservationIgnored private var turnNotesRefusedAt: [String: Date] = [:]
    /// Whether a turn's notes in `stored` are worth handing to the plugin: not refused lately.
    func takesTurnNotes(in stored: String? = nil, at now: Date = .now) -> Bool {
        turnNotesRefusedAt[turnNotesKey(stored)].map { now.timeIntervalSince($0) >= TurnNotes.askAgainAfter || now < $0 } ?? true
    }
    func turnNotesRefused(in stored: String? = nil, at now: Date = .now) { turnNotesRefusedAt[turnNotesKey(stored)] = now }
    private func turnNotesKey(_ stored: String?) -> String { stored.flatMap { sessionProfiles[$0] } ?? "" }
    /// True after a successful `ensureConnected()` until `disconnect()`; drives auto-reconnect.
    private var wantsConnection = false
    private var reconnectTask: Task<Void, Never>?

    /// Fan-out of server events: (type, session_id, payload).
    typealias Event = (type: String, sessionID: String?, payload: JSONValue)

    let log = Logger(subsystem: "com.goosehouse.echo", category: "serve")
    /// Rebuilt when the server's own headers change (Cloudflare Access's, a reverse proxy's);
    /// every request and WebSocket handshake inherits them from the configuration.
    var session: URLSession
    private var appliedHeaders: [String: String] = [:]
    let settings: any ServeEndpoint
    let password: () -> String?
    /// The tokens of a browser sign-in, when there is one; they then stand in for the password.
    let tokenStore: DashboardTokenStore
    /// Tests install a stub URLProtocol here; production leaves it empty.
    private let protocolClasses: [AnyClass]

    init(settings: any ServeEndpoint,
         password: @escaping () -> String? = { Keychain.read(.serveDashboardPassword) },
         tokens: DashboardTokenStore = .keychain,
         protocolClasses: [AnyClass] = []) {
        self.settings = settings
        self.password = password
        self.tokenStore = tokens
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
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }

    /// Keeps the login from leaving the server: a redirect to another origin loses the session
    /// token and a bearer token before it is followed (asked 2026-10-30).
    nonisolated final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(HermesServeClient.redirected(request, from: task.originalRequest?.url))
        }
    }

    /// `request` as a redirect from `origin` may follow it: with no login on it when it goes elsewhere.
    nonisolated static func redirected(_ request: URLRequest, from origin: URL?) -> URLRequest {
        guard !SessionPage.sameOrigin(origin, request.url) else { return request }
        var request = request
        request.setValue(nil, forHTTPHeaderField: SessionPage.header)
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        return request
    }

    /// Apply the server's current headers; drops the socket and cookies if they changed.
    func syncAccessHeaders() {
        let wanted = settings.accessHeaders
        guard wanted != appliedHeaders else { return }
        appliedHeaders = wanted
        authenticatedAt = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session.invalidateAndCancel()
        session = Self.makeSession(headers: wanted, protocolClasses: protocolClasses)
        log.info("hermes serve session rebuilt (\(wanted.count) header\(wanted.count == 1 ? "" : "s") of the server's own)")
    }
    /// Frame ceiling for every WebSocket we open. A stored transcript arrives in one frame.
    static let maxFrameBytes = 64 * 1024 * 1024

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var nextID = 1
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    var listeners: [UUID: (Event) -> Void] = [:]
    /// stored session id → runtime session id, valid for this connection.
    var runtimeIDs: [String: String] = [:]
    /// Questions the Dashboard has put to this client and is waiting on: frame id → what was
    /// asked. See `prompt(method:id:params:)`.
    var openRequests: [String: (id: JSONValue, method: String)] = [:]
    /// Reasoning level last pinned on each runtime session over this connection, so a turn
    /// doesn't re-send `config.set` every time (see `openSession`).
    var pinnedEfforts: [String: String] = [:]
    /// The agent's task list as the host had it when a session's history was last fetched, by
    /// stored session id (`todo_state` on a resume): what a replayed transcript is set against.
    @ObservationIgnored var hostTodos: [String: [TodoItem]] = [:]

    var baseURL: URL? { settings.serveBaseURL }

    // MARK: - Connection

    /// The connect attempt in flight, shared by every caller that arrives while it runs.
    private var connectTask: Task<Void, Error>?
    private var connectSerial = 0

    func ensureConnected() async throws {
        if state == .connected, socket != nil { return }
        // A reconnect loop is already working on it: wait for it rather than racing it.
        if case .reconnecting = state, reconnectTask != nil {
            if await waitForConnection(timeout: 30) { return }
            throw TransportError.unreachable(String(localized: "Hermes Dashboard is unreachable"))
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
            let pass = try await socketPass()
            do {
                try await openSocket(baseURL: baseURL, pass: pass)
            } catch let error where !(error is CancellationError) {
                // A Dashboard with no sign-in that refused the page's token: it restarted since and
                // made a new one. The page once more, and once more only.
                guard case let .token(spent) = pass, let fresh = try await rereadPage(baseURL: baseURL, spent: spent) else { throw error }
                try await openSocket(baseURL: baseURL, pass: .token(fresh))
            }
            try Task.checkCancellation()   // disconnect() while the handshake ran: don't keep the link
            // Once per connection: this client answers the Dashboard's own requests (approvals,
            // questions, passwords). Hermes 0.21.5 withholds them from a client that hasn't said
            // so, and withdraws the approval on the spot; an older host doesn't know the method.
            let opened = socket
            _ = try? await call("client.capabilities", params: .object(["server_requests": .bool(true)]), timeout: 15)
            try Task.checkCancellation()
            // The link closed again while it was being set up (a host restarting under it, seen in
            // the no-sign-in lab 2026-10-30): "connected" with no socket left a reconnect waiting
            // on nothing. Failed, the loop tries again.
            guard let opened, socket === opened else {
                throw TransportError.unreachable(String(localized: "the connection to Hermes Dashboard closed"))
            }
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

    /// Before another server becomes active: drop the link and this server's login cookies.
    /// Cookies ignore ports, so two servers on one host would otherwise share a session cookie.
    func resetForServerChange() {
        let host = baseURL?.host()
        // A refresh still in flight belongs to the server being left: its answer must not be
        // filed under the next one.
        refreshTask?.cancel(); refreshTask = nil
        authenticatedAt = nil
        letInWithoutLogin = nil
        pageToken = nil
        ChatControlStore.shared.removeAll()
        disconnect()
        if let host, let cookies = HTTPCookieStorage.shared.cookies {
            for cookie in cookies where cookie.domain == host || cookie.domain == "." + host {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }

    #if DEBUG
    /// Tests: the socket drops now (as when Hermes closes a client that fell behind, or the phone
    /// loses the network) and isn't tried again for `seconds`.
    private var reconnectHeldUntil: Date?
    func dropForTesting(holdingReconnectFor seconds: TimeInterval) {
        reconnectHeldUntil = Date().addingTimeInterval(seconds)
        socket?.cancel(with: .goingAway, reason: nil)
    }
    #endif

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
                #if DEBUG
                if let until = reconnectHeldUntil, until > .now { try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow)) }
                #endif
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
        pinnedEfforts = [:]
        openRequests = [:]   // the host sends the ones still waiting again when a session is resumed
        // The request left the socket; whether the host acted on it is unknown, so this is a
        // lost stream, not a malformed reply (the conversation must not report it as one).
        for (_, cont) in pending { cont.resume(throwing: TransportError.streamLost(String(localized: "the connection to Hermes Dashboard closed"))) }
        pending = [:]
    }

    private func openSocket(baseURL: URL, pass: SocketPass) async throws {
        guard let wsURL = Self.socketURL(baseURL: baseURL, path: "api/ws", pass: pass) else { throw TransportError.badURL }
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
            group.addTask { try await Task.sleep(for: .seconds(10)); throw TransportError.unreachable(String(localized: "Hermes Dashboard didn't answer the WebSocket handshake")) }
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
            var event: Event = (params["type"]?.string ?? "", params["session_id"]?.string, params["payload"] ?? .null)
            // A question the host has stopped waiting on (answered elsewhere, timed out, the turn
            // was stopped): the card goes, as with the older `<kind>.expire` notification.
            if event.type == "request.cancel", let key = Self.key(event.payload["id"]), let open = openRequests.removeValue(forKey: key) {
                event = ("\(open.method).expire", event.sessionID, .object(["request_id": .string(key)]))
            }
            // A session saying how it runs now (auto-approve, fast mode): the chat's header shows it.
            if event.type == "session.info", let stored = event.payload["stored_session_id"]?.string, !stored.isEmpty {
                ChatControlStore.shared.note(event.payload, for: stored)
            }
            for l in listeners.values { l(event) }
            return
        }
        guard let id = json["id"], let method = json["method"]?.string else { return }
        if let key = Self.key(id), let event = Self.prompt(method: method, id: key, params: json["params"] ?? .null) {
            openRequests[key] = (id, method)
            for l in listeners.values { l(event) }
        } else {
            // Host request we can't serve (terminal, file dialogs): decline politely.
            send(.object(["jsonrpc": .string("2.0"), "id": id,
                          "error": .object(["code": .number(-32601), "message": .string("Method not supported on Redde")])]))
        }
    }

    // MARK: - RPC

    nonisolated struct RPCError: LocalizedError, Sendable {
        var code: Int
        var message: String
        var errorDescription: String? { "\(message) (\(code))" }
    }

    static let encoder = JSONEncoder()

    /// Cancelling the calling task fails the call with `CancellationError` at once; a turn that
    /// was stopped must not sit out the reply (or the timeout) of a request it no longer wants.
    /// Methods that aren't tied to a live session and take a `profile` param (their contracts
    /// extend SessionParams or ProfileParams). Session-bound calls such as `prompt.submit` run in
    /// the session's own profile. Params reject unknown keys, so no other method gets one.
    private static let profileScopedMethods: Set<String> = [
        "session.create", "session.resume", "session.delete", "session.branch",
        "projects.tree", "projects.project_sessions", "projects.create", "projects.update", "projects.delete",
        "model.options", "config.set",
        "slash.exec", "command.dispatch", "session.workspace.move", "plugins.manage",
    ]

    /// The profile Redde is on (nil: the main one), for a REST body that names it itself.
    var selectedProfile: String? { settings.profileName }

    /// Adds the selected profile to a profile-scoped call; the default profile sends nothing. A
    /// call about a bot's chat names the bot's profile instead (`sessionProfiles`).
    func withProfile(_ params: JSONValue, for method: String) -> JSONValue {
        guard Self.profileScopedMethods.contains(method), case .object(var fields) = params, fields["profile"] == nil,
              let profile = sessionProfile(in: fields) ?? settings.profileName else { return params }
        fields["profile"] = .string(profile)
        return .object(fields)
    }

    /// Bots' chats this app has opened, by stored session id: the profile each belongs to. A bot's
    /// chat is a session of the bot's own profile, whichever profile Redde is set to, and Hermes
    /// only finds it when told which (`session.resume` without it finds none).
    var sessionProfiles: [String: String] = [:]

    /// Has every later call about `stored` name `profile`.
    func noteProfile(_ profile: String, forStored stored: String) { sessionProfiles[stored] = profile }

    /// The profile of the session a call is about, when it is a bot's chat, by its stored id or
    /// the runtime id it has on this connection.
    private func sessionProfile(in fields: [String: JSONValue]) -> String? {
        guard !sessionProfiles.isEmpty, let id = (fields["session_id"] ?? fields["session_key"])?.string else { return nil }
        if let profile = sessionProfiles[id] { return profile }
        return runtimeIDs.first { $0.value == id }.flatMap { sessionProfiles[$0.key] }
    }

    /// A session this client made outside `openSession` (a bot's chat): later turns use its runtime id.
    func adopt(runtime: String, stored: String) { runtimeIDs[stored] = runtime }

    @discardableResult
    func call(_ method: String, params: JSONValue, timeout: TimeInterval = 60) async throws -> JSONValue {
        try Task.checkCancellation()
        // No socket means the request never left the phone: safe for the caller to send again.
        guard socket != nil else { throw TransportError.unreachable(String(localized: "not connected to Hermes Dashboard")) }
        let id = "echo-\(nextID)"
        nextID += 1
        let frame = JSONValue.object(["jsonrpc": .string("2.0"), "id": .string(id),
                                      "method": .string(method), "params": withProfile(params, for: method)])
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
    func send(_ frame: JSONValue, forCall id: String? = nil) {
        guard let socket, let data = try? Self.encoder.encode(frame) else {
            if let id, let cont = pending.removeValue(forKey: id) {
                cont.resume(throwing: TransportError.unreachable(String(localized: "not connected to Hermes Dashboard")))
            }
            return
        }
        socket.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self else { return }
                self.log.error("send failed: \(error.localizedDescription)")
                // A socket that has gone ("Socket is not connected") answers nothing more: closed
                // here, so the next call dials again and doesn't wait for URLSession to notice. And
                // said as what it is, not as iOS words it ("The operation couldn't be completed",
                // GitHub issue 71).
                let gone = NetworkFailure.isConnectivity(error)
                if let id, let cont = self.pending.removeValue(forKey: id) {
                    cont.resume(throwing: gone ? TransportError.unreachable(String(localized: "the connection to Hermes Dashboard dropped")) : error)
                }
                if gone { self.socketClosed(socket, error: error) }
            }
        }
    }

    func addListener(_ listener: @escaping (Event) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    func removeListener(_ id: UUID) { listeners[id] = nil }

    /// An event is about this stored session: by that id, or by the one it runs under here.
    func isSession(_ sessionID: String?, stored: String) -> Bool {
        guard let sessionID else { return false }
        return sessionID == stored || runtimeIDs[stored] == sessionID
    }

    // Stored here for HermesServeClient+SignIn.swift: an extension can't hold stored properties.

    /// When the cookie was last proven good. Within the TTL, REST calls skip the login probe
    /// entirely (one round trip instead of two); a 401 clears it and the call retries once.
    var authenticatedAt: Date?
    let authTTL: TimeInterval = 10 * 60
    /// The Dashboard that let this phone in at the last look with no stored login: one with no
    /// password on it, or a login's cookie still good after the login itself was gone. Chats
    /// worked through it while Settings → Agent, files and the rest said there was no login
    /// (his report, 2026-10-22).
    var letInWithoutLogin: URL?

    /// The session token of the Dashboard at `url`, read off its page: the login of a Dashboard
    /// with no sign-in. Memory only (asked 2026-10-30): a restart of the host makes a new one.
    var pageToken: (url: URL, token: String)?
    /// The page being read, once however many requests want it.
    var pageTask: Task<String, Error>?

    var refreshTask: Task<Void, Error>?
}
