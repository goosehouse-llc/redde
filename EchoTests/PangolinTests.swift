import Foundation
import Testing
@testable import Echo

/// Pangolin (pangolin.net) in front of the Dashboard or the Hermes API: a Link's access token,
/// sent as `P-Access-Token-Id` and `P-Access-Token` on every request (asked 2026-10-23).
@MainActor
struct PangolinTests {
    @Test func aTokenAsPastedIsStoredAsItsPair() {
        #expect(Settings.pangolinToken("abc123.tok-en_9") == "abc123.tok-en_9")
        #expect(Settings.pangolinToken("  abc123.tok-en_9\n") == "abc123.tok-en_9")
        #expect(Settings.pangolinToken("https://hermes.example.com/?p_token=abc123.tok-en_9&x=1") == "abc123.tok-en_9", "a Link's address")
        #expect(Settings.pangolinToken("p_token=abc123.tok-en_9") == "abc123.tok-en_9")
        for wrong in ["", "abc123", ".token", "abc123.", "abc 123.token", "https://hermes.example.com/", "Bearer abc"] {
            #expect(Settings.pangolinToken(wrong) == nil, "\(wrong)")
        }
    }

    @Test func itsHeadersOnlyWithAWholeToken() {
        #expect(Settings.pangolinHeaders(nil).isEmpty)
        #expect(Settings.pangolinHeaders("nonsense").isEmpty)
        #expect(Settings.pangolinHeaders("abc123.tok-en_9") == ["P-Access-Token-Id": "abc123", "P-Access-Token": "tok-en_9"])
    }

    /// A Link opens one resource: the Dashboard and the API each get their own token, and one
    /// given alone goes to both (a Dashboard and API behind one resource).
    @Test func eachConnectionGetsItsOwnTokenOrTheOneThereIs() {
        let server = HermesServer(id: UUID(), name: "Cabin", gatewayURL: "https://api.cabin.example/", serveURL: "https://dash.cabin.example/")
        let dashboard = Keychain.account(.pangolinDashboard, server: server.id.uuidString)
        let api = Keychain.account(.pangolinAPI, server: server.id.uuidString)
        defer { Keychain.delete(account: dashboard); Keychain.delete(account: api) }
        #expect(RemoteServer(server).accessHeaders["P-Access-Token"] == nil)

        Keychain.write(account: api, value: "apiid.apitoken")
        #expect(RemoteServer(server).accessHeaders["P-Access-Token-Id"] == "apiid", "the one there is")
        #expect(RemoteServer.apiHeaders(of: server)["P-Access-Token-Id"] == "apiid")

        Keychain.write(account: dashboard, value: "dashid.dashtoken")
        #expect(RemoteServer(server).accessHeaders["P-Access-Token-Id"] == "dashid")
        #expect(RemoteServer(server).accessHeaders["P-Access-Token"] == "dashtoken")
        #expect(RemoteServer.apiHeaders(of: server)["P-Access-Token-Id"] == "apiid", "each its own")
    }
}
