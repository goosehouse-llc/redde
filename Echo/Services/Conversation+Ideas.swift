import Foundation

extension Conversation {
    /// An idea taken (Do It on its card, or on the Your Day widget): its request goes to the agent
    /// that offered it, as the person's message, in a new conversation with the main agent or in
    /// the bot's chat. A bot gone since: the main agent.
    func take(_ idea: AgentIdea, settings: Settings = .shared) async throws {
        if idea.profile != "default", let bot = BotDirectory.shared.roster?.bots.first(where: { $0.name == idea.profile }) {
            try await openBot(bot, mainName: settings.headerTitle)
        } else if idea.profile != (settings.profileName ?? ProfileCatalog.defaultID) {
            // The agent that offered it, whichever profile the app is on (2026-10-29: Sol's
            // ideas went to the research profile the app was left on, and Claude Code
            // answered them without the calendar).
            ProfileCatalog.startConversation(on: idea.profile, conversation: self, settings: settings)
        } else if bot != nil || elsewhere != nil || hasMessages || !outbox.isEmpty {
            reset()
        }
        send(AgentIdea.message(for: idea))
    }
}
