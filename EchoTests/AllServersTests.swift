import Foundation
import Testing
@testable import Echo

/// All Servers: another saved server is reached by its own record and the secrets filed under its
/// id, never the active server's.
@MainActor
struct AllServersTests {
    @Test func anotherServersAPIGoesByItsOwnProfileAndKey() throws {
        let server = HermesServer(id: UUID(), name: "Cabin", transport: .hermesSessions, gatewayURL: "https://cabin.example/v1/", hermesProfile: "ops")
        let id = server.id.uuidString
        let main = Keychain.account(.gatewayAPIKey, server: id), own = Keychain.profileAccount("ops", server: id)
        let headers = Keychain.account(.customHeaders, server: id)
        defer { [main, own, headers].forEach { Keychain.delete(account: $0) } }

        #expect(AllServers.api(for: server) == nil, "no key saved for it")
        Keychain.write(account: main, value: "main-key")
        let viaMain = try #require(AllServers.api(for: server))
        #expect(viaMain.baseURL.absoluteString == "https://cabin.example/p/ops" && viaMain.apiKey == "main-key")
        Keychain.write(account: own, value: "ops-key")
        Keychain.write(account: headers, value: CustomHeader.encode([CustomHeader(name: "X-Lab", value: "1")]))
        let viaOwn = try #require(AllServers.api(for: server))
        #expect(viaOwn.apiKey == "ops-key" && viaOwn.headers == ["X-Lab": "1"])

        var main2 = server
        main2.hermesProfile = "default"
        #expect(AllServers.api(for: main2)?.baseURL.absoluteString == "https://cabin.example")
    }

    @Test func anotherServersDashboardGoesByItsOwnRecord() {
        let server = HermesServer(id: UUID(), name: "Cabin", serveURL: "https://dash.cabin.example/", serveUsername: "sam", cfAccessClientID: "abc.access")
        let secret = Keychain.account(.cfAccessClientSecret, server: server.id.uuidString)
        defer { Keychain.delete(account: secret) }
        Keychain.write(account: secret, value: "shh")
        let remote = RemoteServer(server)
        #expect(remote.serveBaseURL?.absoluteString == "https://dash.cabin.example")
        #expect(remote.serveUsername == "sam" && remote.profileName == nil)
        #expect(remote.accessHeaders["CF-Access-Client-Id"] == "abc.access" && remote.accessHeaders["CF-Access-Client-Secret"] == "shh")
    }

    @Test func aRowKeepsItsServerTagThroughDecodingAsBefore() throws {
        let json = #"[{"id":"s1","title":"Hi","last_active":1772999500}]"#
        let rows = try JSONDecoder().decode([HermesSessionsAPI.SessionSummary].self, from: Data(json.utf8))
        #expect(rows.first?.otherServer == nil)
    }
}
