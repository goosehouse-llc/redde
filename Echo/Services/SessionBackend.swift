import Foundation

/// One seam for "which server owns the sessions": hermes serve's WS RPCs or the gateway
/// ledger's REST. Screens ask for the current backend instead of branching on the transport —
/// the copies of `if viaServe { … } else if let api = ledgerAPI() { … }` live here now.
@MainActor
enum SessionBackend {
    case serve(HermesServeClient)
    case ledger(HermesSessionsAPI)
    /// An ACP agent's own sessions (`session/list`, `session/load`): no titles to set, pins,
    /// unread marks or archive, which ACP version 1 hasn't got.
    case acp(AcpClient)

    /// The backend for the active transport, or nil when it isn't configured yet.
    static func current(_ conversation: Conversation, settings: Settings = .shared) -> SessionBackend? {
        if settings.transport == .acp { return AcpClient.current(settings).map(SessionBackend.acp) }
        return settings.transport == .hermesServe ? .serve(.shared) : conversation.ledgerAPI().map(SessionBackend.ledger)
    }

    /// The chat list's: the selected profile's sessions, whichever conversation is open (one of a
    /// bot's, or another profile's, goes by its own).
    static func list(_ conversation: Conversation, settings: Settings = .shared) -> SessionBackend? {
        if settings.transport == .acp { return AcpClient.current(settings).map(SessionBackend.acp) }
        return settings.transport == .hermesServe ? .serve(.shared) : conversation.ledgerAPI(profile: nil).map(SessionBackend.ledger)
    }

    private static var notOnACP: AcpError {
        AcpError(code: -32601, message: String(localized: "This agent doesn't keep that for its chats.", comment: "A chat list action an ACP agent can't do"))
    }

    /// For a row of the list: its own profile's, when it is another's. On the Dashboard the row's
    /// profile was noted for its id when it was listed, so every call about it names it.
    static func owning(_ session: HermesSessionsAPI.SessionSummary, _ conversation: Conversation, settings: Settings = .shared) -> SessionBackend? {
        if settings.transport == .acp { return list(conversation, settings: settings) }
        guard let route = session.elsewhere else { return list(conversation, settings: settings) }
        return route.viaAPI ? conversation.ledgerAPI(profile: route.profile).map(SessionBackend.ledger) : .serve(.shared)
    }

    /// Every profile's chats, newest first, for the list with All Profiles on (his ask
    /// 2026-10-22, after a Reddit request: Hermes Desktop shows them all at once). From the
    /// Dashboard's list of every profile when it can be used, on either connection; on the Hermes
    /// API alone, each profile this phone knows asked at /p/<profile>/ (its own key, else the main
    /// one: a profile that takes neither is left out). Another profile's bot chat and group chat
    /// sessions are its bot's, in the Bots section, not rows.
    static func everyProfile(_ conversation: Conversation, settings: Settings = .shared,
                             dashboard: HermesServeClient = .shared, bots: BotRoster? = nil) async throws -> [HermesSessionsAPI.SessionSummary] {
        let selected = settings.profileName ?? ProfileCatalog.defaultID
        let botChats = Set((bots?.bots ?? []).compactMap(\.chatID))
        func isBots(_ row: HermesSessionsAPI.SessionSummary) -> Bool {
            botChats.contains(row.id) || row.title == BotChat.title || (row.title ?? "").hasPrefix("Group: ")
        }
        var rows: [HermesSessionsAPI.SessionSummary] = []
        var viaDashboard = settings.transport == .hermesServe
        if !viaDashboard { viaDashboard = await dashboard.canUse() }
        if viaDashboard {
            for var row in try await dashboard.allProfileSessions() {
                if let profile = row.profile, profile != selected {
                    guard !isBots(row) else { continue }
                    row.elsewhere = ProfileRoute(profile: profile, viaAPI: false)
                    dashboard.noteProfile(profile, forStored: row.id)
                }
                rows.append(row)
            }
        } else {
            guard let own = conversation.ledgerAPI(profile: nil) else { return [] }
            rows = try await own.listSessions()
            var others = ProfileCatalog.known(settings: settings).map(\.name) + settings.apiBotsHere.map(\.profile)
            others = others.reduce(into: []) { if !$0.contains($1), $1 != selected { $0.append($1) } }
            let apis = others.compactMap { name in conversation.ledgerAPI(profile: name).map { (name, $0) } }
            let listed = await withTaskGroup(of: [HermesSessionsAPI.SessionSummary].self) { group in
                for (name, api) in apis {
                    group.addTask {
                        guard let found = try? await api.listSessions() else { return [] }
                        return found.map { row in
                            var row = row
                            row.profile = name
                            row.elsewhere = ProfileRoute(profile: name, viaAPI: true)
                            return row
                        }
                    }
                }
                var all: [HermesSessionsAPI.SessionSummary] = []
                for await found in group { all += found }
                return all
            }
            rows += listed.filter { !isBots($0) }
        }
        return rows.sorted { ($0.lastActiveDate ?? .distantPast) > ($1.lastActiveDate ?? .distantPast) }
    }

