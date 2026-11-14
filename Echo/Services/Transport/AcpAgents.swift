import Foundation

/// Every agent on a Redde bridge in one chat list (asked 2026-11-14, picked from three: "One list,
/// all agents"). Each agent's chats are listed over its own socket and tagged with it; a chat opens
/// on its agent, and New Chat asks which. The app still talks to one agent at a time: with
/// `Settings.acpAllAgents` on, the server's `acpAgent` follows the open chat (`use`), so every
/// screen that asks `AcpClient.current` gets the open chat's agent.
@MainActor
enum AcpAgents {
    /// How long one agent may take to list its chats: one that's slow to start doesn't hold up
    /// the others'.
    static let patience: Duration = .seconds(15)

    /// The bridge's agents as last listed, for New Chat's menu before the list has been asked.
    static func known(_ settings: Settings = .shared) -> [AcpEndpoint.Agent] {
        guard let key = key(settings), let data = UserDefaults.standard.data(forKey: key),
              let agents = try? JSONDecoder().decode([AcpEndpoint.Agent].self, from: data) else { return [] }
        return agents
    }

    /// Kept for `known`, whenever the bridge lists them.
    static func remember(_ agents: [AcpEndpoint.Agent], _ settings: Settings = .shared) {
        guard let key = key(settings), let data = try? JSONEncoder().encode(agents) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Per bridge address (the agents are the bridge's, whichever is picked).
    private static func key(_ settings: Settings) -> String? {
        AcpEndpoint.make(address: settings.acpURL, agent: "", token: nil, folder: nil)?.agentsURL.map { "acpAgents." + $0.absoluteString }
    }

    /// Every agent's chats, newest first, each row tagged with its agent. An agent that doesn't
    /// answer is left out; when none does, the first error is thrown.
    static func everyAgent(_ settings: Settings = .shared) async throws -> [HermesSessionsAPI.SessionSummary] {
        guard let bridge = settings.acpEndpoint else { throw TransportError.noAPIKey }
        let agents = try await bridge.agents()
        if !agents.isEmpty { remember(agents, settings) }
        let token = bridge.token
        let asked = agents.compactMap { agent -> (AcpEndpoint.Agent, Task<[HermesSessionsAPI.SessionSummary], Error>)? in
            guard let endpoint = AcpEndpoint.make(address: settings.acpURL, agent: agent.id, token: token, folder: settings.acpFolder) else { return nil }
            return (agent, Task { try await within(patience) { @MainActor in AcpSessions.summaries(try await AcpClient.client(for: endpoint).listSessions()) } })
        }
        var rows: [HermesSessionsAPI.SessionSummary] = []
        var firstError: Error?
        var answered = 0
        for (agent, task) in asked {
            do {
                rows += try await task.value.map { row in
                    var row = row
                    row.acpAgent = agent.id
                    return row
                }
                answered += 1
            } catch {
                firstError = firstError ?? error
            }
        }
        if answered == 0, let firstError { throw firstError }
        return rows.sorted { ($0.lastActiveDate ?? .distantPast) > ($1.lastActiveDate ?? .distantPast) }
    }

    /// What an agent is called: the bridge's name for it, else its id.
    static func name(of agent: String, _ settings: Settings = .shared) -> String {
        known(settings).first { $0.id == agent }?.name ?? agent
    }

    /// One agent's own client on this bridge, for a row of its (rename, delete).
    static func client(for agent: String, _ settings: Settings = .shared) -> AcpClient? {
        AcpEndpoint.make(address: settings.acpURL, agent: agent, token: Keychain.read(.acpToken), folder: settings.acpFolder).map(AcpClient.client(for:))
    }

    /// The open chat's agent made the server's (with every agent in one list), so the screens
    /// that ask the server's agent ask this one.
    static func use(_ agent: String?, _ settings: Settings = .shared) {
        guard settings.transport == .acp, settings.acpAllAgents, let agent = agent?.nilIfEmpty, agent != settings.acpAgent else { return }
        settings.acpAgent = agent
    }

    /// A chat no agent is known for, loaded from whichever of the others has it; the app is left on
    /// that agent. None has it: the app goes back to the agent it was on, and `error` is thrown.
    static func find(_ session: String, failing error: AcpError, _ settings: Settings = .shared) async throws -> [JSONValue] {
        let start = settings.acpAgent
        for agent in known(settings) where agent.id != start {
            use(agent.id, settings)
            guard let client = AcpClient.current(settings) else { continue }
            if let found = try? await within(patience, { @MainActor in try await client.load(session) }) { return found }
        }
        use(start, settings)
        throw error
    }

    /// Pairs this device with the bridge for its notifications. The bridge keeps a pairing per
    /// agent, so with every agent in one list each of the others is paired too, quietly: one that
    /// doesn't answer is left as it was.
    static func pair(through client: AcpClient, _ settings: Settings = .shared) async throws -> PushPairing {
        let pairing = try await PushService.shared.pairDirectly(through: PushService.command(overACP: client))
        guard settings.transport == .acp, settings.acpAllAgents else { return pairing }
        for agent in known(settings) where agent.id != settings.acpAgent {
            guard let other = self.client(for: agent.id, settings) else { continue }
            _ = try? await within(patience) { @MainActor in try await PushService.shared.pairDirectly(through: PushService.command(overACP: other)) }
        }
        return pairing
    }

    /// Gives up on `work` after `limit`.
    private static func within<T: Sendable>(_ limit: Duration, _ work: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw TransportError.streamLost(String(localized: "The agent didn't answer in time.", comment: "An ACP agent that didn't list its chats in time"))
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}
