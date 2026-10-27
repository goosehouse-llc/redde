import Foundation

/// One seam for "which server owns the sessions": hermes serve's WS RPCs or the gateway
/// ledger's REST. Screens ask for the current backend instead of branching on the transport —
/// the copies of `if viaServe { … } else if let api = ledgerAPI() { … }` live here now.
@MainActor
enum SessionBackend {
    case serve(HermesServeClient)
    case ledger(HermesSessionsAPI)

    /// The backend for the active transport, or nil when it isn't configured yet.
    static func current(_ conversation: Conversation, settings: Settings = .shared) -> SessionBackend? {
        settings.transport == .hermesServe ? .serve(.shared) : conversation.ledgerAPI().map(SessionBackend.ledger)
    }

    /// The chat list's: the selected profile's sessions, whichever conversation is open (one of a
    /// bot's, or another profile's, goes by its own).
    static func list(_ conversation: Conversation, settings: Settings = .shared) -> SessionBackend? {
        settings.transport == .hermesServe ? .serve(.shared) : conversation.ledgerAPI(profile: nil).map(SessionBackend.ledger)
    }

    /// For a row of the list: its own profile's, when it is another's. On the Dashboard the row's
    /// profile was noted for its id when it was listed, so every call about it names it.
    static func owning(_ session: HermesSessionsAPI.SessionSummary, _ conversation: Conversation, settings: Settings = .shared) -> SessionBackend? {
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
        let serve: SessionBackend? = HermesServeClient.shared.hasCredentials ? .serve(.shared) : nil
        let ledger = conversation.ledgerAPI().map(SessionBackend.ledger)
        let ordered = settings.transport == .hermesServe ? [serve, ledger] : [ledger, serve]
        return ordered.compactMap { $0 }
    }

    func listSessions() async throws -> [HermesSessionsAPI.SessionSummary] {
        switch self {
        case .serve(let client): try await client.listSessions()
        case .ledger(let api): try await api.listSessions()
        }
    }

    /// A session's transcript, mapped into the app's messages.
    func messages(for id: String) async throws -> [Message] {
        switch self {
        case .serve(let client): Conversation.messages(fromServeRows: try await client.history(stored: id))
        case .ledger(let api): Conversation.mapStored(try await api.messages(sessionID: id))
        }
    }

    func rename(_ id: String, to title: String) async throws {
        switch self {
        case .serve(let client): try await client.updateSession(stored: id, title: title)
        case .ledger(let api): try await api.updateSession(id: id, title: title)
        }
    }

    func setPinned(_ id: String, _ pinned: Bool) async throws {
        switch self {
        case .serve(let client): try await client.updateSession(stored: id, pinned: pinned)
        case .ledger(let api): try await api.updateSession(id: id, pinned: pinned)
        }
    }

    /// Marks a conversation read up to now (false), or unread.
    func setUnread(_ id: String, _ unread: Bool) async throws {
        switch self {
        case .serve(let client): try await client.updateSession(stored: id, unread: unread)
        case .ledger(let api): try await api.updateSession(id: id, unread: unread)
        }
    }

    func archive(_ id: String) async throws {
        switch self {
        case .serve(let client): try await client.updateSession(stored: id, archived: true)
        case .ledger(let api): try await api.updateSession(id: id, archived: true)
        }
    }

    func delete(_ id: String) async throws {
        switch self {
        case .serve(let client): try await client.deleteSession(stored: id)
        case .ledger(let api): try await api.deleteSession(id: id)
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
        }
    }

    func modelOptions() async throws -> [ModelChoice] {
        switch self {
        case .serve(let client): try await client.modelOptions()
        case .ledger(let api): try await api.modelOptions()
        }
    }
}
