import EventKit
import Foundation
import Testing
@testable import Echo

/// A tick in Redde made in Reminders too (2026-11-09): which reminder an item means.
struct ReminderTickTests {
    private let store = EKEventStore()

    private func reminder(_ title: String, due: Date? = nil, completed: Date? = nil) -> EKReminder {
        let r = EKReminder(eventStore: store)
        r.title = title
        if let due { r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due) }
        if let completed { r.completionDate = completed }
        return r
    }

    @Test func theSameTitleInAnyCase() {
        let car = reminder("Car payment")
        let found = DeviceCalendar.match(DeviceCalendar.folded("car  Payment"), in: [reminder("BP"), car], done: true)
        #expect(found === car)
    }

    @Test func anItemWithAWordAfterItsTitle() {
        let bp = reminder("BP")
        #expect(DeviceCalendar.match(DeviceCalendar.folded("BP due Oct 30"), in: [bp], done: true) === bp)
        #expect(DeviceCalendar.match(DeviceCalendar.folded("BPA results"), in: [bp], done: true) == nil, "a whole word only")
    }

    @Test func ofSeveralTheOneDueFirstOrDoneLast() {
        let later = reminder("Water plants", due: .now.addingTimeInterval(86400 * 3))
        let sooner = reminder("Water plants", due: .now.addingTimeInterval(3600))
        #expect(DeviceCalendar.match("water plants", in: [later, sooner], done: true) === sooner)
        let old = reminder("Water plants", completed: .now.addingTimeInterval(-86400))
        let new = reminder("Water plants", completed: .now.addingTimeInterval(-60))
        #expect(DeviceCalendar.match("water plants", in: [new, old], done: false) === new)
    }

    @Test func nothingByThatName() {
        #expect(DeviceCalendar.match("milk", in: [reminder("Oat milk")], done: true) == nil)
    }
}
