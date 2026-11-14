import SwiftUI

/// New Chat's choice of agent, with every agent on a bridge in one list (`AcpAgents`): one button
/// per agent, the one the app is on ticked.
struct AcpAgentChoices: View {
    var settings: Settings
    var start: () -> Void

    var body: some View {
        ForEach(AcpAgents.known(settings)) { agent in
            Button {
                AcpAgents.use(agent.id, settings)
                start()
            } label: {
                Label {
                    Text("Chat with \(agent.name)", comment: "New Chat, with every agent on the bridge in one list: start a chat with this agent")
                } icon: {
                    Image(systemName: agent.id == settings.acpAgent ? "checkmark" : "terminal")
                }
            }
            .accessibilityIdentifier("new-chat-agent-\(agent.id)")
        }
    }

    /// New Chat asks which agent: every agent in one list, and more than one to pick from.
    static func asks(_ settings: Settings) -> Bool {
        settings.transport == .acp && settings.acpAllAgents && AcpAgents.known(settings).count > 1
    }
}
