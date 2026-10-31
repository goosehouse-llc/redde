import EventKit
import SwiftUI

/// A daily brief as a calendar (asked 2026-10-31: "the daily morning brief showed my calendar but
/// not in the card"): a briefing about one day's calendar (`DayBrief`) opens on the day-timeline
/// card replies use (`AgendaCard`), over its words, and its deck card shows the day instead of its
/// first lines (`DayStrip`). Every briefing's words show without the model's narration ahead of
/// the brief itself.

extension AgentBriefing {
    /// Read once per briefing, not at each frame of a drag: its words as shown, and its day.
    private struct Reading {
        let text: String
        let shown: String
        /// `shown` as plain words for a card or a row (`PlainText.display`): its rules ran on every
        /// frame of a deck's drag before (UAT 2.3.1 review, 2026-10-31).
        let plain: String
        let day: DayBrief?
    }

    private static var readings: [String: Reading] = [:]

    private var reading: Reading {
        if let kept = Self.readings[id], kept.text == text { return kept }
        let shown = DayBrief.withoutNarration(text)
        let reading = Reading(text: text, shown: shown, plain: PlainText.display(shown),
                              day: readsAsDay ? DayBrief.read(title: title, text: shown, at: at) : nil)
        Self.readings[id] = reading
        return reading
    }

    /// Its words to show: without the model's narration ahead of the brief (`DayBrief.withoutNarration`).
    var shownText: String { reading.shown }

    /// The same as plain words, as a deck card and a row show them.
    var plainText: String { reading.plain }

    /// One day's calendar, when it reads as one.
    var dayBrief: DayBrief? { reading.day }

    /// A briefing with a look of its own isn't read as a day: a heads-up (its event's card), the
    /// Week Ahead (`WeekPlan`), the wrap-up, Morning Ideas; nor one that failed.
    private var readsAsDay: Bool {
        !failed && !isHeadsUp && ![WeekAhead.title, EveningWrapUp.title].contains(title)
            && title.range(of: "morning ideas", options: .caseInsensitive) == nil
    }
}

extension DayBrief {
    /// The brief's own rows as an agenda card's events, with no calendar of their own.
    func events(calendar: Calendar = .current) -> [ReplyCard.Agenda.Event] {
        func at(_ minute: Int) -> Date {
            guard minute < 24 * 60 else { return calendar.date(byAdding: .day, value: 1, to: date) ?? date }
            return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: date) ?? date
        }
        return rows.map { row in
            ReplyCard.Agenda.Event(title: row.title, start: row.start.map(at) ?? date, end: row.end.map(at), allDay: row.allDay,
                                   day: day, location: row.place, calendar: nil, notes: nil)
        }
    }

    /// The day as an agenda card: the phone's events when it could read them, with any the brief
    /// names that the phone doesn't have (from a calendar only the agent reads); else the brief's.
    func agenda(phone: [ReplyCard.Agenda.Event]? = nil, calendar: Calendar = .current) -> ReplyCard.Agenda {
        guard let phone else { return .init(title: nil, events: events(calendar: calendar), days: [day]) }
        let known = phone.map { Self.squeezed($0.title) }.filter { !$0.isEmpty }
        let more = events(calendar: calendar).filter { event in
            let name = Self.squeezed(event.title)
            return !known.contains { $0 == name || $0.contains(name) || name.contains($0) }
        }
        return .init(title: nil, events: phone + more, days: [day])
    }

    /// When the day begins and ends, for reading the phone's calendar.
    func span(calendar: Calendar = .current) -> (start: Date, end: Date) {
        (date, calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400))
    }
}

/// The day of a daily brief as the calendar card, in its sheet over the words: the phone's own
/// events for the day when Redde can already read the calendar (read once each time it opens, off
/// the main actor; never asked for from here), with any others the brief names; else, and on a
/// Mac without access, the brief's own rows.
struct DayBriefAgenda: View {
    let brief: DayBrief
    @State private var agenda: ReplyCard.Agenda?

    init(brief: DayBrief) {
        self.brief = brief
        _agenda = State(initialValue: Self.readsCalendar ? nil : brief.agenda())
    }

