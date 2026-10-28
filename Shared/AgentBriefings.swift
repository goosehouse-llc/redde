import Foundation

/// Briefings (asked 2026-10-28, after Meta's Muse): what a job whose answer has no chat to be in
/// came up with, a `[redde-notify]` one's (Redde's plugin 1.9 marks its note `x` "brief"): the
/// Evening Wrap-up, a heads-up before an event, a daily brief the agent set up. Kept in the app
/// group as notes arrive, the notification extension's too, so Redde shows the whole of one, not
/// only the notification's lines, with Redde closed between. The newest first; at most `most`,
/// and none older than a week.
nonisolated struct AgentBriefing: Codable, Identifiable, Equatable, Sendable {
    /// The job's id and when it ran: each run is a briefing of its own.
    var id: String
    var title: String
    var agent: String
    var text: String
    var at: Date
    /// It didn't finish, and `text` says why.
    var failed: Bool
    var read = false

    private static let key = "agentBriefings"
    static let most = 40
    static let keptFor: TimeInterval = 7 * 86_400

    /// What a heads-up's name starts with (`headsup.py`), less Redde's tag.
    static let headsUpPrefix = "Heads-up: "
    var isHeadsUp: Bool { title.hasPrefix(Self.headsUpPrefix) }
    /// A heads-up's event; anything else's own name.
    var heading: String { isHeadsUp ? String(title.dropFirst(Self.headsUpPrefix.count)) : title }

    static func all(in defaults: UserDefaults? = NeedsYou.shared, now: Date = .now) -> [AgentBriefing] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return ((try? JSONDecoder().decode([AgentBriefing].self, from: data)) ?? []).filter { now.timeIntervalSince($0.at) < keptFor }
    }

    /// A briefing's note: kept, ahead of the ones before. False for any other note.
    @discardableResult
    static func take(_ note: PushNote, now: Date = .now, in defaults: UserDefaults? = NeedsYou.shared) -> Bool {
        guard note.kind == .routine, note.x == "brief" else { return false }
        let at = note.at.map { Date(timeIntervalSince1970: $0) } ?? now
        let briefing = AgentBriefing(id: "\(note.i ?? UUID().uuidString)/\(Int(at.timeIntervalSince1970))", title: note.t ?? "",
                                     agent: note.d ?? "", text: note.b ?? "", at: at, failed: note.w == "failed")
        let before = all(in: defaults, now: now).filter { $0.id != briefing.id }
        save(Array(([briefing] + before).prefix(most)), in: defaults)
        return true
    }

    static func markRead(_ id: String, in defaults: UserDefaults? = NeedsYou.shared) {
        var kept = all(in: defaults)
        guard let i = kept.firstIndex(where: { $0.id == id }), !kept[i].read else { return }
        kept[i].read = true
        save(kept, in: defaults)
    }

    static func remove(_ id: String, in defaults: UserDefaults? = NeedsYou.shared) {
        save(all(in: defaults).filter { $0.id != id }, in: defaults)
    }

    private static func save(_ briefings: [AgentBriefing], in defaults: UserDefaults?) {
        defaults?.set(try? JSONEncoder().encode(briefings), forKey: key)
    }
}
