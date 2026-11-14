import Foundation
import Testing
@testable import Echo

/// Every agent on a Redde bridge in one list (`AcpAgents`, asked 2026-11-14): a chat keeps its
/// agent, opening it moves the app to that agent, and New Chat's agents are remembered.
@MainActor
struct AcpAgentsTests {
    private func settings(allAgents: Bool) -> Settings {
        let settings = Settings(defaults: UserDefaults(suiteName: "acp-agents-\(UUID().uuidString)")!)
        settings.transport = .acp
        settings.acpURL = "ws://bridge-\(UUID().uuidString.prefix(8)).test:8767"
        settings.acpAgent = "claude"
        settings.acpAllAgents = allAgents
        return settings
    }

    private func conversation(_ settings: Settings) -> Conversation {
        Conversation(settings: settings, store: ConversationStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "acp-agents-\(UUID().uuidString)")))
    }

    private func record(agent: String?) -> ConversationRecord {
        var record = ConversationRecord(id: UUID(), title: "Fix the build", createdAt: .now, updatedAt: .now, transport: .acp,
                                        serverSessionID: "s-1", messages: [Message(role: .user, text: "Fix the build.")])
        record.acpAgent = agent
        return record
    }

    @Test func aChatOpensOnItsAgent() {
        let settings = settings(allAgents: true)
        let conversation = conversation(settings)
        conversation.load(record(agent: "codex"))
        #expect(settings.acpAgent == "codex")
        #expect(conversation.acpAgent == "codex")
        // A new chat is with the agent the app is on.
        conversation.reset()
        #expect(conversation.acpAgent == "codex")
    }

    @Test func withOneAgentAChatDoesntMoveTheApp() {
        let settings = settings(allAgents: false)
        let conversation = conversation(settings)
        conversation.load(record(agent: "codex"))
        #expect(settings.acpAgent == "claude")
        #expect(conversation.acpAgent == nil)
    }

    @Test func olderCopiesHaveNoAgent() throws {
        let data = try JSONEncoder().encode(record(agent: "codex"))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["acpAgent"] as? String == "codex")
        json["acpAgent"] = nil
        let older = try JSONDecoder().decode(ConversationRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(older.acpAgent == nil)
        #expect(ConversationSummary(record(agent: "codex")).acpAgent == "codex")
    }

    @Test func theBridgesAgentsAreRememberedForNewChat() {
        let settings = settings(allAgents: true)
        #expect(!AcpAgentChoices.asks(settings), "nothing listed yet")
        AcpAgents.remember([.init(id: "claude", name: "Claude Code"), .init(id: "codex", name: "Codex")], settings)
        #expect(AcpAgents.known(settings).map(\.id) == ["claude", "codex"])
        #expect(AcpAgents.name(of: "codex", settings) == "Codex")
        #expect(AcpAgents.name(of: "goose", settings) == "goose")
        #expect(AcpAgentChoices.asks(settings))
        #expect(settings.headerTitle == "Claude Code")
        settings.acpAllAgents = false
        #expect(!AcpAgentChoices.asks(settings))
    }
}
