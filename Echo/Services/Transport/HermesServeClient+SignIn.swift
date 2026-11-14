import Foundation
import os

// HermesServeClient's logins: password, no sign-in (the page's token), browser sign-in, and the sockets they open.
extension HermesServeClient {
    func login(baseURL: URL) async throws {
        syncAccessHeaders()
        if let tokens = signInTokens() {
            // A browser sign-in: the token is the login. Trade it in when it is about to lapse.
            if tokens.expires(within: 60) { try await refreshTokens(baseURL: baseURL, spent: tokens.accessToken) }
            return
        }
        // No login stored: a Dashboard with no sign-in, whose page holds the token.
        guard hasStoredLogin else { return try await openLogin(baseURL: baseURL) }
        if let at = authenticatedAt, Date.now.timeIntervalSince(at) < authTTL { return }
        // Cookie may still be live from an earlier session: cheap probe before a real login.
        guard var comps = URLComponents(url: baseURL.appending(path: "api/sessions"), resolvingAgainstBaseURL: false) else { throw TransportError.badURL }
        comps.queryItems = [.init(name: "limit", value: "1")]
        if let probeURL = comps.url, let (_, r) = try? await session.data(for: URLRequest(url: probeURL)),
           (r as? HTTPURLResponse)?.statusCode == 200 {
            authenticatedAt = .now
            return
        }
        letInWithoutLogin = nil

        let username = settings.serveUsername
        guard !username.isEmpty, let password = password(), !password.isEmpty else {
            throw TransportError.malformed(TransportError.missingLoginText)
        }
        struct Body: Encodable { var provider = "basic"; var username: String; var password: String }
        var request = URLRequest(url: baseURL.appending(path: "auth/password-login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(username: username, password: password))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // A Dashboard that took its login away has nothing to log in to (it answers "Unknown
            // provider", not a refusal): said as that, so the person can choose to go on without
            // one (asked 2026-10-30).
            if status != 401, (try? await asksForLogin(baseURL: baseURL)) == false { throw DashboardSignInChange.noLongerAsks }
            throw TransportError.http(status: status, body: status == 401 ? String(localized: "login rejected", comment: "Follows \"Server returned HTTP 401.\"") : String(decoding: data.prefix(200), as: UTF8.self))
        }
        authenticatedAt = .now
        log.info("hermes serve login ok")
    }

    // MARK: - No sign-in

    /// The Dashboard with no login stored for it. A cookie from a login since forgotten still
    /// lets this phone in as before; otherwise it is one with no sign-in at all, whose status
    /// says so (`auth_required: false`) and whose page holds the token.
    private func openLogin(baseURL: URL) async throws {
        // The page's token stands until the host refuses it (`send`, `connectOnce`).
        if pageToken?.url == baseURL { return }
        if letInWithoutLogin == baseURL, let at = authenticatedAt, Date.now.timeIntervalSince(at) < authTTL { return }
        if let probe = URL(string: "api/sessions?limit=1", relativeTo: baseURL.appending(path: "/")),
           let (_, answer) = try? await session.data(for: URLRequest(url: probe)), (answer as? HTTPURLResponse)?.statusCode == 200 {
            authenticatedAt = .now
            letInWithoutLogin = baseURL
            return
        }
        _ = try await readPage(baseURL: baseURL)
    }

    /// Reads the page and proves its token, sharing a read already under way.
    private func readPage(baseURL: URL) async throws -> String {
        if let pageTask { return try await pageTask.value }
        let task = Task { [self] in
            defer { pageTask = nil }
            let token = try await fetchPageToken(baseURL: baseURL)
            try Task.checkCancellation()   // the server changed meanwhile (resetForServerChange)
            pageToken = (baseURL, token)
            authenticatedAt = .now
            letInWithoutLogin = baseURL
            return token
        }
        pageTask = task
        return try await task.value
    }

    /// After the host refused `spent`: its page once more, for the token it has now. Nil when it
    /// still has the same one (the refusal was about something else).
    func rereadPage(baseURL: URL, spent: String) async throws -> String? {
        if let current = pageToken, current.url == baseURL, current.token != spent { return current.token }   // read again meanwhile
        pageToken = nil
        authenticatedAt = nil
        letInWithoutLogin = nil
        let fresh = try await readPage(baseURL: baseURL)
        return fresh == spent ? nil : fresh
    }

    private func fetchPageToken(baseURL: URL) async throws -> String {
        // The status first: it is public on every release, and only a Dashboard that says it has
        // no sign-in puts the token in its page.
        if try await asksForLogin(baseURL: baseURL) {
            throw settings.serveOpenAccess ? DashboardSignInChange.nowAsksForLogin : TransportError.malformed(TransportError.missingLoginText)
        }
        var request = URLRequest(url: baseURL.appending(path: "/"))
        request.timeoutInterval = 15
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let refusal = SessionPage.hostRefusal(status: status, body: data) { throw refusal }
        guard let token = SessionPage.token(in: data) else {
            throw TransportError.malformed(String(localized: "Hermes Dashboard says it has no sign-in, but its page at \(baseURL.host() ?? baseURL.absoluteString) has no session token. Something in front of it may be answering instead.",
                                                  comment: "The Dashboard's page, read for its session token, had none; the host name"))
        }
        // Proven by a read the token alone opens: the conversation list, there on every release.
        // (`api/auth/me` answers it too from 0.22, as "Local", but not on 0.21.)
        guard let url = URL(string: "api/sessions?limit=1", relativeTo: baseURL.appending(path: "/")) else { throw TransportError.badURL }
        var probe = URLRequest(url: url)
        probe.timeoutInterval = 15
        let (said, answer) = try await session.data(for: SessionPage.apply(token, to: probe))
        let proved = (answer as? HTTPURLResponse)?.statusCode ?? 0
        if let refusal = SessionPage.hostRefusal(status: proved, body: said) { throw refusal }
        guard (200 ..< 300).contains(proved) else { throw Self.refusal(proved, said) }
        log.info("hermes serve: no sign-in, the session token read from its page")
        return token
    }

    /// Whether the Dashboard says it asks for a login (`GET api/status`, public on every release).
    private func asksForLogin(baseURL: URL) async throws -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "api/status"))
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let refusal = SessionPage.hostRefusal(status: status, body: data) { throw refusal }
        guard status == 200 else { throw Self.refusal(status, data) }
        return try JSONValue.parse(data)["auth_required"]?.bool == true
    }

    /// True while this client goes in on a Dashboard's page token: one with no sign-in.
    var usesPageToken: Bool { pageToken != nil && pageToken?.url == baseURL && signInTokens() == nil }

    /// Proves the cookie (logging in if needed) and mints a single-use WebSocket ticket.
    func authenticate() async throws -> String {
        guard let baseURL else { throw TransportError.badURL }
        try await login(baseURL: baseURL)
        return try await mintTicket(baseURL: baseURL)
    }

    /// What opens a WebSocket: a single-use ticket bought with the login, or, on a Dashboard with
    /// no sign-in, its session token itself (it sells no tickets there).
    nonisolated enum SocketPass: Equatable, Sendable {
        case ticket(String)
        case token(String)

        /// The query item an upgrade presents it as, with no subprotocol.
        var queryItem: URLQueryItem {
            switch self {
            case let .ticket(ticket): URLQueryItem(name: "ticket", value: ticket)
            case let .token(token): URLQueryItem(name: "token", value: token)
            }
        }
    }

    /// Logs in if needed, then what the next WebSocket opens with.
    func socketPass() async throws -> SocketPass {
        guard let baseURL else { throw TransportError.badURL }
        try await login(baseURL: baseURL)
        if usesPageToken, let token = pageToken?.token { return .token(token) }
        return .ticket(try await mintTicket(baseURL: baseURL))
    }

    /// A WebSocket address on the Dashboard: `path` with `query`, then the pass.
    nonisolated static func socketURL(baseURL: URL, path: String, query: [URLQueryItem] = [], pass: SocketPass) -> URL? {
        guard var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        comps.queryItems = query + [pass.queryItem]
        return comps.url
    }

    private func mintTicket(baseURL: URL) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "api/auth/ws-ticket"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await send(request, baseURL: baseURL)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw TransportError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: "ws-ticket")
        }
        guard let ticket = try JSONValue.parse(data)["ticket"]?.string else {
            throw TransportError.malformed("no ws ticket")
        }
        return ticket
    }

    /// What proves the login on a request, besides the cookie jar.
    private enum Proof: Equatable {
        /// A browser sign-in's access token.
        case bearer(String)
        /// A Dashboard with no sign-in: the token off its page.
        case page(String)
    }

    private var proof: Proof? {
        if let token = signInTokens()?.accessToken { return .bearer(token) }
        if usesPageToken, let token = pageToken?.token { return .page(token) }
        return nil
    }

    /// One round trip with whatever proves the login: the cookie jar, a browser sign-in's bearer
    /// token, or the session token off a Dashboard's page. A 401 gets one fresh proof and one more
    /// try: the cookie the TTL vouched for is dead (gateway restart, password change), the access
    /// token lapsed early, or the host restarted and made itself a new session token.
    func send(_ request: URLRequest, baseURL: URL) async throws -> (Data, URLResponse) {
        try await send(request, baseURL: baseURL) { try await self.session.data(for: $0) }
    }

    /// The same, for a round trip that isn't data in and data out: a body sent from a file, or
    /// an answer saved to one (`perform`).
    func send<Answer>(_ request: URLRequest, baseURL: URL,
                              perform: (URLRequest) async throws -> (Answer, URLResponse)) async throws -> (Answer, URLResponse) {
        func authorized(_ proof: Proof?) -> URLRequest {
            switch proof {
            case let .bearer(token)?:
                var request = request
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return request
            case let .page(token)?: return SessionPage.apply(token, to: request)
            case nil: return request
            }
        }
        let used = proof
        let first = try await perform(authorized(used))
        guard (first.1 as? HTTPURLResponse)?.statusCode == 401 else { return first }
        switch used {
        case let .bearer(token)?:
            try await refreshTokens(baseURL: baseURL, spent: token)
        case let .page(token)?:
            guard try await rereadPage(baseURL: baseURL, spent: token) != nil else { return first }
        case nil where authenticatedAt != nil:
            authenticatedAt = nil
            letInWithoutLogin = nil
            try await login(baseURL: baseURL)
        case nil:
            return first
        }
        return try await perform(authorized(proof))
    }

    // MARK: - Browser sign-in

    /// The browser sign-in for the Dashboard at the address in Settings. A token goes only to
    /// the server that issued it: one made at another address stays stored and unsent.
    private func signInTokens() -> DashboardTokens? {
        DashboardSignIn.tokens(for: baseURL, in: tokenStore)
    }

    /// Trades the refresh token for a new pair, once however many requests ask: a refresh token
    /// is good for one use, and an identity provider that sees it twice ends the session.
    /// `spent` is the access token the caller found wanting; when the stored one is already
    /// another, someone refreshed meanwhile and there is nothing left to do. A refresh token the
    /// server no longer takes signs the phone out: only the person can sign in again.
    private func refreshTokens(baseURL: URL, spent: String) async throws {
        if let refreshTask { return try await refreshTask.value }
        guard let current = signInTokens() else { throw DashboardSignIn.Failure.expired }
        guard current.accessToken == spent else { return }
        let task = Task { [self] in
            defer { refreshTask = nil }
            do {
                let fresh = try await DashboardSignIn.refresh(current, baseURL: baseURL, session: session)
                try Task.checkCancellation()   // the server changed meanwhile (resetForServerChange)
                tokenStore.write(fresh)
            } catch DashboardSignIn.Failure.expired {
                tokenStore.write(nil)
                log.info("hermes serve sign-in expired")
                throw DashboardSignIn.Failure.expired
            }
        }
        refreshTask = task
        try await task.value
    }

    /// True when this server is signed in to through a browser, not with a password.
    var isSignedIn: Bool { signInTokens() != nil }

    /// Signs in through a browser (see `DashboardSignIn`). `browser` shows the address and
    /// returns when the browser is done with it; it throws when the person closes it instead.
    /// The code comes back to a listener on this phone, never through `browser`.
    func signIn(browser: @escaping @MainActor @Sendable (URL) async throws -> Void) async throws {
        guard let baseURL else { throw TransportError.badURL }
        syncAccessHeaders()
        let offer = try await DashboardSignIn.offer(baseURL: baseURL, session: session)
        guard offer.loginRequired else {
            throw DashboardSignIn.Failure.notOffered(String(localized: "This Hermes Dashboard doesn't ask for a login."))
        }
        guard offer.browserSignIn else {
            throw DashboardSignIn.Failure.notOffered(String(localized: "This Hermes Dashboard doesn't offer browser sign-in. It needs Hermes 0.21 or later."))
        }
        let verifier = DashboardSignIn.verifier(), state = DashboardSignIn.verifier()
        let callback = try await LoopbackCallback.start(state: state, done: DashboardSignIn.doneURL)
        defer { callback.stop() }
        guard let url = DashboardSignIn.authorizeURL(baseURL: baseURL, challenge: DashboardSignIn.challenge(for: verifier),
                                                     redirectURI: callback.redirectURI, state: state) else { throw TransportError.badURL }
        let code = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await callback.code() }
            group.addTask {
                try await browser(url)
                // The browser is done. The code is usually here by now; a slow last hop gets a moment.
                try await Task.sleep(for: .seconds(3))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let code = first else { throw DashboardSignIn.Failure.noCode }
            return code
        }
        var tokens = try await DashboardSignIn.exchange(code: code, verifier: verifier, baseURL: baseURL, session: session)
        tokens.origin = DashboardSignIn.origin(of: baseURL)
        // The sign-in replaces whatever login the link was made with.
        disconnect()
        tokenStore.write(tokens)
        log.info("hermes serve signed in through the browser (provider \(tokens.provider, privacy: .public))")
    }

    /// Forgets the browser sign-in on this phone. A saved password, if there is one, is the login again.
    func signOut() {
        refreshTask?.cancel(); refreshTask = nil
        tokenStore.write(nil)
        disconnect()
    }

    /// Who the Dashboard says is signed in (`GET api/auth/me`), for Settings.
    func signedInName() async throws -> String {
        let me = try JSONValue.parse(try await rest("GET", "api/auth/me", body: nil as Data?))
        return me["display_name"]?.string?.nilIfEmpty ?? me["email"]?.string?.nilIfEmpty ?? me["user_id"]?.string ?? ""
    }

    /// Opens a WebSocket to a dashboard plugin path (e.g. `api/plugins/kanban/events`) after
    /// logging in and minting a ticket (or, on a Dashboard with no sign-in, with the page's
    /// token). The caller owns the task.
    func openPluginSocket(path: String, query: [URLQueryItem]) async throws -> URLSessionWebSocketTask {
        guard let baseURL else { throw TransportError.badURL }
        let pass = try await socketPass()
        guard let url = Self.socketURL(baseURL: baseURL, path: path, query: query, pass: pass) else { throw TransportError.badURL }
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = Self.maxFrameBytes
        task.resume()
        return task
    }

    /// Bot Screen's picture stream (`/api/display/ws`, Hermes 0.21.5+): raw RFB as binary frames,
    /// opened with the single-use ticket `display.observe` minted on this connection's `/api/ws`.
    /// The ticket alone lets it in, so no login pass rides along; the session's own headers (a
    /// Pangolin token) do, which a web view's socket couldn't send. The caller owns the task.
    func openDisplaySocket(path: String, ticket: String) throws -> URLSessionWebSocketTask {
        guard let baseURL, let url = BotScreen.socketURL(baseURL: baseURL, path: path, ticket: ticket) else { throw TransportError.badURL }
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = Self.maxFrameBytes
        task.resume()
        return task
    }

    /// The Dashboard's speech socket (`HermesSpeech`), speaking with the selected profile's voice.
    func openSpeechSocket() async throws -> URLSessionWebSocketTask {
        try await openPluginSocket(path: "api/audio/speak-stream",
                                   query: settings.profileName.map { [URLQueryItem(name: "profile", value: $0)] } ?? [])
    }

    /// Logs in (cookies, or a fresh enough token) without opening the WebSocket; enough for REST.
    func ensureLoggedIn() async throws {
        guard let baseURL else { throw TransportError.badURL }
        try await login(baseURL: baseURL)
    }

    /// True when the Dashboard can be used: a browser sign-in, a username and stored password, a
    /// server set up as one with no sign-in, or it let this phone in without either at the last
    /// look (`letInWithoutLogin`).
    var hasCredentials: Bool {
        hasStoredLogin || settings.serveOpenAccess || (letInWithoutLogin != nil && letInWithoutLogin == baseURL)
    }

    /// A browser sign-in, or a username and stored password.
    private var hasStoredLogin: Bool {
        isSignedIn || (!settings.serveUsername.isEmpty && password() != nil)
    }

    /// Whether the Dashboard can be used, finding out now if nothing has asked it yet: with no
    /// stored login it may still let this phone in.
    func canUse() async -> Bool {
        if hasCredentials { return true }
        guard let baseURL else { return false }
        try? await login(baseURL: baseURL)
        return hasCredentials
    }
}
