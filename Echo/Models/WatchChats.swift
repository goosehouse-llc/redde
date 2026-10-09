import Foundation

/// A conversation on the Hermes server as the Apple Watch lists it, to carry one on from the
/// wrist. Compiled into the phone's app as well, where its tests run.
nonisolated struct WatchChat: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var lastActive: Date?

    init(id: String, title: String, lastActive: Date? = nil) {
        self.id = id; self.title = title; self.lastActive = lastActive
    }

    /// The most the wrist is shown: a list to pick from at a glance, not an archive.
    static let most = 20

    /// The server's sessions as the list shows them: the newest first, without the ones nothing
    /// was ever said in, each under its title or how it began.
    static func list(_ sessions: [HermesSessionsAPI.SessionSummary], limit: Int = most) -> [WatchChat] {
        sessions.filter { ($0.message_count ?? 1) > 0 }
            .sorted { ($0.lastActiveDate ?? .distantPast) > ($1.lastActiveDate ?? .distantPast) }
            .prefix(limit)
            .map { WatchChat(id: $0.id, title: title($0), lastActive: $0.lastActiveDate) }
    }

    private static func title(_ session: HermesSessionsAPI.SessionSummary) -> String {
        let title = (session.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let preview = ReplyLanguage.stripNote(session.preview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? "Untitled chat" : String(preview.prefix(60))
    }

    /// Where a conversation stands, from the end of its transcript: the last thing the person
    /// said and what was answered. Tool rows and rows Hermes hides are passed over; a question
    /// with no answer yet has an empty reply.
    static func lastExchange(_ rows: [HermesSessionsAPI.StoredMessage]) -> (question: String, reply: String) {
        var question = ""
        var reply = ""
        for row in rows where row.display_kind != "hidden" {
            let text = (row.content?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch row.role {
            case "user":
                let said = ReplyLanguage.stripNote(text).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !said.isEmpty else { continue }
                question = said
                reply = ""
            case "assistant":
                if !text.isEmpty { reply = text }
            default:
                continue
            }
        }
        return (question, reply)
    }

    /// "2 hr ago", for a row.
    func when(now: Date = .now) -> String? {
        guard let lastActive else { return nil }
        if now.timeIntervalSince(lastActive) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastActive, relativeTo: now)
    }
}
