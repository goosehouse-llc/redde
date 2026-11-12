import CoreGraphics
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

    /// The calendars the agent may use: those chosen in Settings → Agent → Calendars
    /// (`CalendarChoice`), or nil for all of them when none are chosen. Asked on Reddit
    /// 2026-11-02: the choice only told the agent and filtered cards, while this tool read every
    /// calendar on the phone.
    static func shared(in store: EKEventStore, chosen: [String] = CalendarChoice.chosen) -> [EKCalendar]? {
        guard !chosen.isEmpty else { return nil }
        return store.calendars(for: .event).filter { CalendarChoice.shows($0.title, among: chosen) }
    }

    /// `start`, `end` (default: now and a week on; a year on for a search), `query` (any of its
    /// words in the title, place or notes), `limit`. `most` is the agent's 200, or Keep a Copy's
    /// larger fetch. A search looked a week ahead for "dad flight" and missed a flight a month
    /// away (11-10).
    static func events(_ args: JSONValue, now: Date = .now, most: Int = 200) async throws -> JSONValue {
        guard await allowed(.event) else { throw DeviceToolError.refused(.calendar) }
        let start = try args.date("start") ?? now
        let query = args["query"]?.string?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var end = try args.date("end") ?? start.addingTimeInterval(query.isEmpty ? 7 * 86400 : searchReach)
        // "Up to the 14th" means the whole of the 14th.
        if let text = args["end"]?.string, DeviceDates.isDayOnly(text) { end = end.addingTimeInterval(86400) }
        guard end > start else { throw DeviceToolError("\"end\" has to be after \"start\".") }
        let store = EKEventStore()
        let calendars = shared(in: store)
        // None of the chosen calendars is on this phone: nothing to read (an empty list would be all).
        if calendars?.isEmpty == true { return .object(["events": .array([]), "more": .number(0)]) }
        let found = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars))
            .filter { event in matches([event.title, event.location, event.notes], query: query) }
            .sorted { $0.startDate < $1.startDate }
        let limit = args.limit(default: 50, most: most)
        return .object([
            "events": .array(found.prefix(limit).map(describe)),
            "more": .number(Double(max(0, found.count - limit))),
        ])
    }

    /// How far ahead a search with no end looks.
    static let searchReach: TimeInterval = 365 * 86400

    /// Whether any word of `query` (three letters or more, not a filler word) is in one of the
    /// texts; a query with no such word, as a whole. The agent searches in its own words ("dad
    /// flight"), which an event seldom has all of.
    static func matches(_ texts: [String?], query: String) -> Bool {
        let query = query.lowercased()
        guard !query.isEmpty else { return true }
        let haystack = texts.compactMap { $0?.lowercased() }
        let words = query.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 && !fillers.contains($0) }
        if words.isEmpty { return haystack.contains { $0.contains(query) } }
        return words.contains { word in haystack.contains { $0.contains(word) } }
    }

    private static let fillers: Set<String> = ["the", "and", "for", "with", "from", "into", "onto", "our", "his", "her", "their", "my", "any", "all"]

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
        // Only into a calendar the agent may use; the others aren't named either.
        let writable = (shared(in: store) ?? store.calendars(for: .event)).filter(\.allowsContentModifications)
        if let named = args["calendar"]?.string?.nilIfEmpty {
            guard let calendar = writable.first(where: { $0.title.caseInsensitiveCompare(named) == .orderedSame }) else {
                let names = writable.map(\.title).joined(separator: ", ")
                throw DeviceToolError("There is no calendar called \"\(named)\" that can be added to. The ones that can: \(names.isEmpty ? "none" : names).")
            }
            event.calendar = calendar
        } else if let chosen = CalendarChoice.newEvents,
                  let calendar = store.calendars(for: .event).first(where: { $0.allowsContentModifications && $0.title.caseInsensitiveCompare(chosen) == .orderedSame }) {
            // The calendar chosen for new events in Settings → Agent → Calendars, ahead of the
            // Calendar app's default; chosen there, it may be added to even when it isn't shown.
            event.calendar = calendar
        } else if let calendar = store.defaultCalendarForNewEvents, writable.contains(where: { $0.calendarIdentifier == calendar.calendarIdentifier }) {
            event.calendar = calendar
        } else if let calendar = writable.first {
            event.calendar = calendar
        } else {
            throw DeviceToolError(CalendarChoice.chosen.isEmpty ? "The iPhone has no calendar to add events to."
                                  : "None of the calendars chosen in Redde's Settings → Agent → Calendars can be added to on this iPhone.")
        }
        do { try store.save(event, span: .thisEvent) } catch { throw DeviceToolError("The event couldn't be saved: \(error.localizedDescription)") }
        // Planned shows what the agent added.
        PhoneMade.note(.init(kind: .event, id: event.eventIdentifier ?? "", title: title, at: start, added: .now))
        return .object(["added": describe(event)])
    }

    /// A colour as "#RRGGBB" in sRGB.
    static func hex(_ color: CGColor) -> String? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let parts = color.converted(to: srgb, intent: .defaultIntent, options: nil)?.components, parts.count >= 3 else { return nil }
        let byte = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(parts[0]), byte(parts[1]), byte(parts[2]))
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
        // The calendar's colour here, for the agent to put on a calendar card: an iPad or a Mac
        // that can't see this calendar then draws it as this phone does.
        if let color = event.calendar?.cgColor.flatMap(hex) { fields["color"] = .string(color) }
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
        PhoneMade.note(.init(kind: .reminder, id: reminder.calendarItemIdentifier, title: title,
                             at: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }, added: .now))
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

    // MARK: - Ticks from Redde

    /// A tick on a checklist card or one of the person's lists, made in Reminders too (asked
    /// 2026-11-09: "when I check something off the to do list, it checks it off the apple
    /// reminders list too"): the reminder of that title, in any list, done (or not done again).
    /// Only where Redde may read reminders already: this never asks. Nothing happens when no
    /// reminder has the title. True when one was changed.
    @discardableResult
    static func tick(_ text: String, done: Bool, now: Date = .now) async -> Bool {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return false }
        let wanted = folded(text)
        guard !wanted.isEmpty else { return false }
        let store = EKEventStore()
        // Done: the ones still open. Undone: those done in the last week (the tick taken back).
        let predicate = done ? store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            : store.predicateForCompletedReminders(withCompletionDateStarting: now.addingTimeInterval(-7 * 86400), ending: now, calendars: nil)
        return await withCheckedContinuation { finished in
            store.fetchReminders(matching: predicate) { reminders in
                let candidates = (reminders ?? []).filter { $0.calendar?.allowsContentModifications != false }
                guard let reminder = match(wanted, in: candidates, done: done) else { finished.resume(returning: false); return }
                reminder.isCompleted = done
                finished.resume(returning: (try? store.save(reminder, commit: true)) != nil)
            }
        }
    }

    /// A reminder due by a day's end and not done (`TodayLists.addDueReminders`).
    nonisolated struct DueReminder: Equatable, Sendable {
        var id: String
        var title: String
        var due: Date
    }

    /// Every reminder not done whose day has come: due by `end` (overdue ones too), oldest
    /// first. None without Reminders access (this never asks) or without a due date.
    static func remindersDue(by end: Date) async -> [DueReminder] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return [] }
        let store = EKEventStore()
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
        return await withCheckedContinuation { finished in
            store.fetchReminders(matching: predicate) { reminders in
                let due = (reminders ?? []).compactMap { r -> DueReminder? in
                    guard let date = r.dueDateComponents.flatMap({ Calendar.current.date(from: $0) }), date <= end,
                          let title = r.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
                    return DueReminder(id: r.calendarItemIdentifier, title: title, due: date)
                }
                finished.resume(returning: due.sorted { $0.due < $1.due })
            }
        }
    }

    /// Which of these reminders are done now (or gone from Reminders altogether).
    static func finished(_ ids: Set<String>) async -> Set<String> {
        guard !ids.isEmpty, EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return [] }
        let store = EKEventStore()
        return Set(ids.filter { id in
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return true }
            return reminder.isCompleted
        })
    }

    /// The reminder an item means: its title the item's, or the item's start when the item adds a
    /// word after it ("BP due Oct 30" for "BP", as Make It a List writes a note in). Of several,
    /// the one due first (ticking), or the one done last (taking a tick back).
    static func match(_ wanted: String, in reminders: [EKReminder], done: Bool) -> EKReminder? {
        let titled = reminders.map { (reminder: $0, title: folded($0.title ?? "")) }.filter { !$0.title.isEmpty }
        var found = titled.filter { $0.title == wanted }
        if found.isEmpty { found = titled.filter { wanted.hasPrefix($0.title + " ") } }
        let picked = found.map(\.reminder)
        if done {
            return picked.min { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
        }
        return picked.max { ($0.completionDate ?? .distantPast) < ($1.completionDate ?? .distantPast) }
    }

    /// A title as compared: any case, spaces evened out.
    static func folded(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
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
