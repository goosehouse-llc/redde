import EventKit
import Foundation

/// EventKit, read-mostly. All access goes through one serial queue.
final class CalendarService {
    let allowWrites: Bool
    private let store = EKEventStore()
    private let queue = DispatchQueue(label: "com.goosehouse.redde-calendar-mcp.eventkit")
    static let maxRangeDays = 400
    static let maxEvents = 500
    static let maxNotes = 1000

    init(allowWrites: Bool) { self.allowWrites = allowWrites }

    var accessStatus: String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: "granted"
        case .writeOnly: "write-only"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not requested yet"
        @unknown default: "unknown"
        }
    }

    var hasReadAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Asks for full Calendar access once; macOS shows its permission prompt the first time.
    func requestAccess() {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else {
            Log.info("calendar access: \(accessStatus)"); return
        }
        store.requestFullAccessToEvents { granted, error in
            Log.info("calendar access \(granted ? "granted" : "not granted")\(error.map { ": \($0.localizedDescription)" } ?? "")")
        }
    }

    private func requireAccess() throws {
        guard hasReadAccess else {
            throw ToolError("Calendar access is \(accessStatus) on this Mac. Allow \"Redde Calendar MCP\" in System Settings → Privacy & Security → Calendars.")
        }
    }

    func calendars() throws -> [[String: Any]] {
        try requireAccess()
        return queue.sync {
            store.calendars(for: .event).map { cal in
                [
                    "id": cal.calendarIdentifier,
                    "title": cal.title,
                    "account": cal.source.title,
                    "allows_changes": cal.allowsContentModifications,
                    "subscribed": cal.type == .subscription || cal.type == .birthday,
                    "hidden_from_agenda": Self.isBackground(cal),
                    "is_default": cal.calendarIdentifier == store.defaultCalendarForNewEvents?.calendarIdentifier,
                ]
            }
        }
    }

    private func resolveCalendars(_ ids: [String]?) throws -> [EKCalendar]? {
        guard let ids, !ids.isEmpty else { return nil }
        let all = store.calendars(for: .event)
        let chosen = all.filter { ids.contains($0.calendarIdentifier) || ids.contains($0.title) }
        guard !chosen.isEmpty else { throw ToolError("None of those calendars exist. Use list_calendars for ids.") }
        return chosen
    }

    func events(from start: Date, to end: Date, calendarIDs: [String]?) throws -> [EKEvent] {
        try requireAccess()
        guard end > start else { throw ToolError("end must be after start") }
        guard end.timeIntervalSince(start) <= Double(Self.maxRangeDays) * 86400 else {
            throw ToolError("The range can be at most \(Self.maxRangeDays) days.")
        }
        return try queue.sync {
            let calendars = try resolveCalendars(calendarIDs)
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
            return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        }
    }

    func event(id: String) throws -> EKEvent {
        try requireAccess()
        guard let event = queue.sync(execute: { store.event(withIdentifier: id) }) else {
            throw ToolError("No event with that id.")
        }
        return event
    }

    var defaultCalendarTitle: String? {
        guard hasReadAccess else { return nil }
        return queue.sync { store.defaultCalendarForNewEvents?.title }
    }

    /// Adds an event. There is deliberately no edit or delete anywhere in this server. Returns the
    /// existing event instead when one with the same title already starts at the same time, so a
    /// retried call can't make copies.
    func createEvent(title: String, start: Date, end: Date, allDay: Bool, calendarID: String?,
                     location: String?, notes: String?) throws -> (EKEvent, existed: Bool) {
        guard allowWrites else { throw ToolError("This server is read-only.") }
        try requireAccess()
        return try queue.sync {
            let target: EKCalendar
            if let calendarID {
                let all = store.calendars(for: .event)
                guard let cal = all.first(where: { $0.calendarIdentifier == calendarID })
                        ?? all.first(where: { $0.title.caseInsensitiveCompare(calendarID) == .orderedSame }) else {
                    throw ToolError("No calendar called \(calendarID). list_calendars shows the names.")
                }
                target = cal
            } else {
                guard let cal = store.defaultCalendarForNewEvents else { throw ToolError("No default calendar is set.") }
                target = cal
            }
            guard target.allowsContentModifications else { throw ToolError("\(target.title) is read-only.") }

            let window = store.predicateForEvents(withStart: start.addingTimeInterval(-60), end: start.addingTimeInterval(60), calendars: [target])
            if let existing = store.events(matching: window).first(where: {
                abs($0.startDate.timeIntervalSince(start)) < 60 && ($0.title ?? "").caseInsensitiveCompare(title) == .orderedSame
            }) {
                return (existing, true)
            }

            let event = EKEvent(eventStore: store)
            event.calendar = target
            event.title = title
            event.startDate = start
            event.endDate = end
            event.isAllDay = allDay
            if let location, !location.isEmpty { event.location = location }
            if let notes, !notes.isEmpty { event.notes = notes }
            try store.save(event, span: .thisEvent, commit: true)
            Log.info("created event on \(target.title) at \(DateCodec.string(start))")
            return (event, false)
        }
    }

    /// Google and Outlook invites often carry HTML notes. Keep the words and the link targets.
    static func plainText(_ text: String) -> String {
        guard text.contains("<") || text.contains("&") else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var s = text
        func sub(_ pattern: String, _ template: String) {
            s = (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]))
                .map { $0.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template) } ?? s
        }
        sub(#"<a\s[^>]*href\s*=\s*["']([^"']*)["'][^>]*>(.*?)</a>"#, "$2 ($1)")
        sub(#"<(br|/p|/div|/li|/tr|/h[1-6])\b[^>]*>"#, "\n")
        sub(#"<li\b[^>]*>"#, "- ")
        sub(#"<[^>]+>"#, "")
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        // "https://x (https://x)" when the link text was the URL itself.
        sub(#"(\S+) \(\1\)"#, "$1")
        s = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        sub(#"\n{3,}"#, "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sports schedules, holidays and birthdays: shown when asked for, but not in an agenda or as busy time.
    static func isBackground(_ cal: EKCalendar?, hidden: Set<String> = ServerSettings.hiddenCalendars) -> Bool {
        guard let cal else { return false }
        if cal.type == .subscription || cal.type == .birthday { return true }
        if cal.title.lowercased().contains("holiday") { return true }
        return hidden.contains(cal.title.lowercased()) || hidden.contains(cal.calendarIdentifier.lowercased())
    }

    /// The short form for lists: enough to answer "what's on my calendar", without notes and attendees.
    static func summarize(_ event: EKEvent) -> [String: Any] {
        var out: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "start": DateCodec.string(event.startDate),
            "end": DateCodec.string(event.endDate),
            "calendar": event.calendar?.title ?? "",
        ]
        if event.isAllDay { out["all_day"] = true }
        if let location = event.location, !location.isEmpty { out["location"] = String(location.prefix(120)) }
        if let count = event.attendees?.count, count > 0 { out["attendees"] = count }
        if event.availability == .free { out["availability"] = "free" }
        return out
    }

    static func describe(_ event: EKEvent) -> [String: Any] {
        var out: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "start": DateCodec.string(event.startDate),
            "end": DateCodec.string(event.endDate),
            "all_day": event.isAllDay,
            "calendar": event.calendar?.title ?? "",
            "calendar_id": event.calendar?.calendarIdentifier ?? "",
            "recurring": event.hasRecurrenceRules,
        ]
        if let location = event.location, !location.isEmpty { out["location"] = location }
        if let url = event.url { out["url"] = url.absoluteString }
        if let raw = event.notes {
            let notes = plainText(raw)
            if !notes.isEmpty { out["notes"] = notes.count > maxNotes ? String(notes.prefix(maxNotes)) + "…" : notes }
        }
        if let organizer = event.organizer { out["organizer"] = organizer.name ?? "" }
        if let attendees = event.attendees, !attendees.isEmpty {
            out["attendees"] = attendees.map { a -> [String: Any] in
                var p: [String: Any] = ["name": a.name ?? ""]
                let mail = a.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                if mail.contains("@") { p["email"] = mail }
                p["status"] = switch a.participantStatus {
                case .accepted: "accepted"
                case .declined: "declined"
                case .tentative: "tentative"
                case .pending: "pending"
                default: "unknown"
                }
                return p
            }
        }
        switch event.availability {
        case .free: out["availability"] = "free"
        case .tentative: out["availability"] = "tentative"
        case .unavailable: out["availability"] = "unavailable"
        default: out["availability"] = "busy"
        }
        return out
    }
}
