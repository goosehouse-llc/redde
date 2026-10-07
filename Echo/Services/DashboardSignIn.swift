import CryptoKit
import Foundation
import Network
import os

/// What a browser sign-in to the Hermes Dashboard leaves the app holding: a short-lived access
/// token sent as `Authorization: Bearer` with every request, and a refresh token that buys the
/// next pair. A Dashboard that signs people in with Google or another identity provider has no
/// password to give the app, so this is the only login it takes. The pair is kept in the
/// Keychain, per server.
nonisolated struct DashboardTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    /// When the access token stops working, in Unix seconds; nil when the server didn't say.
    var expiresAt: Double?
    /// The Dashboard's name for who issued them ("basic", "self_hosted", "nous"); sent back on refresh.
    var provider = ""
    var userID = ""
    /// The Dashboard they were issued by (`DashboardSignIn.origin`), noted when they are stored.
    /// They are sent nowhere else: if the address in Settings is changed, the sign-in waits,
    /// unused, for the address to come back.
    var origin: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresAt = "expires_at"
        case provider, userID = "user_id", origin
    }

    init(accessToken: String, refreshToken: String, expiresAt: Double? = nil, provider: String = "", userID: String = "", origin: String? = nil) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.provider = provider; self.userID = userID; self.origin = origin
    }

    /// Only the two tokens have to be there: a provider is free to leave the rest out.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken) ?? ""
        expiresAt = try? c.decodeIfPresent(Double.self, forKey: .expiresAt)
        provider = (try? c.decodeIfPresent(String.self, forKey: .provider)) ?? ""
        userID = (try? c.decodeIfPresent(String.self, forKey: .userID)) ?? ""
        origin = try? c.decodeIfPresent(String.self, forKey: .origin)
    }

    /// True when the access token has less than `margin` left: time to trade it in before a request.
    func expires(within margin: TimeInterval, of now: Date = .now) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt - now.timeIntervalSince1970 < margin
    }
}

/// Where the tokens are kept: the Keychain for the app, memory for the tests.
nonisolated struct DashboardTokenStore: Sendable {
    var read: @Sendable () -> DashboardTokens?
    /// Nil forgets them: signed out, or the server no longer takes the refresh token.
    var write: @Sendable (DashboardTokens?) -> Void

    static let keychain = DashboardTokenStore(
        read: { Keychain.read(.serveSignIn).flatMap { try? JSONDecoder().decode(DashboardTokens.self, from: Data($0.utf8)) } },
        write: { tokens in
            guard let tokens, let data = try? JSONEncoder().encode(tokens) else { Keychain.delete(.serveSignIn); return }
            Keychain.write(.serveSignIn, value: String(decoding: data, as: UTF8.self))
        })
}

