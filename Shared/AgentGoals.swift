import Foundation

/// Goals (2.4, after Meta's Muse): a goal the person named, which an agent turned into a plan
/// (cards on the Hermes Kanban board, tenant `redde-goal-<id>`) and checks in on, on a schedule
/// (a job named `[redde-goal:<id>] <title>`, Redde's plugin 1.15 `goals.py`). Each check-in's
/// note (`routine`, `x` "brief") carries the goal (`o`) and how far along it is (`q` "3/7"): kept
/// here in the app group as notes arrive, the notification extension's too, so the chat list can
/// show each goal's progress with Redde closed between, and without asking the server.
nonisolated struct GoalReport: Codable, Identifiable, Equatable, Sendable {
    /// The goal's id (the job's tag).
    var id: String
    var title: String
    /// Who checks in: its name, and its profile ("default", the main agent).
    var agent: String
    var profile: String?
    /// Steps done of all of them; 0 of 0 before the first check-in.
    var done: Int
    var total: Int
    /// What the last check-in said, in a line, and the next step.
    var headline: String
    var next: String?
    /// When the last check-in was (or the goal was first heard of).
    var at: Date
    /// The last check-in didn't finish, and `headline` says why.
    var failed: Bool
    /// The check-in job, once known.
    var job: String?
    /// By when, and the plan's steps, as the Dashboard's `/redde-push goals list` gives them.
    var target: Date?
    var steps: [Step]?

    nonisolated struct Step: Codable, Equatable, Sendable {
        var title: String
        var cardID: String?
        var done: Bool
    }

    /// The share done, 0 to 1; 0 with no steps yet.
    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    var isComplete: Bool { total > 0 && done >= total }

    private static let key = "goalReports"
    /// Goals ended in Redde: kept out when a list from the server still has them.
    private static let endedKey = "goalsEnded"
    static let most = 30

    /// What a check-in job's name starts with, less any bot tag before it.
    static let tag = "[redde-goal:"

    /// The goal's id in a job's name ("[redde-goal:g7] Run a 10K" → "g7"), wherever the tag is
    /// (Hermes Desktop puts "[bot:x] " before a bot's).
    static func id(inJobName name: String) -> String? {
        guard let start = name.range(of: tag), let end = name[start.upperBound...].firstIndex(of: "]") else { return nil }
        let id = String(name[start.upperBound..<end])
        return id.isEmpty ? nil : id
    }

    /// A job's name less its tags: the goal as the person put it.
    static func title(ofJobName name: String) -> String {
        var rest = Substring(name)
        while rest.hasPrefix("["), let end = rest.firstIndex(of: "]") { rest = rest[rest.index(after: end)...].drop { $0 == " " } }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// "3/7" (or "3 of 7"): steps done and all of them. Nil for anything else.
    static func progress(_ q: String?) -> (done: Int, total: Int)? {
        guard let q else { return nil }
        let parts = q.replacingOccurrences(of: " of ", with: "/").split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]), done >= 0, total >= 0 else { return nil }
        return (min(done, total), total)
    }

    /// A check-in's words: its first line is the headline, the rest the next step ("Next: …").
    static func split(_ text: String) -> (headline: String, next: String?) {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return ("", nil) }
        let rest = lines.dropFirst().joined(separator: " ")
        var next = rest
        for prefix in ["Next step:", "Next:", "Up next:"] where next.lowercased().hasPrefix(prefix.lowercased()) {
            next = String(next.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return (first, next.isEmpty ? nil : next)
    }

    static func all(in defaults: UserDefaults? = NeedsYou.shared) -> [String: GoalReport] {
        guard let data = defaults?.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: GoalReport].self, from: data)) ?? [:]
    }

    /// The newest check-in first.
    static func showing(in defaults: UserDefaults? = NeedsYou.shared) -> [GoalReport] {
        all(in: defaults).values.sorted { $0.at > $1.at }
    }

    /// A goal's check-in note: kept as that goal's latest. False for any other note.
    @discardableResult
    static func take(_ note: PushNote, now: Date = .now, in defaults: UserDefaults? = NeedsYou.shared) -> Bool {
        guard note.kind == .routine, let id = note.o, !id.isEmpty else { return false }
        guard !ended(in: defaults).contains(id) else { return true }
        var kept = all(in: defaults)
        var report = kept[id] ?? GoalReport(id: id, title: "", agent: "", done: 0, total: 0, headline: "", at: now, failed: false)
        if let t = note.t, !t.isEmpty { report.title = title(ofJobName: t) }
        if let d = note.d, !d.isEmpty { report.agent = d }
        if let p = note.p, !p.isEmpty { report.profile = p }
        if let i = note.i, !i.isEmpty { report.job = i }
        if let (done, total) = progress(note.q) { report.done = done; report.total = total }
        let (headline, next) = split(note.b ?? "")
        report.headline = headline
        report.next = next
        report.failed = note.w == "failed"
        report.at = note.at.map { Date(timeIntervalSince1970: $0) } ?? now
        kept[id] = report
        save(kept, in: defaults)
        return true
    }

    /// What the Dashboard's `/redde-push goals list` said: each goal's plan and progress over what
    /// was kept, and goals no longer there let go. A check-in heard since keeps its words.
    static func merge(_ listed: [GoalReport], in defaults: UserDefaults? = NeedsYou.shared) {
        let ended = ended(in: defaults)
        let before = all(in: defaults)
        var kept: [String: GoalReport] = [:]
        for var goal in listed where !ended.contains(goal.id) {
            if let old = before[goal.id] {
                if old.at > goal.at {
                    goal.headline = old.headline.isEmpty ? goal.headline : old.headline
                    goal.next = old.next ?? goal.next
                    goal.failed = old.failed
                    goal.at = old.at
                }
                if goal.headline.isEmpty { goal.headline = old.headline }
                goal.job = goal.job ?? old.job
                goal.profile = goal.profile ?? old.profile
                if goal.agent.isEmpty { goal.agent = old.agent }
            }
            kept[goal.id] = goal
        }
        save(kept, in: defaults)
    }

    /// The goals the job list has, for a connection that can't ask the plugin (the Hermes API):
    /// one not heard of yet is added with no check-in, one whose job is gone let go.
    static func merge(jobs: [(id: String, job: String, title: String, profile: String?)], in defaults: UserDefaults? = NeedsYou.shared, now: Date = .now) {
        let ended = ended(in: defaults)
        var kept = all(in: defaults)
        let live = Set(jobs.map(\.id))
        for id in kept.keys where !live.contains(id) { kept[id] = nil }
        for job in jobs where !ended.contains(job.id) {
            var report = kept[job.id] ?? GoalReport(id: job.id, title: job.title, agent: "", profile: job.profile, done: 0, total: 0,
                                                    headline: "", at: now, failed: false)
            report.job = job.job
            if report.title.isEmpty { report.title = job.title }
            kept[job.id] = report
        }
        save(kept, in: defaults)
    }

    /// Ended in Redde: let go, and kept out of later lists.
    static func end(_ id: String, in defaults: UserDefaults? = NeedsYou.shared) {
        var kept = all(in: defaults)
        kept[id] = nil
        save(kept, in: defaults)
        defaults?.set(Array(Array(ended(in: defaults).union([id])).suffix(100)), forKey: endedKey)
    }

    static func ended(in defaults: UserDefaults? = NeedsYou.shared) -> Set<String> {
        Set(defaults?.stringArray(forKey: endedKey) ?? [])
    }

    private static func save(_ kept: [String: GoalReport], in defaults: UserDefaults?) {
        var kept = kept
        if kept.count > most {
            for old in kept.values.sorted(by: { $0.at < $1.at }).prefix(kept.count - most) { kept[old.id] = nil }
        }
        defaults?.set(try? JSONEncoder().encode(kept), forKey: key)
    }
}
