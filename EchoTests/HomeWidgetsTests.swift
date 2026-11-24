import CoreLocation
import Foundation
import SwiftUI
import Testing
import WidgetKit
@testable import Echo

/// The Home Screen widgets, revamped (asked 2026-11-24: "build them all, Up Next with A switching
/// to B"): what each reads from the app group, how Up Next turns to the way out in the hour
/// before leaving, the widgets' buttons when the app isn't there to take them, and every card
/// drawn in every size (`BOARD_SHOTS=<folder>` keeps the pictures).
struct HomeWidgetsTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "widgets-\(UUID().uuidString)")! }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, _ title: String, in minutes: Double, for length: Double = 60, place: String? = nil) -> DayAhead.Event {
        DayAhead.Event(id: id, title: title, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + length) * 60), place: place)
    }

    // MARK: Up Next

    @Test func theDayInOrderThenTheWayOut() {
        let review = event("1", "Budget review", in: 80)
        let pickup = event("2", "Pick up Milo", in: 160, place: "Maple Street School")
        let movie = event("3", "Movie night", in: 330)
        let tomorrow = event("4", "Dentist", in: 24 * 60)
        let leave = DayAhead.Leave(title: "Pick up Milo", start: pickup.start, leave: pickup.start.addingTimeInterval(-25 * 60), travel: 18 * 60, mode: .driving)
        let day = DayAhead(events: [movie, tomorrow, pickup, review], leaves: [leave], written: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let plan = UpNextPlan.make(day: day, briefings: [], now: now, calendar: calendar)
        #expect(plan.mode == .day)
        #expect(plan.next == review, "the soonest first")
        #expect(plan.later.map(\.title) == ["Pick up Milo", "Movie night"], "the rest of that day, not tomorrow's")

        // An hour before it's time to leave for the pickup, even with the review still on.
        let soon = leave.leave.addingTimeInterval(-50 * 60)
        let going = UpNextPlan.make(day: day, briefings: [], now: soon, calendar: calendar)
        #expect(going.mode == .leave)
        #expect(going.next == pickup)
        #expect(going.leave == leave)
        #expect(UpNextPlan.make(day: day, briefings: [], now: leave.leave.addingTimeInterval(-61 * 60), calendar: calendar).mode == .day,
                "not before the hour")
        let under = UpNextPlan.make(day: day, briefings: [], now: pickup.start.addingTimeInterval(60), calendar: calendar)
        #expect(under.next == pickup && under.mode == .day, "under way: the day again, with it on")
        #expect(UpNextPlan.make(day: day, briefings: [], now: pickup.end.addingTimeInterval(60), calendar: calendar).next == movie,
                "once it is over, on to the next")

        let turns = UpNextPlan.turns(day: day, briefings: [], after: now)
        #expect(turns.contains(leave.leave.addingTimeInterval(-UpNextPlan.leaveWindow)), "the widget turns over by itself")
        #expect(turns.contains(leave.leave))
        #expect(turns == turns.sorted())
    }

    @Test func aDayLongEventIsTheBackground() {
        let workday = DayAhead.Event(id: "w", title: "Office", start: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(5 * 3600))
        let call = event("c", "Call with Robin", in: 30)
        let plan = UpNextPlan.make(day: DayAhead(events: [workday, call], leaves: [], written: now), briefings: [], now: now)
        #expect(plan.next == call)
    }

    @Test func theHeadsUpIsTheNoteAndWithNoCalendarTheEvent() {
        var heads = AgentBriefing(id: "h", title: "Heads-up: Budget review", agent: "Sol",
                                  text: "- Bring the signed copy\n- **Ana** wants the Q3 numbers\nLeave by 1:40 PM", at: now, failed: false)
        heads.eventAt = now.addingTimeInterval(80 * 60)
        heads.leaveAt = now.addingTimeInterval(50 * 60)
        #expect(heads.beforeYouGo == ["Bring the signed copy", "Ana wants the Q3 numbers"], "marks and the leaving line off")

        let review = event("1", "Budget Review (Q3)", in: 80)
        let withCalendar = UpNextPlan.make(day: DayAhead(events: [review], leaves: [], written: now), briefings: [heads], now: now)
        #expect(withCalendar.note?.id == "h", "the same event by its time and words")
        #expect(withCalendar.leave?.leave == heads.leaveAt, "the heads-up's leaving time")
        #expect(withCalendar.mode == .leave, "within the hour of it")

        let without = UpNextPlan.make(day: nil, briefings: [heads], now: now.addingTimeInterval(-3 * 3600))
        #expect(without.next?.title == "Budget review", "no calendar: the heads-up's event")
        #expect(without.mode == .day)
        #expect(without.note?.id == "h")
    }

    @Test func theDayIsWrittenOnlyWhenItChanged() {
        let store = defaults()
        let day = DayAhead(events: [event("1", "Budget review", in: 80)], leaves: [], written: now)
        #expect(day.save(in: store))
        #expect(!DayAhead(events: day.events, leaves: [], written: now.addingTimeInterval(60)).save(in: store), "the same day, written later")
        #expect(DayAhead.load(in: store)?.events.first?.title == "Budget review")
    }

    // MARK: Needs You

    @Test func aQuestionWithChoicesIsAnsweredOnTheWidget() throws {
        let store = defaults()
        let json: [String: Any] = ["v": 1, "k": "question", "at": now.timeIntervalSince1970, "s": "sess-1", "t": "Flights to Lisbon",
                                   "b": "Which one should I book?", "c": ["7:05 AM", " 9:40 AM ", ""], "h": "abc123"]
        let note = try JSONDecoder().decode(PushNote.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(NeedsYou.take(note, at: now, in: store))
        let request = try #require(NeedsYou.waiting(at: now, in: store).first)
        #expect(request.choices == ["7:05 AM", "9:40 AM"])
        #expect(request.digest == "abc123")
        #expect(request.answerable)
        var words = request
        words.choices = nil
        #expect(!words.answerable, "one answered in words opens Redde")
    }

    // MARK: Buttons with the app away

    @Test func aTickWithTheAppAwayShowsAndWaits() async throws {
        let store = defaults()
        let list = TodayList(id: "g", title: "Groceries", items: [.init(id: "1", text: "Lemons", done: false), .init(id: "2", text: "Eggs", done: false)], kind: .shopping)
        struct Kept: Codable { var server: String; var lists: [TodayList] }
        store.set(try JSONEncoder().encode(Kept(server: "s", lists: [list])), forKey: "todayLists")
        #expect(TodayList.kept(in: store).first?.title == "Groceries")

        let before = WidgetActions.run
        WidgetActions.run = nil
        defer { WidgetActions.run = before }
        await WidgetActions.perform(.tick(list: "g", item: "1", done: true), in: store)
        #expect(TodayList.kept(in: store).first?.items.first?.done == true, "shown at once")
        #expect(WidgetActions.drain(in: store) == [.tick(list: "g", item: "1", done: true)], "for the app to tell the Hermes")
        #expect(WidgetActions.drain(in: store).isEmpty, "once")
    }

    @Test func theListAndTheGoalAWidgetShowsUnpicked() {
        let todo = TodayList(id: "t", title: "House", items: [.init(id: "1", text: "Gutters", done: false)], kind: .todo)
        let watch = TodayList(id: "w", title: "Films", items: [.init(id: "1", text: "Elf", done: false)], kind: .watch)
        let done = TodayList(id: "d", title: "Done", items: [.init(id: "1", text: "x", done: true)], kind: .todo)
        #expect(TodayList.pick([done, watch, todo])?.id == "t", "a to-do list with something left first")
        #expect(TodayList.pick([done, watch])?.id == "w")
        #expect(TodayList.pick([done])?.id == "d")

        var finished = GoalReport(id: "f", title: "Read", agent: "Sol", done: 3, total: 3, headline: "", at: now, failed: false)
        finished.steps = []
        var going = GoalReport(id: "g", title: "Run a 5K", agent: "Sol", done: 1, total: 4, headline: "", at: now, failed: false)
        going.steps = [.init(title: "Shoes", cardID: nil, done: true, who: "you"), .init(title: "Run 3 km", cardID: nil, done: false, who: "you")]
        #expect(GoalReport.pick([finished, going])?.id == "g")
    }

    // MARK: Weather

    @Test func theWeatherIsReadFromOpenMeteo() throws {
        let json = """
        {"utc_offset_seconds": -18000,
         "current": {"temperature_2m": 47.6, "weather_code": 3, "is_day": 1},
         "hourly": {"time": ["2027-01-15T13:00", "2027-01-15T14:00", "2027-01-15T15:00", "2027-01-15T16:00"],
                    "temperature_2m": [48, 47, 46, 45], "weather_code": [3, 3, 61, 63],
                    "precipitation_probability": [10, 30, 60, 80], "is_day": [1, 1, 1, 0]},
         "daily": {"temperature_2m_max": [50.2], "temperature_2m_min": [41]}}
        """
        let place = CLLocationCoordinate2D(latitude: 45.5, longitude: -73.6)
        let weather = try #require(WidgetWeather.read(Data(json.utf8), at: place, units: "F", now: now))
        #expect(weather.temperature == 47.6)
        #expect(weather.symbol == "cloud.fill")
        #expect(weather.high == 50.2 && weather.low == 41)
        #expect(weather.hours.count == 4)
        let start = ISO8601DateFormatter().date(from: "2027-01-15T18:00:00Z")!
        #expect(weather.hours.first?.at == start, "the place's time, with its offset")
        #expect(weather.wet(after: start)?.at == start.addingTimeInterval(2 * 3600), "rain from 3 PM there")
        #expect(weather.hours.last?.night == true)
        #expect(WidgetWeather.symbol(0, night: true) == "moon.stars.fill")
    }

    @Test func noPlaceNoWeather() async {
        let store = defaults()
        #expect(await WidgetWeather.current(in: store, now: now) == nil)
        store.set([45.5, -73.6, now.timeIntervalSince1970 - 4 * 86_400], forKey: "lastPlace")
        #expect(WidgetWeather.place(in: store, now: now) == nil, "too old a place")
        store.set([45.5, -73.6, now.timeIntervalSince1970 - 86_400], forKey: "lastPlace")
        #expect(WidgetWeather.place(in: store, now: now)?.latitude == 45.5)
    }

    // MARK: Agents

    @Test func workingIsBelievedForAWhile() {
        let agents = WidgetAgents(agents: [.init(id: "default", name: "Sol", status: .working, isMain: true)], written: now)
        let sol = agents.agents[0]
        #expect(agents.status(of: sol, at: now.addingTimeInterval(60)) == .working)
        #expect(agents.status(of: sol, at: now.addingTimeInterval(WidgetAgents.believed + 1)) == .idle, "the app wasn't there to see it end")
        #expect(agents.main?.name == "Sol")
    }

    // MARK: Drawing

    @Test func everyWidgetDrawsInEverySize() throws {
        let homes: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
        let locks: [WidgetFamily] = [.accessoryCircular, .accessoryRectangular, .accessoryInline]
        var shots: [(String, UIImage?)] = []

        // Needs You, with a question to answer and a command to review.
        let sample = NeedsYouEntry.sample.requests
        for family in homes + locks {
            shots.append(("needs-answer-\(family)", WidgetDrawing.drawn(NeedsYouCard(requests: sample, family: family), family)))
            shots.append(("needs-answer-one-\(family)", WidgetDrawing.drawn(NeedsYouCard(requests: [sample[0]], family: family), family)))
            shots.append(("needs-hidden-\(family)", WidgetDrawing.drawn(NeedsYouCard(requests: sample, hidesWords: true, family: family), family)))
        }

        // Lists: a shopping list, a list by when, a watch list, none.
        var house = TodayList(id: "h", title: "House To-Dos", items: [
            .init(id: "1", text: "Call the plumber", done: false, when: Date.now.addingTimeInterval(-86_400)),
            .init(id: "2", text: "Return the library books", done: false, when: Date.now.addingTimeInterval(3600)),
            .init(id: "3", text: "Clean the gutters", done: false, when: Date.now.addingTimeInterval(3 * 86_400)),
            .init(id: "4", text: "Fix the porch light", done: false),
        ], kind: .todo, emoji: "🏠", hue: .orange)
        house.items.append(.init(id: "5", text: "Book the chimney sweep", done: true))
        let films = TodayList(id: "f", title: "Movie Nights", items: ["Paper Moons", "Northbound", "The Long Thaw", "Harbor Lights", "Elf"].enumerated().map {
            .init(id: "\($0.offset)", text: $0.element, done: false, when: $0.offset == 0 ? Date.now.addingTimeInterval(2 * 86_400) : nil, company: $0.offset == 0 ? "Robin" : nil)
        }, kind: .watch, emoji: "🍿", hue: .purple)
        for family in homes {
            for (name, entry) in [("groceries", ListsEntry.sample), ("house", ListsEntry(date: .now, list: house)), ("films", ListsEntry(date: .now, list: films)),
                                  ("none", ListsEntry(date: .now, list: nil)), ("hidden", ListsEntry(date: .now, list: house, hidesWords: true))] {
                shots.append(("lists-\(name)-\(family)", WidgetDrawing.drawn(ListsCard(entry: entry, family: family), family)))
            }
        }

        // Your Day: with the weather and an idea, with a briefing, with nothing known.
        var briefing = DayEntry.sample
        briefing.idea = nil
        briefing.briefing = AgentBriefing(id: "b", title: "Morning briefing", agent: "Sol",
                                          text: "Budget review with Ana at 2. The signed copy is still in Drafts.\nRain from 4: leave by 3:40 for Milo.", at: .now, failed: false)
        for family in homes {
            for (name, entry) in [("idea", DayEntry.sample), ("briefing", briefing), ("bare", DayEntry(date: .now)),
                                  ("hidden", { var e = DayEntry.sample; e.hidesWords = true; return e }())] {
                shots.append(("day-\(name)-\(family)", WidgetDrawing.drawn(DayCard(entry: entry, family: family), family)))
            }
        }

        // Your Agents and Goals.
        for family in homes + locks {
            for (name, entry) in [("team", AgentsEntry.sample), ("none", AgentsEntry(date: .now)),
                                  ("hidden", { var e = AgentsEntry.sample; e.hidesWords = true; return e }())] {
                shots.append(("agents-\(name)-\(family)", WidgetDrawing.drawn(AgentsCard(entry: entry, family: family), family)))
            }
            for (name, entry) in [("goal", GoalsEntry.sample), ("none", GoalsEntry(date: .now)),
                                  ("hidden", { var e = GoalsEntry.sample; e.hidesWords = true; return e }())] {
                shots.append(("goals-\(name)-\(family)", WidgetDrawing.drawn(GoalsCard(entry: entry, family: family).tint(.green), family)))
            }
        }
        shots.append(("dark-upnext-systemMedium", WidgetDrawing.drawn(UpNextCard(entry: .sample(), family: .systemMedium), .systemMedium, dark: true)))
        shots.append(("dark-day-systemLarge", WidgetDrawing.drawn(DayCard(entry: .sample, family: .systemLarge), .systemLarge, dark: true)))

        for (name, image) in shots {
            #expect(image != nil, "\(name) didn't draw")
            if let image { WidgetDrawing.keep(image, name) }
        }
    }
}

