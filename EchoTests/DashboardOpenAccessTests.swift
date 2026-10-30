import Foundation
import Testing
@testable import Echo

/// A Hermes Dashboard with no sign-in (asked 2026-10-30): its token read off its page in either
/// shape, carried in its own header and as `?token=` on a WebSocket, and the form's choice. The
/// client against a stand-in Dashboard is in `HermesServeClientTests` (below), the same against a
/// real Hermes in `HermesLabOpenAccessTests`.
struct DashboardOpenAccessTests {
    // The two pages as Hermes 0.22 writes them (hermes_cli/web_server_dashboard.py).
    nonisolated static let dashboardPage = """
        <!doctype html><html lang="en"><head><meta charset="UTF-8"><title>Hermes</title>\
        <script>window.__HERMES_SESSION_TOKEN__="Zq3-x_Y9aB0cD1eF2gH3iJ4kL5mN6oP7qR8sT9uV0wX";\
        window.__HERMES_DASHBOARD_EMBEDDED_CHAT__=true;window.__HERMES_BASE_PATH__="";\
        window.__HERMES_AUTH_REQUIRED__=false;window.__HERMES_INITIAL_PROFILE__="";\
        window.__HERMES_DASHBOARD_PROFILE__="default";</script></head><body><div id="root"></div></body></html>
        """
    nonisolated static let headlessPage = """
        <!doctype html><html><head><script>window.__HERMES_SESSION_TOKEN__="hl-token_42";\
        window.__HERMES_AUTH_REQUIRED__=false;</script></head><body>Hermes serve is headless.</body></html>
        """

    @Test func readsTheTokenOffEitherPage() {
        #expect(SessionPage.token(in: Data(Self.dashboardPage.utf8)) == "Zq3-x_Y9aB0cD1eF2gH3iJ4kL5mN6oP7qR8sT9uV0wX")
        #expect(SessionPage.token(in: Data(Self.headlessPage.utf8)) == "hl-token_42")
        // Spaces around the "=", single quotes, and a JSON escape (the headless page is json.dumps').
        #expect(SessionPage.token(in: "window.__HERMES_SESSION_TOKEN__ = 'abc';") == "abc")
        #expect(SessionPage.token(in: #"window.__HERMES_SESSION_TOKEN__="a-b";"#) == "a-b")
    }

    @Test func aPageWithNoTokenHasNone() {
        // A Dashboard with a sign-in never puts one there; only the flag that says so.
        let gated = #"<script>window.__HERMES_DASHBOARD_EMBEDDED_CHAT__=true;window.__HERMES_AUTH_REQUIRED__=true;</script>"#
        #expect(SessionPage.token(in: gated) == nil)
        #expect(SessionPage.token(in: #"window.__HERMES_SESSION_TOKEN__="";"#) == nil)
        #expect(SessionPage.token(in: #"window.__HERMES_SESSION_TOKEN__=undefined;"#) == nil)
        #expect(SessionPage.token(in: #"window.__HERMES_SESSION_TOKEN__="unterminated"#) == nil)
        #expect(SessionPage.token(in: Data(#"{"error":"Hermes serve is headless."}"#.utf8)) == nil)
    }

    @Test func theTokenGoesInItsOwnHeader() {
        var request = URLRequest(url: URL(string: "http://hermes.test:9119/api/sessions")!)
        request.setValue("Basic cHJveHk6cGFzcw==", forHTTPHeaderField: "Authorization")   // a proxy's own
        let sent = SessionPage.apply("tok", to: request)
        #expect(sent.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Basic cHJveHk6cGFzcw==", "the proxy's header is left alone")
    }

    @Test func aWebSocketPresentsTheTokenAsAQuery() {
        let base = URL(string: "http://hermes.test:9119")!
        #expect(HermesServeClient.socketURL(baseURL: base, path: "api/ws", pass: .token("tok"))?.absoluteString == "ws://hermes.test:9119/api/ws?token=tok")
        #expect(HermesServeClient.socketURL(baseURL: base, path: "api/ws", pass: .ticket("t-1"))?.absoluteString == "ws://hermes.test:9119/api/ws?ticket=t-1")
        let secure = URL(string: "https://mac.tail.example.ts.net")!
        let plugin = HermesServeClient.socketURL(baseURL: secure, path: "api/plugins/kanban/events", query: [.init(name: "since", value: "7")], pass: .token("a+b"))
        #expect(plugin?.scheme == "wss")
        #expect(plugin?.path() == "/api/plugins/kanban/events")
        let items = plugin.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        #expect(items == [.init(name: "since", value: "7"), .init(name: "token", value: "a+b")])
    }