/// Signing in to a Hermes Dashboard through a browser: OAuth for native apps (RFC 8252) with PKCE,
/// which the Dashboard has offered since Hermes 0.21 and says so in `/api/status`
/// (`auth_flows: native_pkce`). The browser is sent to the Dashboard's `/auth/native/authorize`,
/// which hands it on to whatever the Dashboard signs people in with (a Google or other OIDC
/// login, Nous Portal, or its own username-and-password page). When that ends, the Dashboard
/// sends the browser to a loopback address on this phone with a one-time code, and the code plus
/// the PKCE verifier, which never left the app, buy the tokens. The app never sees the password
/// or talks to the identity provider.
nonisolated enum DashboardSignIn {
    /// Where the loopback page sends the browser last, so a sign-in sheet knows to close.
    static let doneScheme = "redde-signin"
    static var doneURL: URL { URL(string: "\(doneScheme)://done")! }

    enum Failure: LocalizedError, Equatable {
        /// The Dashboard doesn't offer browser sign-in: older than Hermes 0.21, or no login at all.
        case notOffered(String)
        /// The browser closed, or came back, without the code.
        case noCode
        /// The refresh token is spent: only signing in again helps.
        case expired
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .notOffered(let why): why
            case .noCode: "The browser came back without signing in. Try again."
            case .expired: "Your sign-in to the Hermes Dashboard has expired. Sign in again under Settings → Connection."
            case .refused(let detail): "The Hermes Dashboard refused the sign-in: \(detail)"
            }
        }
    }

    /// Scheme, host and port: what a sign-in belongs to.
    static func origin(of url: URL) -> String {
        let scheme = (url.scheme ?? "http").lowercased()
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\((url.host() ?? "").lowercased()):\(port)"
    }

    /// The stored sign-in, if it is this Dashboard's. One made at another address isn't offered.
    static func tokens(for baseURL: URL?, in store: DashboardTokenStore) -> DashboardTokens? {
        guard let baseURL, let tokens = store.read() else { return nil }
        if let issuedBy = tokens.origin, issuedBy != origin(of: baseURL) { return nil }
        return tokens
    }

    // MARK: PKCE (RFC 7636)

    /// 32 random bytes as base64url: the secret half, kept in the app.
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    /// The S256 challenge the browser carries: base64url(SHA-256(verifier)).
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: Requests

    /// The address the browser opens to start signing in.
    static func authorizeURL(baseURL: URL, challenge: String, redirectURI: String, state: String) -> URL? {
        var comps = URLComponents(url: baseURL.appending(path: "auth/native/authorize"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "redirect_uri", value: redirectURI), .init(name: "state", value: state),
        ]
        return comps?.url
    }

    /// What `/api/status` says about signing in. Public: asked before any login.
    struct Offer: Equatable, Sendable {
        var version = ""
        var loginRequired = false
        var browserSignIn = false
    }

    static func offer(baseURL: URL, session: URLSession) async throws -> Offer {
        var request = URLRequest(url: baseURL.appending(path: "api/status"))
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TransportError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: "status")
        }
        let json = try JSONValue.parse(data)
        return Offer(version: json["version"]?.string ?? "", loginRequired: json["auth_required"]?.bool == true,
                     browserSignIn: (json["auth_flows"]?.array ?? []).contains { $0.string == "native_pkce" })
    }

    /// The one-time code and the verifier, for the tokens.
    static func exchange(code: String, verifier: String, baseURL: URL, session: URLSession) async throws -> DashboardTokens {
        struct Body: Encodable { var code: String; var code_verifier: String }
        let (data, status) = try await post("auth/native/token", Body(code: code, code_verifier: verifier), baseURL: baseURL, session: session)
        guard status == 200 else { throw Failure.refused(detail(data) ?? "HTTP \(status)") }
        return try JSONDecoder().decode(DashboardTokens.self, from: data)
    }

    /// The refresh token, for the next pair. It is spent by this: the answer's is the one to keep.
    static func refresh(_ tokens: DashboardTokens, baseURL: URL, session: URLSession) async throws -> DashboardTokens {
        struct Body: Encodable { var refresh_token: String; var provider: String }
        let (data, status) = try await post("auth/native/refresh", Body(refresh_token: tokens.refreshToken, provider: tokens.provider),
                                            baseURL: baseURL, session: session)
        switch status {
        case 200:
            var fresh = try JSONDecoder().decode(DashboardTokens.self, from: data)
            // A provider that doesn't rotate may leave these out; what the app holds still stands.
            if fresh.refreshToken.isEmpty { fresh.refreshToken = tokens.refreshToken }
            if fresh.provider.isEmpty { fresh.provider = tokens.provider }
            if fresh.userID.isEmpty { fresh.userID = tokens.userID }
            fresh.origin = tokens.origin
            return fresh
        case 400, 401: throw Failure.expired
        // 503: the identity provider couldn't be reached. The tokens may still be good.
        default: throw TransportError.http(status: status, body: detail(data) ?? "refresh")
        }
    }

    private static func post(_ path: String, _ body: some Encodable, baseURL: URL, session: URLSession) async throws -> (Data, Int) {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func detail(_ data: Data) -> String? {
        (try? JSONValue.parse(data))?["detail"]?.string
    }
}

