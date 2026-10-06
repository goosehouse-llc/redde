import Foundation

/// What the iPhone hands the Apple Watch so it can talk to Hermes on its own: one of the phone's
/// connections, reduced to what a request needs. It travels as WatchConnectivity application
/// context — the latest copy wins and it arrives even while the watch app isn't running — and is
/// sent again whenever the phone's settings change.
///
/// The watch speaks plain HTTP: the Hermes API or the fast lane. The Dashboard runs over a
/// WebSocket, and watchOS keeps that from an ordinary app (it is "low-level networking", allowed
/// only while streaming audio or on a call; the simulator allows it, a watch doesn't). So the
/// phone never offers the Dashboard. A phone on it hands over the same agent by the Hermes API,
/// and one with nothing but the Dashboard says so (`needsAPIKey`), for the watch to say what to add.
nonisolated struct WatchConnection: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case hermesAPI, fastLane
        /// No longer offered. Still read, so the copy an earlier build stored on the watch is
        /// recognised and dropped instead of being tried.
        case dashboard
    }

    var kind: Kind
    /// The base as the transports take it: for the Hermes API with the profile path included.
    var url: String
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

    /// The application-context key the connection travels under.
    static let contextKey = "connection"
    /// Sent in place of a connection: the phone reaches its agent by the Dashboard alone, which
    /// the watch can't use.
    static let needsAPIKey = "needsAPI"
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

    static func needsAPI(context: [String: Any]) -> Bool {
        context[needsAPIKey] as? Bool == true
    }
}
