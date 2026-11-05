import EventKit
import Foundation

/// What the agent set on this device through the phone tools, for Planned (asked 2026-11-03: "show
/// things like reminders, or other actions set"): the reminders and calendar events it added, by
/// id, kept here because EventKit doesn't say who made one. Alarms and timers are
/// `DeviceAlarms`' own list. Read when Planned appears or is pulled; nothing polls.
nonisolated enum PhoneMade {
    struct Record: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case reminder, event }
        var kind: Kind
        var id: String
        var title: String
        /// A reminder's due time, an event's start.
        var at: Date?
        var added: Date
    }

    /// What a reminder or event is now, as EventKit has it; nil when it's gone.
    struct Now: Equatable, Sendable {
        var title: String
        var at: Date?
        var completed = false
    }

    /// An alarm or timer Redde set and iOS still holds.
    struct Alarm: Equatable, Sendable {
        var id: String
        var title: String
        var rings: Date
        var timer: Bool
    }

    static var file: URL { .applicationSupportDirectory.appending(path: "phone-made.json") }
    static let most = 200
    /// Kept this long after it was added, done or not.
    static let keep: TimeInterval = 60 * 24 * 3600

    static func load(from file: URL = file) -> [Record] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
    }

    static func save(_ records: [Record], to file: URL = file) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(records).write(to: file, options: .atomic)
    }

    /// One the agent just added. The newest are kept.
    static func note(_ record: Record, file: URL = file, now: Date = .now) {
        guard !record.id.isEmpty else { return }
        var records = load(from: file).filter { $0.id != record.id && now.timeIntervalSince($0.added) < keep }
        records.append(record)
        save(Array(records.suffix(most)), to: file)
    }

    static func forget(_ ids: Set<String>, file: URL = file) {
        guard !ids.isEmpty else { return }
        save(load(from: file).filter { !ids.contains($0.id) }, to: file)
    }

    /// Planned's rows for what the agent set here, from `now` to `within` on: alarms and timers
    /// yet to ring, reminders not done (one overdue still shows, under today), events not over.
    /// `gone` are the records to forget: deleted, or a reminder done.
    static func items(alarms: [Alarm], records: [Record], live: [String: Now], now: Date,
                      within: TimeInterval) -> (items: [ComingUp.Item], gone: Set<String>) {
        let end = now.addingTimeInterval(within)
        var items: [ComingUp.Item] = []
        var gone: Set<String> = []
        for alarm in alarms where alarm.rings > now && alarm.rings <= end {
            items.append(ComingUp.Item(id: "alarm/" + alarm.id, kind: alarm.timer ? .timer : .alarm, title: alarm.title,
                                       profile: nil, at: alarm.rings, phoneID: alarm.id))
        }
        for record in records {
            guard let state = live[record.id] else { gone.insert(record.id); continue }
            switch record.kind {
            case .reminder:
                if state.completed { gone.insert(record.id); continue }
                // A reminder with no time isn't on a day: it shows today, until it is done.
                let at = state.at ?? now
                guard at <= end else { continue }
                items.append(ComingUp.Item(id: "reminder/" + record.id, kind: .reminder, title: state.title, profile: nil,
                                           at: at, cadence: state.at == nil ? String(localized: "No due time", comment: "Planned: a reminder the agent added without a time") : nil,
                                           phoneID: record.id, untimed: state.at == nil))
            case .event:
                guard let at = state.at, at > now.addingTimeInterval(-3600), at <= end else { continue }
                items.append(ComingUp.Item(id: "event/" + record.id, kind: .event, title: state.title, profile: nil, at: at,
                                           phoneID: record.id))
            }
        }
        return (items, gone)
    }

    /// Reads it all, off the main actor: EventKit and AlarmKit are asked only with access already
    /// given (Planned never asks).
    @concurrent static func read(now: Date, within: TimeInterval) async -> [ComingUp.Item] {
        let records = load()
        var live: [String: Now] = [:]
        let store = EKEventStore()
        let reminders = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        let events = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        for record in records {
            switch record.kind {
            case .reminder:
                guard reminders else { live[record.id] = Now(title: record.title, at: record.at); continue }
                if let reminder = store.calendarItem(withIdentifier: record.id) as? EKReminder {
                    live[record.id] = Now(title: reminder.title ?? record.title,
                                          at: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                                          completed: reminder.isCompleted)
                }
            case .event:
                guard events else { live[record.id] = Now(title: record.title, at: record.at); continue }
                if let event = store.event(withIdentifier: record.id) {
                    live[record.id] = Now(title: event.title ?? record.title, at: event.startDate)
                }
            }
        }
        var alarms: [Alarm] = []
        #if os(iOS)
        alarms = ((try? DeviceAlarms().upcoming()) ?? []).map { Alarm(id: $0.id.uuidString, title: $0.title, rings: $0.rings, timer: $0.timer) }
        #endif
        let made = items(alarms: alarms, records: records, live: live, now: now, within: within)
        forget(made.gone)
        return made.items
    }
}
