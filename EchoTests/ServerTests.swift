import Foundation
import Testing
@testable import Echo

@Suite(.serialized)
struct ServerTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "server-test-\(UUID().uuidString)")! }

    @Test func existingSetupBecomesTheFirstServer() {
        let d = defaults()
        d.set("https://gw.test:8642", forKey: "gatewayURL")
        d.set("http://serve.test:9119", forKey: "serveURL")
        d.set("redde", forKey: "serveUsername")
        d.set("work", forKey: "hermesProfile")
        d.set("hermesServe", forKey: "transport")
        let settings = Settings(defaults: d)
        #expect(settings.servers.count == 1)
        let first = settings.servers[0]
        #expect(first.id == settings.activeServerID)
        #expect(first.gatewayURL == "https://gw.test:8642")
        #expect(first.serveURL == "http://serve.test:9119")
        #expect(first.serveUsername == "redde")
        #expect(first.hermesProfile == "work")
        #expect(first.transport == .hermesServe)
        // The same list comes back on the next launch.
        let again = Settings(defaults: d)
        #expect(again.servers == settings.servers)
        #expect(again.activeServerID == settings.activeServerID)
    }

    @Test func switchingSwapsTheWorkingCopy() {
        let settings = Settings(defaults: defaults())
        settings.serveURL = "http://home.test:9119"
        settings.hermesProfile = "work"
        let home = settings.activeServerID
        let office = settings.addServer(name: "Office")

        settings.activateServer(office)
        #expect(settings.activeServerID == office)
        #expect(settings.serveURL == "")
        #expect(settings.hermesProfile == "")
        settings.serveURL = "http://office.test:9119"
        settings.transport = .hermesSessions

        settings.activateServer(home)
        #expect(settings.serveURL == "http://home.test:9119")
        #expect(settings.hermesProfile == "work")
        let officeRecord = settings.servers.first { $0.id == office }
        #expect(officeRecord?.serveURL == "http://office.test:9119")
        #expect(officeRecord?.transport == .hermesSessions)
    }

    @Test func theOpenAICompatibleChoiceIsntAServers() {
        let settings = Settings(defaults: defaults())
        settings.transport = .hermesServe
        settings.transport = .chatCompletions
        #expect(settings.activeServer?.transport == .hermesServe)
    }

    @Test func removingAServerDeletesItsSecrets() {
        let settings = Settings(defaults: defaults())
        let other = settings.addServer(name: "Other")
        let server = other.uuidString
        Keychain.write(account: Keychain.account(.gatewayAPIKey, server: server), value: "k")
        Keychain.write(account: Keychain.profileAccount("work", server: server), value: "p")
        settings.removeServer(other)
        #expect(!settings.servers.contains { $0.id == other })
        #expect(Keychain.read(account: Keychain.account(.gatewayAPIKey, server: server)) == nil)
        #expect(Keychain.read(account: Keychain.profileAccount("work", server: server)) == nil)
    }

    @Test func theActiveAndTheLastServerStay() {
        let settings = Settings(defaults: defaults())
        settings.removeServer(settings.activeServerID)
        #expect(settings.servers.count == 1)
    }

    @Test func legacySecretsMoveUnderTheServer() {
        let settings = Settings(defaults: defaults())
        let server = settings.activeServerID.uuidString
        let profile = "legacy\(UUID().uuidString.prefix(6).lowercased())"
        let bareProfile = "gateway-api-key.\(profile)"
        // Only the profile key is written bare here: the plain items belong to the app's own
        // (already migrated) setup in the test host.
        Keychain.write(account: bareProfile, value: "profile-secret")
        defer {
            Keychain.delete(account: bareProfile)
            Keychain.delete(account: bareProfile + "@" + server)
        }
        settings.moveLegacySecretsToActiveServer()
        #expect(Keychain.read(account: bareProfile) == nil)
        #expect(Keychain.read(account: bareProfile + "@" + server) == "profile-secret")
    }

    @Test func moveKeepsTheOriginalUntilTheCopyReadsBack() {
        let from = "move-test-\(UUID().uuidString)"
        let to = from + "@x"
        defer { Keychain.delete(account: from); Keychain.delete(account: to) }
        Keychain.write(account: from, value: "v")
        #expect(Keychain.move(account: from, to: to))
        #expect(Keychain.read(account: to) == "v")
        #expect(Keychain.read(account: from) == nil)
    }

    @Test func serverTitles() {
        var server = HermesServer(id: UUID(), name: "  ")
        #expect(server.title == "New server")
        server.serveURL = "http://hermes.home.test:9119"
        #expect(server.title == "hermes.home.test")
        server.name = "Home"
        #expect(server.title == "Home")
    }

    @Test func oldConversationFilesStillLoad() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"t","createdAt":0,"updatedAt":0,"transport":"hermesServe","messages":[]}"#
        let record = try JSONDecoder().decode(ConversationRecord.self, from: Data(json.utf8))
        #expect(record.serverID == nil)
    }

    /// The open conversation is saved as the old server's before the switch; saved after it, it
    /// was stamped with the new server and reopened there, sending to the wrong server.
    @Test func switchingSavesTheOpenConversationAsTheOldServers() async {
        let dir = URL.temporaryDirectory.appending(path: "echo-test-\(UUID().uuidString)").appending(path: "conversations")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = ConversationStore(directory: dir)
        let settings = Settings(defaults: defaults())
        settings.transport = .hermesServe
        let home = settings.activeServerID
        let office = settings.addServer(name: "Office")
        let conversation = Conversation(settings: settings, store: store)
        conversation.load(ConversationRecord(id: UUID(), title: "t", createdAt: .now, updatedAt: .now, transport: .hermesServe,
                                             serverSessionID: "home-session",
                                             messages: [Message(role: .user, text: "hi"), Message(role: .assistant, text: "hello")],
                                             serverID: home))
        let id = conversation.id
        ServerSwitcher.switchTo(office, conversation: conversation, settings: settings)
        let saved = store.cachedRecord(id: id)
        #expect(saved?.serverID == home)
        #expect(saved?.transport == .hermesServe)
        #expect(conversation.id != id, "a fresh conversation for the new server")
    }

    /// Chats saved before multi-server have no server; they're the first server's, not every one's.
    @Test func untaggedChatsBelongToTheFirstServer() async {
        let dir = URL.temporaryDirectory.appending(path: "echo-test-\(UUID().uuidString)").appending(path: "conversations")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = ConversationStore(directory: dir)
        let settings = Settings(defaults: defaults())
        let office = settings.addServer(name: "Office")
        let legacy = ConversationRecord(id: UUID(), title: "old", createdAt: .now, updatedAt: .now, transport: .hermesServe,
                                        serverSessionID: "home-session", messages: [Message(role: .user, text: "hi")])
        store.upsert(legacy)
        #expect(Conversation(settings: settings, store: store).id == legacy.id, "the first server picks it up")
        settings.activateServer(office)
        #expect(Conversation(settings: settings, store: store).id != legacy.id, "another server doesn't")
    }

    /// A record from another version (a field missing, or one added) still loads.
    @Test func serversDecodeWithMissingFields() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Home","serveURL":"http://h.test:9119","future":1}]"#
        let servers = try JSONDecoder().decode([HermesServer].self, from: Data(json.utf8))
        #expect(servers.first?.serveURL == "http://h.test:9119")
        #expect(servers.first?.transport == .hermesServe)
    }

    /// An unreadable list isn't overwritten, and the active server keeps its id, so the Keychain
    /// secrets filed under it still match.
    @Test func anUnreadableServerListKeepsTheActiveID() {
        let d = defaults()
        let id = UUID()
        d.set(Data("not json".utf8), forKey: "hermesServers")
        d.set(id.uuidString, forKey: Keychain.activeServerKey)
        d.set("http://h.test:9119", forKey: "serveURL")
        let settings = Settings(defaults: d)
        #expect(settings.activeServerID == id)
        #expect(settings.activeServer?.serveURL == "http://h.test:9119")
        #expect(d.data(forKey: "hermesServers.unreadable") == Data("not json".utf8))
    }

    @Test func switchingServersKeepsTheOpenAICompatibleConnection() {
        let settings = Settings(defaults: defaults())
        let office = settings.addServer(name: "Office")
        settings.transport = .chatCompletions
        settings.activateServer(office)
        #expect(settings.transport == .chatCompletions)
    }

    /// Shortcut sessions from before multi-server move under the first server's id, once.
    @Test func shortcutSessionsAreScopedByServer() {
        let d = defaults()
        d.set("s1", forKey: "shortcutSessionID")
        d.set("s2", forKey: "shortcutSessionID.work.serve")
        let settings = Settings(defaults: d)
        let first = settings.activeServerID.uuidString
        #expect(d.string(forKey: "shortcutSessionID.\(first)") == "s1")
        #expect(d.string(forKey: "shortcutSessionID.\(first).work.serve") == "s2")
        #expect(d.string(forKey: "shortcutSessionID") == nil)
        // A second launch leaves them where they are.
        _ = Settings(defaults: d)
        #expect(d.string(forKey: "shortcutSessionID.\(first)") == "s1")
    }
}

