import Foundation

/// What an empty conversation offers to start from (`Views/StartScreen.swift`), worked out from
/// what the phone already knows: its calendar, and the tools the gateway says the agent has.
nonisolated enum StartCards {
    /// A calendar event, reduced to what a card needs.
    struct Event: Equatable, Sendable {
        var title: String
        var start: Date
        var end: Date
        var allDay = false
    }

    /// The next thing on the calendar: what the card says, the day to attach, the question it asks.
    struct Upcoming: Equatable, Sendable {
        var title: String
        var subtitle: String
        var day: Date
        var question: String
    }

    /// The card for today's and tomorrow's events: the next event today that hasn't ended (one
    /// under way counts), else whatever is all day today, else tomorrow's first. Nil when both
    /// days are empty.
    static func upcoming(_ events: [Event], now: Date, calendar: Calendar = .current) -> Upcoming? {
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let dayAfter = calendar.date(byAdding: .day, value: 2, to: today) else { return nil }
        func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
        func more(_ count: Int) -> String { count > 0 ? " · \(count) more" : "" }
        let sorted = events.sorted { $0.start < $1.start }

        let left = sorted.filter { $0.start < tomorrow && $0.end > now }
        let timed = left.filter { !$0.allDay }
        if let next = timed.first {
            let when = next.start > now ? "Today at \(time(next.start))" : "Now, until \(time(next.end))"
            return Upcoming(title: next.title, subtitle: when + more(left.count - 1), day: today, question: "What's on my calendar today?")
        }
        if let allDay = left.first {
            return Upcoming(title: allDay.title, subtitle: "Today, all day" + more(left.count - 1), day: today, question: "What's on my calendar today?")
        }
        let next = sorted.filter { $0.start >= tomorrow && $0.start < dayAfter }
        guard let first = next.first(where: { !$0.allDay }) ?? next.first else { return nil }
        let when = first.allDay ? "Tomorrow, all day" : "Tomorrow at \(time(first.start))"
        return Upcoming(title: first.title, subtitle: when + more(next.count - 1), day: tomorrow, question: "What's on my calendar tomorrow?")
    }

    /// Whether the gateway's toolsets include Home Assistant, switched on and set up. Hermes's
    /// own toolset is `homeassistant`; an MCP server of that name registers the same way.
    static func hasHomeAssistant(_ toolsets: [HermesSessionsAPI.Toolset]) -> Bool {
        toolsets.contains { set in
            let name = set.name.lowercased().filter(\.isLetter)
            return name.contains("homeassistant") && set.enabled != false && set.configured != false
        }
    }
}
