import EventKit
import Foundation

/// The calendar and reminders tools, through EventKit. Each call makes its own store and hands
/// back plain values: EventKit's objects don't cross between threads, and its callbacks come on
/// threads of their own, which is why none of this is tied to the main actor.
nonisolated enum DeviceCalendar {
    // MARK: - Permission

    /// Whether iOS lets Redde at the calendar (or the reminders), asking the first time.
    static func allowed(_ type: EKEntityType) async -> Bool {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return true
        case .notDetermined:
            let store = EKEventStore()
            return (try? await (type == .event ? store.requestFullAccessToEvents() : store.requestFullAccessToReminders())) ?? false
        default: return false
        }
    }

    // MARK: - Events

    /// `start`, `end` (default: now and a week on), `query` (words in the title, place or
    /// notes), `limit`.
    static func events(_ args: JSONValue, now: Date = .now) async throws -> JSONValue {
        guard await allowed(.event) else { throw DeviceToolError.refused(.calendar) }
        let start = try args.date("start") ?? now
        var end = try args.date("end") ?? start.addingTimeInterval(7 * 86400)
        // "Up to the 14th" means the whole of the 14th.
        if let text = args["end"]?.string, DeviceDates.isDayOnly(text) { end = end.addingTimeInterval(86400) }
        guard end > start else { throw DeviceToolError("\"end\" has to be after \"start\".") }
        let query = args["query"]?.string?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let store = EKEventStore()
        let found = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { event in
                query.isEmpty || [event.title, event.location, event.notes].contains { $0?.lowercased().contains(query) == true }
            }
            .sorted { $0.startDate < $1.startDate }
        let limit = args.limit(default: 50, most: 200)
        return .object([
            "events": .array(found.prefix(limit).map(describe)),
            "more": .number(Double(max(0, found.count - limit))),
        ])
    }

    /// `title`, `start`, and optionally `end`, `all_day`, `location`, `notes`, `calendar`.
    static func addEvent(_ args: JSONValue) async throws -> JSONValue {
        guard await allowed(.event) else { throw DeviceToolError.refused(.calendar) }
        let title = try args.required("title")
        guard let startText = args["start"]?.string, let start = try args.date("start") else { throw DeviceToolError.missing("start") }
        let allDay = args["all_day"]?.bool ?? DeviceDates.isDayOnly(startText)
        let end = try args.date("end") ?? (allDay ? start : start.addingTimeInterval(3600))
        guard end >= start else { throw DeviceToolError("\"end\" has to be after \"start\".") }
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = allDay
        event.location = args["location"]?.string
        event.notes = args["notes"]?.string
        if let named = args["calendar"]?.string?.nilIfEmpty {
            guard let calendar = store.calendars(for: .event).first(where: { $0.title.caseInsensitiveCompare(named) == .orderedSame && $0.allowsContentModifications }) else {
                let names = store.calendars(for: .event).filter(\.allowsContentModifications).map(\.title).joined(separator: ", ")
                throw DeviceToolError("There is no calendar called \"\(named)\" that can be added to. The ones that can: \(names).")
            }
            event.calendar = calendar
        } else {
            guard let calendar = store.defaultCalendarForNewEvents else { throw DeviceToolError("The iPhone has no calendar to add events to.") }
            event.calendar = calendar
        }
        do { try store.save(event, span: .thisEvent) } catch { throw DeviceToolError("The event couldn't be saved: \(error.localizedDescription)") }
        return .object(["added": describe(event)])
    }

    private static func describe(_ event: EKEvent) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(event.eventIdentifier ?? ""),
            "title": .string(event.title ?? "(untitled)"),
            "start": .string(DeviceDates.string(event.startDate)),
            "end": .string(DeviceDates.string(event.endDate)),
            "all_day": .bool(event.isAllDay),
            "calendar": .string(event.calendar?.title ?? ""),
        ]
        if let location = event.location?.nilIfEmpty { fields["location"] = .string(location) }
        if let notes = event.notes?.nilIfEmpty { fields["notes"] = .string(String(notes.prefix(600))) }
        return .object(fields)
    }

    // MARK: - Reminders

    /// `list` (a list's name), `include_completed`, `limit`.
    static func reminders(_ args: JSONValue) async throws -> JSONValue {
        guard await allowed(.reminder) else { throw DeviceToolError.refused(.reminders) }
        let store = EKEventStore()
        var lists: [EKCalendar]?
        if let named = args["list"]?.string?.nilIfEmpty {
            let matching = store.calendars(for: .reminder).filter { $0.title.caseInsensitiveCompare(named) == .orderedSame }
            guard !matching.isEmpty else {
                throw DeviceToolError("There is no reminders list called \"\(named)\". The lists: \(store.calendars(for: .reminder).map(\.title).joined(separator: ", ")).")
            }
            lists = matching
        }
        let all = args["include_completed"]?.bool == true
        let predicate = all ? store.predicateForReminders(in: lists)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
        let limit = args.limit(default: 50, most: 200)
        // The fetch answers on a thread of EventKit's own; the reminders are turned into plain
        // values there, before they leave it.
        let found: [JSONValue] = await withCheckedContinuation { done in
            store.fetchReminders(matching: predicate) { reminders in
                let sorted = (reminders ?? []).sorted { a, b in
                    (a.dueDateComponents?.date ?? .distantFuture, a.title ?? "") < (b.dueDateComponents?.date ?? .distantFuture, b.title ?? "")
                }
                done.resume(returning: sorted.map(describe))
            }
        }
        return .object([
            "reminders": .array(Array(found.prefix(limit))),
            "more": .number(Double(max(0, found.count - limit))),
        ])
    }

    /// `title`, and optionally `due`, `notes`, `list`.
    static func addReminder(_ args: JSONValue) async throws -> JSONValue {
        guard await allowed(.reminder) else { throw DeviceToolError.refused(.reminders) }
        let title = try args.required("title")
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = args["notes"]?.string
        if let named = args["list"]?.string?.nilIfEmpty {
            guard let list = store.calendars(for: .reminder).first(where: { $0.title.caseInsensitiveCompare(named) == .orderedSame && $0.allowsContentModifications }) else {
                throw DeviceToolError("There is no reminders list called \"\(named)\". The lists: \(store.calendars(for: .reminder).map(\.title).joined(separator: ", ")).")
            }
            reminder.calendar = list
        } else {
            guard let list = store.defaultCalendarForNewReminders() else { throw DeviceToolError("The iPhone has no reminders list to add to.") }
            reminder.calendar = list
        }
        if let text = args["due"]?.string, let due = try args.date("due") {
            let dayOnly = DeviceDates.isDayOnly(text)
            var parts: Set<Calendar.Component> = [.year, .month, .day]
            if !dayOnly { parts.formUnion([.hour, .minute]) }
            reminder.dueDateComponents = Calendar.current.dateComponents(parts, from: due)
            // A time of day is a time to be told.
            if !dayOnly { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        do { try store.save(reminder, commit: true) } catch { throw DeviceToolError("The reminder couldn't be saved: \(error.localizedDescription)") }
        return .object(["added": describe(reminder)])
    }

    /// `id`, as a list gave it.
    static func completeReminder(_ args: JSONValue) async throws -> JSONValue {
        guard await allowed(.reminder) else { throw DeviceToolError.refused(.reminders) }
        let id = try args.required("id")
        let store = EKEventStore()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw DeviceToolError("There is no reminder with that id.") }
        reminder.isCompleted = true
        do { try store.save(reminder, commit: true) } catch { throw DeviceToolError("The reminder couldn't be saved: \(error.localizedDescription)") }
        return .object(["completed": describe(reminder)])
    }

    private static func describe(_ reminder: EKReminder) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(reminder.calendarItemIdentifier),
            "title": .string(reminder.title ?? "(untitled)"),
            "list": .string(reminder.calendar?.title ?? ""),
            "completed": .bool(reminder.isCompleted),
        ]
        if let parts = reminder.dueDateComponents, let due = Calendar.current.date(from: parts) {
            // A day without a time is said as a day.
            fields["due"] = .string(parts.hour == nil ? String(DeviceDates.string(due).prefix(10)) : DeviceDates.string(due))
        }
        if let notes = reminder.notes?.nilIfEmpty { fields["notes"] = .string(String(notes.prefix(600))) }
        return .object(fields)
    }
}
