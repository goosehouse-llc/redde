import Foundation
import Testing
@testable import Echo

/// The cards an empty conversation offers.
struct StartCardsTests {
    private let calendar = Calendar.current
    /// 10:00 on a fixed day.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 10))! }
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func event(_ title: String, _ start: Date, hours: Double = 1, allDay: Bool = false) -> StartCards.Event {
        StartCards.Event(title: title, start: start, end: start.addingTimeInterval(hours * 3600), allDay: allDay)
    }
    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    @Test func theNextEventTodayComesFirst() throws {
        let events = [event("Standup", at(5, 9)), event("Lunch with Dana", at(5, 12, 15)), event("Dentist", at(5, 16)), event("Flight", at(6, 7))]
        let card = try #require(StartCards.upcoming(events, now: now, calendar: calendar))
        #expect(card.title == "Lunch with Dana")          // standup is over
        #expect(card.subtitle == "Today at \(time(at(5, 12, 15))) · 1 more")
        #expect(card.day == calendar.startOfDay(for: now))
        #expect(card.question == "What's on my calendar today?")
    }

    @Test func anEventUnderWayCounts() throws {
        let card = try #require(StartCards.upcoming([event("Workshop", at(5, 9), hours: 3)], now: now, calendar: calendar))
        #expect(card.title == "Workshop")
        #expect(card.subtitle == "Now, until \(time(at(5, 12)))")
    }

    @Test func anAllDayEventStandsInWhenNothingIsTimed() throws {
        let events = [event("Cabinets arrive", at(5, 0), hours: 24, allDay: true), event("Standup", at(5, 9))]
        let card = try #require(StartCards.upcoming(events, now: now, calendar: calendar))
        #expect(card.title == "Cabinets arrive")
        #expect(card.subtitle == "Today, all day")
    }

    @Test func withTodayDoneTheCardIsTomorrows() throws {
        let events = [event("Standup", at(5, 9)), event("Offsite", at(6, 0), hours: 24, allDay: true), event("Flight", at(6, 7, 30))]
        let card = try #require(StartCards.upcoming(events, now: at(5, 18), calendar: calendar))
        #expect(card.title == "Flight")                    // a timed event before an all-day one
        #expect(card.subtitle == "Tomorrow at \(time(at(6, 7, 30))) · 1 more")
        #expect(card.day == calendar.startOfDay(for: at(6, 12)))
        #expect(card.question == "What's on my calendar tomorrow?")
    }

    @Test func twoEmptyDaysMeanNoCard() {
        #expect(StartCards.upcoming([], now: now, calendar: calendar) == nil)
        #expect(StartCards.upcoming([event("Next week", at(12, 9))], now: now, calendar: calendar) == nil)
        #expect(StartCards.upcoming([event("Standup", at(5, 9))], now: now, calendar: calendar) == nil)   // over, nothing else
    }

    @Test func homeAssistantCountsWhenItIsOnAndSetUp() throws {
        func toolsets(_ json: String) throws -> [HermesSessionsAPI.Toolset] {
            try JSONDecoder().decode([HermesSessionsAPI.Toolset].self, from: Data(json.utf8))
        }
        #expect(StartCards.hasHomeAssistant(try toolsets(#"[{"name":"web"},{"name":"homeassistant","enabled":true,"configured":true}]"#)))
        #expect(StartCards.hasHomeAssistant(try toolsets(#"[{"name":"home-assistant"}]"#)))                 // an MCP server by another spelling
        #expect(!StartCards.hasHomeAssistant(try toolsets(#"[{"name":"homeassistant","enabled":false}]"#)))
        #expect(!StartCards.hasHomeAssistant(try toolsets(#"[{"name":"homeassistant","enabled":true,"configured":false}]"#)))
        #expect(!StartCards.hasHomeAssistant(try toolsets(#"[{"name":"web"},{"name":"terminal"}]"#)))
    }
}
