// Conversation's model picks, the Hermes API clients it uses, and its name.
import Foundation

extension Conversation {
    /// Ledger client for listing/reading sessions. Nil without a gateway URL and key.
    // MARK: - Model switching

    /// Re-pins the open conversation's model on the backend. Both hermes backends pin a
    /// conversation's model once it has one, so a change must move the pin: the Hermes API via
    /// the model-lock route, the Dashboard via `config.set` (session-scoped). Nothing to do on
    /// the fast lane, where the model goes on every request, or before a session exists.
    func pinOpenSessionModel(_ model: String, provider: String?) async throws {
        guard let sid = serverSessionID else { return }
        switch connection {
        case .hermesSessions:
            guard let api = ledgerAPI() else { return }
            try await api.lockSessionModel(id: sid, model: model, provider: provider)
        case .hermesServe:
            try await dashboard.withLiveSession(stored: sid) { runtime in
                try await dashboard.setSessionModel(runtimeSession: runtime, model: model, provider: provider)
            }
        case .acp:
            try await AcpClient.current(settings)?.setModel(sid, value: model)
        case .chatCompletions:
            break
        }
    }

    /// Switches to a model the way the picker does: on the fast lane, the setting, for every later
    /// turn; on Hermes, this conversation's own pick (`pickOwnModel`), and the open conversation
    /// is re-pinned. Sticky: it stays until the picker or another switch moves it. Used by
    /// spoken prefixes.
    func switchModel(_ model: String, provider: String?) async throws {
        if settings.transport == .chatCompletions {
            settings.fastLaneModel = model
            return
        }
        let provider = Self.liveProvider(for: model, saved: provider, in: await listedModels())
        pickOwnModel(ConversationModels.Pick(model: model, provider: provider))
        try await pinOpenSessionModel(model, provider: provider)
    }

    /// The model this conversation's own pick names: kept with its session, or held until the first message makes one. Nil: none picked, so it
    /// is on its bot's model or the server's.
    var ownModel: ConversationModels.Pick? {
        guard let serverSessionID else { return unsentModel }
        return models.pick(connection: settings.connectionKey, session: serverSessionID)
    }

    /// Picks this conversation's own model (nil: back to its bot's or the server's), leaving every
    /// other conversation as it is. The caller re-pins an open session.
    func pickOwnModel(_ pick: ConversationModels.Pick?) {
        if let serverSessionID {
            models.set(pick, connection: settings.connectionKey, session: serverSessionID)
        } else {
            unsentModel = pick
        }
    }

    /// The model this conversation's next Hermes turn asks for (`ConversationModels.turnModel`):
    /// its own pick; nil for its bot's or the server's.
    var turnModel: ConversationModels.Pick? { ConversationModels.turnModel(own: ownModel) }

    /// The provider to send with `model`, checked against what the backend lists right now. A
    /// saved slug is only a memory of a past list: the host may have renamed or removed that
    /// provider, the pick may come from another profile or server, or there is none (a rule made
    /// on the fast lane). Hermes fails the whole turn on a provider it doesn't know, and a model
    /// sent without one goes to the default endpoint, which may not serve it. So:
    /// - the saved provider stays while it still lists the model — except the bare "custom"
    ///   bucket when it isn't the host's current provider and a named endpoint lists the model
    ///   too: that row is a config leftover with no endpoint behind it ("Unknown provider
    ///   'custom:custom'");
    /// - else a provider that lists the model, a named endpoint first;
    /// - else the saved one if it is still there (hidden models serve by name);
    /// - else the host's current provider.
    /// Nothing changes when the list couldn't be read.
    nonisolated static func liveProvider(for model: String, saved: String?, in choices: [ModelChoice]) -> String? {
        guard !choices.isEmpty else { return saved }
        let saved = saved?.nilIfEmpty
        let serving = choices.filter { $0.model == model }
        let named = serving.first { $0.provider != "custom" }
        if let saved, serving.contains(where: { $0.provider == saved }) {
            let bareLeftover = saved == "custom" && !choices.contains { $0.provider == "custom" && $0.isCurrent }
            return bareLeftover ? named?.provider ?? saved : saved
        }
        if let other = named ?? serving.first { return other.provider }
        if let saved, choices.contains(where: { $0.provider == saved }) { return saved }
        return choices.first(where: \.isCurrent)?.provider
    }

