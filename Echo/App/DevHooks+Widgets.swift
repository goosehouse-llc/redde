#if DEBUG
import Foundation
import WidgetKit

/// `-echo.demoWidgets [day]`: the Home Screen widgets filled with made-up content, for checking
/// them on a simulator and for screenshots (2026-11-24). Up Next has a pickup to leave for in 25
/// minutes (with `day`, three hours on, so it shows the day in order); Needs You a question to
/// answer and a command; Your Day an idea and the weather; Your Agents four agents; Goals a 5K.
/// With `-echo.demoLists`, Lists shows the demo lists, and a tick on the widget reaches them.
/// While it runs the app's own writers hold off (`WidgetWriter.holding`, `NeedsYou.holding`), as
/// nothing real is there.
extension DevHooks {
    @MainActor
    static func seedWidgets() {
        guard let group = NeedsYou.shared, value("-echo.demoWidgets") != "clear" else { return }
        WidgetWriter.holding = true
        let now = Date.now
        let leaving = value("-echo.demoWidgets") != "day"
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

        // Up Next: the day, a heads-up for the pickup with what to take, and its leaving time.
        let pickupStart = at(leaving ? 43 : 190)
        let events = [
            DayAhead.Event(id: "d1", title: "Budget review", start: at(80), end: at(140), place: "Conference room B", color: "#4C8DFF"),
            DayAhead.Event(id: "d2", title: "Pick up Milo", start: pickupStart, end: pickupStart.addingTimeInterval(1800), place: "Maple Street School", color: "#30D158"),
            DayAhead.Event(id: "d3", title: "Movie night", start: at(330), end: at(450), color: "#BF5AF2"),
        ]
        let leave = DayAhead.Leave(title: "Pick up Milo", start: pickupStart, leave: pickupStart.addingTimeInterval(-18 * 60), travel: 18 * 60, mode: .driving,
                                   latitude: 37.3349, longitude: -122.009, place: "Maple Street School")
        _ = DayAhead(events: events, leaves: [leave], written: now).save()
        var review = AgentBriefing(id: "demo-review", title: "Heads-up: Budget review", agent: "Sol",
                                   text: "You promised Ana the signed copy by Friday. It's still in Drafts.", at: now, failed: false)
        review.eventAt = events[0].start
        var pickup = AgentBriefing(id: "demo-pickup", title: "Heads-up: Pick up Milo", agent: "Sol",
                                   text: "- Milo's swim bag\n- The signed permission slip\n- Rain from 4: take the umbrella", at: now, failed: false)
        pickup.eventAt = pickupStart
        var morning = AgentBriefing(id: "demo-morning", title: "Morning briefing", agent: "Sol",
                                    text: "Budget review with Ana at 2. The signed copy is still in Drafts.", at: at(-120), failed: false)
        morning.read = false
        group.set(try? JSONEncoder().encode([review, pickup, morning]), forKey: "agentBriefings")

        // Your Day's idea.
        let idea = AgentIdea(id: "demo-idea", profile: "default", agent: "Sol", title: "Milo's passport runs out February 20",
                             why: "Renewing takes a few weeks, and you fly to Lisbon on the 4th. Start it this week?", request: "Help me renew Milo's passport.", at: now)
        group.set(try? JSONEncoder().encode([idea]), forKey: "agentIdeas")

        // Goals.
        var goal = GoalReport(id: "demo-5k", title: "Run a 5K", agent: "Sol", done: 3, total: 7,
                              headline: "2 km felt easy on Sunday. Try 3 on Thursday.", at: at(-2 * 1440), failed: false)
        goal.target = at(26 * 1440)
        goal.steps = [
            .init(title: "Buy running shoes", cardID: nil, done: true, who: "you"),
            .init(title: "Run 3 km Thursday", cardID: nil, done: false, who: "you"),
            .init(title: "Run 5 km Sunday", cardID: nil, done: false, who: "you"),
            .init(title: "A four-week training plan", cardID: "c1", done: true, who: "agent"),
            .init(title: "Find a 5K race on December 20", cardID: "c2", done: false, who: "agent"),
        ]
        group.set(try? JSONEncoder().encode([goal.id: goal]), forKey: "goalReports")

        // Needs You: a question with two answers, and a command.
        let requests = [
            WaitingRequest(id: "demo-q", kind: .question, title: "Flights to Lisbon", text: "Both land before noon. Which one should I book?",
                           session: nil, since: at(-3), until: at(60), choices: ["7:05 AM", "9:40 AM"], digest: "demo"),
            WaitingRequest(id: "demo-a", kind: .approval, title: "Clear out the old builds", text: "rm -rf ~/builds/2025-*",
                           session: nil, since: at(-1), until: at(120)),   // (after the question, which leads)
        ]
        group.set(try? JSONEncoder().encode(requests), forKey: "needsYou")
        NeedsYou.holding = true

        // Your Agents.
        _ = WidgetAgents(agents: [
            .init(id: "default", name: "Sol", status: .working, line: "Your Montreal packing list is ready: eight things, two to buy.", at: at(-5), isMain: true),
            .init(id: "home", name: "Home", status: .idle, line: "The dryer finished at 11:40.", at: at(-60), isMain: false),
            .init(id: "coder", name: "Coder", status: .needsYou, line: "Ready to push the login fix.", at: at(-10), isMain: false),
            .init(id: "research", name: "Research", status: .idle, line: "Three hotels near Old Montreal.", at: at(-120), isMain: false),
        ], written: now.addingTimeInterval(3600)).save()   // (believed for the next hour)

        // Your Day's weather: Montreal's, unless the phone has been somewhere lately.
        if WidgetWeather.place(in: group) == nil { group.set([45.5019, -73.5674, now.timeIntervalSince1970], forKey: "lastPlace") }

        // Lists: the demo lists, as the app keeps them for the widget.
        struct Kept: Codable { var server: String; var lists: [TodayList] }
        if TodayLists.demo { group.set(try? JSONEncoder().encode(Kept(server: "", lists: TodayLists.shared.lists)), forKey: "todayLists") }

        WidgetCenter.shared.reloadAllTimelines()
    }
}
#endif
