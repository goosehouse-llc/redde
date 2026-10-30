#if DEBUG
import Foundation
import UserNotifications

/// "A day with Redde", the promo video for the release with briefings, ideas, @tags, triggers,
/// watches and routines (design/video, `make_day.py`): `-echo.demoDay [scene]`, with
/// `-echo.demoProjects -echo.demoBots -displayName Sol`. Everything in it is made up: the agents
/// are Sol (the main one), Home and Coder; the people, the dog and the places are nobody's.
///
/// With it on, the bots are those three, the chat list's chats an ordinary day's, a chat's and an
/// @tag's answers canned (`DemoDayTransport`: nothing goes to a server), and the screens that read
/// the server show sample data: Agent Activity, Plugin Updates (its updates "install"), a new
/// watch's agents and a routine's schedule. The scenes:
/// - `morning`: the Week Ahead waiting in Briefings; `-echo.demoDayAt` seconds in (five by
///   default) the dentist's heads-up comes, as a banner over the chat list and on top of the deck,
///   with its time, when to leave and its address (an event card and a map when it's opened).
/// - `week`: the Week Ahead on top of the deck (the heads-up read), its strip of days.
/// - `ideas`: three idea cards (and the briefings, read).
/// - `evening`: the Evening wrap-up waiting in Briefings.
/// - `home`: Home's answer to the arrive-home automation, as Redde's notification, that many
///   seconds in (Redde in the background by then, as the automation runs it).
/// - `dinner`, `packing`: an empty chat with Sol, whose answers come with a choice card (where to
///   eat) and a checklist card (the cabin's packing list).
/// - `routine`: a chat in which Sol planned the week's dinners, Make This a Routine open over it.
/// - `watch`: New Watch open, on the garage door.
/// The `morning` and `home` scenes ask to send notifications; a UI test taps Allow.
@MainActor
enum DemoDay {
    static var on: Bool { DevHooks.has("-echo.demoDay") }
    static var scene: String? { DevHooks.value("-echo.demoDay") }
    static var arrivesAfter: Double { DevHooks.value("-echo.demoDayAt").flatMap(Double.init) ?? 5 }

    /// The story's clock, for what counts down from now (`EventCard`): the simulator's clock is
    /// the Mac's, and the status bar is set to the scene's time. Nil outside the morning.
    static var storyNow: Date? { on && scene == "morning" ? today(7, 0) : nil }

    /// The made-up places' addresses (real streets, so the map has somewhere to put its pin).
    nonisolated static let dentistAddress = "214 Pine Street, Burlington, VT 05401"
    nonisolated static let lupaAddress = "36 Maple Street, Burlington, VT 05401"

    // MARK: The agents

    static var roster: BotRoster {
        BotRoster(bots: [
            HermesBot(name: "default", isDefault: true, isSetUp: true, lastActive: .now.addingTimeInterval(-900), preview: "Booked: tomorrow at 3:30."),
            HermesBot(name: "home", title: "Home", description: "Looks after the house", isSetUp: true, lastActive: .now.addingTimeInterval(-300),
                      preview: "Yep, it's shut. I closed it at 8:12."),
            HermesBot(name: "coder", title: "Coder", description: "Writes and fixes code", isSetUp: true, lastActive: .now.addingTimeInterval(-5_400),
                      preview: "The tests pass. Ready for your review."),
        ])
    }

    /// Today at a time of the story's (the simulator's clock is the Mac's).
    static func today(_ hour: Int, _ minute: Int, daysAgo: Int = 0) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    /// The chat list's chats: an ordinary week's, from yesterday back, so no time on them
    /// disagrees with the story's.
    static var chats: [HermesSessionsAPI.SessionSummary] {
        let now = Int(today(21, 30, daysAgo: 1).timeIntervalSince1970)
        let rows: [(String, String, String, Int)] = [
            ("day-1", "Dinner plan for the week", "Five dinners, and the shopping is on your list.", 0),
            ("day-2", "Milo's birthday ideas", "A dinosaur cake, or the planetarium?", 9_000),
            ("day-3", "Fix the bike's back brake", "Tighten the cable a quarter turn first.", 30_000),
            ("day-4", "Weekend weather", "Sunny Saturday, rain on Sunday afternoon.", 90_000),
        ]
        let json = "[" + rows.map { id, title, preview, ago in
            #"{"id":"\#(id)","title":"\#(title)","preview":"\#(preview)","source":"api_server","started_at":\#(now - ago - 600),"last_active":\#(now - ago),"message_count":6}"#
        }.joined(separator: ",") + "]"
        return (try? JSONDecoder().decode([HermesSessionsAPI.SessionSummary].self, from: Data(json.utf8))) ?? []
    }