    /// What the backend lists right now, or nothing when it can't say within a few seconds: a
    /// spoken turn waits on this, and a slow list must not hold it up.
    func listedModels() async -> [ModelChoice] {
        guard let backend = SessionBackend.available(self, settings: settings).first else { return [] }
        return await withTaskGroup(of: [ModelChoice]?.self) { group in
            group.addTask { try? await backend.modelOptions() }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    func ledgerAPI() -> HermesSessionsAPI? { ledgerAPI(profile: apiProfile) }

    /// The Hermes API as this conversation reaches it: the app's, or an API bot's at
    /// /p/<profile>/ with that profile's own key.
    func ledgerAPI(for bot: BotRef?) -> HermesSessionsAPI? { ledgerAPI(profile: bot?.viaAPI == true ? bot?.profile : nil) }

    /// The Hermes API for a profile at /p/<profile>/ with its own key; nil, the app's.
    func ledgerAPI(profile: String?) -> HermesSessionsAPI? {
        // An ACP server's record may still hold a Hermes address from before; it isn't this chat's.
        guard settings.transport != .acp, let endpoint = settings.gatewayEndpoint(profile: profile) else { return nil }
        return HermesSessionsAPI(baseURL: endpoint.url, apiKey: endpoint.key, headers: settings.apiHeaders)
    }

    // MARK: Name

    /// Names the conversation. A gateway session is renamed on the gateway first, so the list,
    /// the Dashboard and the header agree; titles there must be unique, so it can refuse. An
    /// empty name takes a local conversation back to its first question (a gateway session
    /// keeps the title it has).
    func rename(to newName: String) async throws {
        // A bot's chat is known by its title on the server: renaming it would lose it.
        guard bot == nil else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if connection == .acp {
            // Named on the agent where it keeps names (Claude Code, or its bridge for it); otherwise
            // the name is this device's (`AcpTitles`), which the list's next read keeps (it put
            // the old name back before, 2026-11-14).
            if let sessionID = serverSessionID, !trimmed.isEmpty {
                AcpTitles.set(trimmed, for: sessionID)
                if let client = settings.acpEndpoint(agent: acpAgent).map(AcpClient.client(for:)),
                   (try? await client.setTitle(sessionID, title: trimmed)) == true {
                    AcpTitles.set(nil, for: sessionID)
                }
            }
        } else if let sessionID = serverSessionID {
            guard !trimmed.isEmpty else { return }
            guard let backend = SessionBackend.current(self, settings: settings) else {
                throw TransportError.malformed(SessionBackend.notConfiguredMessage)
            }
            try await backend.rename(sessionID, to: trimmed)
        }
        setName(trimmed.isEmpty ? nil : trimmed)
    }

    /// The gateway's list of sessions, just loaded: the open session's title there, when it is a
    /// name, is this conversation's name. That picks up a rename made in the list or the
    /// Dashboard, and the title Hermes gives a session by itself.
    func noteServerTitles(_ sessions: [HermesSessionsAPI.SessionSummary]) {
        // A bot's chat goes by its bot, whatever its title ("Bot Chat") says.
        guard bot == nil, let sessionID = serverSessionID, let session = sessions.first(where: { $0.id == sessionID }) else { return }
        setName(Self.name(fromServerTitle: session.title, firstQuestion: messages.first { $0.role == .user && !$0.isSteer }?.text))
    }

    func setName(_ new: String?) {
        guard new != name else { return }
        name = new
        persist()
    }

    /// A gateway title as a conversation's name: nil when there is none, and nil for the title
    /// Redde itself gives a new session (`sessionTitle(from:)`: the start of the first question,
    /// " · ", a timestamp), which says nothing the question doesn't.
    nonisolated static func name(fromServerTitle title: String?, firstQuestion: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        if let firstQuestion, title.hasPrefix(firstQuestion.prefix(48) + " · ") { return nil }
        return title
    }

    static func sessionTitle(from text: String) -> String {
        // Titles must be unique on the gateway; a timestamp keeps repeats ("hi") from colliding.
        let stamp = Date.now.formatted(date: .abbreviated, time: .shortened)
        return "\(text.prefix(48)) · \(stamp)"
    }
}
