import Foundation

/// Which calendars the agent looks at (asked 2026-10-30: "choose which calendars to look at"):
/// Settings → Agent → Calendars, all of them or the ones chosen there, by title, which is what the
/// calendar tool's `calendar_ids` takes. The agent is told only with a question about the calendar,
/// as the plugin finds one (`cards.py`'s `_ASKS_CALENDAR`, not `_PUTS_ON_CALENDAR`): on the Hermes
/// API in the turn's instructions, on the Dashboard as a note on the message, which Redde hides.
/// An agenda card shows only their events (`ReplyCard.Agenda.byDay(showing:)`).
nonisolated enum CalendarChoice {
    /// Settings' key (an array of titles, empty for all); read straight from the defaults, so a
    /// transport off the main actor has it too.
    static let key = "agendaCalendars"
    /// The calendars agenda cards have named so far, for the page to offer (this device only).
    static let seenKey = "agendaCalendarsSeen"
    static let seenLimit = 40

    static var chosen: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    /// An event of this calendar is shown: all are with none chosen, and so is one without a name.
    static func shows(_ calendar: String?, among chosen: [String]) -> Bool {
        guard !chosen.isEmpty, let calendar = calendar?.trimmingCharacters(in: .whitespaces), !calendar.isEmpty else { return true }
        return chosen.contains { $0.caseInsensitiveCompare(calendar) == .orderedSame }
    }

    // MARK: Telling the agent

    /// A question about what's on, not a change to it ("what's on tomorrow", "am I free Friday",
    /// not "add lunch with Dana"), as the plugin tells them apart.
    static func asksCalendar(_ text: String) -> Bool {
        text.range(of: asks, options: [.regularExpression, .caseInsensitive]) != nil
            && text.range(of: puts, options: [.regularExpression, .caseInsensitive]) == nil
    }

    /// The calendars to name for this message: the chosen ones, on a question about the calendar;
    /// nothing otherwise, so every other prompt stays as short as it was.
    static func forAgent(asked text: String, chosen: [String] = chosen) -> [String]? {
        let names = chosen.map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !names.isEmpty, asksCalendar(text) else { return nil }
        return names
    }

    /// For the turn's instructions (the Hermes API, the fast lane).
    static func instruction(_ names: [String]) -> String {
        "Look only at these calendars: \(names.joined(separator: ", ")) (pass them as calendar_ids to the calendar tool)."
    }

    /// On the message itself (the Dashboard takes no instructions).
    static func note(_ names: [String]) -> String {
        noteOpening + names.joined(separator: ", ") + noteClosing
    }

    private static let noteOpening = "\n\n(Look only at these calendars: "
    private static let noteClosing = "; pass them as calendar_ids.)"

    /// A message read back, without its note.
    static func strip(_ text: String) -> String {
        guard text.hasSuffix(noteClosing), let range = text.range(of: noteOpening, options: .backwards),
              !text[range.upperBound...].contains("\n") else { return text }
        return String(text[..<range.lowerBound])
    }

    // MARK: Seen on cards

    static var seen: [String] { UserDefaults.standard.stringArray(forKey: seenKey) ?? [] }

    /// Keeps the calendars a card names, for the page to offer: saved only when one is new.
    static func saw(_ names: [String], defaults: UserDefaults = .standard) {
        var known = defaults.stringArray(forKey: seenKey) ?? []
        var added = false
        for name in names {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !known.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            known.append(name)
            added = true
        }
        guard added else { return }
        defaults.set(Array(known.suffix(seenLimit)), forKey: seenKey)
    }

    // The plugin's own tests, word for word (`companion/hermes-plugin/redde-push/cards.py`).
    private static let asks = #"\b(?:my|the|our) (?:calendar|agenda|schedule)\b|\bcalendar\b.*\?|\bagenda\b"#
        + #"|\bwhat(?:'s|’s| is) (?:on|happening|planned|going on)\b[^.?!]*\b(?:today|tonight|tomorrow|this (?:week|weekend|morning|"#
        + #"afternoon|evening)|next week|(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|the \d)"#
        + #"|\bwhat(?:'s|’s| is) on\s*(?:\?|$)|\bwhat (?:do|did) (?:i|we) have\b|\bwhat have (?:i|we) got\b"#
        + #"|\b(?:am i|are we) (?:free|busy|booked)\b|\bany (?:meetings|appointments|events|plans)\b"#
        + #"|\b(?:what|when)(?:'s|’s| is) (?:my )?next (?:meeting|appointment|event)\b|\b(?:when|what time) (?:is|does|do) my\b[^.?!]*\b(?:meeting|appointment|event|call|class|game)s?\b"#
    private static let puts = #"\b(?:add|put|create|make|book|set up|move|reschedule|cancel|delete|remove|invite|block(?: off| out)?)\b"#
        + #"|\bschedule (?:a|an|the|me|it|that|this|my)\b|\bremind me\b"#
}
