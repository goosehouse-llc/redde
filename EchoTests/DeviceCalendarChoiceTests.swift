import EventKit
import Foundation
import Testing
@testable import Echo

/// The phone's calendar tool keeps to the calendars chosen in Settings → Agent → Calendars (asked on
/// Reddit 2026-11-02: it read every calendar). Needs full calendar access in the test host
/// (`xcrun simctl privacy <device> grant calendar com.goosehouse.echo`); skipped without it.
@Suite(.serialized, .enabled(if: EKEventStore.authorizationStatus(for: .event) == .fullAccess))
struct DeviceCalendarChoiceTests {
    private func calendars() throws -> (EKEventStore, shared: EKCalendar, other: EKCalendar) {
        let store = EKEventStore()
        let source = try #require(store.sources.first { $0.sourceType == .local } ?? store.defaultCalendarForNewEvents?.source)
        func make(_ title: String) throws -> EKCalendar {
            let calendar = EKCalendar(for: .event, eventStore: store)
            calendar.title = title
            calendar.source = source
            try store.saveCalendar(calendar, commit: true)
            return calendar
        }
        return (store, try make("RT Shared \(UUID().uuidString.prefix(6))"), try make("RT Private \(UUID().uuidString.prefix(6))"))
    }

    private func event(_ title: String, in calendar: EKCalendar, _ store: EKEventStore, at start: Date) throws {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(3600)
        event.calendar = calendar
        try store.save(event, span: .thisEvent)
    }

    @Test func readsAndAddsOnlyToTheChosenCalendars() async throws {
        let (store, shared, other) = try calendars()
        let kept = UserDefaults.standard.stringArray(forKey: CalendarChoice.key)
        defer {
            UserDefaults.standard.set(kept, forKey: CalendarChoice.key)
            try? store.removeCalendar(shared, commit: true)
            try? store.removeCalendar(other, commit: true)
        }
        let start = Date.now.addingTimeInterval(3600)
        try event("Lunch with Dana", in: shared, store, at: start)
        try event("Doctor", in: other, store, at: start)
        let window: JSONValue = .object(["start": .string(DeviceDates.string(start.addingTimeInterval(-60))),
                                         "end": .string(DeviceDates.string(start.addingTimeInterval(7200)))])

        UserDefaults.standard.set([shared.title], forKey: CalendarChoice.key)
        let read = try await DeviceCalendar.events(window)
        let titles = (read["events"]?.array ?? []).compactMap { $0["title"]?.string }
        #expect(titles.contains("Lunch with Dana"))
        #expect(!titles.contains("Doctor"), "a calendar not chosen is never read")

        let into: JSONValue = .object(["title": .string("Call"), "start": .string(DeviceDates.string(start)), "calendar": .string(other.title)])
        await #expect(throws: DeviceToolError.self) { try await DeviceCalendar.addEvent(into) }
        let added = try await DeviceCalendar.addEvent(.object(["title": .string("Call"), "start": .string(DeviceDates.string(start))]))
        #expect(added["added"]?["calendar"]?.string == shared.title, "with none named, into a chosen calendar")

        UserDefaults.standard.set([String](), forKey: CalendarChoice.key)
        let all = (try await DeviceCalendar.events(window)["events"]?.array ?? []).compactMap { $0["title"]?.string }
        #expect(all.contains("Doctor"), "none chosen: all of them, as before")
    }
}
