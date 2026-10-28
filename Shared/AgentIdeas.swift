import Foundation

/// Things an agent could do for the person, offered as cards (`suggest_to_user`, Redde's plugin
/// 1.9; asked 2026-10-28, after OpenDuet's suggestion cards): taken with a swipe, the request goes
/// to that agent as the person's message; put away, it is gone. Kept in the app group, so the
/// notification extension can keep the ones that arrive with Redde closed. The newest offer's
/// come first; at most `most`, and none older than three days.
nonisolated struct AgentIdea: Codable, Identifiable, Equatable, Sendable {
    /// The offer's id and the idea's place in it.
    var id: String
    /// The agent's profile ("default", the main agent) and what it is called.
    var profile: String
    var agent: String
    var title: String
    var why: String?
    /// What goes to the agent when the card is taken, as the person would say it.
    var request: String
    var at: Date

    private static let key = "agentIdeas"
    static let most = 20
    static let keptFor: TimeInterval = 3 * 86_400

    static func all(in defaults: UserDefaults? = NeedsYou.shared, now: Date = .now) -> [AgentIdea] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return ((try? JSONDecoder().decode([AgentIdea].self, from: data)) ?? []).filter { now.timeIntervalSince($0.at) < keptFor }
    }

    /// A note of ideas from the plugin: kept, ahead of the ones before. False for any other note.
    @discardableResult
    static func take(_ note: PushNote, now: Date = .now, in defaults: UserDefaults? = NeedsYou.shared) -> Bool {
        guard note.kind == .ideas, let offered = note.y, !offered.isEmpty else { return false }
        let offer = note.i ?? UUID().uuidString
        let profile = note.p.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        let at = note.at.map { Date(timeIntervalSince1970: $0) } ?? now
        let new = offered.enumerated().compactMap { index, idea -> AgentIdea? in
            guard let request = idea.r?.trimmingCharacters(in: .whitespacesAndNewlines), !request.isEmpty else { return nil }
            return AgentIdea(id: "\(offer)/\(index)", profile: profile, agent: note.d ?? "", title: idea.t ?? request,
                             why: idea.w.flatMap { $0.isEmpty ? nil : $0 }, request: request, at: at)
        }
        guard !new.isEmpty else { return false }
        let before = all(in: defaults, now: now).filter { old in !new.contains { $0.id == old.id } }
        save(Array((new + before).prefix(most)), in: defaults)
        return true
    }

    /// What goes to the agent when the card is taken: the request, and the reason it gave, so it
    /// starts the new chat knowing why (asked 2026-10-28). Words to the model: English, as Redde's
    /// other notes to it are.
    static func message(for idea: AgentIdea) -> String {
        guard let why = idea.why?.trimmingCharacters(in: .whitespacesAndNewlines), !why.isEmpty else { return idea.request }
        let reason = why.last.map { ".!?".contains($0) } == true ? why : why + "."
        return "\(idea.request)\n\n(Your idea, \"\(idea.title)\": \(reason))"
    }

    /// Taken or put away: off the list.
    static func remove(_ id: String, in defaults: UserDefaults? = NeedsYou.shared) {
        save(all(in: defaults).filter { $0.id != id }, in: defaults)
    }

    private static func save(_ ideas: [AgentIdea], in defaults: UserDefaults?) {
        defaults?.set(try? JSONEncoder().encode(ideas), forKey: key)
    }
}