/// Where the browser is sent when sign-in ends: a listener on this phone's own loopback
/// interface, as RFC 8252 has native apps do. Hermes takes no other kind of address
/// (`http://127.0.0.1:<port>/…` only), so a custom URL scheme can't stand in. It answers one
/// request, the one carrying this sign-in's `state`, and hands over its `code`. Nothing off the
/// phone can reach it.
nonisolated final class LoopbackCallback: Sendable {
    static let path = "/callback"
    let port: UInt16
    var redirectURI: String { "http://127.0.0.1:\(port)\(Self.path)" }

    private let listener: NWListener
    private let codes: AsyncThrowingStream<String, Error>
    private static let queue = DispatchQueue(label: "com.goosehouse.echo.signin-callback")

    private init(listener: NWListener, port: UInt16, codes: AsyncThrowingStream<String, Error>) {
        self.listener = listener; self.port = port; self.codes = codes
    }

    /// Opens the listener on a port the system picks. `state` is what the request must carry;
    /// `done` is where the browser is sent once it has delivered the code.
    static func start(state: String, done: URL) async throws -> LoopbackCallback {
        let parameters = NWParameters.tcp
        // Bound to 127.0.0.1 and nothing else: that is what keeps other devices out.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let (codes, feed) = AsyncThrowingStream.makeStream(of: String.self)
        listener.newConnectionHandler = { serve($0, state: state, done: done, feed: feed) }
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let port: UInt16 = try await withCheckedThrowingContinuation { ready in
            // The handler runs again when the listener is cancelled; the continuation resumes once.
            @Sendable func resume(_ result: Result<UInt16, Error>) {
                let first = resumed.withLock { done in defer { done = true }; return !done }
                if first { ready.resume(with: result) }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { resume(.success(port)) } else { resume(.failure(DashboardSignIn.Failure.noCode)) }
                case .failed(let error):
                    resume(.failure(error))
                    feed.finish(throwing: error)
                case .cancelled:
                    resume(.failure(CancellationError()))
                    feed.finish()
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return LoopbackCallback(listener: listener, port: port, codes: codes)
    }

    /// The code, once the browser brings it. Throws if the listener stops first.
    func code() async throws -> String {
        try await withTaskCancellationHandler {
            for try await code in codes { return code }
            throw Task.isCancelled ? CancellationError() : DashboardSignIn.Failure.noCode
        } onCancel: {
            listener.cancel()
        }
    }

    func stop() { listener.cancel() }

    private static func serve(_ connection: NWConnection, state: String, done: URL, feed: AsyncThrowingStream<String, Error>.Continuation) {
        connection.start(queue: queue)
        // A GET's request line is in the first segment; the rest of the request isn't needed.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let answer = answer(to: request, state: state, done: done)
            connection.send(content: Data(answer.response.utf8), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in
                if let code = answer.code { feed.yield(code) }
                // Hang up after the browser does, or after a moment, so the answer isn't cut short.
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, _, _ in connection.cancel() }
                queue.asyncAfter(deadline: .now() + 2) { connection.cancel() }
            })
        }
    }

    /// What to say to one request, and the code it carried if it is the sign-in's own.
    static func answer(to request: String, state: String, done: URL) -> (code: String?, response: String) {
        func reply(_ status: String, _ body: String, location: URL? = nil) -> String {
            let page = "<!doctype html><meta name=viewport content=\"width=device-width\"><body style=\"font:-apple-system-body;margin:2em\">\(body)"
            return "HTTP/1.1 \(status)\r\n" + (location.map { "Location: \($0.absoluteString)\r\n" } ?? "")
                + "Content-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" + page
        }
        let line = request.prefix { $0 != "\r" && $0 != "\n" }.split(separator: " ")
        guard line.count >= 2, line[0] == "GET", let target = URLComponents(string: "http://127.0.0.1" + line[1]),
              target.path == path else {
            return (nil, reply("404 Not Found", "Nothing here."))
        }
        let query = Dictionary((target.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }
        guard query["state"] == state, let code = query["code"], !code.isEmpty else {
            return (nil, reply("400 Bad Request", "This isn't the sign-in Redde started. Go back to Redde and try again."))
        }
        return (code, reply("302 Found", "Signed in. You can go back to Redde.", location: done))
    }
}
