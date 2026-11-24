import CoreLocation
import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// What the Home Screen widgets read (asked 2026-11-24: "revamp the widgets … Up Next with A
// switching to B"). The app writes it into the app group (`WidgetFeed` in the app) as things
// change; the widgets read it in their timelines. Up Next and Needs You keep their kinds; Your
// Agents takes Last Reply's, so a Last Reply widget already on a Home Screen becomes it.

nonisolated enum WidgetKind {
    static let upNext = UpNext.widgetKind
    static let needsYou = NeedsYou.widgetKind
    static let lists = "com.goosehouse.echo.lists"
    static let day = "com.goosehouse.echo.day"
    /// Your Agents, in Last Reply's place.
    static let agents = "com.goosehouse.echo.lastreply"
    static let goals = "com.goosehouse.echo.goals"
}

// MARK: - The day ahead

/// The calendar's next day and a half, as the app read it (the calendars chosen in Settings ›
/// Calendars), and when to leave for its events where the phone worked that out. The widget
/// can't read the calendar itself: the app writes this when it comes forward, when the calendars
/// change while it runs, and after each Leave-By Alerts run (which a background refresh does too).
nonisolated struct DayAhead: Codable, Equatable, Sendable {
    struct Event: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var place: String?
        /// Its calendar's colour, as "#RRGGBB".
        var color: String?
        var allDay = false

        func isOn(at now: Date) -> Bool { start <= now && end > now }
    }

    /// When to leave for an event: Leave-By Alerts' or a heads-up's.
    struct Leave: Codable, Equatable, Sendable {
        var title: String
        var start: Date
        var leave: Date
        var travel: TimeInterval?
        var mode: LeaveTime.Mode?
        var latitude: Double?
        var longitude: Double?
        var place: String?
    }

    var events: [Event]
    var leaves: [Leave]
    var written: Date

    static let key = "dayAhead"
    /// How far ahead the app reads.
    static let reach: TimeInterval = 36 * 3600

    static func load(in defaults: UserDefaults? = NeedsYou.shared) -> DayAhead? {
        defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(DayAhead.self, from: $0) }
    }

    /// False when it says what was there already (when it was written aside).
    @discardableResult
    func save(in defaults: UserDefaults? = NeedsYou.shared) -> Bool {
        if let kept = Self.load(in: defaults), kept.events == events, kept.leaves == leaves { return false }
        defaults?.set(try? JSONEncoder().encode(self), forKey: Self.key)
        return true
    }

    static func clear(in defaults: UserDefaults? = NeedsYou.shared) { defaults?.removeObject(forKey: key) }
}

