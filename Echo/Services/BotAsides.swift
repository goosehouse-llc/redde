import Foundation

/// @tags in a normal chat (asked 2026-10-28): "@Home is the garage shut?" in a chat with the main
/// agent goes to Home, in Home's own Bot Chat, and Home's answer shows here under its face as it
/// is written. Hermes gives the agent of a normal chat no message_agent tool (only a Bot Chat has
/// one), so Redde does the asking, on either connection. The main agent hears of it with the
/// person's next message to it (`AsideNote`): no turn of its own, no wait. The note is kept on the
/// host with that message, which is how the exchange comes back when the chat is read again.
nonisolated enum BotAsides {
    /// The bots a message to this chat's agent tags, when it should go to them instead: a normal
    /// chat on a Hermes with bots, the message plain text.
    static func tagged(in text: String, roster: [HermesBot], speaking: String) -> [HermesBot] {
        guard text.contains("@"), !text.hasPrefix("/") else { return [] }
        return BotMentions.mentioned(in: text, roster: roster, to: speaking)
    }

    /// What goes to the tagged bot with the person's words. Words to the model: English.
    static func note(from chat: String) -> String {
        "\n\n[Redde: the user tagged you in their chat with \(chat), not here; your answer is shown to them there. Answer them directly.]"
    }
}

/// One turn with a bot in its own Bot Chat, from outside any open conversation: a tag in a normal
/// chat (`Conversation`'s asides) and Shortcuts' Ask a Redde Bot a Question, which an automation
/// can run with Redde in the background (asked 2026-10-28: "When I get home, ask Home to warm the
/// house"). On the Dashboard, or (a bot added for the Hermes API alone) at /p/<profile>/ with its
/// own key.
@MainActor
enum BotTurns {
    static func transport(for bot: HermesBot, mainName: String, settings: Settings = .shared,
                          dashboard: HermesServeClient = .shared) async throws -> (any HermesTransport, String) {
        if bot.viaAPI {
            let name = bot.label(mainName: mainName)
            guard let endpoint = settings.gatewayEndpoint(profile: bot.name) else { throw APIBotProblem.noKey(name) }
            let api = HermesSessionsAPI(baseURL: endpoint.url, apiKey: endpoint.key, headers: settings.apiHeaders)
            let found = try await APIBotChat.find(api)
            let summary = if let found { found } else { try await api.createSession(title: BotChat.title) }
            return (HermesSessionsTransport(baseURL: api.baseURL, apiKey: api.apiKey, headers: api.headers), summary.id)
        }
        let (stored, _) = try await dashboard.botChat(for: bot)
        dashboard.noteProfile(bot.name, forStored: stored)
        return (HermesServeTransport(client: dashboard), stored)
    }

    /// The bot's answer to `text`, whole. A question it can only go on with the person's answer to
    /// (an approval) is left waiting in its chat.
    /// `departure`: left by the caller that can wait no longer (a place's trigger, in the
    /// background): the turn goes on, on the host, its reply in the bot's chat.
    static func ask(_ bot: HermesBot, _ text: String, settings: Settings = .shared, departure: TurnDeparture = TurnDeparture()) async throws -> String {
        let (transport, stored) = try await transport(for: bot, mainName: settings.headerTitle, settings: settings)
        var request = TurnRequest(userText: text, history: [], sessionID: stored, model: nil, provider: nil, reasoningEffort: nil,
                                  instructions: nil, attachments: [], replyLanguage: settings.replyLanguage.nilIfEmpty, brief: false)
        request.departure = departure
        var written = ""
        stream: for try await event in transport.stream(request) {
            switch event {
            case let .textDelta(delta): written += delta
            case let .textFinal(final): written = final
            case .interrupt:
                departure.leave()   // it goes on in its chat once answered there
                return String(localized: "\(bot.label(mainName: settings.headerTitle)) is waiting for you in its chat.")
            default: continue
            }
        }
        return written.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
