import Foundation
import UserNotifications

/// Quiet hours (asked 2026-10-28, "Proactive": proactive gets annoying fast): between the times the
/// person picks, what agents send on their own (ideas, briefings and heads-ups, a watch's change, a
/// schedule's answer) arrives without a sound or a banner, into the list only, and at the end of the
/// quiet one notification says what came. What waits on the person (an approval, a question), a
/// reply they asked for, and a call come through as always. Kept in the app group: the
/// notification extension decides as each note arrives.
nonisolated struct QuietHours: Codable, Equatable, Sendable {
    var on = false
    /// Minutes after midnight.
    var start = 22 * 60
    var end = 7 * 60
    /// At most this many a day of what agents send on their own, the rest quietly to the list
    /// (2026-11-22, after hermes-muse's daily budget). Nil: no limit. Counted on each device.
    var perDay: Int?

    private static let key = "quietHours"
    private static let countKey = "quietCount"
    static let limits = [3, 5, 10, 20]

    /// Whether a note that waits (`waits`) has gone past the day's limit; one that hasn't is
    /// counted. Nothing is counted while there's no limit.
    func spent(at date: Date, in defaults: UserDefaults? = NeedsYou.shared, calendar: Calendar = .current) -> Bool {
        guard let perDay, perDay > 0 else { return false }
        let day = calendar.startOfDay(for: date).timeIntervalSince1970
        let kept = defaults?.dictionary(forKey: Self.countKey)
        let count = (kept?["day"] as? Double) == day ? (kept?["n"] as? Int ?? 0) : 0
        guard count < perDay else { return true }
        defaults?.set(["day": day, "n": count + 1], forKey: Self.countKey)
        return false
    }

    static func load(from defaults: UserDefaults? = NeedsYou.shared) -> QuietHours {
        defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(QuietHours.self, from: $0) } ?? QuietHours()
    }

    func save(to defaults: UserDefaults? = NeedsYou.shared) {
        defaults?.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    /// Whether `date` falls in the quiet, across midnight or not.
    func covers(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard on, start != end else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return start < end ? (now >= start && now < end) : (now >= start || now < end)
    }

    /// When the quiet that `date` is in ends.
    func ends(after date: Date, calendar: Calendar = .current) -> Date {
        let midnight = calendar.startOfDay(for: date)
        var end = calendar.date(byAdding: .minute, value: self.end, to: midnight) ?? date
        if end <= date { end = calendar.date(byAdding: .day, value: 1, to: end) ?? end }
        return end
    }

    /// A note that waits for the morning: what an agent sent on its own.
    static func waits(_ note: PushNote) -> Bool { waits(kind: note.kind) }

    static func waits(kind: PushNote.Kind?) -> Bool {
        switch kind {
        case .ideas, .watch, .routine: true
        default: false
        }
    }
}

