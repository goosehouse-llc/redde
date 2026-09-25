import ActivityKit
import Foundation

/// Live Activity payload for one turn. Shared by the app (which drives it) and the widget
/// extension (which draws it).
nonisolated struct EchoTurnAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable { case thinking, tool, replying, done, failed }
        var phase: Phase
        /// Tool name while `.tool`; reply preview while `.replying` / `.done`; error text if `.failed`.
        var detail: String
        var startedAt: Date
    }

    /// The question, trimmed for the banner.
    var question: String
}