    @Test func aRedirectElsewhereLosesTheLogin() {
        let origin = URL(string: "https://hermes.test/api/sessions")!
        var request = URLRequest(url: URL(string: "https://hermes.test/api/sessions/")!)
        request.setValue("tok", forHTTPHeaderField: SessionPage.header)
        request.setValue("Bearer access", forHTTPHeaderField: "Authorization")
        let same = HermesServeClient.redirected(request, from: origin)
        #expect(same.value(forHTTPHeaderField: SessionPage.header) == "tok")
        #expect(same.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        for elsewhere in ["https://login.example/", "http://hermes.test/", "https://hermes.test:8443/"] {
            var moved = request
            moved.url = URL(string: elsewhere)
            let followed = HermesServeClient.redirected(moved, from: origin)
            #expect(followed.value(forHTTPHeaderField: SessionPage.header) == nil, "\(elsewhere)")
            #expect(followed.value(forHTTPHeaderField: "Authorization") == nil, "\(elsewhere)")
        }
        #expect(SessionPage.sameOrigin(URL(string: "https://hermes.test/a"), URL(string: "https://HERMES.test:443/b")))
    }

    @Test func theFormFollowsWhatTheAddressSays() {
        typealias Mode = DashboardFormMode
        // A Dashboard with no sign-in and nothing saved: no fields, the warning.
        #expect(Mode.decide(asksForLogin: false, hasLogin: false, savedOpen: false) == .open)
        #expect(Mode.decide(asksForLogin: false, hasLogin: false, savedOpen: true) == .open)
        // A login saved for one that no longer asks: said, with the fix.
        #expect(Mode.decide(asksForLogin: false, hasLogin: true, savedOpen: false) == .loginNoLongerAsked)
        // One that asks: the fields; said as a change when the server was saved with no sign-in.
        #expect(Mode.decide(asksForLogin: true, hasLogin: false, savedOpen: false) == .login)
        #expect(Mode.decide(asksForLogin: true, hasLogin: true, savedOpen: false) == .login)
        #expect(Mode.decide(asksForLogin: true, hasLogin: false, savedOpen: true) == .loginNowAsked)
        // Not answered (yet, or off the network): the server as it was saved, warning and all.
        #expect(Mode.decide(asksForLogin: nil, hasLogin: false, savedOpen: true) == .open)
        #expect(Mode.decide(asksForLogin: nil, hasLogin: false, savedOpen: false) == .login)
        #expect(Mode.decide(asksForLogin: nil, hasLogin: true, savedOpen: true) == .login)
        #expect(Mode.open.asksForLogin == false && Mode.loginNoLongerAsked.asksForLogin == false)
        #expect(Mode.login.asksForLogin && Mode.loginNowAsked.asksForLogin)
    }

    @Test func aHostThatTurnsTheAddressAwayIsSaidSo() {
        let refused = Data(#"{"detail":"Invalid Host header. Dashboard requests must use the bound hostname or the configured public hostname."}"#.utf8)
        #expect(SessionPage.hostRefusal(status: 400, body: refused) == .addressRefused)
        #expect(SessionPage.hostRefusal(status: 400, body: Data("bad".utf8)) == nil)
        #expect(SessionPage.hostRefusal(status: 401, body: refused) == nil)
    }

    @Test func aSetupCodeCarriesNoSignIn() throws {
        let link = "redde://connect?name=Den&dashboard=http://den.tail.example.ts.net&sign-in=none"
        let code = try #require(try SetupCode.read(URL(string: link)!))
        #expect(code.dashboardOpen)
        #expect(!code.hasSecrets)
        // Written back the same; read again the same.
        let again = try #require(try SetupCode.read(code.url))
        #expect(again.dashboardOpen && again.dashboardURL == code.dashboardURL)
        #expect(code.url.absoluteString.contains("sign-in=none"))
        // With a login in it, it is a Dashboard with a login, whatever it says.
        let withLogin = try #require(try SetupCode.read(URL(string: link + "&user=redde")!))
        #expect(!withLogin.dashboardOpen)
        #expect(!withLogin.url.absoluteString.contains("sign-in"))
        // Without a Dashboard there is nothing for it to be about.
        let apiOnly = try #require(try SetupCode.read(URL(string: "redde://connect?api=http://h.test:8642&sign-in=none")!))
        #expect(!apiOnly.dashboardOpen)
    }

    @Test @MainActor func aServerWithNoSignInIsSetUpTheSameElsewhere() throws {
        let here = Settings(defaults: UserDefaults(suiteName: "open-code-\(UUID().uuidString)")!)
        here.serveURL = "http://den.tail.example.ts.net"
        here.transport = .hermesServe
        here.serveOpenAccess = true
        let server = try #require(here.activeServer)
        #expect(server.serveOpenAccess, "the record carries it")
        let code = SetupCode(server: server, settings: here, secrets: false)
        #expect(code.dashboardOpen)

        let there = Settings(defaults: UserDefaults(suiteName: "open-code-\(UUID().uuidString)")!)
        let read = try #require(try SetupCode.read(code.url))
        read.install(in: there) { there.activateServer($0) }
        #expect(there.serveOpenAccess && there.serveURL == "http://den.tail.example.ts.net" && there.serveUsername.isEmpty)
        #expect(there.isConfigured, "nothing to store, and ready all the same")
        #expect(!there.activeServerIsUnused, "a second code would add a server, not overwrite this one")

        // The record round-trips (iCloud carries records as JSON), and an older one reads as false.
        let decoded = try JSONDecoder().decode(HermesServer.self, from: JSONEncoder().encode(server))
        #expect(decoded.serveOpenAccess)
        let older = try JSONDecoder().decode(HermesServer.self, from: Data(#"{"id":"\#(UUID().uuidString)","serveURL":"http://x"}"#.utf8))
        #expect(!older.serveOpenAccess)
    }

    @Test @MainActor func usingItWithoutALoginForgetsTheLogin() {
        let settings = Settings(defaults: UserDefaults(suiteName: "open-fix-\(UUID().uuidString)")!)
        settings.serveURL = "http://den.test:9119"
        settings.serveUsername = "redde"
        settings.useDashboardWithoutLogin()
        #expect(settings.serveUsername.isEmpty && settings.serveOpenAccess)
        #expect(settings.activeServer?.serveOpenAccess == true)
    }
}

/// The client against a stand-in Dashboard with no sign-in: what it asks, in what order, with
/// which token, and how it gets over a restart of the host. In this suite so it shares
/// `ServeStub` with the others one test at a time.
extension HermesServeClientTests {
    /// A Dashboard with no sign-in whose token is `token.value`; `asks` turns its sign-in on.
    nonisolated final class OpenHost: @unchecked Sendable {
        private let lock = NSLock()
        private var _token = "tok-1"
        private var _asks = false
        private var _sent: [String] = []
        var token: String { get { lock.withLock { _token } } set { lock.withLock { _token = newValue } } }
        var asks: Bool { get { lock.withLock { _asks } } set { lock.withLock { _asks = newValue } } }
        /// The token each request carried, by path ("-" for none).
        var sent: [String] { lock.withLock { _sent } }

        func answer(_ request: URLRequest) -> (Int, Data) {
            let carried = request.value(forHTTPHeaderField: SessionPage.header)
            lock.withLock { _sent.append("\(request.url?.path() ?? "") \(carried ?? "-")") }
            let good = carried == token && !asks
            switch (request.httpMethod ?? "GET", request.url?.path() ?? "") {
            case ("GET", "/api/status"): return (200, Data(#"{"version":"0.22.2","auth_required":\#(asks)}"#.utf8))
            case ("GET", "/"):
                return asks ? (200, Data("<html></html>".utf8)) : (200, Data(DashboardOpenAccessTests.headlessPage.replacingOccurrences(of: "hl-token_42", with: token).utf8))
            case ("POST", "/api/auth/ws-ticket"): return (403, Data(#"{"detail":"no session"}"#.utf8))
            case ("POST", "/auth/password-login"): return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            case ("GET", "/api/sessions"): return good ? (200, Data(#"{"sessions":[]}"#.utf8)) : (401, Data(#"{"detail":"Unauthorized"}"#.utf8))
            case ("GET", "/api/cron/jobs"): return good ? (200, Data(#"{"jobs":[]}"#.utf8)) : (401, Data(#"{"detail":"Unauthorized"}"#.utf8))
            default: return (404, Data())
            }
        }
    }

    private func openClient(_ host: OpenHost, savedOpen: Bool = true, username: String = "", password: String? = nil) -> HermesServeClient {
        ServeStub.reset()
        ServeStub.handler = { request, _ in host.answer(request) }
        let settings = Settings(defaults: UserDefaults(suiteName: "serve-open-\(UUID().uuidString)")!)
        settings.serveURL = "http://den.test:9119"
        settings.serveUsername = username
        settings.serveOpenAccess = savedOpen
        return HermesServeClient(settings: settings, password: { password }, tokens: TokenBox().store, protocolClasses: [ServeStub.self])
    }

    @Test func noSignInReadsThePageAndSendsItsToken() async throws {
        let host = OpenHost()
        let client = openClient(host)
        defer { ServeStub.reset() }
        #expect(client.hasCredentials, "a server saved with no sign-in is usable before anything is asked")
        _ = try await client.restJSON("GET", "api/cron/jobs")
        // A cookie first (one from a login since forgotten would do), then the status, the page,
        // and a read the token alone opens; then the call itself, carrying it.
        #expect(ServeStub.log == ["GET /api/sessions", "GET /api/status", "GET /", "GET /api/sessions", "GET /api/cron/jobs"])
        #expect(host.sent.last == "/api/cron/jobs tok-1")
        #expect(client.usesPageToken)

        // The WebSocket opens on the token itself: the ticket route refuses this mode.
        #expect(try await client.socketPass() == .token("tok-1"))
        #expect(!ServeStub.log.contains("POST /api/auth/ws-ticket"))

        // Within the hour nothing is read again.
        ServeStub.log = []
        _ = try await client.restJSON("GET", "api/cron/jobs")
        #expect(ServeStub.log == ["GET /api/cron/jobs"])
    }

    @Test func aRestartedHostsNewTokenIsReadOnceAndTheCallRetried() async throws {
        let host = OpenHost()
        let client = openClient(host)
        defer { ServeStub.reset() }
        _ = try await client.restJSON("GET", "api/cron/jobs")
        host.token = "tok-2"   // the host restarted
        ServeStub.log = []
        _ = try await client.restJSON("GET", "api/cron/jobs")
        #expect(ServeStub.log == ["GET /api/cron/jobs", "GET /api/status", "GET /", "GET /api/sessions", "GET /api/cron/jobs"])
        #expect(host.sent.last == "/api/cron/jobs tok-2")
        #expect(try await client.socketPass() == .token("tok-2"))
    }

    @Test func aRefusalTheNewPageDoesntCureIsNotRetriedAgain() async throws {
        let host = OpenHost()
        let client = openClient(host)
        defer { ServeStub.reset() }
        _ = try await client.restJSON("GET", "api/cron/jobs")
        // The route refuses even a good token (as a 401): one read of the page, no loop.
        ServeStub.handler = { request, _ in
            request.url?.path() == "/api/cron/jobs" ? (401, Data(#"{"detail":"Unauthorized"}"#.utf8)) : host.answer(request)
        }
        ServeStub.log = []
        await #expect(throws: TransportError.self) { try await client.restJSON("GET", "api/cron/jobs") }
        #expect(ServeStub.log == ["GET /api/cron/jobs", "GET /api/status", "GET /", "GET /api/sessions"])
    }

    @Test func aHostThatTurnsItsSignInOnIsSaidSo() async throws {
        let host = OpenHost()
        host.asks = true
        let saved = openClient(host, savedOpen: true)
        defer { ServeStub.reset() }
        do {
            _ = try await saved.restJSON("GET", "api/cron/jobs")
            Issue.record("a Dashboard that asks for a login let the phone in with none")
        } catch {
            #expect(error as? DashboardSignInChange == .nowAsksForLogin)
            #expect(error.localizedDescription == DashboardSignInChange.nowAsksText)
        }
        #expect(!ServeStub.log.contains("GET /"), "a gated host's page is never read")
        // Never set up with no sign-in: just the missing login, as before.
        let never = openClient(host, savedOpen: false)
        do {
            _ = try await never.restJSON("GET", "api/cron/jobs")
        } catch {
            #expect(error.localizedDescription.contains(TransportError.missingLoginText))
        }
    }

    @Test func aLoginSavedForAHostWithNoSignInIsSaidSo() async throws {
        let host = OpenHost()
        let client = openClient(host, savedOpen: false, username: "redde", password: "hunter2")
        defer { ServeStub.reset() }
        do {
            _ = try await client.restJSON("GET", "api/cron/jobs")
            Issue.record("a saved login went through on a Dashboard with no sign-in")
        } catch {
            #expect(error as? DashboardSignInChange == .noLongerAsks)
        }
        #expect(ServeStub.log.contains("POST /auth/password-login"))
        #expect(!ServeStub.log.contains("GET /"), "with a login saved, the page isn't read: the person says first")
    }

    @Test func aProxyPassingItsOwnNameIsSaidSo() async throws {
        let host = OpenHost()
        let client = openClient(host)
        ServeStub.handler = { request, _ in
            request.url?.path() == "/api/sessions" && request.value(forHTTPHeaderField: SessionPage.header) == nil
                ? (401, Data())
                : (400, Data(#"{"detail":"Invalid Host header. Dashboard requests must use the bound hostname or the configured public hostname."}"#.utf8))
        }
        defer { ServeStub.reset() }
        do {
            _ = try await client.restJSON("GET", "api/cron/jobs")
            Issue.record("went through")
        } catch {
            #expect(error as? DashboardSignInChange == .addressRefused)
        }
    }
}