/// What Up Next shows at a moment: the day in order (its next event, the agent's note for it,
/// the rest of the day), or, in the hour before it is time to leave for an event, the way out.
nonisolated struct UpNextPlan: Equatable, Sendable {
    enum Mode: Equatable, Sendable { case day, leave }

    var mode: Mode
    var next: DayAhead.Event?
    /// What comes after it the same day.
    var later: [DayAhead.Event]
    /// When to leave for `next`, where known.
    var leave: DayAhead.Leave?
    /// The agent's heads-up for `next`.
    var note: AgentBriefing?

    /// How long before it is time to leave Up Next turns to the way out.
    static let leaveWindow: TimeInterval = 3600
    /// An event under way longer than this (a workday, a trip) is the day's background, not what's next.
    static let background: TimeInterval = 3 * 3600

    static func make(day: DayAhead?, briefings: [AgentBriefing], now: Date, calendar: Calendar = .current) -> UpNextPlan {
        var events = (day?.events ?? []).filter { !$0.allDay && $0.end > now && $0.start < now.addingTimeInterval(DayAhead.reach) }
            .filter { !($0.start <= now && $0.end.timeIntervalSince($0.start) > background) }
        // No calendar to go by: the events heads-ups were set for, as before.
        if events.isEmpty {
            events = briefings.filter { $0.showing(at: now) }.compactMap { b -> DayAhead.Event? in
                guard let at = b.eventAt, at.addingTimeInterval(3600) > now else { return nil }
                return DayAhead.Event(id: "brief:" + b.id, title: b.heading, start: at, end: at.addingTimeInterval(3600), place: b.place)
            }
        }
        events.sort { ($0.start, $0.end) < ($1.start, $1.end) }
        let leaves = (day?.leaves ?? []) + briefings.compactMap { b -> DayAhead.Leave? in
            guard let at = b.eventAt, let leave = b.leaveAt else { return nil }
            return DayAhead.Leave(title: b.heading, start: at, leave: leave, place: b.place)
        }
        func leave(for event: DayAhead.Event) -> DayAhead.Leave? {
            leaves.filter { abs($0.start.timeIntervalSince(event.start)) < 90 && (same($0.title, event.title) || leaves.count == 1) }
                .min { $0.leave < $1.leave }
                ?? leaves.first { abs($0.start.timeIntervalSince(event.start)) < 90 }
        }
        // Time to go: the soonest event whose leaving time is within the hour and which hasn't started.
        if let going = events.first(where: { event in
            guard event.start > now, let l = leave(for: event) else { return false }
            return l.leave.addingTimeInterval(-leaveWindow) <= now
        }) {
            return UpNextPlan(mode: .leave, next: going, later: rest(after: going, in: events, calendar: calendar),
                              leave: leave(for: going), note: note(for: going, in: briefings, now: now))
        }
        guard let next = events.first else { return UpNextPlan(mode: .day, next: nil, later: [], leave: nil, note: nil) }
        return UpNextPlan(mode: .day, next: next, later: rest(after: next, in: events, calendar: calendar),
                          leave: leave(for: next), note: note(for: next, in: briefings, now: now))
    }

    /// The moments after `now` when what shows changes: an event starting or ending, an hour
    /// before a leaving time, the leaving time itself.
    static func turns(day: DayAhead?, briefings: [AgentBriefing], after now: Date) -> [Date] {
        let events = day?.events ?? []
        var moments = events.flatMap { [$0.start, $0.end] }
        for l in day?.leaves ?? [] { moments += [l.leave.addingTimeInterval(-leaveWindow), l.leave, l.start] }
        for b in briefings {
            if let at = b.eventAt { moments += [at, at.addingTimeInterval(3600)] }
            if let leave = b.leaveAt { moments += [leave.addingTimeInterval(-leaveWindow), leave] }
        }
        return Array(Set(moments.filter { $0 > now && $0 < now.addingTimeInterval(DayAhead.reach) })).sorted()
    }

    private static func rest(after next: DayAhead.Event, in events: [DayAhead.Event], calendar: Calendar) -> [DayAhead.Event] {
        events.filter { $0 != next && $0.start >= next.start && calendar.isDate($0.start, inSameDayAs: next.start) }
    }

    private static func note(for event: DayAhead.Event, in briefings: [AgentBriefing], now: Date) -> AgentBriefing? {
        briefings.filter { $0.showing(at: now) && $0.eventAt != nil }.first { b in
            guard let at = b.eventAt else { return false }
            return abs(at.timeIntervalSince(event.start)) < 120 && (same(b.heading, event.title) || abs(at.timeIntervalSince(event.start)) < 1)
                || ("brief:" + b.id) == event.id
        }
    }

    /// Two titles for the same event: one in the other, without case or marks.
    static func same(_ a: String, _ b: String) -> Bool {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber } }
        let (x, y) = (fold(a), fold(b))
        return !x.isEmpty && !y.isEmpty && (x.contains(y) || y.contains(x))
    }
}

nonisolated extension AgentBriefing {
    /// A heads-up's note as lines to check before going ("Bring the card."), its list marks off.
    var beforeYouGo: [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).replacing(/^(?:[-*•–]|\d+[.)]|\[[ xX]\])\s+/, with: "") }
            .map { $0.replacing(/\*\*|__/, with: "") }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.lowercased().hasPrefix("leave by") }
    }
}

// MARK: - Agents

