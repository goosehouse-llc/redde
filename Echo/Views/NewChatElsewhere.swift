import SwiftUI

/// New Chat, held: a new chat on another saved connection (asked 2026-11-14, "how do I start a new
/// chat with Claude when Hermes is selected?"). One button per other server; a bridge set to All
/// Agents lists each of its agents. Picking one moves the app to that server, then starts the chat.
struct NewChatElsewhere: View {
    var settings: Settings
    var conversation: Conversation
    var start: () -> Void

    struct Choice: Identifiable {
        var server: UUID
        var agent: String?
        var name: String
        var symbol: String
        var id: String { "\(server)|\(agent ?? "")" }
    }

    var body: some View {
        ForEach(Self.choices(settings)) { choice in
            Button {
                ServerSwitcher.switchTo(choice.server, conversation: conversation, settings: settings)
                if let agent = choice.agent { AcpAgents.use(agent, settings) }
                conversation.reset()   // with the agent the app is on now
                start()
            } label: {
                Label {
                    Text("Chat with \(choice.name)", comment: "New Chat, with every agent on the bridge in one list: start a chat with this agent")
                } icon: {
                    Image(systemName: choice.symbol)
                }
            }
            .accessibilityIdentifier("new-chat-elsewhere-\(choice.name)")
        }
    }

    /// Every other server's chat, once per name (two servers on one bridge list its agents once).
    static func choices(_ settings: Settings) -> [Choice] {
        // The open bridge's own agents are New Chat's already.
        var seen = Set(AcpAgentChoices.asks(settings) ? AcpAgents.known(settings).map(\.name) : [])
        var choices: [Choice] = []
        for server in settings.servers where server.id != settings.activeServerID && server.transport != .chatCompletions {
            let agents = server.transport == .acp && server.acpAllAgents ? AcpAgents.known(address: server.acpURL) : []
            let here: [Choice] = agents.count > 1
                ? agents.map { Choice(server: server.id, agent: $0.id, name: $0.name, symbol: "terminal") }
                : [Choice(server: server.id, agent: nil, name: server.title, symbol: server.transport == .acp ? "terminal" : "bubble.left")]
            for choice in here where seen.insert(choice.name).inserted { choices.append(choice) }
        }
        return choices
    }
}
