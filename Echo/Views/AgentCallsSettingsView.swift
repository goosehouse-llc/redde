import SwiftUI

/// Settings → Notifications → Calls from Agents (`AgentCalls`): calls on or off on this iPhone,
/// and which agents on the server in use may call it.
struct AgentCallsSettingsView: View {
    @State private var settings = Settings.shared
    @State private var calls = AgentCalls.shared
    @State private var push = PushService.shared
    @State private var bots = BotDirectory.shared

    var body: some View {
        Form {
            Section {
                Toggle("Let Agents Call Me", isOn: Binding(
                    get: { settings.agentCalls },
                    set: { on in
                        settings.agentCalls = on
                        if on, settings.callersHere.isEmpty { settings.callersHere = ["default"] }
                        calls.settingsChanged()
                    }))
            } footer: {
                Text("An agent you allow rings this iPhone like a phone call when something shouldn't wait, on the Lock Screen too. Answer, and voice mode opens in its chat: it says why it called, and you talk, hands-free, until one of you hangs up. Not answered, it is a missed call that says what it was about.")
            }
            if settings.agentCalls {
                if let problem {
                    Section {
                        Label(problem.text, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        if let link = problem.link {
                            NavigationLink(link.title) { link.destination }
                        }
                    }
                }
                Section {
                    Toggle(settings.headerTitle, isOn: allows("default"))
                    ForEach(botList, id: \.name) { bot in
                        Toggle(bot.label(mainName: settings.headerTitle), isOn: allows(bot.name))
                    }
                } header: {
                    Text("Who Can Call")
                } footer: {
                    Text("Each agent rings at most once in five minutes (one minute after a call you answered), and all of them twenty times a day. On Hermes 0.21 a bot's own chat runs as the main agent, so there only the main agent calls.")
                }
                Section {
                    Toggle("Talk While Locked", isOn: $settings.callsWhileLocked)
                } footer: {
                    settings.callsWhileLocked
                        ? Text("A call answered on a locked iPhone listens straight away, so whoever answers can talk with your agent, as with AirPods and the iPhone in a pocket. With Redde's Face ID lock on, it always waits for Redde to be unlocked.")
                        : Text("A call answered on a locked iPhone says why the agent called, then waits for you to unlock it before it listens, so nobody else who picks it up can talk with your agent. With Redde's Face ID lock on, it always waits for Redde to be unlocked.")
                }
                Section {
                } footer: {
                    Text("Calls need the Redde plugin 1.8.0 on your Hermes, this iPhone paired for notifications, and the Dashboard login.")
                }
            }
        }
        .navigationTitle("Calls from Agents")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if settings.agentCalls { calls.publish() }
            if BotDirectory.available(settings), bots.bots(for: settings.connectionKey).isEmpty { _ = try? await bots.refresh() }
        }
    }

    private var botList: [HermesBot] {
        bots.bots(for: settings.connectionKey).filter { !$0.isDefault }
    }

    private func allows(_ profile: String) -> Binding<Bool> {
        Binding(
            get: { settings.callersHere.contains(profile) },
            set: { on in
                var callers = settings.callersHere.filter { $0 != profile }
                if on { callers.append(profile) }
                settings.callersHere = callers
                calls.settingsChanged()
            })
    }

    private struct Problem {
        struct Link {
            var title: String
            var destination: AnyView
        }
        var text: String
        var link: Link?
    }

    /// What keeps calls from coming, if anything, and where to put it right.
    private var problem: Problem? {
        if !push.pairings.contains(where: \.isPaired) {
            return Problem(text: String(localized: "Pair this iPhone for notifications first: calls come the same way."),
                           link: .init(title: String(localized: "Notify When Redde Is Closed"), destination: AnyView(PushSettingsView())))
        }
        if settings.serveBaseURL == nil {
            return Problem(text: String(localized: "Calls need the Dashboard login, which is how Redde tells your Hermes who may call."))
        }
        switch calls.status {
        case .oldPlugin, .noPlugin:
            return Problem(text: String(localized: "Calls need the Redde plugin 1.8.0 or later on your Hermes."),
                           link: .init(title: String(localized: "Redde Plugin"), destination: AnyView(ReddePluginView())))
        case .noPairing:
            return Problem(text: String(localized: "This iPhone isn't paired with the Hermes Redde is on now, so it can't call you. Pair it from Notify When Redde Is Closed."),
                           link: .init(title: String(localized: "Notify When Redde Is Closed"), destination: AnyView(PushSettingsView())))
        case .noDashboard:
            return Problem(text: String(localized: "Calls need the Dashboard login, which is how Redde tells your Hermes who may call."))
        case .failed(let reason):
            return Problem(text: String(localized: "Couldn't tell your Hermes who may call: \(reason)"))
        case .ready, .unknown:
            return nil
        }
    }
}