    // MARK: Ideas and briefings

    /// The first is put away (Not Now), the second taken (Do It).
    static let ideas = [
        AgentIdea(id: "day/0", profile: "default", agent: "Sol", title: "Learn the bagpipes",
                  why: "You said you were bored on Tuesday", request: "Find me a bagpipe teacher nearby", at: .now),
        AgentIdea(id: "day/1", profile: "default", agent: "Sol", title: "Book the vet for Pickles",
                  why: "His jab is due soon, and tomorrow afternoon is free", request: "Book Pickles in at the vet tomorrow afternoon", at: .now),
        AgentIdea(id: "day/2", profile: "home", agent: "Home", title: "Turn the heating down while you're out",
                  why: "Nobody's home until six", request: "Set the heating to 16° until 6 pm", at: .now),
    ]

    /// The dentist's, as Redde's plugin (1.9) sends one: when the event starts and where, and when
    /// to leave (worked out on the phone from the travel time, here set).
    static var headsUp: AgentBriefing {
        var briefing = AgentBriefing(id: "day/heads-up", title: AgentBriefing.headsUpPrefix + "Dentist", agent: "Sol",
                                     text: "Dentist at 7:30, in 30 minutes. Bring your insurance card! Parking is round the back.",
                                     at: today(7, 0), failed: false)
        briefing.eventAt = today(7, 30)
        briefing.place = dentistAddress
        briefing.leaveAt = today(7, 10)
        briefing.profile = "default"
        return briefing
    }

    /// The Week Ahead, from tomorrow, in the layout its job asks for (`WeekAhead.prompt`), so it
    /// draws as a calendar: dated from the day it is shown, so the days and dates agree.
    static var weekAhead: AgentBriefing {
        let days: [[String]] = [
            ["9:00 AM Team planning", "12:30 PM Lunch with the book club", "5:30 PM Pick Milo up from soccer"],
            ["> A slow morning", "10:00 AM Milo's soccer game", "7:00 PM Movie night"],
            ["11:00 AM Brunch with the neighbors", "5:00 PM Plan the week's dinners"],
            ["8:30 AM Car service", "2:00 PM Quarterly review"],
            ["6:00 PM Milo's swim lesson"],
            ["7:00 PM Parents' evening at school"],
            ["Bins out"],
        ]
        let format = Date.FormatStyle(locale: Locale(identifier: "en_US")).weekday(.wide).month(.abbreviated).day()
        var text = "A busy Friday, then an easy weekend."
        for (n, items) in days.enumerated() {
            let day = Calendar.current.date(byAdding: .day, value: n + 1, to: today(12, 0)) ?? .now
            text += "\n\n## " + day.formatted(format) + "\n" + items.map { $0.hasPrefix(">") ? $0 : "- " + $0 }.joined(separator: "\n")
        }
        text += "\n\nGet ready: shin pads and snacks for the soccer game"
        var briefing = AgentBriefing(id: "day/week", title: WeekAhead.title, agent: "Sol", text: text, at: today(6, 0), failed: false)
        briefing.profile = "default"
        return briefing
    }

    static var wrapUp: AgentBriefing {
        AgentBriefing(id: "day/wrap-up", title: EveningWrapUp.title, agent: "Sol", text: """
            ### Done
            - The dentist, on time 🦷
            - Pickles booked at the vet, tomorrow at 3:30
            - The house warm when you got home
            - Dinner at Lupa Trattoria 🍝

            ### Waiting on you
            - One approval from Coder

            ### Tomorrow
            - Call the plumber: it comes back as an idea at 9
            """, at: today(21, 0), failed: false)
    }

    /// What the chat list's Briefings start with, by scene.
    static var briefings: [AgentBriefing] {
        switch scene {
        case "morning": [weekAhead]
        case "week": [weekAhead, read(headsUp)]
        case "evening": [wrapUp, read(headsUp), read(weekAhead)]
        default: [read(headsUp), read(weekAhead)]
        }
    }

