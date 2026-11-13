import Foundation
import Testing
@testable import Echo

/// The Today tiles' order (Move Left / Right, Arrange Tiles…) and the Up Next tile's event.
struct TodayTilesTests {
    @Test func tilesGoInThePersonsOrderThenTheRest() {
        let strip = ["upnext", "inbox", "list:a", "brief:b", "goal:c"]
        #expect(TodayStrip.arranged(strip, order: []) == strip)
        #expect(TodayStrip.arranged(strip, order: ["goal:c", "inbox"]) == ["goal:c", "inbox", "upnext", "list:a", "brief:b"])
        // A tile in the order that isn't shown now keeps its place for later.
        #expect(TodayStrip.arranged(["inbox", "list:a"], order: ["brief:gone", "list:a", "inbox"]) == ["list:a", "inbox"])
    }

    @Test func movingSwapsWithANeighbourAndKeepsTheRest() {
        let shown = ["inbox", "list:a", "goal:c"]
        let moved = TodayStrip.moving("list:a", by: -1, in: shown, order: ["brief:gone"])
        #expect(moved == ["list:a", "inbox", "goal:c", "brief:gone"])
        #expect(TodayStrip.moving("goal:c", by: 1, in: shown, order: ["x"]) == ["x"])   // already last
    }

    private func event(_ title: String, _ from: Double, _ to: Double, now: Date) -> CalendarUpNext.Event {
        .init(id: title, title: title, start: now.addingTimeInterval(from * 60), end: now.addingTimeInterval(to * 60))
    }

    @Test func upNextIsTheNextEventNotTheDaysBackground() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let workday = event("Work", -120, 360, now: now)
        let lunch = event("Lunch", 30, 90, now: now)
        let call = event("Call", -10, 20, now: now)
        let done = event("Standup", -60, -30, now: now)
        #expect(CalendarUpNext.pick([workday, lunch, done], now: now)?.title == "Lunch")
        #expect(CalendarUpNext.pick([workday, lunch, call], now: now)?.title == "Call")   // under way, and short
        #expect(CalendarUpNext.pick([done], now: now) == nil)
    }

    @Test func whenItIsInAFewWords() {
        let now = Date()
        #expect(CalendarUpNext.when(event("Call", -10, 20, now: now), now: now).hasPrefix("until "))
        #expect(CalendarUpNext.when(event("Lunch", 25, 60, now: now), now: now).hasPrefix("in "))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!.addingTimeInterval(9 * 3600)
        let morning = CalendarUpNext.Event(id: "m", title: "Dentist", start: tomorrow, end: tomorrow.addingTimeInterval(3600))
        #expect(CalendarUpNext.when(morning, now: now).hasPrefix("Tomorrow "))
    }
}
