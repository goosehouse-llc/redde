import EventKit
import Foundation

/// EventKit reminders, mirroring CalendarService's shape: its own store, one serial queue,
/// read-mostly with create/complete behind --allow-writes. Reminders authorization is separate
/// from Calendar's, so this asks (and can be denied) on its own.
final class ReminderService {
    let allowWrites: Bool
    private let store = EKEventStore()
    private let queue = DispatchQueue(label: "com.goosehouse.redde-calendar-mcp.reminders")
    static let maxReminders = 300

    init(allowWrites: Bool) { self.allowWrites = allowWrites }

    var accessStatus: String {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: "granted"
        case .writeOnly: "write-only"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not requested yet"
        @unknown default: "unknown"
        }
    }

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    func requestAccess() {
        guard EKEventStore.authorizationStatus(for: .reminder) == .notDetermined else {
            Log.info("reminders access: \(accessStatus)"); return
        }
        store.requestFullAccessToReminders { granted, error in
            Log.info("reminders access \(granted ? "granted" : "not granted")\(error.map { ": \($0.localizedDescription)" } ?? "")")
        }
    }

    private func requireAccess() throws {
        guard hasAccess else {
            throw ToolError("Reminders access is \(accessStatus) on this Mac. Allow \"Redde Calendar MCP\" in System Settings → Privacy & Security → Reminders.")
        }
    }

    func lists() throws -> [[String: Any]] {
        try requireAccess()
        return queue.sync {
            store.calendars(for: .reminder).map { list in
                [
                    "id": list.calendarIdentifier,
                    "title": list.title,
                    "account": list.source.title,
                    "is_default": list.calendarIdentifier == store.defaultCalendarForNewReminders()?.calendarIdentifier,
                ]
            }
        }
    }

    private func resolveLists(_ ids: [String]?) throws -> [EKCalendar]? {
        guard let ids, !ids.isEmpty else { return nil }
        let chosen = store.calendars(for: .reminder).filter { ids.contains($0.calendarIdentifier) || ids.contains($0.title) }
        guard !chosen.isEmpty else { throw ToolError("None of those reminder lists exist. list_reminders with no filter shows every list's name.") }
        return chosen
    }

    /// The reminders fetch API is callback-only; run it on the queue and wait.
    private func fetch(_ predicate: NSPredicate) -> [EKReminder] {
        queue.sync {
            var out: [EKReminder] = []
            let done = DispatchSemaphore(value: 0)
            store.fetchReminders(matching: predicate) { found in
                out = found ?? []
                done.signal()
            }
            _ = done.wait(timeout: .now() + 10)
            return out
        }
    }

    func incomplete(listIDs: [String]?) throws -> [EKReminder] {
        try requireAccess()
        let lists = try queue.sync { try resolveLists(listIDs) }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
        return fetch(predicate)
    }

    func completedRecently(days: Int, listIDs: [String]?) throws -> [EKReminder] {
        try requireAccess()
        let lists = try queue.sync { try resolveLists(listIDs) }
        let start = Date().addingTimeInterval(-Double(days) * 86400)
        let predicate = store.predicateForCompletedReminders(withCompletionDateStarting: start, ending: Date(), calendars: lists)
        return fetch(predicate)
    }

    func createReminder(title: String, due: Date?, allDayDue: Bool, notes: String?, listID: String?) throws -> (EKReminder, existed: Bool) {
        guard allowWrites else { throw ToolError("This server is read-only.") }
        try requireAccess()
        // Idempotent like create_event: an incomplete reminder with the same title (and same
        // due day, when one is given) is returned instead of a copy.
        let existing = try incomplete(listIDs: listID.map { [$0] })
        if let match = existing.first(where: { reminder in
            guard reminder.title.caseInsensitiveCompare(title) == .orderedSame else { return false }
            guard let due else { return reminder.dueDateComponents == nil }
            guard let comps = reminder.dueDateComponents, let existingDue = Calendar.current.date(from: comps) else { return false }
            return Calendar.current.isDate(existingDue, inSameDayAs: due)
        }) {
            return (match, true)
        }
        return try queue.sync {
            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.notes = notes
            if let listID {
                guard let list = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == listID || $0.title == listID }) else {
                    throw ToolError("No reminder list named \(listID).")
                }
                reminder.calendar = list
            } else {
                reminder.calendar = store.defaultCalendarForNewReminders()
            }
            if let due {
                var units: Set<Calendar.Component> = [.year, .month, .day]
                if !allDayDue { units.formUnion([.hour, .minute]) }
                reminder.dueDateComponents = Calendar.current.dateComponents(units, from: due)
                if !allDayDue { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
            }
            try store.save(reminder, commit: true)
            return (reminder, false)
        }
    }

    func complete(id: String?, title: String?) throws -> EKReminder {
        guard allowWrites else { throw ToolError("This server is read-only.") }
        try requireAccess()
        let open = try incomplete(listIDs: nil)
        let match: EKReminder?
        if let id, !id.isEmpty {
            match = open.first { $0.calendarItemIdentifier == id }
        } else if let title, !title.isEmpty {
            match = open.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
                ?? open.first { $0.title.localizedCaseInsensitiveContains(title) }
        } else {
            throw ToolError("Pass an id or a title.")
        }
        guard let reminder = match else { throw ToolError("No open reminder matches that. list_reminders shows what's open.") }
        return try queue.sync {
            reminder.isCompleted = true
            try store.save(reminder, commit: true)
            return reminder
        }
    }

    static func describe(_ reminder: EKReminder) -> [String: Any] {
        var item: [String: Any] = [
            "id": reminder.calendarItemIdentifier,
            "title": reminder.title ?? "",
            "list": reminder.calendar?.title ?? "",
            "completed": reminder.isCompleted,
        ]
        if let comps = reminder.dueDateComponents, let due = Calendar.current.date(from: comps) {
            let hasTime = comps.hour != nil
            item["due"] = hasTime ? DateCodec.string(due) : DayParser.dayString.string(from: due)
            if !reminder.isCompleted, due < (hasTime ? Date() : Calendar.current.startOfDay(for: Date())) {
                item["overdue"] = true
            }
        }
        if let notes = reminder.notes, !notes.isEmpty { item["notes"] = String(notes.prefix(500)) }
        if reminder.priority > 0 { item["priority"] = reminder.priority }
        if let done = reminder.completionDate { item["completed_at"] = DateCodec.string(done) }
        return item
    }

    /// Overdue first (oldest first), then dated soonest-first, then undated.
    static func sorted(_ reminders: [EKReminder]) -> [EKReminder] {
        reminders.sorted { a, b in
            let da = a.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            let db = b.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            switch (da, db) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return (a.title ?? "") < (b.title ?? "")
            }
        }
    }
}
