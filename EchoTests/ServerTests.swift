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
}