/// What came in the quiet, or for a summary (`NoteLevels`), for the notification that says what waited.
nonisolated struct HeldNote: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case ideas, briefing, watch, schedule, reply, group, mail, work, checkin }
    var kind: Kind
    var title: String
    var at: Date

    private static let key = "quietHeld"
    /// When the digest is set for, and whether that's the end of the quiet hours (its words differ).
    private static let dueKey = "quietHeldDue"
    private static let quietKey = "quietHeldQuiet"
    static let digestID = "redde.quietDigest"
    /// Where held notifications stack in the list, the digest atop them.
    static let thread = "redde.quiet"

    static func all(in defaults: UserDefaults? = NeedsYou.shared) -> [HeldNote] {
        defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode([HeldNote].self, from: $0) } ?? []
    }

    static func kind(of note: PushNote) -> Kind {
        switch note.kind {
        case .ideas: .ideas
        case .watch: .watch
        case .reply, .task, .failed: .reply
        case .group: .group
        case .mail: .mail
        case .work: .work
        default: note.o != nil ? .checkin : note.x == "brief" ? .briefing : .schedule
        }
    }

    /// What a note is held as: its kind, and the name the digest says (an agent's for ideas and a
    /// group chat's message, the note's title for the rest).
    static func of(_ note: PushNote, at now: Date = .now) -> HeldNote {
        let title = note.kind == .ideas || note.kind == .group ? (note.d ?? "") : (note.t ?? note.d ?? "")
        return HeldNote(kind: kind(of: note), title: title, at: now)
    }

    /// The note kept for the digest; what is held now.
    @discardableResult
    static func hold(_ note: PushNote, now: Date = .now, in defaults: UserDefaults? = NeedsYou.shared) -> [HeldNote] {
        hold(of(note, at: now), in: defaults)
    }

    @discardableResult
    static func hold(_ held: HeldNote, in defaults: UserDefaults? = NeedsYou.shared) -> [HeldNote] {
        let kept = Array((all(in: defaults) + [held]).suffix(50))
        defaults?.set(try? JSONEncoder().encode(kept), forKey: key)
        return kept
    }

    /// Holds what came for the digest and sets the digest for `until`, or keeps it for when it is
    /// set already if that's sooner. A digest that has gone off told what it held: that goes first,
    /// so the next one says only what came since. When the digest will come.
    @discardableResult
    static func wait(_ held: HeldNote, until: Date, afterQuiet: Bool, now: Date = .now, in defaults: UserDefaults? = NeedsYou.shared,
                     schedule: Bool = true) -> Date {
        var due = until, quiet = afterQuiet
        if let set = defaults?.object(forKey: dueKey) as? Double {
            let setFor = Date(timeIntervalSince1970: set)
            if setFor <= now {
                clear(in: defaults)
            } else if setFor < due {
                due = setFor
                quiet = defaults?.bool(forKey: quietKey) ?? false
            }
        }
        let kept = hold(held, in: defaults)
        defaults?.set(due.timeIntervalSince1970, forKey: dueKey)
        defaults?.set(quiet, forKey: quietKey)
        if schedule { scheduleDigest(kept, at: due, afterQuiet: quiet) }
        return due
    }

    @discardableResult
    static func wait(_ note: PushNote, until: Date, afterQuiet: Bool, now: Date = .now, in defaults: UserDefaults? = NeedsYou.shared,
                     schedule: Bool = true) -> Date {
        wait(of(note, at: now), until: until, afterQuiet: afterQuiet, now: now, in: defaults, schedule: schedule)
    }

    static func clear(in defaults: UserDefaults? = NeedsYou.shared) {
        defaults?.removeObject(forKey: key)
        defaults?.removeObject(forKey: dueKey)
        defaults?.removeObject(forKey: quietKey)
    }

    /// The digest's words: how many of each, and the briefings' and watches' names. "While it was
    /// quiet" at the end of the quiet hours, "Your summary" at a summary's time.
    static func digest(_ held: [HeldNote], afterQuiet: Bool = true) -> (title: String, body: String) {
        var parts: [String] = []
        func named(_ kind: Kind) -> String {
            let names = held.filter { $0.kind == kind }.map(\.title).filter { !$0.isEmpty }
            let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            return unique.isEmpty ? "" : " (" + unique.prefix(3).joined(separator: ", ") + ")"
        }
        let count = { (kind: Kind) in held.filter { $0.kind == kind }.count }
        if count(.briefing) > 0 { parts.append(String(localized: "\(count(.briefing)) briefings") + named(.briefing)) }
        if count(.ideas) > 0 { parts.append(String(localized: "\(count(.ideas)) sets of ideas")) }
        if count(.watch) > 0 { parts.append(String(localized: "\(count(.watch)) watch changes") + named(.watch)) }
        if count(.checkin) > 0 { parts.append(String(localized: "\(count(.checkin)) goal check-ins") + named(.checkin)) }
        if count(.reply) > 0 { parts.append(String(localized: "\(count(.reply)) replies")) }
        if count(.group) > 0 { parts.append(String(localized: "\(count(.group)) group chat messages")) }
        if count(.mail) > 0 { parts.append(String(localized: "\(count(.mail)) mail matches") + named(.mail)) }
        if count(.work) > 0 { parts.append(String(localized: "\(count(.work)) workstream updates")) }
        if count(.schedule) > 0 { parts.append(String(localized: "\(count(.schedule)) scheduled answers")) }
        return (afterQuiet ? String(localized: "While it was quiet") : String(localized: "Your summary",
                                                                                comment: "Title of the notification that says what waited for a summary time"),
                parts.joined(separator: " · "))
    }

    /// The digest, (re)set for `end`: one notification, replaced as more comes.
    static func scheduleDigest(_ held: [HeldNote], at end: Date, afterQuiet: Bool = true, center: UNUserNotificationCenter = .current()) {
        guard !held.isEmpty else { return }
        let words = digest(held, afterQuiet: afterQuiet)
        let content = UNMutableNotificationContent()
        content.title = words.title
        content.body = words.body
        content.threadIdentifier = thread
        content.userInfo = [PushNote.taskKey: "brief"]   // a tap opens Briefings
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: end)
        center.add(UNNotificationRequest(identifier: digestID, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
    }

    /// Seen already: Redde opened in the quiet, or after it. The digest is taken off away from the
    /// main thread: `removePendingNotificationRequests` waits for the notification service's reply,
    /// and a service that doesn't answer held Redde's main thread for good as it came forward
    /// (2026-11-22, the 13" iPad simulator: every UI query timed out on a frozen app).
    static func seen(in defaults: UserDefaults? = NeedsYou.shared) {
        clear(in: defaults)
        let id = digestID
        DispatchQueue.global(qos: .utility).async {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        }
    }
}

