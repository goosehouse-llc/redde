import Foundation
import Testing
@testable import Echo

/// What's on the calendar as an agenda card (asked 2026-10-29): read leniently from what the
/// agent wrote, each event on this phone's day, the days asked about kept even when free.
struct AgendaCardTests {
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func agenda(_ json: String, zone: TimeZone? = nil) -> ReplyCard.Agenda? {
        guard let value = try? JSONValue.parse(Data(json.utf8)) else { return nil }
        return ReplyCards.agenda(value, timeZone: zone ?? newYork)
    }

    @Test func eventsAreReadFromWhatTheAgentWrote() throws {
        let card = try #require(agenda("""
        {"type": "agenda", "title": "Tomorrow", "date": "2026-10-30", "events": [
          {"title": "Standup", "start": "2026-10-30T09:30:00-04:00", "end": "2026-10-30T09:45:00-04:00", "calendar": "Work", "location": "Zoom"},
          {"summary": "Recycling day", "start": "2026-10-30"},
          {"title": "Lunch", "start": "2026-10-30 12:30", "end": "2026-10-30 13:30"},
          {"title": "No start"},
          {"title": "Bad start", "start": "Friday at 3"}]}
        """))
        #expect(card.title == "Tomorrow")
        #expect(card.events.map(\.title) == ["Standup", "Recycling day", "Lunch"])
        #expect(card.events[0].calendar == "Work" && card.events[0].location == "Zoom")
        #expect(card.events[1].allDay && card.events[1].day == "2026-10-30")
        #expect(card.days == ["2026-10-30"])
        let lunch = card.events[2]
        #expect(!lunch.allDay && lunch.end!.timeIntervalSince(lunch.start) == 3600, "no offset: this phone's own time")
    }

    @Test func aTimeGivenInAnotherZoneLandsOnThisPhonesDay() throws {
        // 11 PM in Los Angeles is 2 AM the next day in New York.
        let card = try #require(agenda(#"{"type": "agenda", "events": [{"title": "Red-eye", "start": "2026-10-30T23:00:00-07:00"}]}"#))
        #expect(card.events[0].day == "2026-10-31")
        let utc = try #require(agenda(#"{"type": "agenda", "events": [{"title": "Call", "start": "2026-10-30T13:00:00Z"}]}"#))
        #expect(utc.events[0].day == "2026-10-30")
        let fraction = try #require(agenda(#"{"type": "agenda", "events": [{"title": "Call", "start": "2026-10-30T13:00:00.000+00:00"}]}"#))
        #expect(fraction.events.count == 1)
    }

    @Test func aFreeDayStillMakesACard() throws {
        let card = try #require(agenda(#"{"type": "agenda", "date": "2026-10-31", "events": []}"#))
        #expect(card.byDay.count == 1 && card.byDay[0].events.isEmpty)
        #expect(agenda(#"{"type": "agenda"}"#) == nil, "nothing to draw")
        #expect(agenda(#"{"type": "agenda", "events": [{"title": "x"}]}"#) == nil)
    }

    @Test func daysAreInOrderWithAllDayEventsFirst() throws {
        let card = try #require(agenda("""
        {"type": "agenda", "dates": ["2026-11-01", "2026-10-31"], "events": [
          {"title": "Late", "start": "2026-10-30T18:00:00-04:00"},
          {"title": "Early", "start": "2026-10-30T08:00:00-04:00"},
          {"title": "Holiday", "start": "2026-10-30"}]}
        """))
        #expect(card.byDay.map(\.day) == ["2026-10-30", "2026-10-31", "2026-11-01"])
        #expect(card.byDay[0].events.map(\.title) == ["Holiday", "Early", "Late"])
    }

    @Test func theCallReadsAsAnAgendaCardOnEitherConnection() {
        let args = try? JSONValue.parse(Data(#"{"cards": [{"type": "agenda", "date": "2026-10-30", "events": [{"title": "Standup", "start": "2026-10-30T09:30:00-04:00"}]}]}"#.utf8))
        guard case .agenda = ReplyCards.parse(args).first else { Issue.record("not an agenda"); return }
        #expect(!ReplyCard.agenda(.init(title: nil, events: [], days: ["2026-10-30"])).answerable)
    }

    @Test func daysAreNamedForThePerson() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 10))!
        #expect(AgendaCard.dayName("2026-10-29", now: now, calendar: calendar) == String(localized: "Today"))
        #expect(AgendaCard.dayName("2026-10-30", now: now, calendar: calendar) == String(localized: "Tomorrow"))
        #expect(AgendaCard.dayName("2026-10-30", withDate: true, now: now, calendar: calendar).hasPrefix(String(localized: "Tomorrow") + " · "))
        #expect(!AgendaCard.dayName("2026-11-02", now: now, calendar: calendar).isEmpty)
    }

    // MARK: The day timeline (asked 2026-10-30, the "Calendar A" design)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 31) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// An event on Oct 31 from one clock time to another ("9:00" to "10:15"), or with no end.
    private func event(_ title: String, _ start: Date, _ end: Date?) -> ReplyCard.Agenda.Event {
        .init(title: title, start: start, end: end, allDay: false, day: "2026-10-31", location: nil, calendar: nil, notes: nil)
    }

    private func timeline(_ events: [ReplyCard.Agenda.Event]) throws -> AgendaCard.Timeline {
        try #require(AgendaCard.Timeline.make(events, on: "2026-10-31", calendar: calendar))
    }

    private func block(_ title: String, in timeline: AgendaCard.Timeline) throws -> AgendaCard.Timeline.Block {
        try #require(timeline.blocks.first { $0.event.title == title })
    }

    /// The approved design's Saturday.
    private var saturday: [ReplyCard.Agenda.Event] {
        [event("Soccer", at(9), at(10, 15)), event("Call", at(11), nil), event("Lunch", at(12, 30), at(13, 30)),
         event("Pumpkins", at(16), at(17)), event("Trick-or-treat", at(18), at(20))]
    }

    @Test func theRailRunsFromTheFirstEventToTheLastOnesEnd() throws {
        let day = try timeline(saturday)
        let hour = AgendaCard.Timeline.hourHeight
        #expect(day.firstHour == 9 && day.lastHour == 20 && day.hours.count == 12)
        #expect(day.height == 11 * hour)
        let soccer = try block("Soccer", in: day)
        #expect(soccer.y == 0 && soccer.height == 1.25 * hour)
        #expect(try block("Lunch", in: day).y == 3.5 * hour)
        #expect(try block("Call", in: day).height == AgendaCard.Timeline.shortest, "no end: half an hour, drawn no shorter than the least")
        #expect(day.clusters.allSatisfy { $0.columns == 1 }, "nothing overlaps")
        #expect(day.y(ofHour: 12) == 3 * hour)
    }

    @Test func twoHoursOrMoreFreeIsMarked() throws {
        let day = try timeline(saturday)
        #expect(day.free.map(\.minutes) == [150], "only the afternoon: the hour-long gaps are not marked")
        let free = try #require(day.free.first)
        let lunch = try block("Lunch", in: day), pumpkins = try block("Pumpkins", in: day)
        #expect(free.y > lunch.y + lunch.height && free.y + free.height < pumpkins.y, "between the two, not over them")
        #expect(day.ruled.contains(13) && !day.ruled.contains(14) && !day.ruled.contains(15) && day.ruled.contains(16), "no lines across it")
        // Free time starts when everything so far has ended: a long event covers the short ones in it.
        let covered = try timeline([event("Workshop", at(9), at(15)), event("Coffee", at(10), at(10, 30)), event("Dinner", at(16), at(17))])
        #expect(covered.free.isEmpty)
    }

    @Test func eventsThatOverlapSitSideBySide() throws {
        let day = try timeline([event("Review", at(10), at(11)), event("Dentist", at(10, 30), at(11, 30)), event("Lunch", at(12), at(13))])
        #expect(day.clusters.map(\.columns) == [2, 1])
        #expect(try block("Review", in: day).column == 0 && block("Dentist", in: day).column == 1 && block("Lunch", in: day).column == 0)
        // A long one beside two in a row: two columns, the second used twice.
        let three = try timeline([event("Offsite", at(9), at(11)), event("Standup", at(9), at(10)), event("Sync", at(10), at(11))])
        #expect(three.clusters.count == 1 && three.clusters[0].columns == 2)
        #expect(try block("Offsite", in: three).column == 0 && block("Standup", in: three).column == 1 && block("Sync", in: three).column == 1)
        // Back to back is not overlapping; two short ones drawn taller than their times are.
        #expect(try timeline([event("A", at(9), at(10)), event("B", at(10), at(11))]).clusters.map(\.columns) == [1, 1])
        #expect(try timeline([event("A", at(9, 30), at(9, 45)), event("B", at(9, 45), at(10))]).clusters.map(\.columns) == [2])
    }

    @Test func aDayWithoutTimedEventsHasNoTimeline() throws {
        let holiday = ReplyCard.Agenda.Event(title: "Holiday", start: at(0), end: nil, allDay: true, day: "2026-10-31",
                                             location: nil, calendar: nil, notes: nil)
        #expect(AgendaCard.Timeline.make([holiday], on: "2026-10-31", calendar: calendar) == nil)
        // An hour at least; past midnight, the rail stops at the day's end.
        let late = try timeline([event("Party", at(22), nil)])
        #expect(late.firstHour == 22 && late.lastHour == 23)
        let overnight = try timeline([event("Red-eye", at(23), at(6, day: 32))])
        #expect(overnight.lastHour == 24 && overnight.height == AgendaCard.Timeline.hourHeight)
    }

    @Test func nowIsOnTheRailOnlyWithinIt() throws {
        let day = try timeline([event("Soccer", at(9), at(10, 15)), event("Lunch", at(12, 30), at(13, 30))])
        #expect(day.y(of: at(10, 30)) == 1.5 * AgendaCard.Timeline.hourHeight)
        #expect(day.y(of: at(8)) == nil && day.y(of: at(15)) == nil)
        #expect(day.y(of: at(10, 30, day: 32)) == nil, "another day")
    }

    @Test func anOpenEventPushesWhatIsBelowItDown() throws {
        let day = try timeline([event("Soccer", at(9), at(10)), event("Meeting", at(9, 30), at(11)), event("Lunch", at(12), at(13))])
        let soccer = try block("Soccer", in: day), meeting = try block("Meeting", in: day), lunch = try block("Lunch", in: day)
        let shift = AgendaCard.Shift(day, grown: [soccer.event: soccer.height + 60])
        #expect(shift.frame(of: soccer).y == soccer.y && shift.frame(of: soccer).height == soccer.height + 60, "grown to fit")
        #expect(shift.frame(of: lunch).y == lunch.y + 60, "below it: moved down")
        #expect(shift.frame(of: meeting).y == meeting.y && shift.frame(of: meeting).height == meeting.height + 60, "across its foot: stretched")
        #expect(shift.top(day.height) == day.height + 60)
        // Already fitting its block: nothing moves.
        let none = AgendaCard.Shift(day, grown: [soccer.event: 10])
        #expect(none.frame(of: lunch).y == lunch.y && none.top(day.height) == day.height)
    }

    @Test func theRailAndFreeTimeAreNamedForThePerson() throws {
        let day = try timeline([event("Soccer", at(9), at(10)), event("Dinner", at(17), at(18))])
        // (A narrow space before "AM", as the formatter writes it.)
        let labels = AgendaCard.hourLabels(day.hours, on: day.dayStart, calendar: calendar).map { $0.replacing("\u{202F}", with: " ") }
        #expect(labels.count == 10)
        #expect(labels[0] == "9 AM" && labels[1] == "10" && labels[3] == String(localized: "Noon") && labels[4] == "1 PM" && labels[5] == "2",
                "\(labels)")
        let english = Locale(identifier: "en_US")
        #expect(AgendaCard.span(minutes: 150, locale: english) == "2½ hours")
        #expect(AgendaCard.span(minutes: 180, locale: english) == "3 hours")
        #expect(AgendaCard.span(minutes: 140, locale: english) == "2½ hours", "to the half hour")
    }

    @Test func eachEventReadsAsOne() {
        var lunch = event("Lunch with Dana", at(12, 30), at(13, 30))
        lunch.location = "Rossio Roasters"
        lunch.calendar = "Personal"
        let spoken = AgendaCard.spoken(lunch)
        #expect(spoken.hasPrefix("Lunch with Dana, ") && spoken.hasSuffix(", Rossio Roasters"))
    }
}