    private static func read(_ briefing: AgentBriefing) -> AgentBriefing {
        var briefing = briefing
        briefing.read = true
        return briefing
    }

    // MARK: At launch

    static func applyAtLaunch(conversation: Conversation, settings: Settings) {
        guard on else { return }
        switch scene {
        case "morning":
            Task {
                _ = await allowNotifications()
                try? await Task.sleep(for: .seconds(arrivesAfter))
                let briefing = headsUp
                BriefingsInbox.shared.arriveForDemo(briefing)
                // As the plugin's note fills it (`PushNote.fill`): Redde in front shows it as a banner.
                let json = #"{"v":1,"k":"routine","t":"\#(briefing.title)","d":"Sol","p":"default","x":"brief","b":"\#(briefing.text)"}"#
                if let note = try? JSONDecoder().decode(PushNote.self, from: Data(json.utf8)) { post(note) }
            }
        case "home":
            Task {
                _ = await allowNotifications()
                // As `BotTrigger.post` makes it, when the automation ran with Redde in the background.
                let content = UNMutableNotificationContent()
                content.title = "Home"
                content.body = "Welcome home! Warming the house to 21°, and the hall light is on."
                content.threadIdentifier = "redde.trigger.home"
                content.userInfo = [PushNote.botKey: "home"]
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, arrivesAfter), repeats: false)
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "redde.demo.day.home", content: content, trigger: trigger))
            }
        case "routine":
            conversation.replaceForDemo(id: UUID(uuidString: "DE300000-0000-4000-8000-0000000000D1")!, messages: [
                Message(role: .user, text: "Plan this week's dinners"),
                Message(role: .assistant, text: """
                    Here's the week:

                    - **Mon** Lemon chicken traybake
                    - **Tue** Veggie tacos 🌮
                    - **Wed** Pasta with peas and bacon
                    - **Thu** Salmon, rice and greens
                    - **Fri** Pizza night 🍕

                    The shopping is on your list: 14 things, sorted by aisle.
                    """),
            ])
        case "watch":
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                WatchDraft.shared.start("The garage door. If it's still open after 10 pm, that's a change.")
            }
        default: break
        }
    }

    private static func allowNotifications() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    private static func post(_ note: PushNote) {
        let content = UNMutableNotificationContent()
        guard note.fill(content) else { return }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "redde.demo.day.\(UUID().uuidString)", content: content, trigger: nil))
    }

    // MARK: Screens that read the server

    /// Agent Activity, the day so far.
    static var activity: [ActivityEntry] {
        func at(_ hour: Int, _ minute: Int, daysAgo: Int = 0) -> Date { today(hour, minute, daysAgo: daysAgo) }
        return [
            ActivityEntry(id: "a1", source: .brief, profile: "default", title: EveningWrapUp.title,
                          detail: "Done: the dentist, Pickles booked at the vet, the house warm. Waiting on you: one approval from Coder.", at: at(21, 0)),
            ActivityEntry(id: "a2", source: .watch, profile: "home", title: "The garage door",
                          detail: String(localized: "Looked \(34) times: nothing new"), at: at(20, 58)),
            ActivityEntry(id: "a3", source: .finished, profile: "coder", title: "Fix the photo upload",
                          detail: "Big photos upload again. The change is ready for your review.", at: at(16, 42)),
            ActivityEntry(id: "a4", source: .ideas, profile: "default", title: "Ideas for you",
                          detail: "Book the vet for Pickles · Learn the bagpipes · Turn the heating down", at: at(7, 5)),
            ActivityEntry(id: "a5", source: .brief, profile: "default", title: "Heads-up: Dentist",
                          detail: "Dentist at 7:30, in 30 minutes. Bring your insurance card!", at: at(7, 0)),
            ActivityEntry(id: "a6", source: .job, profile: "default", title: "Heads-ups", detail: "", at: at(6, 30)),
            ActivityEntry(id: "a7", source: .brief, profile: "default", title: EveningWrapUp.title,
                          detail: "Done: the bike's brake, the birthday cake ordered. Tomorrow: the dentist at 7:30.", at: at(21, 0, daysAgo: 1)),
        ]
    }

    static let pluginAgents: [(profile: String?, owner: String)] = [(nil, "Sol"), ("home", "Home"), ("coder", "Coder")]

    /// Plugin Updates: three with something newer, one up to date.
    static var pluginChecks: [PluginUpdateCheck] {
        func plugin(_ name: String, _ version: String) -> InstalledPlugin? {
            InstalledPlugin(.object(["name": .string(name), "version": .string(version), "status": .string("enabled")]))
        }
        let rows: [(String?, String, String, String, PluginUpdateState)] = [
            (nil, "Sol", "weather-tools", "2.0.1", .catalog("2.1.0")),
            ("home", "Home", "smart-home", "0.8.2", .commits(3)),
            (nil, "Sol", "calendar-sync", "1.4.0", .feed("1.5.0")),
            ("coder", "Coder", "web-search", "3.2.0", .current),
        ]
        return rows.compactMap { profile, owner, name, version, state in
            plugin(name, version).map { PluginUpdateCheck(profile: profile, owner: owner, plugin: $0, state: state) }
        }
    }
}

