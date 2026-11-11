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
    /// A heads-up's event: when it starts and where (Redde's plugin 1.9 sends them), and when to
    /// leave for it, worked out on the phone (`LeaveTime`).
    var eventAt: Date?
    var place: String?
    var leaveAt: Date?
    /// Put off until then ("Later"): out of the list till it comes round.
    var snoozedUntil: Date?
    /// Whose it is ("default", the main agent), for its face on the card.
    var profile: String?
    /// The job it came from (the note's `i`): its runs are one card in the deck (2026-11-05).
    var job: String?
    /// The session its run was in (the note's `j`, plugin 1.21.1), to ask on in it (GitHub issue 62).
    var runSession: String?
    /// Where its weather is for (the note's `e`, plugin 1.26.0): Redde shows the forecast card.
    var weather: String?

    /// The run's session, where the app can open it: the main agent's (a bot's is in its own
    /// profile, which a session id alone doesn't reach).
    var openableRun: String? {
        guard let runSession, !runSession.isEmpty, (profile ?? "default") == "default" else { return nil }
        return runSession
    }

    private static let key = "agentBriefings"
    static let most = 40
    static let keptFor: TimeInterval = 7 * 86_400
    /// The runs of one job kept: a job that runs every few hours doesn't push the others out.
    static let runsKept = 5
    /// How long a briefing stays in the deck when nothing newer replaces it: a day; a heads-up's
    /// until a little after its event starts; the week ahead's, its week (2026-11-05).
    static let inDeckFor: TimeInterval = 86_400
    static let headsUpAfterStart: TimeInterval = 30 * 60

    /// Which job's runs these are: whose, and the job's id ("default|1a2b3c"). One kept from before
    /// 2026-11-05 has its job's id ahead of the "/" in its own.
    var jobKey: String {
        let id = job ?? (self.id.range(of: "/", options: .backwards).map { String(self.id[..<$0.lowerBound]) } ?? self.id)
        return "\(profile ?? "default")|\(id)"
    }

    /// Out of the deck by now, left to All Briefings: a heads-up once its event is under way, the
    /// week ahead after its week, any other after a day.
    func isOver(at now: Date = .now) -> Bool {
        if let eventAt { return now > eventAt.addingTimeInterval(Self.headsUpAfterStart) }
        if title == "Week ahead" || title == "Week Ahead" { return now.timeIntervalSince(shownAt) > Self.keptFor }
        return now.timeIntervalSince(shownAt) > Self.inDeckFor
    }

    /// What a heads-up's name starts with (`headsup.py`), less Redde's tag.
    static let headsUpPrefix = "Heads-up: "
    var isHeadsUp: Bool { title.hasPrefix(Self.headsUpPrefix) }
    /// A heads-up's event; anything else's own name.
    var heading: String { isHeadsUp ? String(title.dropFirst(Self.headsUpPrefix.count)) : title }

    static func all(in defaults: UserDefaults? = NeedsYou.shared, now: Date = .now) -> [AgentBriefing] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return ((try? JSONDecoder().decode([AgentBriefing].self, from: data)) ?? []).filter { now.timeIntervalSince($0.shownAt) < keptFor }
    }

    /// One run's id: its job's, and when it ran, to the second.
    static func id(job: String, at: TimeInterval) -> String { "\(job)/\(Int(at))" }

    /// The briefing a note is kept as, for its notification to open that one (GitHub #63: a tap
    /// opened the newest). Nil for a note with no job or time, whose id is made up on arrival.
    static func id(of note: PushNote) -> String? {
        guard note.kind == .routine, note.x == "brief", note.o == nil, let job = note.i, !job.isEmpty, let at = note.at else { return nil }
        return id(job: job, at: at)
    }

    /// A briefing's note: kept, ahead of the ones before. False for any other note.
    @discardableResult
    static func take(_ note: PushNote, now: Date = .now, in defaults: UserDefaults? = NeedsYou.shared) -> Bool {
        // A goal's check-in is the goal's (`GoalReport`), on its card, not a briefing as well.
        guard note.kind == .routine, note.x == "brief", note.o == nil else { return false }
        let at = note.at.map { Date(timeIntervalSince1970: $0) } ?? now
        var briefing = AgentBriefing(id: id(job: note.i ?? UUID().uuidString, at: at.timeIntervalSince1970), title: note.t ?? "",
                                     agent: note.d ?? "", text: note.b ?? "", at: at, failed: note.w == "failed")
        briefing.eventAt = note.u.flatMap { ISO8601DateFormatter().date(from: $0) }
        briefing.place = note.r.flatMap { $0.isEmpty ? nil : $0 }
        briefing.profile = note.p
        briefing.job = note.i.flatMap { $0.isEmpty ? nil : $0 }
        briefing.runSession = note.j.flatMap { $0.isEmpty ? nil : $0 }
        briefing.weather = note.e.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
        // A job the person said not to show (`JobNotices`): not kept at all.
        if JobNotices.choice(for: briefing.jobKey, in: defaults) == .hidden { return false }
        var before = all(in: defaults, now: now).filter { $0.id != briefing.id }
        // At most `runsKept` of one job: its oldest go.
        let same = before.filter { $0.jobKey == briefing.jobKey }.sorted { $0.at > $1.at }
        let dropped = Set(same.dropFirst(runsKept - 1).map(\.id))
        before.removeAll { dropped.contains($0.id) }
        save(Array(([briefing] + before).prefix(most)), in: defaults)
        JobNotices.name(briefing.jobKey, briefing.heading, in: defaults)
        return true
    }

    /// When to leave for a heads-up's event, once worked out.
    static func setLeave(_ id: String, at leave: Date, in defaults: UserDefaults? = NeedsYou.shared) {
        var kept = all(in: defaults)
        guard let i = kept.firstIndex(where: { $0.id == id }) else { return }
        kept[i].leaveAt = leave
        save(kept, in: defaults)
    }

    /// Put off until `until`, or back now (nil).
    static func snooze(_ id: String, until: Date?, in defaults: UserDefaults? = NeedsYou.shared) {
        var kept = all(in: defaults)
        guard let i = kept.firstIndex(where: { $0.id == id }) else { return }
        kept[i].snoozedUntil = until
        kept[i].read = false
        save(kept, in: defaults)
    }

    /// Showing now: not put off till later.
    func showing(at now: Date = .now) -> Bool { (snoozedUntil ?? .distantPast) <= now }
    /// When it came, or came back from Later: the list's order.
    var shownAt: Date { max(at, snoozedUntil ?? at) }

    /// When the next one put off comes back, for a reload then.
    static func nextBack(in defaults: UserDefaults? = NeedsYou.shared, now: Date = .now) -> Date? {
        all(in: defaults, now: now).compactMap(\.snoozedUntil).filter { $0 > now }.min()
    }

    /// The next heads-up's event still to come, for the widget.
    static func next(in briefings: [AgentBriefing], after now: Date = .now) -> AgentBriefing? {
        briefings.filter { ($0.eventAt ?? .distantPast) > now && $0.showing(at: now) }.min { $0.eventAt! < $1.eventAt! }
    }

    static func markRead(_ id: String, in defaults: UserDefaults? = NeedsYou.shared) {
        var kept = all(in: defaults)
        guard let i = kept.firstIndex(where: { $0.id == id }), !kept[i].read else { return }
        kept[i].read = true
        save(kept, in: defaults)
    }

    /// Every run of that job read: its card leaves the deck whole.
    static func markJobRead(_ jobKey: String, in defaults: UserDefaults? = NeedsYou.shared) {
        var kept = all(in: defaults)
        var changed = false
        for i in kept.indices where kept[i].jobKey == jobKey && !kept[i].read {
            kept[i].read = true
            changed = true
        }
        if changed { save(kept, in: defaults) }
    }

    /// The deck: the newest run of each job not read yet and not over (`isOver`), newest first,
    /// with how many earlier runs of it are unread under it. Pure, for the tests.
    static func deck(_ briefings: [AgentBriefing], now: Date = .now) -> [(briefing: AgentBriefing, earlier: Int)] {
        var seen: [String: Int] = [:]
        var out: [(briefing: AgentBriefing, earlier: Int)] = []
        for briefing in briefings.sorted(by: { $0.shownAt > $1.shownAt }) where !briefing.read && briefing.showing(at: now) {
            if let at = seen[briefing.jobKey] {
                if at >= 0 { out[at].earlier += 1 }
            } else if !briefing.isOver(at: now) {
                seen[briefing.jobKey] = out.count
                out.append((briefing, 0))
            } else {
                seen[briefing.jobKey] = -1   // its newest is over: so are the earlier ones
            }
        }
        return out
    }

    static func remove(_ id: String, in defaults: UserDefaults? = NeedsYou.shared) {
        save(all(in: defaults).filter { $0.id != id }, in: defaults)
    }

    private static func save(_ briefings: [AgentBriefing], in defaults: UserDefaults?) {
        defaults?.set(try? JSONEncoder().encode(briefings), forKey: key)
    }
}

