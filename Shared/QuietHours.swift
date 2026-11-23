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

/// What came in the quiet, for the notification at its end.
nonisolated struct HeldNote: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case ideas, briefing, watch, schedule }
    var kind: Kind
    var title: String
    var at: Date

    private static let key = "quietHeld"
    static let digestID = "redde.quietDigest"

    static func all(in defaults: UserDefaults? = NeedsYou.shared) -> [HeldNote] {
        defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode([HeldNote].self, from: $0) } ?? []
    }

    /// The note kept for the digest; what is held now.
    @discardableResult
    static func hold(_ note: PushNote, now: Date = .now, in defaults: UserDefaults? = NeedsYou.shared) -> [HeldNote] {
        let kind: Kind = switch note.kind {
        case .ideas: .ideas
        case .watch: .watch
        default: note.x == "brief" ? .briefing : .schedule
        }
        let title = note.kind == .ideas ? (note.d ?? "") : (note.t ?? "")
        let held = Array((all(in: defaults) + [HeldNote(kind: kind, title: title, at: now)]).suffix(50))
        defaults?.set(try? JSONEncoder().encode(held), forKey: key)
        return held
    }

    static func clear(in defaults: UserDefaults? = NeedsYou.shared) {
        defaults?.removeObject(forKey: key)
    }

    /// The digest's words: how many of each, and the briefings' and watches' names.
    static func digest(_ held: [HeldNote]) -> (title: String, body: String) {
        var parts: [String] = []
        let briefings = held.filter { $0.kind == .briefing }
        if !briefings.isEmpty {
            let names = briefings.map(\.title).filter { !$0.isEmpty }.prefix(3).joined(separator: ", ")
            parts.append(String(localized: "\(briefings.count) briefings") + (names.isEmpty ? "" : " (\(names))"))
        }
        let ideas = held.filter { $0.kind == .ideas }.count
        if ideas > 0 { parts.append(String(localized: "\(ideas) sets of ideas")) }
        let watches = held.filter { $0.kind == .watch }
        if !watches.isEmpty {
            let names = watches.map(\.title).filter { !$0.isEmpty }.prefix(3).joined(separator: ", ")
            parts.append(String(localized: "\(watches.count) watch changes") + (names.isEmpty ? "" : " (\(names))"))
        }
        let schedules = held.filter { $0.kind == .schedule }.count
        if schedules > 0 { parts.append(String(localized: "\(schedules) scheduled answers")) }
        return (String(localized: "While it was quiet"), parts.joined(separator: " · "))
    }

    /// The digest, (re)set for the end of the quiet: one notification, replaced as more comes.
    static func scheduleDigest(_ held: [HeldNote], at end: Date, center: UNUserNotificationCenter = .current()) {
        guard !held.isEmpty else { return }
        let words = digest(held)
        let content = UNMutableNotificationContent()
        content.title = words.title
        content.body = words.body
        content.threadIdentifier = "redde.quiet"
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