/// The main agent and the bots, as the chat list last showed them, for Your Agents.
nonisolated struct WidgetAgents: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case working, needsYou, idle }

    struct Agent: Codable, Equatable, Sendable, Identifiable {
        /// The profile.
        var id: String
        var name: String
        var status: Status
        /// The last thing said in its chat.
        var line: String?
        var at: Date?
        /// Its face, drawn by the app (`WidgetImages`).
        var face: String?
        var isMain: Bool
    }

    var agents: [Agent]
    var written: Date

    static let key = "widgetAgents"
    /// Working, as heard this long ago or more, is no longer believed: the app wasn't there to see it end.
    static let believed: TimeInterval = 20 * 60

    func status(of agent: Agent, at now: Date) -> Status {
        agent.status == .working && now.timeIntervalSince(written) > Self.believed ? .idle : agent.status
    }

    var main: Agent? { agents.first(where: \.isMain) ?? agents.first }

    static func load(in defaults: UserDefaults? = NeedsYou.shared) -> WidgetAgents? {
        defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(WidgetAgents.self, from: $0) }
    }

    /// False when it says what was there already.
    @discardableResult
    func save(in defaults: UserDefaults? = NeedsYou.shared) -> Bool {
        if let kept = Self.load(in: defaults), kept.agents == agents { return false }
        defaults?.set(try? JSONEncoder().encode(self), forKey: Self.key)
        return true
    }
}

// MARK: - Pictures

