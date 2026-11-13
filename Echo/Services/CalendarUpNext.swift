import EventKit
import SwiftUI

/// The Today strip's Up Next tile (asked 2026-11-12: "an 'up next' tile for whatever is next on
/// the calendar, if wanted"): the next event on this device's calendars, the ones chosen in
/// Settings › Agent › Calendars. Read again when the calendars change and each minute the tile is
/// on screen, so a finished event gives way to the next. Never asks for access by itself; turning
/// the tile on does.
@Observable
final class CalendarUpNext {
    static let shared = CalendarUpNext()

    struct Event: Equatable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var location: String?
        var color: Color?

        /// Under way at `now`.
        func isOn(at now: Date) -> Bool { start <= now && end > now }
    }

    private(set) var next: Event?
    @ObservationIgnored private var store: EKEventStore?
    @ObservationIgnored private var changes: NSObjectProtocol?

    var canRead: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Asks for calendar access when it hasn't been asked yet. True once Redde may read them.
    func ask() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .notDetermined:
            let store = self.store ?? EKEventStore()
            self.store = store
            return (try? await store.requestFullAccessToEvents()) ?? false
        default: return false
        }
    }

    func refresh(now: Date = .now) {
        guard canRead else {
            if next != nil { next = nil }
            return
        }
        let store = self.store ?? EKEventStore()
        self.store = store
        if changes == nil {
            changes = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
                MainActor.assumeIsolated { CalendarUpNext.shared.refresh() }
            }
        }
        let calendars = DeviceCalendar.shared(in: store)
        guard calendars?.isEmpty != true, let end = Calendar.current.date(byAdding: .day, value: 7, to: now) else {
            if next != nil { next = nil }
            return
        }
        // From a few hours back, so an event under way is found too.
        let events = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600), end: end, calendars: calendars))
            .filter { !$0.isAllDay && !Self.declined($0) }
            .map { Event(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? String(localized: "(untitled)", comment: "A calendar event with no title"),
                         start: $0.startDate, end: $0.endDate, location: $0.location, color: $0.calendar.map { Color(cgColor: $0.cgColor) }) }
        let found = Self.pick(events, now: now)
        if found != next { next = found }
    }

    /// The event to show: the first that hasn't ended, by when it starts. An event under way for
    /// more than three hours (a workday, a trip) is the day's background, not what's next.
    static func pick(_ events: [Event], now: Date) -> Event? {
        events
            .filter { $0.end > now && !($0.start <= now && $0.end.timeIntervalSince($0.start) > 3 * 3600) }
            .min { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    /// When it is, in a few words: "until 3:00 PM" while it's on, "in 25 min" within the hour,
    /// a time today, "Tomorrow 9:00 AM", else the weekday and time.
    static func when(_ event: Event, now: Date) -> String {
        let time = event.start.formatted(date: .omitted, time: .shortened)
        if event.isOn(at: now) {
            return String(localized: "until \(event.end.formatted(date: .omitted, time: .shortened))", comment: "Today strip, Up Next: the event under way ends at this time")
        }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        if minutes < 60 {
            let span = Duration.seconds(max(1, minutes) * 60).formatted(.units(allowed: [.minutes], width: .abbreviated))
            return String(localized: "in \(span)", comment: "An event card: it starts in this long")
        }
        let calendar = Calendar.current
        if calendar.isDate(event.start, inSameDayAs: now) { return time }
        if calendar.isDateInTomorrow(event.start) {
            return String(localized: "Tomorrow \(time)", comment: "Today strip, Up Next: the next event is tomorrow at this time")
        }
        return event.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
