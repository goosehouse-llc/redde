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

    // MARK: The profiles the phone knows of (Siri's "Ask Work in Redde")

    private func listed(_ name: String, title: String? = nil, isDefault: Bool = false) -> HermesServeClient.Profile {
        HermesServeClient.Profile(name: name, path: "/home/redde/.hermes/profiles/\(name)", isDefault: isDefault, displayName: title, description: nil)
    }

    @Test func whatTheDashboardListedAndWhatWasNamedByHandAreKnown() {
        let defaults = UserDefaults(suiteName: "known-\(UUID().uuidString)")!
        let settings = settings()
        #expect(ProfileCatalog.known(settings: settings, defaults: defaults) == [ProfileCatalog.main])

        #expect(ProfileCatalog.keep(listed: [listed("default", isDefault: true), listed("work", title: "Work"), listed("home")], settings: settings, defaults: defaults))
        #expect(ProfileCatalog.known(settings: settings, defaults: defaults).map(\.title) == ["Default", "Work", "home"])
        #expect(ProfileCatalog.known(settings: settings, defaults: defaults)[1].path == "/home/redde/.hermes/profiles/work")
        #expect(!ProfileCatalog.keep(listed: [listed("default", isDefault: true), listed("work", title: "Work"), listed("home")], settings: settings, defaults: defaults),
                "the same list again is no news")
        // The server's own list replaces what was kept: a profile removed there is gone here.
        #expect(ProfileCatalog.keep(listed: [listed("work", title: "Work")], settings: settings, defaults: defaults))
        #expect(ProfileCatalog.known(settings: settings, defaults: defaults).map(\.name) == ["default", "work"])

        // Over the Hermes API there is no list: a name that was chosen is kept.
        #expect(ProfileCatalog.keep(named: " lab ", settings: settings, defaults: defaults))
        #expect(!ProfileCatalog.keep(named: "LAB", settings: settings, defaults: defaults))
        #expect(!ProfileCatalog.keep(named: "Default", settings: settings, defaults: defaults))
        #expect(!ProfileCatalog.keep(named: "  ", settings: settings, defaults: defaults))
        #expect(ProfileCatalog.known(settings: settings, defaults: defaults).map(\.name) == ["default", "work", "lab"])
        #expect(ProfileCatalog.forget("lab", settings: settings, defaults: defaults))
        #expect(!ProfileCatalog.forget("lab", settings: settings, defaults: defaults))
        #expect(ProfileCatalog.kept(settings: settings, defaults: defaults).map(\.name) == ["work"])
    }

    @Test func theProfileInUseIsKnownAndEachServerHasItsOwn() {
        let defaults = UserDefaults(suiteName: "known-\(UUID().uuidString)")!
        let settings = settings(profile: "research", home: "/srv/research")
        #expect(ProfileCatalog.known(settings: settings, defaults: defaults)
            == [ProfileCatalog.main, KnownProfile(name: "research", title: "research", path: "/srv/research")])
        ProfileCatalog.keep(listed: [listed("research", title: "Research")], settings: settings, defaults: defaults)
        #expect(ProfileCatalog.known(settings: settings, defaults: defaults).map(\.title) == ["Default", "Research"], "once, under the name the server gives it")

        // Another server: none of the first one's.
        let other = settings.addServer(name: "Studio")
        settings.activateServer(other)
        #expect(ProfileCatalog.known(settings: settings, defaults: defaults) == [ProfileCatalog.main])
    }

    @Test func aProfileIsFoundByItsNameOrItsTitle() {
        let known = [ProfileCatalog.main, KnownProfile(name: "work", title: "Büro"), KnownProfile(name: "lab-2", title: "Lab")]
        #expect(ProfileCatalog.find("work", in: known)?.name == "work")
        #expect(ProfileCatalog.find("WORK ", in: known)?.name == "work")
        #expect(ProfileCatalog.find("buro", in: known)?.name == "work", "as Siri heard it, without the accent")
        #expect(ProfileCatalog.find("Lab", in: known)?.name == "lab-2")
        #expect(ProfileCatalog.find("Default", in: known)?.isDefault == true)
        #expect(ProfileCatalog.find("home", in: known) == nil)
        #expect(ProfileCatalog.find("", in: known) == nil)
    }

    @Test func usingAProfileSwitchesAndStartsAFreshConversation() async throws {
        let settings = settings()
        settings.transport = .chatCompletions
        settings.fastLaneURL = "http://example.invalid:11500"
        settings.fastLaneModel = "test"
        let conversation = Conversation(settings: settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "known-\(UUID().uuidString)")),
                                        transportOverride: ConversationLifecycleTests.ScriptedTransport([.textDelta("Hello."), .done]))
        _ = conversation.send("Hi")
        for _ in 0 ..< 300 where conversation.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        #expect(conversation.messages.count == 2)

        let work = KnownProfile(name: "work", title: "Work", path: "/home/redde/.hermes/profiles/work")
        #expect(ProfileCatalog.use(work, conversation: conversation, settings: settings))
        #expect(settings.profileName == "work")
        #expect(settings.hermesProfileHome == "/home/redde/.hermes/profiles/work")
        #expect(conversation.messages.isEmpty, "the open conversation was the other profile's")

        // Already there: nothing changes, and what is open stays open.
        _ = conversation.send("Hi again")
        for _ in 0 ..< 300 where conversation.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!ProfileCatalog.use(work, conversation: conversation, settings: settings))
        #expect(conversation.messages.count == 2)

        #expect(ProfileCatalog.use(ProfileCatalog.main, conversation: conversation, settings: settings))
        #expect(settings.profileName == nil && settings.hermesProfileHome.isEmpty)
    }

    @Test func siriAsksForAProfileWithItsVoiceRequest() async throws {
        let router = LaunchRouter()
        router.requestVoice(handsFree: true, profile: "work")
        let request = try #require(router.consumeVoiceRequest())
        #expect(request.handsFree && request.profile == "work")
        #expect(router.consumeVoiceRequest() == nil)
        router.requestVoice(handsFree: false)
        #expect(router.consumeVoiceRequest()?.profile == nil, "\"Ask Redde\" stays on the profile in use")

        // What Siri and Shortcuts are shown.
        let entity = ReddeProfileEntity(KnownProfile(name: "work", title: "Work"))
        #expect(entity.id == "work" && entity.title == "Work")
        #expect(ReddeProfileEntity(ProfileCatalog.main).id == ProfileCatalog.defaultID)
        // The main profile is always there to be named, whatever the server.
        #expect(try await ReddeProfileQuery().entities(for: [ProfileCatalog.defaultID, "no-such-profile-\(UUID().uuidString)"]).map(\.id) == [ProfileCatalog.defaultID])
    }

    @Test func theListIsAskedOfTheDashboardWhenThereIsALogin() async {
        ServeStub.reset()
        defer { ServeStub.reset() }
        ServeStub.handler = { request, _ in
            switch (request.httpMethod, request.url?.path()) {
            case ("POST", "/auth/password-login"): return (200, Data("{}".utf8))
            case ("GET", "/api/profiles"):
                return (200, Data(#"{"profiles":[{"name":"default","path":"/h","is_default":true},{"name":"work","path":"/h/profiles/work","is_default":false,"display_name":"Work"}]}"#.utf8))
            default: return (404, Data())
            }
        }
        // (The catalog keeps under the shared settings' defaults only through `refreshed`'s own
        // call; here a throwaway server id keeps it apart from everything else.)
        let settings = settings()
        let client = HermesServeClient(settings: settings, password: { "pw" }, protocolClasses: [ServeStub.self])
        let known = await ProfileCatalog.refreshed(settings: settings, client: client)
        defer { ProfileCatalog.forget("work", settings: settings) }
        #expect(known.map(\.title) == ["Default", "Work"])
        #expect(known.last?.path == "/h/profiles/work")

        // No login: what is known already, without asking.
        ServeStub.log = []
        let none = HermesServeClient(settings: self.settings(), password: { nil }, protocolClasses: [ServeStub.self])
        #expect(await ProfileCatalog.refreshed(settings: self.settings(), client: none) == [ProfileCatalog.main])
        #expect(ServeStub.log.isEmpty)
    }
}
