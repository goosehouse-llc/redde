import SwiftUI
import Testing
@testable import Echo

/// By Calendar in each calendar's own colour from Calendar (asked 2026-11-05), by title.
@MainActor
struct CalendarTintsTests {
    @Test func aCalendarIsFoundByItsTitleInAnyCase() {
        let tints = CalendarTints()
        tints.tints = ["work": .yellow, "minnesota vikings": .purple]
        #expect(tints.color(of: "Work") == .yellow)
        #expect(tints.color(of: "MINNESOTA VIKINGS") == .purple)
    }

    @Test func aCalendarThisDeviceHasntGetsNoColour() {
        let tints = CalendarTints()
        tints.tints = ["home": .blue]
        #expect(tints.color(of: "Work") == nil)
    }
}
