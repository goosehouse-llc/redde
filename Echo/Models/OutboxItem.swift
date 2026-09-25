import Foundation

/// A user message that hasn't gone to the server yet: queued behind a reply that is still
/// streaming, or held because the server couldn't be reached. Sent strictly in order, oldest first.
nonisolated struct OutboxItem: Identifiable, Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// Goes out as soon as the reply in front of it finishes.
        case queued
        /// The server couldn't be reached; retried when the connection comes back.
        case waitingForConnection
        /// Held until the reader taps Send: after Stop, a failed turn, or when it has gone stale.
        case paused
    }

    var message: Message
    var state: State
    var queuedAt: Date

    var id: UUID { message.id }

    /// Older than this and a waiting message is held for confirmation instead of sent on its own.
    static let staleAfter: TimeInterval = 60 * 60

    func isStale(now: Date = .now) -> Bool { now.timeIntervalSince(queuedAt) > Self.staleAfter }
}