// MARK: - Levels

/// How loudly a notification comes (asked 2026-11-27: "I seem to get a lot of notifications for
/// things that I don't necessarily need. so many infact that I stopped reviewing them all"). Twelve
/// days on his iPhone: 16 a day that agents sent on their own, a quarter of them a watch saying it
/// had found nothing. Now each kind (`NoteGroup`) comes one of three ways, as the person picks.
nonisolated enum NoteLevel: String, Codable, CaseIterable, Sendable {
    /// A banner and a sound.
    case sound
    /// A banner, no sound.
    case silent
    /// No banner and no sound: into the list, and told of together at the next summary time.
    case summary

    var name: String {
        switch self {
        case .sound: String(localized: "Sound and Banner", comment: "Settings › Notifications › How Notifications Come: a level")
        case .silent: String(localized: "Banner Only", comment: "Settings › Notifications › How Notifications Come: a level, no sound")
        case .summary: String(localized: "In the Summary", comment: "Settings › Notifications › How Notifications Come: a level, no banner, told of at the summary times")
        }
    }
}

/// The kinds of notification the person picks a level for.
nonisolated enum NoteGroup: String, Codable, CaseIterable, Sendable {
    /// An approval, a question, a password or key asked for, a call, a bot waiting, a Leave-By
    /// Alert; and what the plugin marks "now" (`PushNote.l`): a reminder the person set, a watch's
    /// URGENT find, a security notice, a plan's step at the time they picked.
    case needsYou
    /// A reply, a handed-off task back, a turn that failed.
    case replies
    /// A bot's message in a group chat the device follows.
    case groups
    /// A watch's find, a mail rule, a workstream's end, a heads-up before an event, a card about
    /// today (`l` "look").
    case finds
    /// Briefings, ideas and Follow-Through cards, goal check-ins, schedules' answers.
    case background

    /// As Redde starts: only what needs the person sounds; what agents do on their own waits.
    var standard: NoteLevel {
        switch self {
        case .needsYou: .sound
        case .replies, .groups, .finds: .silent
        case .background: .summary
        }
    }

    /// What needs the person always shows: a sound or not, never only in a summary.
    var levels: [NoteLevel] { self == .needsYou ? [.sound, .silent] : NoteLevel.allCases }

    var name: String {
        switch self {
        case .needsYou: String(localized: "Needs You")
        case .replies: String(localized: "Replies")
        case .groups: String(localized: "Group Chats", comment: "Settings › Notifications › How Notifications Come: bots' messages in group chats")
        case .finds: String(localized: "Watches & Mail", comment: "Settings › Notifications › How Notifications Come: watches' finds, mail rules, heads-ups, finished work")
        case .background: String(localized: "Briefings & Ideas", comment: "Settings › Notifications › How Notifications Come: briefings, ideas, check-ins, schedules")
        }
    }

    var about: String {
        switch self {
        case .needsYou: String(localized: "Approvals, questions, calls, reminders you set, urgent finds")
        case .replies: String(localized: "Answers to what you asked")
        case .groups: String(localized: "Bots’ messages in group chats")
        case .finds: String(localized: "What a watch found, mail rules, heads-ups, finished work")
        case .background: String(localized: "Briefings, ideas, goal check-ins, schedules")
        }
    }

    /// The group a note is in; nil for one that is never shown as a notification of its own (a
    /// widget's words, notes cleared elsewhere), or a kind this build doesn't know.
    static func of(_ note: PushNote) -> NoteGroup? {
        if note.l == "now" { return .needsYou }
        guard let kind = note.kind else { return nil }
        switch kind {
        case .approval, .question, .sudo, .secret, .key, .groupWait, .call, .leave, .paired, .test: return .needsYou
        case .reply, .task, .failed: return .replies
        case .group: return .groups
        case .watch, .mail: return .finds
        case .work: return note.w == "needs" ? .needsYou : .finds
        case .routine: return note.l == "look" || note.u != nil ? .finds : .background   // (`u`: a heads-up's event)
        case .ideas: return note.l == "look" ? .finds : .background
        case .widget, .clear: return nil
        }
    }
}

