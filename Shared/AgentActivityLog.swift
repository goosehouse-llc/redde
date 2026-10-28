import Foundation

/// What agents did on their own that reached this phone (asked 2026-10-28, after Meta's Muse,
/// which keeps a record of what it did): ideas offered, a watch that saw a change, a schedule's or
/// a briefing's answer, a call. Kept in the app group as notes arrive, the notification extension's
/// too, for Agent Activity, which sets it beside what Hermes says its jobs and the board did. Two
/// weeks, at most `most`.
nonisolated struct AgentActivityNote: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case ideas, watch, routine, brief, call }
    var id: String
    var kind: Kind
    /// The agent's profile ("default", the main one) and what it is called.
    var profile: String
    var agent: String
    var title: String
    var detail: String
    var at: Date
    var failed: Bool

    private static let key = "agentActivity"
    static let most = 200
    static let keptFor: TimeInterval = 14 * 86_400

    static func all(in defaults: UserDefaults? = NeedsYou.shared, now: Date = .now) -> [AgentActivityNote] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return ((try? JSONDecoder().decode([AgentActivityNote].self, from: data)) ?? []).filter { now.timeIntervalSince($0.at) < keptFor }
    }

    /// What a note says an agent did, or nil for a note of another kind.
    static func made(from note: PushNote, now: Date = .now) -> AgentActivityNote? {
        let at = note.at.map { Date(timeIntervalSince1970: $0) } ?? now
        let profile = note.p.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        let failed = note.w == "failed"
        let kind: Kind, title: String, detail: String
        switch note.kind {
        case .ideas:
            let offered = (note.y ?? []).compactMap { $0.t ?? $0.r }
            guard !offered.isEmpty else { return nil }
            kind = .ideas
            title = String(localized: "Offered \(offered.count) ideas")
            detail = offered.joined(separator: " · ")
        case .watch:
            kind = .watch
            title = note.t ?? String(localized: "A watch")
            detail = note.b ?? ""
        case .routine:
            kind = note.x == "brief" ? .brief : .routine
            title = note.t ?? String(localized: "A schedule")
            detail = note.b ?? ""
        case .call:
            kind = .call
            title = String(localized: "Called you")
            detail = note.b ?? ""
        default:
            return nil
        }
        return AgentActivityNote(id: "\(kind.rawValue)/\(note.i ?? title)/\(Int(at.timeIntervalSince1970))", kind: kind, profile: profile,
                                 agent: note.d ?? "", title: title, detail: detail, at: at, failed: failed)
    }

    @discardableResult
    static func take(_ note: PushNote, now: Date = .now, in defaults: UserDefaults? = NeedsYou.shared) -> Bool {
        guard let made = made(from: note, now: now) else { return false }
        let before = all(in: defaults, now: now).filter { $0.id != made.id }
        defaults?.set(try? JSONEncoder().encode(Array(([made] + before).prefix(most))), forKey: key)
        return true
    }
}
