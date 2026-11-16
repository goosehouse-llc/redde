import EventKit
import Foundation

/// This device's calendars and reminders, through one EKEventStore kept for the life of the app
/// and used off the main actor. Making a store is the dear part (Apple's advice: make one, keep
/// it), and until 2026-11-15 each part of Redde made its own, most of them on the main actor: the
/// start screen for every new conversation, the Up Next tile every minute while the list showed,
/// Settings › Calendars two, every phone tool call one, Keep a Copy three. Everything reads and
/// writes through `read` (the store, on this actor) and hands back plain values: EventKit's
/// objects don't leave it. Apple's new-event editor keeps a store of its own on the main actor
/// (`EventEditorStore`): UIKit uses that one there.
///
/// A store made before Redde was let in sees nothing even once it is, so it is made again when
/// what iOS allows has changed since. Changes to the calendars (`EKEventStoreChanged`, which a
/// calendar that syncs posts many of) reach the rest of the app as one `changed`, on the main
/// actor, half a second after the last.
actor CalendarReader {
    static let shared = CalendarReader()

    /// Posted on the main actor once changes to the calendars or reminders have settled, and when
    /// what Redde may read has changed.
    nonisolated static let changed = Notification.Name("CalendarReader.changed")

    private var store: EKEventStore?
    /// What iOS allowed (events, reminders) when `store` was made.
    private var madeWith: [EKAuthorizationStatus] = []
    private var observer: (any NSObjectProtocol)?
    private var settling: Task<Void, Never>?

    private static var access: [EKAuthorizationStatus] {
        [EKEventStore.authorizationStatus(for: .event), EKEventStore.authorizationStatus(for: .reminder)]
    }

    /// The store: made the first time, and again once what iOS allows has changed.
    private func current() -> EKEventStore {
        let access = Self.access
        if let store, access == madeWith { return store }
        let replacing = store != nil
        let made = EKEventStore()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: made, queue: nil) { [weak self] _ in
            Task { await self?.storeChanged() }
        }
        store = made
        madeWith = access
        if replacing { storeChanged() }   // what can be read isn't what it was
        return made
    }

    /// One `changed` for however many changes come close together.
    private func storeChanged() {
        settling?.cancel()
        settling = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await MainActor.run { NotificationCenter.default.post(name: CalendarReader.changed, object: nil) }
        }
    }

    /// `body` given the store, here: what it hands back must be plain values.
    func read<T: Sendable>(_ body: @Sendable (EKEventStore) throws -> T) rethrows -> T {
        try body(current())
    }

    /// The reminders the predicate `matching` makes finds, as `body` turns them into plain values
    /// where EventKit hands them over (on a thread of its own; `body` may save through the store).
    func reminders<T: Sendable>(matching: @Sendable (EKEventStore) -> NSPredicate,
                                _ body: @escaping @Sendable (EKEventStore, [EKReminder]) -> T) async -> T {
        let store = current()
        let predicate = matching(store)
        nonisolated(unsafe) let handed = store
        return await withCheckedContinuation { done in
            store.fetchReminders(matching: predicate) { reminders in done.resume(returning: body(handed, reminders ?? [])) }
        }
    }

    /// Whether iOS lets Redde at the calendar (or the reminders), asking the first time.
    func allowed(_ type: EKEntityType) async -> Bool {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return true
        case .notDetermined:
            // Asked with a store of its own: the one kept here is made again once the answer is in.
            let asking = EKEventStore()
            let granted = (try? await (type == .event ? asking.requestFullAccessToEvents() : asking.requestFullAccessToReminders())) ?? false
            _ = current()
            return granted
        default: return false
        }
    }

    // MARK: - Leave-By Alerts and the daily brief

    /// The events from `start` to `end` in every calendar, in plain values; none without full access.
    func events(from start: Date, to end: Date) -> [LeaveBy.Event] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let store = current()
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil)).map { event in
            let at = event.structuredLocation?.geoLocation?.coordinate
            return LeaveBy.Event(
                id: event.eventIdentifier ?? event.calendarItemIdentifier, title: event.title ?? "", start: event.startDate,
                place: event.location, latitude: at?.latitude, longitude: at?.longitude, calendar: event.calendar?.title,
                allDay: event.isAllDay, cancelled: event.status == .canceled,
                declined: event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false)
        }
    }

    /// One day's events, from `start` to `end`, as an agenda card draws them (each on `day`, one
    /// that began the day before too), cancelled ones left out; nil without full access, which is
    /// never asked for here.
    func agenda(from start: Date, to end: Date, day: String) -> [ReplyCard.Agenda.Event]? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let store = current()
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { $0.status != .canceled }
            .prefix(50)
            .map { event in
                let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
                return ReplyCard.Agenda.Event(
                    title: String((event.title ?? "").prefix(160)), start: event.startDate,
                    end: event.endDate > event.startDate ? event.endDate : nil, allDay: event.isAllDay, day: day,
                    location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map { String($0.prefix(200)) },
                    calendar: event.calendar?.title, notes: notes?.nilIfEmpty.map { String($0.prefix(600)) })
            }
    }
}
