import Foundation
import Observation

/// Each conversation's own model, for Settings → New Chats Use the Server's Model (GitHub issue
/// 45). With it on, a new conversation starts on the model the server is set to, and a model
/// picked in a conversation is that conversation's alone. The Dashboard keeps a session's model
/// once it is pinned, but a Hermes API run reads neither the session's stored model nor its lock,
/// so the phone keeps the pick, by connection (`Settings.connectionKey`) and server session, and
/// every turn of that conversation sends it.
///
/// A pick outlives a conversation deleted elsewhere; the newest few hundred per connection are
/// kept, which is far more than anyone picks by hand.
@Observable
final class ConversationModels {
    static let shared = ConversationModels()

    /// A model with the provider it is served by (Hermes routes by both); nil leaves the
    /// provider to the server.
    nonisolated struct Pick: Codable, Equatable, Sendable {
        var model: String
        var provider: String?
    }

    private nonisolated struct Entry: Codable, Equatable {
        var session: String
        var pick: Pick
    }

    /// Picks kept per connection, oldest dropped first.
    static let limit = 300
    private static let key = "conversationModels"

    @ObservationIgnored private let defaults: UserDefaults
    /// Oldest first, by connection.
    private var picks: [String: [Entry]]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        picks = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: [Entry]].self, from: $0) } ?? [:]
    }

    func pick(connection: String, session: String) -> Pick? {
        picks[connection]?.last { $0.session == session }?.pick
    }

    /// Keeps `pick` for the session, or (nil) forgets the one it had, so it starts over on the
    /// server's model.
    func set(_ pick: Pick?, connection: String, session: String) {
        var entries = picks[connection] ?? []
        entries.removeAll { $0.session == session }
        if let pick { entries.append(Entry(session: session, pick: pick)) }
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        picks[connection] = entries.isEmpty ? nil : entries
        if let data = try? JSONEncoder().encode(picks) { defaults.set(data, forKey: Self.key) }
    }

    /// The model a Hermes turn asks for, with its provider. Off, Redde's pick, the same for every
    /// conversation (nil for the server's default). On, the conversation's own pick, else nil:
    /// a conversation nobody picked a model in stays on the server's.
    static func turnModel(settings: Settings, own: Pick?) -> Pick? {
        if settings.newChatsUseServerModel { return own }
        return settings.gatewayModel.nilIfEmpty.map { Pick(model: $0, provider: settings.gatewayProvider.nilIfEmpty) }
    }

    /// The same for a turn of a session that isn't on screen (Siri, the watch): its own pick, as
    /// this connection keeps it.
    func turnModel(session: String?, settings: Settings) -> Pick? {
        Self.turnModel(settings: settings, own: session.flatMap { pick(connection: settings.connectionKey, session: $0) })
    }
}
