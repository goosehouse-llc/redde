import Foundation
import Testing
@testable import Echo

@Suite(.serialized)
struct ProfileTests {
    private func settings(profile: String = "", home: String = "") -> Settings {
        let settings = Settings(defaults: UserDefaults(suiteName: "profile-test-\(UUID().uuidString)")!)
        settings.gatewayURL = "https://hermes.test:8642"
        settings.serveURL = "http://serve.test:9119"
        settings.serveUsername = "redde"
        settings.hermesProfile = profile
        settings.hermesProfileHome = home
        return settings
    }

    @Test func defaultProfileNamesNothing() {
        #expect(settings().profileName == nil)
        #expect(settings(profile: "  ").profileName == nil)
        #expect(settings(profile: "Default").profileName == nil)
        #expect(settings(profile: "work").profileName == "work")
    }

    @Test func hermesAPIGoesThroughTheProfilePrefix() {
        #expect(settings().gatewayBaseURL?.absoluteString == "https://hermes.test:8642")
        #expect(settings(profile: "work").gatewayBaseURL?.absoluteString == "https://hermes.test:8642/p/work")
        // Paths the transports append keep the prefix.
        let url = settings(profile: "work").gatewayBaseURL?.appending(path: "api/sessions/abc/chat/stream")
        #expect(url?.path() == "/p/work/api/sessions/abc/chat/stream")
    }

    @Test func contextFilesFollowTheProfileHome() {
        #expect(settings().profileFilePath("SOUL.md") == "~/.hermes/SOUL.md")
        #expect(settings(profile: "work", home: "/home/redde/.hermes/profiles/work/")
            .profileFilePath("memories/MEMORY.md") == "/home/redde/.hermes/profiles/work/memories/MEMORY.md")
        // Named by hand, so the server never reported a home: Hermes's own layout.
        #expect(settings(profile: "work").profileFilePath("SOUL.md") == "~/.hermes/profiles/work/SOUL.md")
    }

    @Test func restPlacementPerRoute() {
        typealias C = HermesServeClient
        #expect(C.profilePlacement(method: "GET", path: "api/sessions?limit=50&offset=0&order=recent") == .query)
        #expect(C.profilePlacement(method: "PATCH", path: "api/sessions/abc") == .body)
        #expect(C.profilePlacement(method: "GET", path: "api/skills") == .query)
        #expect(C.profilePlacement(method: "GET", path: "api/skills/content?name=x") == .query)
        #expect(C.profilePlacement(method: "POST", path: "api/skills") == .body)
        #expect(C.profilePlacement(method: "PUT", path: "api/skills/content") == .body)
        #expect(C.profilePlacement(method: "PUT", path: "api/skills/toggle") == .query)
        #expect(C.profilePlacement(method: "PUT", path: "api/tools/toolsets/web") == .query)
        #expect(C.profilePlacement(method: "POST", path: "api/cron/jobs/j1/pause") == .query)
        #expect(C.profilePlacement(method: "GET", path: "api/fs/read-text?path=x") == .none)
        #expect(C.profilePlacement(method: "GET", path: "api/plugins/kanban/board") == .none)
        #expect(C.profilePlacement(method: "GET", path: "api/profiles") == .none)
        #expect(C.profilePlacement(method: "GET", path: "api/skillsets") == .none)
    }

    @Test func scopedAddsTheProfileOnlyWhereItBelongs() throws {
        typealias C = HermesServeClient
        #expect(C.scoped(method: "GET", path: "api/skills", body: nil, profile: nil).0 == "api/skills")
        #expect(C.scoped(method: "GET", path: "api/skills", body: nil, profile: "work").0 == "api/skills?profile=work")
        #expect(C.scoped(method: "GET", path: "api/sessions?limit=5", body: nil, profile: "work").0 == "api/sessions?limit=5&profile=work")
        // Cron's all-profiles list keeps asking for all of them.
        #expect(C.scoped(method: "GET", path: "api/cron/jobs?profile=all", body: nil, profile: "work").0 == "api/cron/jobs?profile=all")
        #expect(C.scoped(method: "GET", path: "api/fs/read-text?path=a", body: nil, profile: "work").0 == "api/fs/read-text?path=a")

        let body = try JSONSerialization.data(withJSONObject: ["name": "x", "content": "y"])
        let (path, scopedBody) = C.scoped(method: "PUT", path: "api/skills/content", body: body, profile: "work")
        #expect(path == "api/skills/content")
        let data = try #require(scopedBody)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["profile"] as? String == "work")
        #expect(object["name"] as? String == "x")
    }

    @Test func rpcProfileOnlyOnProfileScopedMethods() {
        let client = HermesServeClient(settings: settings(profile: "work"), password: { "pw" }, protocolClasses: [ServeStub.self])
        let params = JSONValue.object(["cols": .number(80)])
        #expect(client.withProfile(params, for: "session.create")["profile"]?.string == "work")
        #expect(client.withProfile(params, for: "projects.tree")["profile"]?.string == "work")
        // Session-bound calls run in the session's profile; their params would reject the key anyway.
        #expect(client.withProfile(params, for: "prompt.submit")["profile"] == nil)
        #expect(client.withProfile(params, for: "complete.slash")["profile"] == nil)

        let plain = HermesServeClient(settings: settings(), password: { "pw" }, protocolClasses: [ServeStub.self])
        #expect(plain.withProfile(params, for: "session.create")["profile"] == nil)
    }

    @Test func namedProfileUsesItsOwnAPIKey() {
        let name = "t\(UUID().uuidString.prefix(8).lowercased())"
        defer { Keychain.delete(account: Keychain.profileAccount(name)) }
        let settings = settings(profile: name)
        let main = Keychain.read(.gatewayAPIKey)
        #expect(settings.gatewayAPIKey == main)  // no profile key yet: the main key
        Keychain.write(account: Keychain.profileAccount(name), value: "profile-key")
        #expect(settings.gatewayAPIKey == "profile-key")
    }

    @Test func rejectedKeyPointsAtTheProfileKey() {
        let body = #"{"error": {"message": "Invalid gateway API key (API_SERVER_KEY)", "code": "gateway_auth_failed"}}"#
        #expect(TransportError.http(status: 401, body: body).localizedDescription.contains("Settings → Profile"))
    }

    @Test func unservedProfileExplainsTheFix() {
        let error = TransportError.http(status: 404, body: #"{"error":"Unknown or unconfigured profile"}"#)
        #expect(error.localizedDescription.contains("multiplex_profiles"))
    }
}
