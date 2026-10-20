import Foundation

/// Incognito chats (New Incognito Chat): a conversation kept nowhere. It isn't saved on the phone
/// or listed; its session on the server is deleted when it is left (on the Dashboard it is made
/// hidden, so no app lists it meanwhile), and one that couldn't be deleted then (the app closed,
/// the server away) is deleted when Redde next comes forward. The agent is told, with each
/// message, that the chat is incognito and to save nothing from it to memory, files or skills:
/// Hermes has no switch for one session's memory, so that is a request, which the agent keeps as
/// it keeps any instruction.
nonisolated enum Incognito {
    /// An incognito chat's session on a server, to be deleted.
    struct Pending: Codable, Equatable, Sendable {
        var session: String
        var server: String
        var transport: Transport
    }

    private static let pendingKey = "incognito.pending"

    static func pending(_ defaults: UserDefaults = .standard) -> [Pending] {
        defaults.data(forKey: pendingKey).flatMap { try? JSONDecoder().decode([Pending].self, from: $0) } ?? []
    }

    static func setPending(_ list: [Pending], _ defaults: UserDefaults = .standard) {
        if list.isEmpty { defaults.removeObject(forKey: pendingKey) } else { defaults.set(try? JSONEncoder().encode(list), forKey: pendingKey) }
    }

    static func add(_ entry: Pending, _ defaults: UserDefaults = .standard) {
        var list = pending(defaults)
        guard !list.contains(entry) else { return }
        list.append(entry)
        setPending(list, defaults)
    }

    static func remove(_ entry: Pending, _ defaults: UserDefaults = .standard) {
        setPending(pending(defaults).filter { $0 != entry }, defaults)
    }

    /// The sessions on `server` waiting to be deleted: none of them is listed.
    static func sessions(on server: String, _ defaults: UserDefaults = .standard) -> Set<String> {
        Set(pending(defaults).filter { $0.server == server }.map(\.session))
    }
}

extension Incognito {
    /// Deletes an incognito chat's session, on the connection it went by: closed first on the
    /// Dashboard (Hermes refuses to delete a live one), tried a few times while a reply that was
    /// stopped winds down. True once it is gone (or the server no longer has it).
    @MainActor
    static func delete(_ entry: Pending, dashboard: HermesServeClient, api: HermesSessionsAPI?) async -> Bool {
        for attempt in 0 ..< 5 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            do {
                switch entry.transport {
                case .hermesServe:
                    try await dashboard.closeAndDeleteSession(stored: entry.session)
                case .hermesSessions:
                    guard let api else { return false }
                    try await api.deleteSession(id: entry.session)
                case .chatCompletions:
                    break
                }
                return true
            } catch TransportError.http(404, _) {
                return true
            } catch let error as HermesServeClient.RPCError where error.code == 4007 || error.message.contains("not found") {
                return true
            } catch {
                continue
            }
        }
        return false
    }
}
