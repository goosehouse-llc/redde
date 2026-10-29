import Foundation
import Testing
@testable import Echo

/// A conversation on another profile than the app's (2026-10-29: the app was left on a research
/// profile, unseen, and Sol's idea cards went there): it carries its profile, and the header,
/// the composer and the chat list name it.
@MainActor
struct ProfileRouteTests {
    private func settings(profile: String = "") -> Settings {
        let settings = Settings(defaults: UserDefaults(suiteName: "route-test-\(UUID().uuidString)")!)
        settings.gatewayURL = "https://hermes.test:8642"
        settings.serveURL = "http://serve.test:9119"
        settings.serveUsername = "redde"
        settings.hermesProfile = profile
        settings.displayName = "Sol"
        return settings
    }

    private func conversation(_ settings: Settings) -> Conversation {
        Conversation(settings: settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "route-\(UUID().uuidString)")))
    }

    @Test func theAgentIsNamedForTheProfileInUse() {
        let main = settings()
        #expect(ProfileCatalog.agentName(nil, settings: main) == main.headerTitle)
        #expect(ProfileCatalog.agentName("default", settings: main) == main.headerTitle)
        let research = settings(profile: "research")
        #expect(ProfileCatalog.agentName(research.profileName, settings: research) == "research", "not the main agent's name")
    }

    @Test func anIdeaFromTheMainAgentStartsThereWhateverProfileTheAppIsOn() {
        let research = settings(profile: "research")
        let onResearch = conversation(research)
        ProfileCatalog.startConversation(on: "default", conversation: onResearch, settings: research)
        #expect(onResearch.elsewhere == ProfileRoute(profile: "default", viaAPI: research.transport == .hermesSessions))
        #expect(research.profileName == "research", "the app stays on its profile")

        let main = settings()
        let onMain = conversation(main)
        ProfileCatalog.startConversation(on: "default", conversation: onMain, settings: main)
        #expect(onMain.elsewhere == nil, "the profile in use: an ordinary fresh conversation")
    }

    @Test func aNewSessionsOwnProfileIsNotOverriddenByTheAppsOne() {
        let client = HermesServeClient(settings: settings(profile: "research"), password: { "pw" })
        let named = JSONValue.object(["profile": .string("default"), "source": .string("desktop")])
        #expect(client.withProfile(named, for: "session.create")["profile"]?.string == "default")
    }
}