    /// What to show when neither Hermes connection has credentials (`available` came back empty).
    static let notConfiguredMessage = String(localized: "Add the Hermes API key or the Hermes Dashboard login in Settings.")

    /// Primary backend first, the other as a fallback — for features (model options) that any
    /// configured server can answer regardless of the active transport.
    static func available(_ conversation: Conversation, settings: Settings = .shared) -> [SessionBackend] {
        if settings.transport == .acp { return AcpClient.current(settings).map { [.acp($0)] } ?? [] }
        let serve: SessionBackend? = HermesServeClient.shared.hasCredentials ? .serve(.shared) : nil
        let ledger = conversation.ledgerAPI().map(SessionBackend.ledger)
        let ordered = settings.transport == .hermesServe ? [serve, ledger] : [ledger, serve]
        return ordered.compactMap { $0 }
    }

    func listSessions() async throws -> [HermesSessionsAPI.SessionSummary] {
        switch self {
        case .serve(let client): try await client.listSessions()
        case .ledger(let api): try await api.listSessions()
        case .acp(let client): AcpSessions.summaries(try await client.listSessions())
        }
    }

    /// A session's transcript, mapped into the app's messages.
    func messages(for id: String) async throws -> [Message] {
        switch self {
        case .serve(let client): await Conversation.readied(serveRows: try await client.history(stored: id))
        case .ledger(let api): await Conversation.readied(stored: try await api.messages(sessionID: id))
        case .acp(let client): AcpHistory.messages(try await client.load(id))
        }
    }

    /// When the host last wrote anything into one session, asked of that session by id: the
    /// question `catchUp` puts before re-reading a conversation, "has the host moved on since
    /// this copy?".
    ///
    /// By id, and not by hunting the session list: a session is had by its id whatever profile
    /// owns it, and whether or not a list would hold it — a bot's chat is hidden, and every list
    /// leaves those out (the Dashboard's REST list has no way to ask for them), so the list this
    /// used to search never held the conversation being asked about (GitHub issue 66).
    ///
    /// Its newest stored message is the answer, not the session's own row: the row's `last_active`
    /// is worked out in the list query and isn't in the row at all, while the message is the very
    /// thing the transcript is built from.
    func newestMessageAt(_ id: String) async throws -> Date? {
        let stored: [HermesSessionsAPI.StoredMessage]
        switch self {
        case .serve(let client): stored = try await client.transcript(stored: id, limit: 1)
        case .ledger(let api): stored = try await api.newestMessages(sessionID: id, limit: 1)
        case .acp(let client):
            // The agent's list says when each session last changed.
            let row = AcpSessions.summaries(try await client.listSessions()).first { $0.id == id }
            return row?.last_active.map { Date(timeIntervalSince1970: $0) }
        }
        return stored.last?.timestamp.map { Date(timeIntervalSince1970: $0) }
    }

    func rename(_ id: String, to title: String) async throws {
        switch self {
        case .serve(let client): try await client.updateSession(stored: id, title: title)
        case .ledger(let api): try await api.updateSession(id: id, title: title)
        case .acp(let client): if try await !client.setTitle(id, title: title) { throw Self.notOnACP }
        }
    }

    func setPinned(_ id: String, _ pinned: Bool) async throws {
        switch self {
        case .serve(let client): try await client.updateSession(stored: id, pinned: pinned)
        case .ledger(let api): try await api.updateSession(id: id, pinned: pinned)
        case .acp: throw Self.notOnACP
        }
    }

    /// Marks a conversation read up to now (false), or unread.
    func setUnread(_ id: String, _ unread: Bool) async throws {
        switch self {
        case .serve(let client): try await client.updateSession(stored: id, unread: unread)
        case .ledger(let api): try await api.updateSession(id: id, unread: unread)
        case .acp: throw Self.notOnACP
        }
    }

    func archive(_ id: String) async throws {
        switch self {
        case .serve(let client): try await client.updateSession(stored: id, archived: true)
        case .ledger(let api): try await api.updateSession(id: id, archived: true)
        case .acp: throw Self.notOnACP
        }
    }

    func delete(_ id: String) async throws {
        switch self {
        case .serve(let client): try await client.deleteSession(stored: id)
        case .ledger(let api): try await api.deleteSession(id: id)
        case .acp(let client): try await client.deleteSession(id)
        }
    }

    /// Fork a session's transcript. The ledger returns the new session for the caller to open;
    /// serve branches in place and the refreshed list shows it.
    func fork(_ id: String, title: String) async throws -> HermesSessionsAPI.SessionSummary? {
        switch self {
        case .serve(let client):
            _ = try await client.branchSession(stored: id, title: title)
            return nil
        case .ledger(let api):
            return try await api.forkSession(id: id, title: title)
        case .acp(let client):
            let cwd = AcpSessions.summaries(try await client.listSessions()).first { $0.id == id }?.cwd
            return try await client.fork(id, cwd: cwd, title: title)
        }
    }

    func modelOptions(refresh: Bool = false) async throws -> [ModelChoice] {
        switch self {
        case .serve(let client): try await client.modelOptions(refresh: refresh)
        case .ledger(let api): try await api.modelOptions(refresh: refresh)
        case .acp(let client): client.modelChoices(session: nil)
        }
    }
}
