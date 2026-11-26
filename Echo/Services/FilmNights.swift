import EventKit
import Foundation

/// A watch list's films and series with a night, on the calendar (asked 2026-11-26: "When a movie
/// on list is given a time and date, have it added to the calendar"). Whoever gives the night, the
/// agent or a long press, Redde puts an event in the calendar for new events and keeps it in step
/// each time the lists are read: moved with the night, renamed with the film, and gone when the
/// night is taken off, or the film is ticked or taken off the list before it. A night already past
/// is left as it is.
///
/// Redde's events carry the item in their URL (`redde://list/<list>/<item>`), and only those are
/// moved or deleted, and only for a list this server has (`known`): another server's stay. One the
/// agent added before, at the same time with the film's name, is taken over rather than doubled.
/// Every device does the same; two made at once, before iCloud brought one to the other, are made
/// one again by keeping the one whose identifier on the calendar's server sorts first, which every
/// device sees alike. The plugin is told (`lists nights`, 1.50), so the agent leaves it to Redde.
nonisolated enum FilmNights {
    /// A night as it should be on the calendar.
    struct Night: Equatable, Sendable {
        var list: String
        var item: String
        /// The film's name, as the list has it.
        var name: String
        /// What the event is called: the list's emoji, the name, who it's with.
        var title: String
        var start: Date
        var notes: String
        var key: String { "\(list)/\(item)" }
    }

    /// An event of Redde's, as plain values.
    struct Placed: Equatable, Sendable {
        var id: String
        /// The calendar server's identifier: the same on every device.
        var external: String
        var key: String
        var title: String
        var start: Date
        var end: Date
    }

    /// An event not Redde's at the time of a night.
    struct Other: Equatable, Sendable {
        var id: String
        var title: String
        var start: Date
        var editable: Bool
    }

    enum Step: Equatable, Sendable {
        case add(Night)
        /// Marks an event already there (the agent's) as this night's.
        case adopt(id: String, Night)
        /// Moves it to the night, keeping how long it is, and names it again when the film's name
        /// isn't in its title.
        case update(id: String, Night, length: TimeInterval, retitle: Bool)
        case remove(id: String)
    }

    /// How long a night is on the calendar.
    static let length: TimeInterval = 2 * 3600
    /// How far ahead nights are looked for: the plugin's 60 days, and a little.
    static let reach: TimeInterval = 62 * 86_400

    static func url(list: String, item: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "redde"
        parts.host = "list"
        parts.path = "/\(list)/\(item)"
        return parts.url
    }

    /// The list and item an event of Redde's is for.
    static func key(of url: URL?) -> String? {
        guard let url, url.scheme == "redde", url.host == "list" else { return nil }
        let parts = url.path.split(separator: "/")
        return parts.count == 2 ? "\(parts[0])/\(parts[1])" : nil
    }

    /// The nights the watch lists have still to come: not ticked off, with a time ahead.
    static func wanted(_ lists: [TodayList], now: Date) -> [Night] {
        lists.filter { $0.kind == .watch }.flatMap { list in
            list.items.compactMap { item -> Night? in
                guard !item.done, let when = item.when, when > now else { return nil }
                var title = item.name
                if let company = item.company, !company.isEmpty {
                    title += " · " + String(localized: "with \(company)", comment: "A list item's plan: who it's with, after its date (\"Thu, Nov 26, 7:30 PM · with Robin\")")
                }
                if let emoji = list.emoji { title = emoji + " " + title }
                let listTitle = list.title
                return Night(list: list.id, item: item.id, name: item.name, title: title, start: when,
                             notes: String(localized: "From your \(listTitle) list in Redde.",
                                           comment: "The notes of a calendar event Redde makes for a film planned for a night on a watch list"))
            }
        }
    }

    /// What to do to the calendar: `placed` are Redde's events ahead, `others` the rest at the
    /// nights' times, `known` the lists this server has had.
    static func steps(wanted: [Night], placed: [Placed], others: [Other], known: Set<String>, now: Date) -> [Step] {
        var steps: [Step] = []
        let ahead = Dictionary(grouping: placed.filter { $0.start > now }, by: \.key)
        var taken = Set<String>()
        for night in wanted {
            let mine = (ahead[night.key] ?? []).sorted { ($0.external, $0.id) < ($1.external, $1.id) }
            if let kept = mine.first {
                steps += mine.dropFirst().map { .remove(id: $0.id) }
                let moved = abs(kept.start.timeIntervalSince(night.start)) >= 60
                let retitle = !folded(kept.title).contains(folded(night.name))
                if moved || retitle {
                    steps.append(.update(id: kept.id, night, length: max(kept.end.timeIntervalSince(kept.start), 60), retitle: retitle))
                }
                continue
            }
            let same = others.filter { !taken.contains($0.id) && abs($0.start.timeIntervalSince(night.start)) < 60
                && folded($0.title).contains(folded(night.name)) }
            if let other = same.first(where: \.editable) {
                taken.insert(other.id)
                steps.append(.adopt(id: other.id, night))
            } else if same.isEmpty {
                steps.append(.add(night))
            }   // (one there that can't be changed: it stays the night's, not doubled)
        }
        let wantedKeys = Set(wanted.map(\.key))
        for (key, events) in ahead where !wantedKeys.contains(key) {
            guard let list = key.split(separator: "/").first, known.contains(String(list)) else { continue }
            steps += events.map { .remove(id: $0.id) }
        }
        return steps
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Whether Redde may read and change the calendar without asking.
    static var canPlace: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    /// Whether iOS was asked and said no (or only to adding events, which can't be kept in step).
    static var refused: Bool {
        let access = EKEventStore.authorizationStatus(for: .event)
        return access != .fullAccess && access != .notDetermined
    }

    /// Puts the nights on the calendar: what it did, or nil without full access to the calendar.
    @discardableResult
    static func place(_ lists: [TodayList], known: Set<String>, now: Date = .now) async -> [Step]? {
        guard canPlace else { return nil }
        let nights = wanted(lists, now: now)
        return await CalendarReader.shared.read { store in
            let found = store.events(matching: store.predicateForEvents(withStart: now, end: now.addingTimeInterval(reach), calendars: nil))
            var placed: [Placed] = [], others: [Other] = []
            for event in found {
                if let key = key(of: event.url) {
                    placed.append(Placed(id: event.eventIdentifier ?? "", external: event.calendarItemExternalIdentifier ?? "",
                                         key: key, title: event.title ?? "", start: event.startDate, end: event.endDate))
                } else if !event.isAllDay, nights.contains(where: { abs(event.startDate.timeIntervalSince($0.start)) < 60 }) {
                    others.append(Other(id: event.eventIdentifier ?? "", title: event.title ?? "", start: event.startDate,
                                        editable: event.calendar?.allowsContentModifications == true))
                }
            }
            let todo = steps(wanted: nights, placed: placed, others: others, known: known, now: now)
            var done: [Step] = []
            for step in todo {
                do {
                    switch step {
                    case let .add(night):
                        guard let calendar = DeviceCalendar.newEventsCalendar(in: store) else { continue }
                        let event = EKEvent(eventStore: store)
                        event.calendar = calendar
                        fill(event, night, length: length, retitle: true)
                        try store.save(event, span: .thisEvent, commit: false)
                    case let .adopt(id, night):
                        guard let event = store.event(withIdentifier: id) else { continue }
                        event.url = url(list: night.list, item: night.item)
                        try store.save(event, span: .thisEvent, commit: false)
                    case let .update(id, night, length, retitle):
                        guard let event = store.event(withIdentifier: id) else { continue }
                        fill(event, night, length: length, retitle: retitle)
                        try store.save(event, span: .thisEvent, commit: false)
                    case let .remove(id):
                        guard let event = store.event(withIdentifier: id) else { continue }
                        try store.remove(event, span: .thisEvent, commit: false)
                    }
                    done.append(step)
                } catch {
                    continue
                }
            }
            if !done.isEmpty { try? store.commit() }
            return done
        }
    }

    private static func fill(_ event: EKEvent, _ night: Night, length: TimeInterval, retitle: Bool) {
        if retitle { event.title = night.title }
        event.startDate = night.start
        event.endDate = night.start.addingTimeInterval(length)
        event.isAllDay = false
        if event.notes?.isEmpty ?? true { event.notes = night.notes }
        event.url = url(list: night.list, item: night.item)
    }
}
