import Foundation
import Testing
@testable import Echo

/// The pieces of a browser sign-in that need no Dashboard: PKCE, the tokens, and the loopback
/// address the browser is sent back to. The client's use of them is in `HermesServeClientTests`;
/// a real Hermes is in `HermesLabSignInTests`.
struct DashboardSignInTests {
    private let done = DashboardSignIn.doneURL

    // MARK: PKCE

    /// RFC 7636, appendix B.
    @Test func challengeIsTheS256OfTheVerifier() {
        #expect(DashboardSignIn.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifiersAreLongEnoughAndNeverRepeat() {
        let a = DashboardSignIn.verifier(), b = DashboardSignIn.verifier()
        #expect(a != b)
        #expect(a.count == 43, "32 bytes as base64url: RFC 7636 asks for 43 to 128 characters")
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func theAuthorizeAddressCarriesTheChallengeAndTheWayBack() throws {
        let url = try #require(DashboardSignIn.authorizeURL(baseURL: URL(string: "https://hermes.example/sub")!, challenge: "CH",
                                                           redirectURI: "http://127.0.0.1:5123/callback", state: "ST"))
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.path == "/sub/auth/native/authorize")
        let query = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query == ["code_challenge": "CH", "code_challenge_method": "S256",
                          "redirect_uri": "http://127.0.0.1:5123/callback", "state": "ST"])
    }

    // MARK: Tokens

    @Test func tokensDecodeFromWhatTheDashboardSends() throws {
        let json = #"{"access_token":"A","refresh_token":"R","token_type":"Bearer","expires_at":1791444348,"provider":"basic","user_id":"lab"}"#
        let tokens = try JSONDecoder().decode(DashboardTokens.self, from: Data(json.utf8))
        #expect(tokens == DashboardTokens(accessToken: "A", refreshToken: "R", expiresAt: 1_791_444_348, provider: "basic", userID: "lab"))
        // What goes into the Keychain comes back the same.
        #expect(try JSONDecoder().decode(DashboardTokens.self, from: JSONEncoder().encode(tokens)) == tokens)
    }

    @Test func onlyTheAccessTokenHasToBeThere() throws {
        let tokens = try JSONDecoder().decode(DashboardTokens.self, from: Data(#"{"access_token":"A","expires_at":null}"#.utf8))
        #expect(tokens.accessToken == "A")
        #expect(tokens.refreshToken.isEmpty)
        #expect(tokens.expiresAt == nil)
    }

    @Test func aTokenIsTradedInAMinuteBeforeItLapses() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(DashboardTokens(accessToken: "A", refreshToken: "R", expiresAt: 1030).expires(within: 60, of: now))
        #expect(DashboardTokens(accessToken: "A", refreshToken: "R", expiresAt: 900).expires(within: 60, of: now))
        #expect(!DashboardTokens(accessToken: "A", refreshToken: "R", expiresAt: 5000).expires(within: 60, of: now))
        #expect(!DashboardTokens(accessToken: "A", refreshToken: "R").expires(within: 60, of: now), "no expiry given: found out by a 401")
    }

    @Test func aSignInBelongsToOneAddress() {
        let origin = DashboardSignIn.origin(of:)
        #expect(origin(URL(string: "https://Hermes.Example/sub/path")!) == "https://hermes.example:443")
        #expect(origin(URL(string: "http://hermes.example")!) == "http://hermes.example:80")
        #expect(origin(URL(string: "http://hermes.example:9119")!) != origin(URL(string: "http://hermes.example:9120")!))

        let mine = DashboardTokens(accessToken: "A", refreshToken: "R", origin: "https://hermes.example:443")
        let store = DashboardTokenStore(read: { mine }, write: { _ in })
        #expect(DashboardSignIn.tokens(for: URL(string: "https://hermes.example/")!, in: store) == mine)
        #expect(DashboardSignIn.tokens(for: URL(string: "https://elsewhere.example")!, in: store) == nil)
        #expect(DashboardSignIn.tokens(for: URL(string: "http://hermes.example")!, in: store) == nil, "the same host without TLS is another address")
        #expect(DashboardSignIn.tokens(for: nil, in: store) == nil)
    }

    // MARK: The way back

    @Test func theCallbackHandsOverTheCodeOfItsOwnSignInOnly() {
        let good = LoopbackCallback.answer(to: "GET /callback?code=C0DE&state=mine HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", state: "mine", done: done)
        #expect(good.code == "C0DE")
        #expect(good.response.hasPrefix("HTTP/1.1 302 Found\r\nLocation: redde-signin://done\r\n"))

        let stranger = LoopbackCallback.answer(to: "GET /callback?code=C0DE&state=theirs HTTP/1.1\r\n\r\n", state: "mine", done: done)
        #expect(stranger.code == nil)
        #expect(stranger.response.hasPrefix("HTTP/1.1 400 "))

        #expect(LoopbackCallback.answer(to: "GET /callback?state=mine HTTP/1.1\r\n\r\n", state: "mine", done: done).code == nil)
        #expect(LoopbackCallback.answer(to: "GET /favicon.ico HTTP/1.1\r\n\r\n", state: "mine", done: done).response.hasPrefix("HTTP/1.1 404 "))
        #expect(LoopbackCallback.answer(to: "POST /callback?code=C0DE&state=mine HTTP/1.1\r\n\r\n", state: "mine", done: done).code == nil)
        #expect(LoopbackCallback.answer(to: "", state: "mine", done: done).code == nil)
    }

    /// The listener for real: a request over the phone's own loopback, as the browser makes it.
    @Test func theListenerTakesTheBrowsersRequest() async throws {
        let callback = try await LoopbackCallback.start(state: "mine", done: done)
        defer { callback.stop() }
        #expect(callback.port > 0)
        #expect(callback.redirectURI == "http://127.0.0.1:\(callback.port)/callback")

        func get(_ query: String) async throws -> (status: Int, location: String?) {
            let url = try #require(URL(string: callback.redirectURI + query))
            let (_, response) = try await NoRedirectSession.shared.data(from: url)
            let http = try #require(response as? HTTPURLResponse)
            return (http.statusCode, http.value(forHTTPHeaderField: "Location"))
        }
        // Someone else's request doesn't end the wait.
        #expect(try await get("?code=nope&state=theirs").status == 400)
        async let code = callback.code()
        let answer = try await get("?code=C0DE&state=mine")
        #expect(answer.status == 302)
        #expect(answer.location == "redde-signin://done")
        let delivered = try await code
        #expect(delivered == "C0DE")
    }

    @Test func aStoppedListenerEndsTheWait() async throws {
        let callback = try await LoopbackCallback.start(state: "mine", done: done)
        let wait = Task { try await callback.code() }
        try await Task.sleep(for: .milliseconds(50))
        callback.stop()
        await #expect(throws: (any Error).self) { _ = try await wait.value }
    }
}
