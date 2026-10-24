import Foundation

/// The chat list with All Servers on (his ask 2026-10-22, after a Reddit request: several gateways
/// in one list, each row tagged with its server). The app is on one server at a time; every other
/// saved one is asked for its chats on its own, by the connection it is used with (its Dashboard,
/// or its Hermes API at its profile's /p/<profile>/) and the secrets filed under its id, and its
/// rows carry a `ServerTag`. A row of another server's opens by switching to that server.
@MainActor
enum AllServers {
    /// How long another server may take: one that is off doesn't hold up the merged list.
    static let patience: Duration = .seconds(8)

    /// Every other saved server's chats, each row tagged, and the names of those that didn't answer.
    static func otherServers(_ settings: Settings = .shared) async -> (rows: [HermesSessionsAPI.SessionSummary], unreachable: [String]) {
        await listing(settings.servers.filter { $0.id != settings.activeServerID })
    }

    /// These servers' chats, each row tagged, and the names of those that didn't answer.
    static func listing(_ others: [HermesServer]) async -> (rows: [HermesSessionsAPI.SessionSummary], unreachable: [String]) {
        // All asked at once: each a task of its own, each given `patience`.
        let asked = others.map { server in (server, Task { await sessionsWithin(server) }) }
        var rows: [HermesSessionsAPI.SessionSummary] = []
        var unreachable: [String] = []
        for (server, task) in asked {
            if let found = await task.value { rows += found } else { unreachable.append(server.title) }
        }
        return (rows, unreachable.sorted())
    }

    /// One server's chats for its own profile (as its record has it), tagged with it. A bot's chat
    /// and a group chat's session are left out, as on the server the app is on.
    static func sessions(of server: HermesServer) async throws -> [HermesSessionsAPI.SessionSummary] {
        let tag = ServerTag(id: server.id, name: server.title)
        let found: [HermesSessionsAPI.SessionSummary]
        switch server.transport {
        case .hermesServe: found = try await client(for: server).listSessions()
        case .hermesSessions:
            guard let api = api(for: server) else { throw TransportError.missingAPIKey }
            found = try await api.listSessions()
        case .chatCompletions: return []
        }
        return found.filter { $0.title != BotChat.title && !($0.title ?? "").hasPrefix("Group: ") }.map { row in
            var row = row
            row.otherServer = tag
            return row
        }
    }

    /// A Dashboard client of the server's own, kept while its record stays the same (its login
    /// cookie with it).
    static func client(for server: HermesServer) -> HermesServeClient {
        if let kept = clients[server.id], kept.server == server { return kept.client }
        let id = server.id.uuidString
        let client = HermesServeClient(settings: RemoteServer(server),
                                       password: { Keychain.read(account: Keychain.account(.serveDashboardPassword, server: id)) },
                                       tokens: DashboardTokenStore.keychain(server: id))
        clients[server.id] = (server, client)
        return client
    }

    private static var clients: [UUID: (server: HermesServer, client: HermesServeClient)] = [:]

    /// The server's Hermes API for its profile: the profile's own key when one is saved, else the main one.
    static func api(for server: HermesServer) -> HermesSessionsAPI? {
        guard var base = Settings.normalizedBase(server.gatewayURL) else { return nil }
        let id = server.id.uuidString
        var key = Keychain.read(account: Keychain.account(.gatewayAPIKey, server: id))?.nilIfEmpty
        if let profile = RemoteServer.profile(of: server) {
            base = base.appending(path: "p/\(profile)")
            key = Keychain.read(account: Keychain.profileAccount(profile, server: id))?.nilIfEmpty ?? key
        }
        guard let key else { return nil }
        return HermesSessionsAPI(baseURL: base, apiKey: key, headers: RemoteServer.apiHeaders(of: server))
    }

    /// A row of a server that has since been taken off this phone.
    struct Gone: LocalizedError {
        var name: String
        var errorDescription: String? { "\(name) isn't one of your servers any more." }
    }

    /// One server's chats, or nil when it can't be reached in time.
    private static func sessionsWithin(_ server: HermesServer) async -> [HermesSessionsAPI.SessionSummary]? {
        let work = Task { try await sessions(of: server) }
        let timer = Task {
            try? await Task.sleep(for: patience)
            work.cancel()
        }
        defer { timer.cancel() }
        return try? await work.value
    }
}

/// Another saved server as the Dashboard client needs it: its address, login name, profile and
/// headers, from its record and the secrets filed under its id.
@MainActor
final class RemoteServer: ServeEndpoint {
    let server: HermesServer

    init(_ server: HermesServer) { self.server = server }

    var serveBaseURL: URL? {
        let raw = server.serveURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: raw.hasSuffix("/") ? String(raw.dropLast()) : raw)
    }

    var serveUsername: String { server.serveUsername }
    var profileName: String? { Self.profile(of: server) }

    var accessHeaders: [String: String] {
        let secret = Keychain.read(account: Keychain.account(.cfAccessClientSecret, server: server.id.uuidString))
        return Self.customHeaders(of: server)
            .merging(Settings.cloudflareAccessHeaders(clientID: server.cfAccessClientID, secret: secret)) { _, access in access }
            .merging(Settings.pangolinHeaders(Self.pangolin(.pangolinDashboard, of: server) ?? Self.pangolin(.pangolinAPI, of: server))) { _, token in token }
    }

    /// What its Hermes API is sent besides the key, as `Settings.apiHeaders` for the active server.
    static func apiHeaders(of server: HermesServer) -> [String: String] {
        customHeaders(of: server)
            .merging(Settings.pangolinHeaders(pangolin(.pangolinAPI, of: server) ?? pangolin(.pangolinDashboard, of: server))) { _, token in token }
    }

    private static func pangolin(_ item: Keychain.Item, of server: HermesServer) -> String? {
        Keychain.read(account: Keychain.account(item, server: server.id.uuidString))
    }

    /// Its profile, as `Settings.profileName` reads the app's: none for the main one.
    static func profile(of server: HermesServer) -> String? {
        let name = server.hermesProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.lowercased() == "default" ? nil : name
    }

    static func customHeaders(of server: HermesServer) -> [String: String] {
        CustomHeader.fields(CustomHeader.decode(Keychain.read(account: Keychain.account(.customHeaders, server: server.id.uuidString))))
    }
}