/// Pictures the widgets show, made by the app into the app group: a widget can't fetch or draw
/// them itself (no network images, no bot faces' code). Posters are kept small.
nonisolated enum WidgetImages {
    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShareInbox.appGroup)?
            .appending(path: "Widgets", directoryHint: .isDirectory)
    }

    static func url(_ name: String) -> URL? { folder?.appending(path: name) }

    /// A file name for a picture at an address.
    static func name(for remote: String, prefix: String = "poster") -> String {
        prefix + "-" + SHA256.hash(data: Data(remote.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    static func has(_ name: String) -> Bool { url(name).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    /// Takes away the pictures of a kind no longer shown.
    static func prune(prefix: String, keeping: Set<String>) {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(prefix + "-") && !keeping.contains(name) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    #if canImport(UIKit)
    static func image(_ name: String?) -> UIImage? {
        guard let name, let url = url(name) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// Writes a picture no wider than `side` points (at 2x), as a JPEG, or a PNG with `png`.
    static func write(_ image: UIImage, as name: String, side: CGFloat, png: Bool = false) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scale = min(1, side * 2 / max(image.size.width * image.scale, 1))
        let size = CGSize(width: image.size.width * image.scale * scale, height: image.size.height * image.scale * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        let data = png ? small.pngData() : small.jpegData(compressionQuality: 0.8)
        try? data?.write(to: folder.appending(path: name), options: .atomic)
    }
    #endif
}

// MARK: - Weather

/// The weather where the phone last was, for Your Day: Open-Meteo's (free, no key; CC BY 4.0, as
/// the app's weather card), read by the widget itself and kept half an hour.
nonisolated struct WidgetWeather: Codable, Equatable, Sendable {
    struct Hour: Codable, Equatable, Sendable {
        var at: Date
        var temperature: Double
        var code: Int
        var rain: Int?
        var night: Bool
    }

    var temperature: Double
    var code: Int
    var night: Bool
    var high: Double?
    var low: Double?
    var hours: [Hour]
    /// "C" or "F".
    var units: String
    var fetched: Date
    var latitude: Double
    var longitude: Double

    static let key = "widgetWeather"
    static let unitsKey = "widgetUnits"
    static let freshFor: TimeInterval = 30 * 60
    /// How old a place the phone was at still does for the weather (a town, not a street).
    static let placeFor: TimeInterval = 3 * 86_400

    var symbol: String { Self.symbol(code, night: night) }

    /// The first hour ahead where rain (or snow, or a storm) is likely: "Rain from 4 PM".
    func wet(after now: Date) -> Hour? { hours.first { $0.at > now.addingTimeInterval(-1800) && ($0.rain ?? 0) >= 50 } }

    func ahead(from now: Date, count: Int) -> [Hour] {
        Array(hours.filter { $0.at > now.addingTimeInterval(-1800) }.prefix(count))
    }

    static func symbol(_ code: Int, night: Bool) -> String {
        switch code {
        case 0, 1: night ? "moon.stars.fill" : "sun.max.fill"
        case 2: night ? "cloud.moon.fill" : "cloud.sun.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55: "cloud.drizzle.fill"
        case 56, 57, 66, 67: "cloud.sleet.fill"
        case 61, 63, 80, 81: "cloud.rain.fill"
        case 65, 82: "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 95, 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    /// Whether a code is snow rather than rain, for the line under the temperature.
    static func snows(_ code: Int) -> Bool { [71, 73, 75, 77, 85, 86].contains(code) }

    static func load(in defaults: UserDefaults? = NeedsYou.shared) -> WidgetWeather? {
        defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(WidgetWeather.self, from: $0) }
    }

    /// The place the phone was last seen at (`LeaveTime`'s), as long as it does for the weather.
    static func place(in defaults: UserDefaults? = NeedsYou.shared, now: Date = .now) -> CLLocationCoordinate2D? {
        guard let kept = defaults?.array(forKey: "lastPlace") as? [Double], kept.count == 3,
              now.timeIntervalSince1970 - kept[2] < placeFor else { return nil }
        return CLLocationCoordinate2D(latitude: kept[0], longitude: kept[1])
    }

    static func units(in defaults: UserDefaults? = NeedsYou.shared) -> String {
        defaults?.string(forKey: unitsKey) ?? (Locale.current.measurementSystem == .us ? "F" : "C")
    }

    /// The kept reading while it is fresh and for about here; else asked again. Nil with no place known.
    static func current(in defaults: UserDefaults? = NeedsYou.shared, now: Date = .now) async -> WidgetWeather? {
        guard let place = place(in: defaults, now: now) else { return nil }
        let units = units(in: defaults)
        let kept = load(in: defaults)
        if let kept, kept.units == units, now.timeIntervalSince(kept.fetched) < freshFor,
           CLLocation(latitude: kept.latitude, longitude: kept.longitude).distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)) < 5000 {
            return kept
        }
        guard let fetched = await fetch(at: place, units: units, now: now) else {
            // An older reading still says something for a few hours.
            return kept.flatMap { now.timeIntervalSince($0.fetched) < 6 * 3600 ? $0 : nil }
        }
        defaults?.set(try? JSONEncoder().encode(fetched), forKey: key)
        return fetched
    }

    private struct Answer: Decodable {
        struct Now: Decodable {
            var temperature_2m: Double
            var weather_code: Int?
            var is_day: Int?
        }
        struct Hourly: Decodable {
            var time: [String]
            var temperature_2m: [Double?]
            var weather_code: [Int?]
            var precipitation_probability: [Int?]?
            var is_day: [Int?]?
        }
        struct Daily: Decodable {
            var temperature_2m_max: [Double?]
            var temperature_2m_min: [Double?]
        }
        var utc_offset_seconds: Int?
        var current: Now
        var hourly: Hourly?
        var daily: Daily?
    }

    static func fetch(at place: CLLocationCoordinate2D, units: String, now: Date) async -> WidgetWeather? {
        // Two decimals: a kilometre or so, enough for the weather.
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        let round = { (v: Double) in String(format: "%.2f", v) }
        parts.queryItems = [
            .init(name: "latitude", value: round(place.latitude)), .init(name: "longitude", value: round(place.longitude)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "temperature_unit", value: units == "F" ? "fahrenheit" : "celsius"),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "1"), .init(name: "forecast_hours", value: "12"),
        ]
        guard let url = parts.url,
              let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return read(data, at: place, units: units, now: now)
    }

    static func read(_ data: Data, at place: CLLocationCoordinate2D, units: String, now: Date) -> WidgetWeather? {
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return nil }
        let offset = answer.utc_offset_seconds ?? 0
        let reader = DateFormatter()
        reader.locale = Locale(identifier: "en_US_POSIX")
        reader.timeZone = TimeZone(secondsFromGMT: offset)
        reader.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let hourly = answer.hourly
        let hours: [Hour] = (hourly?.time ?? []).enumerated().compactMap { i, time in
            guard let at = reader.date(from: time), let h = hourly, i < h.temperature_2m.count, let t = h.temperature_2m[i] else { return nil }
            return Hour(at: at, temperature: t, code: (i < h.weather_code.count ? h.weather_code[i] : nil) ?? 3,
                        rain: h.precipitation_probability.flatMap { i < $0.count ? $0[i] : nil },
                        night: h.is_day.flatMap { i < $0.count ? $0[i] : nil }.map { $0 == 0 } ?? false)
        }
        return WidgetWeather(temperature: answer.current.temperature_2m, code: answer.current.weather_code ?? 3,
                             night: answer.current.is_day.map { $0 == 0 } ?? false,
                             high: answer.daily?.temperature_2m_max.first ?? nil, low: answer.daily?.temperature_2m_min.first ?? nil,
                             hours: hours, units: units, fetched: now, latitude: place.latitude, longitude: place.longitude)
    }
}

// MARK: - What a widget's buttons do

/// A tap on a widget's button. Their intents run in the app (they are Live Activity intents,
/// which iOS starts the app for), where `WidgetActions.run` does what the same button in Redde
/// does and tells the Hermes. Should one run in the widget instead, what it can do there is done
/// at once (the tick shows) and the rest is kept for the app to finish when it next runs.
nonisolated enum WidgetAction: Codable, Equatable, Sendable {
    case tick(list: String, item: String, done: Bool)
    case answer(request: String, choice: String)
    /// Not Now: put away, as on the card in Redde.
    case notNow(idea: String)
    case step(goal: String, index: Int, done: Bool)
    case remind(title: String, start: Date)
}

@MainActor
enum WidgetActions {
    /// Set by the app at launch; nil in the widget.
    static var run: (@MainActor (WidgetAction) async -> Void)?

    private static let key = "widgetActions"

    static func perform(_ action: WidgetAction, in defaults: UserDefaults? = NeedsYou.shared) async {
        if let run {
            await run(action)
            return
        }
        here(action, in: defaults)
        var kept = waiting(in: defaults)
        kept.append(action)
        defaults?.set(try? JSONEncoder().encode(Array(kept.suffix(40))), forKey: key)
    }

    /// What was tapped while the app wasn't there to do it, oldest first, taken off the list.
    static func drain(in defaults: UserDefaults? = NeedsYou.shared) -> [WidgetAction] {
        let kept = waiting(in: defaults)
        if !kept.isEmpty { defaults?.removeObject(forKey: key) }
        return kept
    }

    private static func waiting(in defaults: UserDefaults?) -> [WidgetAction] {
        defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode([WidgetAction].self, from: $0) } ?? []
    }

    /// The part of a tap the widget can show by itself.
    private static func here(_ action: WidgetAction, in defaults: UserDefaults?) {
        switch action {
        case let .tick(list, item, done): TodayList.setKept(list: list, item: item, done: done, in: defaults)
        case let .answer(request, _): NeedsYou.settle(request, in: defaults)
        case let .notNow(idea): AgentIdea.remove(idea, in: defaults)
        case let .step(goal, index, done): GoalReport.setStep(goal, index, done: done, in: defaults)
        case .remind: break
        }
    }
}

nonisolated extension TodayList {
    private struct Kept: Codable {
        var server: String
        var lists: [TodayList]
    }

    /// The lists as the app last kept them in the app group (`TodayLists`), for the widget.
    static func kept(in defaults: UserDefaults? = NeedsYou.shared) -> [TodayList] {
        defaults?.data(forKey: "todayLists").flatMap { try? JSONDecoder().decode(Kept.self, from: $0) }?.lists ?? []
    }

    /// A tick made on the widget, shown at once in the app group's copy.
    static func setKept(list: String, item: String, done: Bool, in defaults: UserDefaults? = NeedsYou.shared) {
        guard let data = defaults?.data(forKey: "todayLists"), var kept = try? JSONDecoder().decode(Kept.self, from: data),
              let l = kept.lists.firstIndex(where: { $0.id == list }), let i = kept.lists[l].items.firstIndex(where: { $0.id == item }) else { return }
        kept.lists[l].items[i].done = done
        defaults?.set(try? JSONEncoder().encode(kept), forKey: "todayLists")
    }

    /// The list a widget shows when none was picked: one with something left, a to-do list first.
    static func pick(_ lists: [TodayList]) -> TodayList? {
        let open = lists.filter { !$0.open.isEmpty }
        return open.first { $0.groupsByWhen } ?? open.first ?? lists.first
    }
}
