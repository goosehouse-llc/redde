import Foundation

/// What the person thought of what the agents brought them unasked (asked 2026-10-28, "Proactive"):
/// More Like This or Fewer Like This on an idea or a heads-up, Useful or Not Useful on a briefing.
/// Kept on the phone and said to the agent in the prompts of the jobs that make them (`DailyJob`,
/// `FeedbackFold`), so it costs nothing in a chat: the agent reads it only when it runs one. The
/// newest `most` each way, for a month.
nonisolated struct AgentFeedback: Codable, Equatable, Sendable {
    enum Topic: String, Codable, Sendable {
        case idea, headsUp, briefing
    }

    var topic: Topic
    /// The idea's title, the heads-up's event, the briefing's name.
    var title: String
    var agent: String
    var liked: Bool
    var at: Date

    private static let key = "agentFeedback"
    static let most = 8
    static let keptFor: TimeInterval = 30 * 86_400

    static func all(in defaults: UserDefaults? = NeedsYou.shared, now: Date = .now) -> [AgentFeedback] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return ((try? JSONDecoder().decode([AgentFeedback].self, from: data)) ?? []).filter { now.timeIntervalSince($0.at) < keptFor }
    }

    /// Said of one: the last word on the same thing replaces the one before.
    static func record(_ topic: Topic, title: String, agent: String, liked: Bool, now: Date = .now,
                       in defaults: UserDefaults? = NeedsYou.shared) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let before = all(in: defaults, now: now).filter { $0.topic != topic || $0.title.lowercased() != title.lowercased() }
        let kept = [AgentFeedback(topic: topic, title: String(title.prefix(80)), agent: agent, liked: liked, at: now)] + before
        // The newest `most` each way, each topic.
        var counts: [String: Int] = [:]
        let trimmed = kept.filter { item in
            let side = "\(item.topic.rawValue)/\(item.liked)"
            counts[side, default: 0] += 1
            return counts[side]! <= most
        }
        defaults?.set(try? JSONEncoder().encode(trimmed), forKey: key)
    }

    static func clear(in defaults: UserDefaults? = NeedsYou.shared) { defaults?.removeObject(forKey: key) }

    /// What a job's prompt says of it, or nil when there's nothing. Words to the model: English.
    static func note(for topics: Set<Topic>, in defaults: UserDefaults? = NeedsYou.shared, now: Date = .now) -> String? {
        let said = all(in: defaults, now: now).filter { topics.contains($0.topic) }
        guard !said.isEmpty else { return nil }
        let quoted: ([AgentFeedback]) -> String = { $0.map { "\"\($0.title)\"" }.joined(separator: ", ") }
        var parts: [String] = []
        for topic in [Topic.idea, .headsUp, .briefing] where topics.contains(topic) {
            let liked = said.filter { $0.topic == topic && $0.liked }, not = said.filter { $0.topic == topic && !$0.liked }
            let (more, fewer) = switch topic {
            case .idea: ("Ideas they wanted more like", "ideas they wanted fewer like")
            case .headsUp: ("Heads-ups they wanted more like", "heads-ups they didn't need")
            case .briefing: ("Briefings they found useful", "briefings they didn't find useful")
            }
            if !liked.isEmpty { parts.append("\(more): \(quoted(liked)).") }
            if !not.isEmpty { parts.append("\(fewer.prefix(1).uppercased() + fewer.dropFirst()): \(quoted(not)).") }
        }
        return "What the user said of earlier ones (let it guide what you choose; don't mention it): " + parts.joined(separator: " ")
    }
}

/// "Later": the times an idea or a briefing can be put off to, from now.
nonisolated enum Later: CaseIterable, Sendable {
    case inAnHour, thisEvening, tomorrowMorning, thisWeekend

    var label: LocalizedStringResource {
        switch self {
        case .inAnHour: "In an Hour"
        case .thisEvening: "This Evening"
        case .tomorrowMorning: "Tomorrow Morning"
        case .thisWeekend: "This Weekend"
        }
    }

    var symbol: String {
        switch self {
        case .inAnHour: "clock"
        case .thisEvening: "moon"
        case .tomorrowMorning: "sunrise"
        case .thisWeekend: "sofa"
        }
    }

    /// When, from `now`; nil where it makes no sense (this evening, in the evening).
    func date(from now: Date = .now, calendar: Calendar = .current) -> Date? {
        let day = calendar.startOfDay(for: now)
        switch self {
        case .inAnHour:
            return now.addingTimeInterval(3600)
        case .thisEvening:
            guard calendar.component(.hour, from: now) < 17 else { return nil }
            return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day)
        case .tomorrowMorning:
            return calendar.date(byAdding: .day, value: 1, to: day).flatMap { calendar.date(bySettingHour: 8, minute: 0, second: 0, of: $0) }
        case .thisWeekend:
            guard !calendar.isDateInWeekend(now), let weekend = calendar.nextWeekend(startingAfter: now)?.start else { return nil }
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: weekend)
        }
    }

    /// The choices that make sense now.
    static func choices(from now: Date = .now) -> [(Later, Date)] {
        allCases.compactMap { later in later.date(from: now).map { (later, $0) } }
    }

    /// A swipe's Later: this evening, in the day; else tomorrow morning.
    static func soon(from now: Date = .now) -> Date {
        Later.thisEvening.date(from: now) ?? Later.tomorrowMorning.date(from: now) ?? now.addingTimeInterval(3 * 3600)
    }
}