    var body: some View {
        Group {
            if let agenda {
                AgendaCard(card: agenda)
            } else {
                // The card's place while the calendar is read, a moment, so the words don't jump far.
                RoundedRectangle(cornerRadius: 20).fill(.background.secondary).frame(height: 180).accessibilityHidden(true)
            }
        }
        .task(id: brief.day) {
            guard agenda == nil else { return }
            let span = brief.span()
            let phone = await LeaveByCalendar.shared.agenda(from: span.start, to: span.end, day: brief.day)
            agenda = brief.agenda(phone: phone)
        }
    }

    /// Whether the phone's calendar is read: with full access only. Never in screenshots' demos,
    /// which show the brief's own (made-up) rows.
    private static var readsCalendar: Bool {
        #if DEBUG
        if DevHooks.has("-echo.demoBriefings") || DemoDay.on { return false }
        #endif
        return EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }
}

/// A daily brief on its deck card: the date as Calendar's icon shows it, and what's next that day
/// (the brief's own rows: no calendar is read for a card), and how many more and all day.
struct DayStrip: View {
    let brief: DayBrief

    var body: some View {
        let now = AgendaCard.now()
        let calendar = Calendar.current
        let timed = upcoming(now: now, calendar: calendar)
        let shownTimed = Array(timed.prefix(brief.allDay.isEmpty ? 3 : 2))
        let shown = shownTimed.isEmpty ? Array(brief.allDay.prefix(3)) : shownTimed
        let more = timed.count - shownTimed.count
        let allDayLeft = shownTimed.isEmpty ? brief.allDay.count - shown.count : brief.allDay.count
        HStack(alignment: .center, spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(time(row, calendar: calendar))
                            .chatFont(.footnote, weight: .semibold)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(width: 66, alignment: .leading)
                            .opacity(0.7)
                        Text(row.title).chatFont(.subheadline, weight: .medium).lineLimit(1)
                    }
                }
                let extra = [more > 0 ? String(localized: "+\(more) more", comment: "A daily brief's card: how many more timed events the day has than the card shows (\"+2 more\")") : nil,
                             allDayLeft > 0 ? String(localized: "+\(allDayLeft) all day", comment: "A daily brief's card: how many all-day events the day has besides those shown (\"+2 all day\")") : nil]
                    .compactMap(\.self)
                if !extra.isEmpty {
                    Text(extra.joined(separator: " · ")).chatFont(.caption, weight: .semibold).opacity(0.6).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.5), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(calendar: calendar))
    }

    /// The date as Calendar's icon shows it, the weekday on a red strip.
    private var badge: some View {
        VStack(spacing: 0) {
            Text(brief.date.formatted(.dateTime.weekday(.abbreviated)))
                .tracking(0.6)
                .textCase(.uppercase)
                .chatFont(size: 10, weight: .bold)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .background(.red)
            Text(brief.date.formatted(.dateTime.day()))
                .chatFont(size: 22, weight: .semibold)
                .monospacedDigit()
                .padding(.vertical, 2)
        }
        .padding(.bottom, 2)
        .frame(width: 46)
        .background(.white)
        .clipShape(.rect(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(DeckCard.ink.opacity(0.12), lineWidth: 0.5) }
    }

    /// The timed rows still to come today (all of them on another day, or when all are past).
    private func upcoming(now: Date, calendar: Calendar) -> [DayBrief.Row] {
        let timed = brief.timed
        guard calendar.isDate(brief.date, inSameDayAs: now) else { return timed }
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let left = timed.filter { ($0.end ?? (($0.start ?? 0) + 30)) > minute }
        return left.isEmpty ? timed : left
    }

    private func time(_ row: DayBrief.Row, calendar: Calendar) -> String {
        guard let start = row.start, let at = calendar.date(bySettingHour: min(start / 60, 23), minute: start % 60, second: 0, of: brief.date) else {
            return String(localized: "All day", comment: "An agenda card: an event without a time")
        }
        return at.formatted(date: .omitted, time: .shortened)
    }

    /// For VoiceOver: the day, then each event and its time.
    private func spoken(calendar: Calendar) -> String {
        ([brief.date.formatted(.dateTime.weekday(.wide).month(.wide).day())]
            + (brief.allDay + brief.timed).map { "\($0.title), \(time($0, calendar: calendar))" })
            .joined(separator: "; ")
    }
}
