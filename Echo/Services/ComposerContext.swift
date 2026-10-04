import EventKit
import Foundation

/// Things the draft mentions that the phone can attach on the spot, offered as chips above the
/// field: a day the calendar has entries for, a file attached to a recent conversation. All
/// found on the device; nothing is attached until the chip is tapped.
nonisolated enum ComposerContext {
    enum Suggestion: Identifiable, Equatable, Sendable {
        /// A day mentioned in the draft ("tomorrow at 9", "Oct 24").
        case calendar(day: Date)
        /// A file the user attached before, named in the draft.
        case file(Attachment)

        var id: String {
            switch self {
            case let .calendar(day): "calendar-\(Int(day.timeIntervalSinceReferenceDate))"
            case let .file(att): "file-\(att.id.uuidString)"
            }
        }

        var title: String {
            switch self {
            case let .calendar(day): "Calendar · " + day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            case let .file(att): "Attach " + att.filename
            }
        }

        var symbol: String {
            switch self {
            case .calendar: "calendar"
            case .file: "doc"
            }
        }
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    private static let draftCap = 2000

    /// The chips for a draft: up to two days and two files, in the order they appear.
    static func suggestions(for draft: String, recentFiles: [Attachment]) -> [Suggestion] {
        guard !draft.isEmpty, draft.count <= draftCap else { return [] }
        var out: [Suggestion] = []
        for day in days(in: draft).prefix(2) { out.append(.calendar(day: day)) }
        let lowered = draft.lowercased()
        var seenNames = Set<String>()
        for att in recentFiles where !att.filename.isEmpty && lowered.contains(att.filename.lowercased()) {
            guard seenNames.insert(att.filename.lowercased()).inserted else { continue }
            out.append(.file(att))
            if seenNames.count == 2 { break }
        }
        return out
    }

    /// The distinct days the draft mentions, as midnight in the current calendar.
    static func days(in draft: String) -> [Date] {
        guard let detector else { return [] }
        let calendar = Calendar.current
        var days: [Date] = []
        for match in detector.matches(in: draft, range: NSRange(draft.startIndex..., in: draft)) {
            guard let date = match.date else { continue }
            let day = calendar.startOfDay(for: date)
            if !days.contains(day) { days.append(day) }
        }
        return days
    }

    /// Files attached in the open conversation and the most recent others, newest first.
    @MainActor
    static func recentFiles(current: [Message], store: ConversationStore, limit: Int = 8) -> [Attachment] {
        var files: [Attachment] = []
        func take(_ messages: [Message]) {
            for message in messages.reversed() {
                for att in message.attachments where att.kind != .image && !files.contains(where: { $0.filename == att.filename }) {
                    files.append(att)
                }
            }
        }
        take(current)
        for summary in store.sorted.prefix(limit) {
            if let record = store.cachedRecord(id: summary.id) { take(record.messages) }
        }
        return files
    }

    // MARK: Calendar

    /// That day's events as a text attachment, asking for calendar access the first time.
    /// Nil when access is refused.
    static func calendarAttachment(for day: Date) async -> Attachment? {
        let store = EKEventStore()
        let allowed: Bool
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: allowed = true
        case .notDetermined: allowed = (try? await store.requestFullAccessToEvents()) ?? false
        default: allowed = false
        }
        guard allowed else { return nil }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
        let text = describe(events: events, day: start)
        return Attachment(kind: .text, filename: "calendar-" + start.formatted(.iso8601.year().month().day()) + ".txt",
                          mimeType: "text/plain", data: Data(text.utf8))
    }

    /// "Calendar for Friday, October 24, 2026:" then one line per event; or that it is free.
    static func describe(events: [EKEvent], day: Date) -> String {
        let heading = "Calendar for " + day.formatted(.dateTime.weekday(.wide).month(.wide).day().year()) + ":"
        guard !events.isEmpty else { return heading + "\nNo events." }
        let lines = events.map { event -> String in
            var line = "- "
            if event.isAllDay {
                line += "All day: "
            } else {
                line += event.startDate.formatted(date: .omitted, time: .shortened) + "–"
                    + event.endDate.formatted(date: .omitted, time: .shortened) + " "
            }
            line += event.title ?? "(untitled)"
            if let location = event.location, !location.isEmpty { line += " (" + location + ")" }
            return line
        }
        return ([heading] + lines).joined(separator: "\n")
    }
}
