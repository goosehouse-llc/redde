import Foundation
import Testing
@testable import Echo

/// Choosing which calendars to look at, and adding an event from the agenda card (both asked
/// 2026-10-30): the agent is told only on a calendar question, the note it rides in on the
/// Dashboard is hidden again, the card shows the chosen calendars, and a tap becomes a time.
struct CalendarChoiceTests {
    private let newYork = TimeZone(identifier: "America/New_York")!

    // MARK: Telling the agent

    @Test func onlyAQuestionAboutTheCalendarIsTold() {
        for asked in ["What's on my calendar tomorrow?", "what’s happening this weekend", "Am I free Friday afternoon?",
                      "Any meetings today?", "When is my next appointment?", "what's on?", "What do I have on Thursday",
                      "When does my soccer game start"] {
            #expect(CalendarChoice.asksCalendar(asked), "\(asked)")
        }
        for said in ["Add lunch with Dana to my calendar tomorrow", "Move my dentist appointment to Friday",
                     "Remind me to check my schedule", "What's the weather tomorrow?", "Tell me a joke", "Schedule a call with Sam"] {
            #expect(!CalendarChoice.asksCalendar(said), "\(said)")
        }
    }

    @Test func theChosenCalendarsAreNamedOnlyWhenAsked() {
        let chosen = ["Work", "Family"]
        #expect(CalendarChoice.forAgent(asked: "What's on my calendar tomorrow?", chosen: chosen) == chosen)
        #expect(CalendarChoice.forAgent(asked: "Tell me a joke", chosen: chosen) == nil, "no tokens on other messages")
        #expect(CalendarChoice.forAgent(asked: "What's on my calendar tomorrow?", chosen: []) == nil, "all calendars: nothing to say")
        #expect(CalendarChoice.instruction(chosen) == "Look only at these calendars: Work, Family (pass them as calendar_ids to the calendar tool).")
    }

    @Test func theNoteOnTheDashboardIsHiddenWhenReadBack() {
        let asked = "What's on my calendar tomorrow?"
        let sent = asked + CalendarChoice.note(["Work", "Family"])
        #expect(sent.contains("calendar_ids"))
        #expect(CalendarChoice.strip(sent) == asked)
        #expect(CalendarChoice.strip(asked) == asked)
        // With the units' note before it and the car's after it, all of them go.
        let all = asked + MeasureUnits.note(.us) + CalendarChoice.note(["Work"]) + CarBrevity.note
        #expect(ReplyLanguage.stripNote(all) == asked)
    }

    // MARK: The card

    @Test func theCardShowsTheChosenCalendarsOnly() {
        let day = "2026-10-31"
        func event(_ title: String, _ calendar: String?) -> ReplyCard.Agenda.Event {
            .init(title: title, start: .now, end: nil, allDay: false, day: day, location: nil, calendar: calendar, notes: nil)
        }
        let card = ReplyCard.Agenda(title: nil, events: [event("Standup", "Work"), event("Soccer", "family"), event("Untold", nil)], days: [day])
        #expect(card.byDay(showing: []).first?.events.count == 3, "all")
        #expect(card.byDay(showing: ["Family"]).first?.events.map(\.title) == ["Soccer", "Untold"], "by title, any case; one without a calendar stays")
        let hidden = card.byDay(showing: ["Holidays"])
        #expect(hidden.map(\.day) == [day] && hidden[0].events.map(\.title) == ["Untold"])
        let none = ReplyCard.Agenda(title: nil, events: [event("Standup", "Work")], days: [])
        #expect(none.byDay(showing: ["Family"]).map(\.day) == [day] && none.byDay(showing: ["Family"])[0].events.isEmpty,
                "a day whose events are all hidden is still drawn, free")
    }

    @Test func calendarsSeenOnCardsAreKeptOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "CalendarChoiceTests"))
        defaults.removePersistentDomain(forName: "CalendarChoiceTests")
        CalendarChoice.saw(["Work", "Family", "work", " "], defaults: defaults)
        CalendarChoice.saw(["Family"], defaults: defaults)
        #expect(defaults.stringArray(forKey: CalendarChoice.seenKey) == ["Work", "Family"])
        defaults.removePersistentDomain(forName: "CalendarChoiceTests")
    }

    // MARK: Adding an event

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: hour, minute: minute))!
    }

    private func timeline(_ spans: [(Date, Date)]) throws -> AgendaCard.Timeline {
        let events = spans.enumerated().map { index, span in
            ReplyCard.Agenda.Event(title: "Event \(index)", start: span.0, end: span.1, allDay: false, day: "2026-10-31",
                                   location: nil, calendar: nil, notes: nil)
        }
        return try #require(AgendaCard.Timeline.make(events, on: "2026-10-31", calendar: calendar))
    }

    @Test func aTapOnTheRailIsTheNearestQuarterHourForAnHour() throws {
        let day = try timeline([(at(9), at(10)), (at(16), at(17))])
        let hour = AgendaCard.Timeline.hourHeight
        let slot = try #require(day.slot(atY: 5.2 * hour))   // 2:12 PM
        #expect(slot.start == at(14, 15) && slot.end == at(15, 15))
        #expect(day.slot(atY: 5.1 * hour)?.start == at(14), "2:06 PM: down to 2")
        #expect(day.slot(atY: -10)?.start == at(9), "no earlier than the rail")
    }

    @Test func aTapOnAFreeStretchStartsWhenItDoes() throws {
        let day = try timeline([(at(9), at(10, 15)), (at(12, 30), at(13, 15)), (at(14), at(15))])
        let free = try #require(day.free.first)   // 10:15 to 12:30
        let slot = try #require(day.slot(for: free))
        #expect(slot.start == at(10, 15) && slot.end == at(11, 15), "an hour at most")
        // A stretch shorter than an hour is taken whole (one the card doesn't mark, worked out by hand).
        let short = AgendaCard.Timeline.Free(y: 0, height: 0, minutes: 45, start: 13 * 60 + 15)
        let whole = try #require(day.slot(for: short))
        #expect(whole.start == at(13, 15) && whole.end == at(14))
    }

    @Test func aTapBelowAnOpenEventIsTakenWhereItWasDrawn() throws {
        let day = try timeline([(at(9), at(10)), (at(12), at(13))])
        let soccer = try #require(day.blocks.first)
        let shift = AgendaCard.Shift(day, grown: [soccer.event: soccer.height + 60])
        let hour = AgendaCard.Timeline.hourHeight
        #expect(shift.unshift(0.5 * hour) == 0.5 * hour, "above what grew: as it was")
        #expect(shift.unshift(soccer.height + 30) == soccer.height, "in the open event's details: its foot")
        #expect(shift.unshift(2 * hour + 60) == 2 * hour, "below it: moved back up")
        #expect(shift.unshift(shift.top(3 * hour)) == 3 * hour)
    }

    @Test func voiceOverAddsAtTheNextWholeHour() throws {
        let now = at(14, 20)
        let slot = try #require(AgendaCard.Slot.nextHour(on: at(0), now: now, calendar: calendar))
        #expect(slot.start == at(15) && slot.end == at(16))
        #expect(AgendaCard.Slot.nextHour(on: at(0), now: at(23, 30), calendar: calendar)?.start == at(23), "no later than 11 PM")
    }

    @Test func theMacsLineSaysWhen() {
        let line = AgendaCard.addLine(.init(start: at(14), end: at(15)))
        #expect(line.hasSuffix(": ") && line.contains(at(14).formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute())))
    }
}