/// What the phone hands the watch (`Shared/WatchSync.swift`, `Services/WatchLink.swift`).
@MainActor
struct WatchSyncTests {
    @Test func aConnectionSurvivesTheTripAsContext() {
        let sent = WatchConnection(kind: .hermesAPI, url: "https://hermes.example:8642/p/sol", apiKey: "k", model: "qwen", provider: "custom:x",
                                   reasoningEffort: "high", replyLanguage: "fr", agentName: "Sol")
        #expect(WatchConnection.from(context: sent.asContext()) == sent)
        #expect(WatchConnection.from(context: [:]) == nil)
    }

    private func phone(_ transport: Transport) -> Settings {
        let settings = Settings(defaults: UserDefaults(suiteName: "watch-\(UUID().uuidString)")!)
        settings.transport = transport
        return settings
    }

    @Test func thePhoneOffersTheFastLaneWhenThatIsAllItHas() {
        let settings = phone(.chatCompletions)
        settings.fastLaneURL = "http://llama.home.example:11500/v1"
        settings.fastLaneModel = "qwen3-4b"
        settings.displayName = "Sol"
        let connection = WatchLink.connection(settings, gatewayKey: { nil })
        #expect(connection?.kind == .fastLane)
        #expect(connection?.url == "http://llama.home.example:11500")
        #expect(connection?.model == "qwen3-4b")
        #expect(connection?.agentName == "Sol")
    }

