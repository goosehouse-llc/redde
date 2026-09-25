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

    /// What to show when neither Hermes connection has credentials (`available` came back empty).
    static let notConfiguredMessage = "Add the Hermes API key or the Hermes Dashboard login in Settings."

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
