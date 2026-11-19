import Foundation

/// Where a bot lives when it isn't one of the open Hermes's (2.7, his ask 2026-11-17: "allow all to
/// talk to each other by @mention"): an agent on a saved Redde bridge (Claude Code, Codex, Pi,
/// OpenClaw…), or a bot of another saved Hermes server. Such a bot is a `HermesBot` like any other
/// to the tags, the composer's suggestions and the asides; only its turn goes elsewhere
/// (`TagRoster.transport`).
nonisolated struct BotElsewhere: Hashable, Sendable {
    /// The saved server it's reached by, and what that server is called.
    var server: UUID
    var serverName: String
    /// The bridge's agent; nil for a Hermes bot, which goes by `profile`.
    var agent: String?
    var profile: String?
}

/// Everyone a message can tag, wherever they are: the open Hermes's bots (`BotDirectory`), every
/// agent on every saved bridge, the open bridge's included (all but the chat's own), and the bots
/// of every other saved Hermes. A tagged one is asked in its own chat, and its answer shows in the
/// chat it was tagged in (`BotAsides`), the chat's own agent told with the person's next message
/// (`AsideNote`), on the Dashboard, the Hermes API and a bridge alike.
@MainActor @Observable
final class TagRoster {
    static let shared = TagRoster()

    /// Other saved Hermes servers' bots, by server, as last asked.
    private(set) var hermes: [UUID: [HermesBot]] = [:]
    @ObservationIgnored private var askedAt: Date?
    /// The saved servers as they were when last asked: a change (another server, the open one now
    /// a bridge) asks again at once.
    @ObservationIgnored private var askedOf: [String] = []
    @ObservationIgnored private var asking: Task<Void, Never>?

    /// How often the other servers are asked again, at most.
    static let freshFor: TimeInterval = 120

    /// Everyone but the open Hermes's own bots, which `BotDirectory` has.
    func others(_ settings: Settings = .shared) -> [HermesBot] {
        Self.others(servers: Self.servers(settings), active: settings.activeServerID, agents: { AcpAgents.known(address: $0) }, hermes: hermes,
                    mainName: settings.displayName)
    }

    /// The saved servers, the open one as the app is on it now (its record can lag a moment behind).
    static func servers(_ settings: Settings) -> [HermesServer] {
        settings.servers.map { server in
            guard server.id == settings.activeServerID else { return server }
            var open = server
            open.transport = settings.transport
            open.acpURL = settings.acpURL
            open.acpAgent = settings.acpAgent
            open.acpFolder = settings.acpFolder
            return open
        }
    }

    /// Everyone a message in a chat on `connection` can tag: the open Hermes's bots too, when it
    /// has them.
    func roster(connection: Transport, _ settings: Settings = .shared, dashboard: HermesServeClient = .shared) -> [HermesBot] {
        let own = connection.isHermes && BotDirectory.available(settings, dashboard: dashboard)
            ? BotDirectory.shared.bots(for: settings.connectionKey) : []
        return own + others(settings)
    }

    /// The bridge agents and other servers' bots, from the saved servers as they are: one entry per
    /// agent of a bridge (two servers on one bridge list it once, the open server's first), and
    /// the other Hermes servers' bots as last asked. `mainName` is what the person calls their Hermes
    /// agent (Settings › Name, "Sol"): with one Hermes saved, its main agent goes by it here too.
    nonisolated static func others(servers: [HermesServer], active: UUID, agents: (String) -> [AcpEndpoint.Agent],
                                   hermes: [UUID: [HermesBot]], mainName: String = "") -> [HermesBot] {
        var found: [HermesBot] = []
        var seen = Set<String>()
        // The name is one for all of them, so with two Hermes servers saved it names neither.
        let hermesServers = servers.filter { $0.transport == .hermesServe || $0.transport == .hermesSessions }
        let main = hermesServers.count == 1 ? mainName.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        for server in servers.sorted(by: { a, _ in a.id == active }) {
            switch server.transport {
            case .acp:
                var listed = agents(server.acpURL)
                if listed.isEmpty, let agent = server.acpAgent.nilIfEmpty { listed = [AcpEndpoint.Agent(id: agent, name: agent)] }
                for agent in listed where seen.insert(bridgeKey(server.acpURL, agent.id)).inserted {
                    found.append(bridgeAgent(agent, on: server))
                }
            case .hermesServe, .hermesSessions:
                guard server.id != active else { continue }   // the open one's are BotDirectory's
                for bot in hermes[server.id] ?? [] where !bot.isHidden {
                    found.append(hermesBot(bot, on: server, mainName: main))
                }
            case .chatCompletions:
                continue
            }
        }
        return found
    }

