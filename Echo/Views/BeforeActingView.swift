import SwiftUI

/// Settings → Agent → Before Acting (`AgentAutonomy`): how much each agent may do unasked.
struct BeforeActingView: View {
    @State private var levels: [String: AgentAutonomy.Level] = [:]
    private let settings = Settings.shared

    /// Your agent and, where there are bots, each of them.
    private var agents: [(profile: String, name: String)] {
        var out: [(String, String)] = [("default", settings.headerTitle)]
        if BotDirectory.available(), BotDirectory.shared.key == settings.connectionKey {
            for bot in BotDirectory.shared.roster?.listed ?? [] where !bot.isDefault { out.append((bot.name, bot.label(mainName: settings.headerTitle))) }
        }
        return out
    }

    var body: some View {
        Form {
            ForEach(agents, id: \.profile) { agent in
                Section {
                    Picker(agent.name, selection: Binding(get: { levels[agent.profile] ?? AgentAutonomy.level(agent.profile) },
                                                          set: { levels[agent.profile] = $0; AgentAutonomy.set(agent.profile, $0) })) {
                        ForEach(AgentAutonomy.Level.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text((levels[agent.profile] ?? AgentAutonomy.level(agent.profile)).detail)
                }
            }
            Section {
            } footer: {
                Text("This is about your errands: messages, bookings, orders. Commands on your server still ask as Hermes is set to. Needs the Hermes Dashboard login and Redde's plugin 1.9 on your Hermes.")
            }
        }
        .navigationTitle("Before Acting")
        .navigationBarTitleDisplayMode(.inline)
    }
}
