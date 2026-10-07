import Foundation
import Testing
@testable import Echo

/// Answers the serve client's REST calls in-process. WebSockets don't pass through URLProtocol,
/// so these cover login, ticket minting and the 401 retry, not the socket itself.
nonisolated final class ServeStub: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data?) -> (Int, Data))?
    nonisolated(unsafe) static var log: [String] = []

    static func reset() { handler = nil; log = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        }
        Self.log.append("\(request.httpMethod ?? "GET") \(request.url?.path() ?? "")")
        let (status, payload) = Self.handler?(request, body) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct HermesServeClientTests {
    private func makeClient(profile: String = "") -> HermesServeClient {
        let settings = Settings(defaults: UserDefaults(suiteName: "serve-test-\(UUID().uuidString)")!)
        settings.serveURL = "http://serve.test:9119"
        settings.serveUsername = "redde"
        settings.hermesProfile = profile
        return HermesServeClient(settings: settings, password: { "hunter2" }, tokens: TokenBox().store, protocolClasses: [ServeStub.self])
    }

    @Test func sessionListAsksForTheProfile() async throws {
        ServeStub.reset()
        nonisolated(unsafe) var urls: [String] = []
        ServeStub.handler = { request, _ in
            urls.append(request.url?.absoluteString ?? "")
            return (200, Data(#"{"sessions":[]}"#.utf8))
        }
        defer { ServeStub.reset() }
        let client = makeClient(profile: "work")
        _ = try await client.listSessions(limit: 10)
        #expect(urls.contains { $0.contains("/api/sessions?") && $0.contains("profile=work") })
    }

    /// Stateful stub: the session probe fails until a login has happened, like a cookie jar.
    private func installGateway(rejectLogin: Bool = false, jobsFirstStatus: Int = 200) {
        ServeStub.reset()
        nonisolated(unsafe) var loggedIn = false
        nonisolated(unsafe) var jobsCalls = 0
        ServeStub.handler = { request, body in
            switch (request.httpMethod, request.url?.path()) {
            case ("GET", "/api/sessions"):
                return loggedIn ? (200, Data("[]".utf8)) : (401, Data())
            case ("POST", "/auth/password-login"):
                let fields = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any]
                guard !rejectLogin, fields?["username"] as? String == "redde", fields?["password"] as? String == "hunter2",
                      fields?["provider"] as? String == "basic" else { return (401, Data()) }
                loggedIn = true
                return (200, Data("{}".utf8))
            case ("POST", "/api/auth/ws-ticket"):
                return loggedIn ? (200, Data(#"{"ticket":"t-1"}"#.utf8)) : (401, Data())
            case ("GET", "/api/cron/jobs"):
                jobsCalls += 1
                return jobsCalls == 1 ? (jobsFirstStatus, Data()) : (200, Data(#"{"ok":true}"#.utf8))
            default:
                return (404, Data())
            }
        }
    }

    @Test func logsInOnceThenReusesTheCookieWithinTheTTL() async throws {
        installGateway()
        let client = makeClient()
        let ticket = try await client.authenticate()
        #expect(ticket == "t-1")
        #expect(ServeStub.log == ["GET /api/sessions", "POST /auth/password-login", "POST /api/auth/ws-ticket"])

        _ = try await client.authenticate()
        #expect(ServeStub.log.count == 4, "within the TTL only the ticket is minted again")
        #expect(ServeStub.log.last == "POST /api/auth/ws-ticket")
    }

    @Test func retriesOnceAfterA401() async throws {
        installGateway(jobsFirstStatus: 401)
        let client = makeClient()
        _ = try await client.authenticate()
        ServeStub.log = []
        let result = try await client.restJSON("GET", "api/cron/jobs")
        #expect(result["ok"]?.bool == true)
        #expect(ServeStub.log == ["GET /api/cron/jobs", "GET /api/sessions", "GET /api/cron/jobs"],
                "an expired cookie is re-proven (the probe still passes here) and the call retried once")
    }

    @Test func surfacesARejectedLogin() async {
        installGateway(rejectLogin: true)
        let client = makeClient()
        await #expect(throws: TransportError.self) { try await client.authenticate() }
        #expect(ServeStub.log == ["GET /api/sessions", "POST /auth/password-login"])
    }

    // MARK: - Browser sign-in

    /// Tokens kept in memory, as the Keychain keeps them for the app.
    nonisolated final class TokenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: DashboardTokens?
        init(_ tokens: DashboardTokens? = nil) { self.tokens = tokens }
        var current: DashboardTokens? { lock.withLock { tokens } }
        var store: DashboardTokenStore {
            DashboardTokenStore(read: { self.current }, write: { new in self.lock.withLock { self.tokens = new } })
        }
    }

    private func signedInClient(_ box: TokenBox) -> HermesServeClient {
        let settings = Settings(defaults: UserDefaults(suiteName: "serve-test-\(UUID().uuidString)")!)
        settings.serveURL = "http://serve.test:9119"
        return HermesServeClient(settings: settings, password: { nil }, tokens: box.store, protocolClasses: [ServeStub.self])
    }

    private nonisolated static let farOff = Date.now.timeIntervalSince1970 + 3600
    private nonisolated static func tokens(_ n: Int, expiresAt: Double? = farOff) -> DashboardTokens {
        DashboardTokens(accessToken: "access-\(n)", refreshToken: "refresh-\(n)", expiresAt: expiresAt, provider: "self_hosted", userID: "sam")
    }
    private nonisolated static func json(_ tokens: DashboardTokens) -> Data { (try? JSONEncoder().encode(tokens)) ?? Data() }

    /// A Dashboard that takes bearer tokens: `good` is the access token it accepts, and each
    /// refresh with the current refresh token moves both on by one.
    private func installTokenGateway(accepting first: Int, refreshStatus: Int = 200) {
        ServeStub.reset()
        nonisolated(unsafe) var generation = first
        ServeStub.handler = { request, body in
            let fields = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any]
            switch (request.httpMethod, request.url?.path()) {
            case ("POST", "/auth/native/refresh"):
                guard refreshStatus == 200 else { return (refreshStatus, Data(#"{"error":"session_expired"}"#.utf8)) }
                guard fields?["refresh_token"] as? String == "refresh-\(generation)", fields?["provider"] as? String == "self_hosted" else {
                    return (401, Data(#"{"error":"session_expired"}"#.utf8))
                }
                generation += 1
                return (200, Self.json(Self.tokens(generation)))
            case ("POST", "/auth/password-login"):
                return (500, Data())   // a signed-in client has no password to send
            default:
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer access-\(generation)" else {
                    return (401, Data(#"{"error":"session_expired","detail":"Unauthorized"}"#.utf8))
                }
                switch request.url?.path() {
                case "/api/auth/ws-ticket": return (200, Data(#"{"ticket":"t-9"}"#.utf8))
                case "/api/auth/me": return (200, Data(#"{"user_id":"sam","email":"sam@example.com","display_name":""}"#.utf8))
                default: return (200, Data(#"{"ok":true}"#.utf8))
                }
            }
        }
    }

    @Test func aSignedInClientSendsItsTokenAndNeverLogsIn() async throws {
        installTokenGateway(accepting: 1)
        defer { ServeStub.reset() }
        let client = signedInClient(TokenBox(Self.tokens(1)))
        #expect(client.hasCredentials)
        #expect(try await client.authenticate() == "t-9")
        #expect(try await client.restJSON("GET", "api/cron/jobs")["ok"]?.bool == true)
        #expect(try await client.signedInName() == "sam@example.com")
        #expect(ServeStub.log == ["POST /api/auth/ws-ticket", "GET /api/cron/jobs", "GET /api/auth/me"],
                "no probe, no password login, no refresh while the token is good")
    }

    @Test func aLapsedTokenIsTradedInBeforeTheRequest() async throws {
        installTokenGateway(accepting: 1)
        defer { ServeStub.reset() }
        let box = TokenBox(Self.tokens(1, expiresAt: Date.now.timeIntervalSince1970 + 20))
        let client = signedInClient(box)
        _ = try await client.restJSON("GET", "api/cron/jobs")
        #expect(ServeStub.log == ["POST /auth/native/refresh", "GET /api/cron/jobs"])
        #expect(box.current == Self.tokens(2), "the refresh token is spent by the trade: the new pair is the one kept")
    }

    @Test func aRefusedTokenIsTradedInOnceAndTheCallRetried() async throws {
        installTokenGateway(accepting: 2)   // the server has moved on; the phone's clock says access-1 is fine
        defer { ServeStub.reset() }
        let box = TokenBox(DashboardTokens(accessToken: "access-1", refreshToken: "refresh-2", expiresAt: Self.farOff, provider: "self_hosted", userID: "sam"))
        let client = signedInClient(box)
        #expect(try await client.restJSON("GET", "api/cron/jobs")["ok"]?.bool == true)
        #expect(ServeStub.log == ["GET /api/cron/jobs", "POST /auth/native/refresh", "GET /api/cron/jobs"])
        #expect(box.current?.accessToken == "access-3")
    }

    @Test func requestsAtTheSameMomentShareOneRefresh() async throws {
        installTokenGateway(accepting: 1)
        defer { ServeStub.reset() }
        let box = TokenBox(Self.tokens(1, expiresAt: Date.now.timeIntervalSince1970 - 5))
        let client = signedInClient(box)
        async let a = client.restJSON("GET", "api/cron/jobs")
        async let b = client.restJSON("GET", "api/skills")
        async let c = client.authenticate()
        _ = try await (a, b, c)
        #expect(ServeStub.log.filter { $0 == "POST /auth/native/refresh" }.count == 1,
                "a second use of one refresh token ends the session at the identity provider")
        #expect(box.current == Self.tokens(2))
    }

    @Test func aSpentRefreshTokenSignsThePhoneOutAndSaysSo() async throws {
        installTokenGateway(accepting: 7, refreshStatus: 401)
        defer { ServeStub.reset() }
        let box = TokenBox(Self.tokens(1))
        let client = signedInClient(box)
        let error = await #expect(throws: DashboardSignIn.Failure.self) { try await client.restJSON("GET", "api/cron/jobs") }
        #expect(error == .expired)
        #expect(error?.localizedDescription.contains("Sign in again") == true)
        #expect(box.current == nil)
        #expect(!client.hasCredentials)
    }

    @Test func anIdentityProviderThatIsDownDoesNotSignThePhoneOut() async throws {
        installTokenGateway(accepting: 7, refreshStatus: 503)
        defer { ServeStub.reset() }
        let box = TokenBox(Self.tokens(1))
        let client = signedInClient(box)
        await #expect(throws: TransportError.self) { try await client.restJSON("GET", "api/cron/jobs") }
        #expect(box.current == Self.tokens(1), "nobody refused the tokens; they are kept for the next try")
    }

    /// The whole of a sign-in, with the test as the browser: it is sent to the Dashboard's
    /// authorize address, and comes back to the phone's loopback listener with a one-time code.
    @Test func signingInBuysTokensWithTheCodeTheBrowserBringsBack() async throws {
        ServeStub.reset()
        defer { ServeStub.reset() }
        nonisolated(unsafe) var challenge = ""
        ServeStub.handler = { request, body in
            let fields = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any]
            switch (request.httpMethod, request.url?.path()) {
            case ("GET", "/api/status"):
                return (200, Data(#"{"version":"0.21.5","auth_required":true,"auth_flows":["cookie","native_pkce"]}"#.utf8))
            case ("POST", "/auth/native/token"):
                // Only the verifier this challenge was made from buys the tokens.
                guard fields?["code"] as? String == "one-time", let verifier = fields?["code_verifier"] as? String,
                      DashboardSignIn.challenge(for: verifier) == challenge else { return (400, Data(#"{"detail":"Invalid or expired authorization code."}"#.utf8)) }
                return (200, Self.json(Self.tokens(1)))
            default:
                return (404, Data())
            }
        }
        let box = TokenBox()
        let client = signedInClient(box)
        #expect(!client.hasCredentials)
        try await client.signIn { url in
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(url.absoluteString.hasPrefix("http://serve.test:9119/auth/native/authorize?"))
            #expect(query["code_challenge_method"] == "S256")
            challenge = query["code_challenge"] ?? ""
            // …the person signs in, and the Dashboard sends the browser back to the phone.
            let back = try #require(URL(string: "\(query["redirect_uri"] ?? "")?code=one-time&state=\(query["state"] ?? "")"))
            let (_, response) = try await NoRedirectSession.shared.data(from: back)
            #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") == "redde-signin://done")
        }
        var kept = Self.tokens(1)
        kept.origin = "http://serve.test:9119"   // the Dashboard they are for, and the only one they go to
        #expect(box.current == kept)
        #expect(client.hasCredentials)
    }

    @Test func aSignInIsNeverSentToAnotherAddress() async throws {
        ServeStub.reset()
        defer { ServeStub.reset() }
        nonisolated(unsafe) var bearers: [String] = []
        ServeStub.handler = { request, _ in
            if let sent = request.value(forHTTPHeaderField: "Authorization") { bearers.append(sent) }
            return (401, Data())
        }
        // Signed in at one address; then the address in Settings was changed.
        var elsewhere = Self.tokens(1)
        elsewhere.origin = "https://hermes.example:443"
        let box = TokenBox(elsewhere)
        let client = signedInClient(box)   // http://serve.test:9119
        #expect(!client.isSignedIn)
        #expect(!client.hasCredentials)
        await #expect(throws: TransportError.self) { try await client.restJSON("GET", "api/cron/jobs") }
        #expect(bearers.isEmpty, "the token went to a server that didn't issue it")
        #expect(!ServeStub.log.contains("POST /auth/native/refresh"))
        #expect(box.current == elsewhere, "kept for when the address comes back")
    }

    @Test func aBrowserClosedByHandLeavesThePhoneSignedOut() async throws {
        ServeStub.reset()
        defer { ServeStub.reset() }
        ServeStub.handler = { _, _ in (200, Data(#"{"auth_required":true,"auth_flows":["cookie","native_pkce"]}"#.utf8)) }
        let box = TokenBox()
        let client = signedInClient(box)
        await #expect(throws: CancellationError.self) {
            try await client.signIn { _ in throw CancellationError() }
        }
        #expect(box.current == nil)
        #expect(ServeStub.log == ["GET /api/status"], "nothing is exchanged without a code")
    }

    @Test func signInIsOnlyOfferedWhereTheDashboardOffersIt() async throws {
        ServeStub.reset()
        defer { ServeStub.reset() }
        // Before Hermes 0.21: a login, but no `auth_flows`.
        ServeStub.handler = { _, _ in (200, Data(#"{"version":"0.20.2","auth_required":true}"#.utf8)) }
        let client = signedInClient(TokenBox())
        let error = await #expect(throws: DashboardSignIn.Failure.self) { try await client.signIn { _ in } }
        #expect(error?.localizedDescription.contains("Hermes 0.21") == true)
    }

    @Test func signingOutLeavesThePasswordLogin() async throws {
        installGateway()
        defer { ServeStub.reset() }
        let box = TokenBox(Self.tokens(1))
        let settings = Settings(defaults: UserDefaults(suiteName: "serve-test-\(UUID().uuidString)")!)
        settings.serveURL = "http://serve.test:9119"
        settings.serveUsername = "redde"
        let client = HermesServeClient(settings: settings, password: { "hunter2" }, tokens: box.store, protocolClasses: [ServeStub.self])
        #expect(client.isSignedIn)
        client.signOut()
        #expect(!client.isSignedIn)
        #expect(client.hasCredentials, "the saved password is the login again")
        #expect(try await client.authenticate() == "t-1")
        #expect(ServeStub.log == ["GET /api/sessions", "POST /auth/password-login", "POST /api/auth/ws-ticket"])
    }
}