    /// A bridge's agent as a bot: tagged by its id ("@pi", "@codex") or its name ("@claude-code").
    nonisolated static func bridgeAgent(_ agent: AcpEndpoint.Agent, on server: HermesServer) -> HermesBot {
        var bot = HermesBot(name: name(agent.id, server.id), displayName: agent.id,
                            title: agent.name.nilIfEmpty ?? agent.id, description: server.title)
        bot.elsewhere = BotElsewhere(server: server.id, serverName: server.title, agent: agent.id, profile: nil)
        return bot
    }

    /// Another server's bot, under its own name; that server's main agent by `mainName` and by the
    /// server's name (11-19 Marta: in Claude Code's chat "@sol" found nobody: the main agent went
    /// only by its server's name, "Hermes", a word no tag may be, so it couldn't be tagged at all).
    nonisolated static func hermesBot(_ bot: HermesBot, on server: HermesServer, mainName: String = "") -> HermesBot {
        let named = bot.isDefault && bot.title?.nilIfEmpty == nil && bot.displayName?.nilIfEmpty == nil
        var other = HermesBot(name: name(bot.name, server.id), displayName: named && !mainName.isEmpty ? server.title : nil,
                              title: bot.label(mainName: mainName.nilIfEmpty ?? server.title), description: server.title,
                              model: bot.model, face: bot.face)
        other.elsewhere = BotElsewhere(server: server.id, serverName: server.title, agent: nil, profile: bot.name)
        return other
    }

    /// The name an agent elsewhere goes by here (its asides' rows, the note to the chat's agent):
    /// never a profile of the open Hermes's, which can't hold "@".
    nonisolated static func name(_ id: String, _ server: UUID) -> String {
        "\(id)@\(server.uuidString.prefix(8).lowercased())"
    }

    /// The name a chat with a bridge's agent speaks as, for the tags to leave it out.
    nonisolated static func speaker(agent: String, server: UUID) -> String { name(agent, server) }

    /// One bridge however its address is written ("host:8767", "ws://host:8767"): 11-17 Marta's
    /// two servers on Paloma listed every agent twice, and a tag two answer to asks nobody.
    private nonisolated static func bridgeKey(_ address: String, _ agent: String) -> String {
        let place = AcpEndpoint.make(address: address, agent: "", token: nil, folder: nil)?.agentsURL?.absoluteString ?? address
        return place.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "|" + agent
    }

    // MARK: Asking the other servers

    /// Asks the other servers what they have, unless asked lately: each bridge for its agents, each
    /// Hermes for its bots. One that doesn't answer keeps what it had.
    func refreshIfStale(_ settings: Settings = .shared) {
        let servers = Self.signature(settings)
        if let askedAt, Date.now.timeIntervalSince(askedAt) < Self.freshFor, servers == askedOf { return }
        guard asking == nil else { return }
        askedAt = .now
        askedOf = servers
        asking = Task { [weak self] in
            await self?.refresh(settings)
            self?.asking = nil
        }
    }