/// The person's levels and summary times. Kept in Settings, which syncs them with iCloud
/// (`Settings.noteLevels`), and in the app group, where the notification extension reads them.
nonisolated struct NoteLevels: Codable, Equatable, Sendable {
    var chosen: [String: NoteLevel] = [:]
    /// Minutes after midnight.
    var summaries: [Int] = NoteLevels.standardTimes

    static let standardTimes = [8 * 60, 12 * 60, 18 * 60]
    static let mostTimes = 4
    private static let key = "noteLevels"

    func level(_ group: NoteGroup) -> NoteLevel {
        let picked = chosen[group.rawValue] ?? group.standard
        return group.levels.contains(picked) ? picked : group.standard
    }

    func level(of note: PushNote) -> NoteLevel? { NoteGroup.of(note).map(level) }

    /// The summary times in order, the standard ones if none.
    var times: [Int] {
        let kept = Array(Set(summaries.filter { (0..<1440).contains($0) })).sorted()
        return kept.isEmpty ? Self.standardTimes : kept
    }

    /// The first summary time after `date` that isn't in the quiet hours; when every one is, the
    /// end of the quiet.
    func nextSummary(after date: Date, quiet: QuietHours, calendar: Calendar = .current) -> Date {
        let midnight = calendar.startOfDay(for: date)
        for day in 0..<2 {
            guard let start = calendar.date(byAdding: .day, value: day, to: midnight) else { continue }
            for minutes in times {
                guard let at = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: start) else { continue }
                if at > date, !quiet.covers(at, calendar: calendar) { return at }
            }
        }
        return quiet.ends(after: date, calendar: calendar)
    }

    /// Read from what Settings keeps (JSON); the standard levels from anything else.
    init(text: String) {
        self = text.data(using: .utf8).flatMap { try? JSONDecoder().decode(NoteLevels.self, from: $0) } ?? NoteLevels()
    }

    init(chosen: [String: NoteLevel] = [:], summaries: [Int] = NoteLevels.standardTimes) {
        self.chosen = chosen
        self.summaries = summaries
    }

    /// As Settings keeps it.
    var text: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static func load(from defaults: UserDefaults? = NeedsYou.shared) -> NoteLevels {
        NoteLevels(text: defaults?.string(forKey: key) ?? "")
    }

    /// For the notification extension: what Settings keeps, as it is.
    static func mirror(_ text: String, to defaults: UserDefaults? = NeedsYou.shared) {
        guard defaults?.string(forKey: key) != text else { return }
        defaults?.set(text, forKey: key)
    }
}