/// The Up Next widget's (`EchoControls/UpNextWidget.swift`): reloaded when a briefing or ideas arrive.
nonisolated enum UpNext {
    static let widgetKind = "com.goosehouse.echo.upnext"
}

/// How one job's runs reach the person (a briefing's menu, Notifications; 2026-11-05): with a
/// notification (the default), in the drawer only (its notification delivered quietly, in the
/// list, no sound or banner: `MutedChats.quiet`), or not at all: not kept, and the plugin told to
/// send nothing for it (`Mutes.publish`, a "j:<job key>" mute) where it can be. Kept in the app
/// group, where the notification extension reads it, by the job's key (`AgentBriefing.jobKey`).
nonisolated enum JobNotices {
    enum Choice: String, Codable, CaseIterable, Sendable {
        case notify, drawerOnly, hidden
    }

    struct Entry: Codable, Equatable, Sendable {
        var choice: Choice
        /// The job's name, for the list of hidden ones.
        var title: String
    }

    private static let key = "jobNotices"

    static func load(_ defaults: UserDefaults? = NeedsYou.shared) -> [String: Entry] {
        guard let data = defaults?.data(forKey: key), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return saved
    }

    private static func save(_ entries: [String: Entry], _ defaults: UserDefaults?) {
        if entries.isEmpty { defaults?.removeObject(forKey: key) } else { defaults?.set(try? JSONEncoder().encode(entries), forKey: key) }
    }

    static func choice(for jobKey: String, in defaults: UserDefaults? = NeedsYou.shared) -> Choice {
        load(defaults)[jobKey]?.choice ?? .notify
    }

    static func set(_ choice: Choice, for jobKey: String, title: String, in defaults: UserDefaults? = NeedsYou.shared) {
        var entries = load(defaults)
        entries[jobKey] = choice == .notify ? nil : Entry(choice: choice, title: title)
        save(entries, defaults)
    }

    /// A job's newest name, where a choice is kept for it.
    static func name(_ jobKey: String, _ title: String, in defaults: UserDefaults? = NeedsYou.shared) {
        var entries = load(defaults)
        guard let entry = entries[jobKey], entry.title != title, !title.isEmpty else { return }
        entries[jobKey] = Entry(choice: entry.choice, title: title)
        save(entries, defaults)
    }

    /// The jobs not shown, by key, for their mutes and the list to show them again.
    static func hidden(in defaults: UserDefaults? = NeedsYou.shared) -> [String: Entry] {
        load(defaults).filter { $0.value.choice == .hidden }
    }

    /// The key a note's job has (a briefing's, `x` "brief" with its job's id in `i`), or nil.
    static func jobKey(of note: PushNote) -> String? {
        guard note.x == "brief", let job = note.i, !job.isEmpty else { return nil }
        return "\(note.p ?? "default")|\(job)"
    }

    /// The plugin's name for a hidden job's mute.
    static func muteKey(_ jobKey: String) -> String { "j:" + jobKey }
}