    func refresh(_ settings: Settings = .shared) async {
        let active = settings.activeServerID
        // All asked at once, each a task of its own, each given `AllServers.patience`.
        var asked: [Task<Void, Never>] = []
        for server in Self.servers(settings) {
            switch server.transport {
            case .acp:
                guard let bridge = Self.bridge(server, agent: "", settings) else { continue }
                let address = server.acpURL
                asked.append(Task {
                    if let agents = try? await Self.within(AllServers.patience, { try await bridge.agents() }), !agents.isEmpty {
                        AcpAgents.remember(agents, address: address)
                    }
                })
            case .hermesServe where server.id != active, .hermesSessions where server.id != active && !server.serveURL.isEmpty:
                let client = AllServers.client(for: server), id = server.id
                asked.append(Task { [weak self] in
                    if let roster = try? await Self.within(AllServers.patience, { try await client.bots() }) {
                        self?.hermes[id] = roster.bots
                    }
                })
            default:
                continue
            }
        }
        for task in asked { await task.value }
        // A server taken off the list takes its bots with it.
        let saved = Set(settings.servers.map(\.id))
        hermes = hermes.filter { saved.contains($0.key) }
    }

    /// What of the saved servers decides who can be asked: each one's kind and address.
    private static func signature(_ settings: Settings) -> [String] {
        settings.servers.map { "\($0.id)|\($0.transport.rawValue)|\($0.acpURL)|\($0.serveURL)" }
            + ["open:\(settings.activeServerID)|\(settings.transport.rawValue)|\(settings.acpURL)"]
    }

    // MARK: A turn elsewhere

    /// Where a turn with a bot elsewhere goes, and the chat it goes on: the bridge agent's own chat
    /// for Redde's asks (nil the first time: the agent makes one, `keep`), or the other Hermes's
    /// bot's Bot Chat.
    static func transport(for place: BotElsewhere, settings: Settings = .shared) async throws -> (any HermesTransport, String?) {
        guard let server = settings.servers.first(where: { $0.id == place.server }) else { throw TransportError.noAPIKey }
        if let agent = place.agent {
            guard let endpoint = bridge(server, agent: agent, settings) else { throw TransportError.noAPIKey }
            return (AcpTransport(endpoint: endpoint), session(for: place))
        }
        let profile = place.profile ?? "default"
        let client = AllServers.client(for: server)
        let (stored, _) = try await client.botChat(for: HermesBot(name: profile, isDefault: profile == "default"))
        client.noteProfile(profile, forStored: stored)
        return (HermesServeTransport(client: client), stored)
    }

    /// The bridge at `server`, for `agent` (empty: the bridge itself), with its token: the open
    /// server's own, or the one filed under the server's id.
    static func bridge(_ server: HermesServer, agent: String, _ settings: Settings = .shared) -> AcpEndpoint? {
        let open = server.id == settings.activeServerID
        let token = open ? Keychain.read(.acpToken) : Keychain.read(account: Keychain.account(.acpToken, server: server.id.uuidString))
        return AcpEndpoint.make(address: open ? settings.acpURL : server.acpURL, agent: agent, token: token,
                                folder: open ? settings.acpFolder : server.acpFolder)
    }

    /// The bridge agent's chat for Redde's asks, once it has one.
    static func session(for place: BotElsewhere) -> String? {
        guard let agent = place.agent else { return nil }
        return UserDefaults.standard.string(forKey: sessionKey(place.server, agent))
    }

    /// Kept when the agent makes it; nil forgets it (the bridge no longer has it).
    static func keep(session: String?, for place: BotElsewhere) {
        guard let agent = place.agent else { return }
        UserDefaults.standard.set(session, forKey: sessionKey(place.server, agent))
    }

    private static func sessionKey(_ server: UUID, _ agent: String) -> String { "tagSession.\(server.uuidString).\(agent)" }

    private static func within<T: Sendable>(_ limit: Duration, _ work: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw CancellationError()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}