/// A widget's card drawn at its size, with the margins and background a widget gives it.
@MainActor
enum WidgetDrawing {
    static func drawn(_ card: some View, _ family: WidgetFamily, dark: Bool = false) -> UIImage? {
        let size: CGSize = switch family {
        case .systemMedium: CGSize(width: 364, height: 170)
        case .systemLarge: CGSize(width: 364, height: 382)
        case .accessoryCircular: CGSize(width: 76, height: 76)
        case .accessoryRectangular: CGSize(width: 172, height: 76)
        case .accessoryInline: CGSize(width: 240, height: 26)
        default: CGSize(width: 170, height: 170)
        }
        let home = [.systemSmall, .systemMedium, .systemLarge].contains(family)
        let inner = CGSize(width: size.width - (home ? 32 : 0), height: size.height - (home ? 32 : 0))
        let renderer = ImageRenderer(content: card
            .frame(width: inner.width, height: inner.height)
            .padding(home ? 16 : 0)
            .background(home ? Color(.secondarySystemBackground) : Color(.systemGray4), in: .rect(cornerRadius: home ? 24 : 12))
            .padding(8)
            .background(Color(.systemBackground))
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        return renderer.uiImage
    }

    static func keep(_ image: UIImage, _ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["BOARD_SHOTS"] else { return }
        try? image.pngData()?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
