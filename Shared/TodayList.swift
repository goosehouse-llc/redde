import Foundation

/// The person's lists (asked 2026-11-09: "the ability to ask for a to do list, add things to it,
/// check them off … added to a today card that stays just to the right of email"): kept on the
/// Hermes by Redde's plugin 1.20 (`lists.py`, the agent's `redde_list`), shared by every bot, and
/// each one a tile on the Today row after the Inbox until it is deleted. Not the agent's own todo
/// list (`TodoList`), which is its plan for one turn.
///
/// From plugin 1.37.0 (asked 2026-11-23 of a list of Christmas films: "make these lists a bit more
/// fun"), each list has a look: its kind, an emoji and a colour, the agent's or guessed from the
/// title; a watch list's films and series come with their posters.
///
/// In Shared (2026-11-24) for the Lists widget, which reads the app's copy in the app group;
/// how the plugin's answers are read stays in the app (`TodayLists.swift`).
nonisolated struct TodayList: Codable, Equatable, Identifiable, Sendable {
    struct Item: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var text: String
        var done: Bool
        /// A film's or a series' poster on a watch list (https, or on the person's own network).
        var poster: String? = nil
        var year: Int? = nil
        /// A plan (plugin 1.38): when, and with whom. Redde reminds them on the day and checks after.
        var when: Date? = nil
        var company: String? = nil

        /// "Thu, Nov 26, 7:30 PM · with Robin".
        var plan: String? {
            when.map { withCompany($0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())) }
        }

        /// "7:30 PM · with Robin", for a row that shows its day on its own.
        var timeAndCompany: String? {
            when.map { withCompany($0.formatted(.dateTime.hour().minute())) }
        }

        private func withCompany(_ at: String) -> String {
            guard let company, !company.isEmpty else { return at }
            return at + " · " + String(localized: "with \(company)", comment: "A list item's plan: who it's with, after its date (\"Thu, Nov 26, 7:30 PM · with Robin\")")
        }

        /// Where the date picker opens: its own date while that's ahead, else tomorrow at 9.
        func suggestedDate(now: Date = .now, calendar: Calendar = .current) -> Date {
            if let when, when > now { return when }
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }

        /// Its name without the year it was written with ("Home Alone (1990)").
        var name: String { text.replacing(/\s*\((?:18|19|20)\d\d\)\s*$/, with: "") }
    }

    /// What a list is for: a watch list's titles show as posters.
    enum Kind: String, Codable, Sendable, CaseIterable {
        case watch, todo, shopping, reading, packing, gifts, other
    }

    /// The colours a list can be: the plugin's names.
    enum Hue: String, Codable, Sendable, CaseIterable {
        case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, brown, gray
    }

    var id: String
    var title: String
    var items: [Item]
    var kind: Kind? = nil
    var emoji: String? = nil
    var hue: Hue? = nil

    var open: [Item] { items.filter { !$0.done } }
    var finished: [Item] { items.filter(\.done) }

    /// Where a to-do sits on its list's page (the By When layout, picked 2026-11-23).
    enum When: Hashable, Sendable {
        case overdue, today, thisWeek, later, anytime
    }

    struct WhenGroup: Identifiable, Equatable, Sendable {
        let when: When
        let items: [Item]
        var id: When { when }
    }

    /// Lists of things to do, where a date is the point: not a shopping, packing or watch list.
    var groupsByWhen: Bool { kind == nil || kind == .todo || kind == .other }

    /// What's left, soonest first: overdue (before today; earlier today is still today), today, the
    /// rest of this calendar week, later, and anytime (no date, in the list's own order). Groups
    /// with nothing in them are left out.
    func openByWhen(now: Date = .now, calendar: Calendar = .current) -> [WhenGroup] {
        let today = calendar.startOfDay(for: now)
        let weekEnd = calendar.dateInterval(of: .weekOfYear, for: now)?.end ?? today.addingTimeInterval(7 * 86_400)
        let placed = Dictionary(grouping: open) { item -> When in
            guard let date = item.when else { return .anytime }
            if date < today { return .overdue }
            if calendar.isDate(date, inSameDayAs: now) { return .today }
            return date < weekEnd ? .thisWeek : .later
        }
        return [When.overdue, .today, .thisWeek, .later, .anytime].compactMap { when in
            guard var items = placed[when] else { return nil }
            if when != .anytime { items.sort { ($0.when ?? .distantFuture) < ($1.when ?? .distantFuture) } }
            return WhenGroup(when: when, items: items)
        }
    }
}