/// A chat's and an @tag's answers in the day's video, canned by what was asked, with a moment's
/// thought first: nothing goes to a server. Dinner comes as a choice card and the packing list as
/// a checklist card, each shown by a `redde_show` call (`ReplyCards`) as a live turn's are.
nonisolated struct DemoDayTransport: HermesTransport {
    /// The cards the dinner and packing answers show.
    static let dinnerCard = #"""
        {"cards": [{"type": "choice", "title": "Dinner tonight", "options": [
          {"title": "Lupa Trattoria", "detail": "Italian · ★ 4.6 · 0.4 mi · $$"},
          {"title": "Sushi Ko", "detail": "Japanese · ★ 4.7 · 0.9 mi · $$$"},
          {"title": "Big Pickle Deli", "detail": "Sandwiches · ★ 4.4 · 0.2 mi · $"}]}]}
        """#
    static let packingCard = #"""
        {"cards": [{"type": "checklist", "title": "Cabin weekend", "emoji": "🏕️", "sections": [
          {"title": "Clothes", "items": [{"text": "Swimsuits", "done": true}, {"text": "Hoodies for the evenings", "done": true}, "Rain jackets"]},
          {"title": "Food", "items": [{"text": "Coffee", "done": true}, "S'mores supplies", {"text": "Cooler and ice", "done": true}]},
          {"title": "Fun", "items": [{"text": "Board games", "done": true}, "Fishing rods"]}]}]}
        """#

    /// The card to show, if any, and the words.
    static func reply(to asked: String) -> (card: String?, answer: String) {
        if asked.contains("lupa") {
            return (nil, "Great pick! 🍝 Table for four at **Lupa Trattoria**, 7:00, at \(DemoDay.lupaAddress). I'll tell you when it's time to leave.")
        }
        if asked.contains("dinner") && !asked.contains("routine") { return (dinnerCard, "Three close by, all open now:") }
        if asked.contains("packing") { return (packingCard, "Here's the list for the cabin. Most of it is packed already!") }
        if asked.contains("garage") { return (nil, "Yep, it's shut. 🔒 I closed it at 8:12, after you drove off.") }
        if asked.contains("vet") {
            return (nil, "Done! 🐶 Pickles is booked in at the vet **tomorrow at 3:30**. It's on your calendar, and I'll remind you at 3.")
        }
        if asked.contains("routine") {
            return (nil, "Saved as a routine. I'll plan the week's dinners every Sunday at 5 and put the shopping on your list.")
        }
        return (nil, "On it!")
    }

    func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        let (card, answer) = Self.reply(to: request.userText.lowercased())
        return AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .seconds(1.1))
                if let card {
                    continuation.yield(.toolStarted(name: ReplyCards.tool, preview: "cards", args: card))
                    try? await Task.sleep(for: .milliseconds(250))
                    continuation.yield(.toolFinished(name: ReplyCards.tool, failed: false, output: nil))
                }
                var rest = Substring(answer)
                while !rest.isEmpty, !Task.isCancelled {
                    let end = rest.firstIndex(of: " ").map { rest.index(after: $0) } ?? rest.endIndex
                    continuation.yield(.textDelta(String(rest[..<end])))
                    rest = rest[end...]
                    try? await Task.sleep(for: .milliseconds(70))
                }
                continuation.yield(.textFinal(answer))
                continuation.yield(.done)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
