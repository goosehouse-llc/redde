import Foundation

/// What the iPhone hands the Apple Watch so it can talk to Hermes on its own: one of the phone's
/// connections, reduced to what a request needs. It travels as WatchConnectivity application
/// context — the latest copy wins and it arrives even while the watch app isn't running — and is
/// sent again whenever the phone's settings change. The phone offers the connection it uses
/// itself when the watch can use it (Dashboard, Hermes API or fast lane), else the best it has.
nonisolated struct WatchConnection: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case hermesAPI, fastLane
        /// `hermes serve`: a WebSocket login with a username and password.
        case dashboard
    }

    var kind: Kind
    /// The base as the transports take it: for the Hermes API with the profile path included.
    var url: String
    /// The API key, or the Dashboard password.
    var apiKey: String
    /// The picked model, or empty for the server's default.
    var model: String
    var provider: String
    var reasoningEffort: String
    var replyLanguage: String
    /// What the phone calls the assistant ("Redde", "Sol").
    var agentName: String
    /// Kokoro, when the phone speaks with it: the server, the voice and the speed. Absent means
    /// the watch uses the system voice. Optional so a watch holding an older copy still decodes.
    var kokoroURL: String?
    var kokoroVoice: String?
    var voiceSpeed: Double?
    /// Dashboard only: the login name, the Hermes profile (nil for the default) and the
    /// Cloudflare Access headers in front of the server, if any.
    var username: String?
    var profile: String?
    var accessHeaders: [String: String]?

    /// The application-context key the connection travels under.
    static let contextKey = "connection"
    /// A message from the watch: send the connection now, in the reply.
    static let syncRequest = "sync"

    /// Property-list form for WatchConnectivity (JSON inside a Data value).
    func asContext() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [Self.contextKey: data]
    }

    static func from(context: [String: Any]) -> WatchConnection? {
        guard let data = context[contextKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchConnection.self, from: data)
    }
}
