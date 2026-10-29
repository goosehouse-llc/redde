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

    private static let key = "quietHours"

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

    /// Seen already: Redde opened in the quiet, or after it.
    static func seen(center: UNUserNotificationCenter = .current(), in defaults: UserDefaults? = NeedsYou.shared) {
        clear(in: defaults)
        center.removePendingNotificationRequests(withIdentifiers: [digestID])
    }
}