    /// The Dashboard is a WebSocket, which a watch can't open: the same agent goes over by the
    /// Hermes API instead, profile and all.
    @Test func thePhoneOnTheDashboardHandsOverTheHermesAPI() {
        let settings = phone(.hermesServe)
        settings.serveURL = "https://hermes.example:9119/"
        settings.serveUsername = "sam"
        settings.gatewayURL = "https://hermes.example:8642/"
        settings.hermesProfile = "work"
        settings.fastLaneURL = "http://llama.home.example:11500/v1"
        let connection = WatchLink.connection(settings, gatewayKey: { "k" })
        #expect(connection?.kind == .hermesAPI)
        #expect(connection?.url == "https://hermes.example:8642/p/work")
        #expect(connection?.apiKey == "k")
        #expect(!WatchLink.needsAPI(settings, gatewayKey: { "k" }, dashboardPassword: { "pw" }))
    }

    @Test func withoutAnAPIKeyTheFastLaneStandsInAndTheDashboardNeverDoes() {
        let settings = phone(.hermesServe)
        settings.serveURL = "https://hermes.example:9119/"
        settings.serveUsername = "sam"
        settings.gatewayURL = "https://hermes.example:8642/"
        settings.fastLaneURL = "http://llama.home.example:11500/v1"
        #expect(WatchLink.connection(settings, gatewayKey: { nil })?.kind == .fastLane)
        #expect(!WatchLink.needsAPI(settings, gatewayKey: { nil }, dashboardPassword: { "pw" }))
        // The Dashboard alone: nothing to hand over, and the watch is told what is missing.
        settings.fastLaneURL = ""
        #expect(WatchLink.connection(settings, gatewayKey: { nil }) == nil)
        #expect(WatchLink.needsAPI(settings, gatewayKey: { nil }, dashboardPassword: { "pw" }))
        // No Dashboard login either: the phone simply isn't set up.
        #expect(!WatchLink.needsAPI(settings, gatewayKey: { nil }, dashboardPassword: { nil }))
    }

    @Test func eachPhoneConnectionHandsOverItsOwnWhenTheWatchCanUseIt() {
        let settings = phone(.hermesSessions)
        settings.gatewayURL = "https://hermes.example:8642"
        settings.fastLaneURL = "http://llama.home.example:11500/v1"
        #expect(WatchLink.connection(settings, gatewayKey: { "k" })?.kind == .hermesAPI)
        settings.transport = .chatCompletions
        #expect(WatchLink.connection(settings, gatewayKey: { "k" })?.kind == .fastLane)
    }

    @Test func theNoticeCrossesInPlaceOfAConnection() {
        #expect(WatchConnection.needsAPI(context: [WatchConnection.needsAPIKey: true]))
        #expect(!WatchConnection.needsAPI(context: [:]))
        // A copy from an earlier build, with fields this one no longer has, still reads.
        let old = #"{"kind":"dashboard","url":"http://h:9119","apiKey":"pw","model":"","provider":"","reasoningEffort":"","replyLanguage":"","agentName":"Redde","username":"sam","accessHeaders":{"a":"b"}}"#
        #expect(WatchConnection.from(context: [WatchConnection.contextKey: Data(old.utf8)])?.kind == .dashboard)
    }

    @Test func nothingConfiguredMeansNoConnection() {
        let settings = phone(.chatCompletions)
        settings.fastLaneURL = ""
        #expect(WatchLink.connection(settings, gatewayKey: { nil }) == nil)
        #expect(!WatchLink.needsAPI(settings, gatewayKey: { nil }, dashboardPassword: { nil }))
    }
}
