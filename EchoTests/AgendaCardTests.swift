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
}
