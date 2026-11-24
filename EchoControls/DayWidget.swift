import AppIntents
import SwiftUI
import WidgetKit
#if WIDGET_VIEWS_IN_TESTS
@testable import Echo
#endif

// Your Day (2026-11-24): a greeting, the weather where the phone last was (Open-Meteo, read by the
// widget: `WidgetWeather`), what's waiting in Redde (to-dos, briefings, ideas), and the agent's
// newest idea with Do It and Not Now, or, with none, the newest briefing.

struct DayEntry: TimelineEntry {
    let date: Date
    var weather: WidgetWeather?
    var toDo = 0
    var briefings = 0
    var ideas = 0
    var idea: AgentIdea?
    var briefing: AgentBriefing?
    /// The faces the app drew, by profile, for the idea's agent.
    var faces: [String: String] = [:]
    var hidesWords = false

    static func now(_ date: Date = .now, weather: WidgetWeather?) -> DayEntry {
        let briefings = AgentBriefing.all().filter { $0.showing(at: date) && $0.eventAt == nil && !$0.failed }
        let ideas = AgentIdea.showing()
        let toDo = TodayList.kept().filter(\.groupsByWhen).reduce(0) { $0 + $1.open.count }
        let faces = Dictionary((WidgetAgents.load()?.agents ?? []).compactMap { a in a.face.map { (a.id, $0) } }, uniquingKeysWith: { a, _ in a })
        return DayEntry(date: date, weather: weather, toDo: toDo, briefings: briefings.filter { !$0.read }.count, ideas: ideas.count,
                        idea: ideas.max { $0.shownAt < $1.shownAt },
                        briefing: briefings.filter { !$0.read }.max { $0.at < $1.at } ?? briefings.max { $0.at < $1.at },
                        faces: faces, hidesWords: NeedsYou.hidesWords)
    }

    static let sample: DayEntry = {
        let now = Date.now
        let hours = (0 ..< 6).map { i in
            WidgetWeather.Hour(at: now.addingTimeInterval(Double(i) * 3600), temperature: 48 - Double(i), code: i >= 3 ? 61 : 3, rain: i >= 3 ? 70 : 10, night: false)
        }
        let weather = WidgetWeather(temperature: 48, code: 3, night: false, high: 50, low: 41, hours: hours, units: "F", fetched: now, latitude: 0, longitude: 0)
        let idea = AgentIdea(id: "sample", profile: "default", agent: "Sol",
                             title: String(localized: "Milo's passport runs out February 20", comment: "Widget gallery: a sample idea from the agent"),
                             why: String(localized: "Renewing takes a few weeks, and you fly to Lisbon on the 4th. Start it this week?", comment: "Widget gallery: why the agent offers the sample idea"),
                             request: "", at: now)
        return DayEntry(date: now, weather: weather, toDo: 6, briefings: 1, ideas: 2, idea: idea)
    }()
}

struct DayProvider: TimelineProvider {
    func placeholder(in context: Context) -> DayEntry { .sample }
    func getSnapshot(in context: Context, completion: @escaping (DayEntry) -> Void) {
        if context.isPreview { completion(.sample); return }
        Task { completion(DayEntry.now(weather: await WidgetWeather.current())) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DayEntry>) -> Void) {
        Task {
            let weather = await WidgetWeather.current()
            let now = Date.now
            // Each hour for the next few, for the greeting and the hours ahead; then the weather again.
            let entries = (0 ..< 3).map { DayEntry.now(now.addingTimeInterval(Double($0) * 3600), weather: weather) }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(WidgetWeather.freshFor))))
        }
    }
}

struct DayCard: View {
    let entry: DayEntry
    let family: WidgetFamily

    private var hides: Bool { entry.hidesWords }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: entry.date) {
        case 5 ..< 12: String(localized: "Good morning")
        case 12 ..< 17: String(localized: "Good afternoon")
        default: String(localized: "Good evening")
        }
    }

    private var day: String { entry.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) }

    private func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }

    /// "Rain from 4 PM".
    private var wet: String? {
        guard let weather = entry.weather, let hour = weather.wet(after: entry.date) else { return nil }
        let time = hour.at.formatted(.dateTime.hour())
        return WidgetWeather.snows(hour.code)
            ? String(localized: "Snow from \(time)", comment: "Your Day widget: when snow is likely to start, as Snow from 4 PM")
            : String(localized: "Rain from \(time)", comment: "Your Day widget: when rain is likely to start, as Rain from 4 PM")
    }

    var body: some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.date.formatted(.dateTime.weekday(.abbreviated).day())).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let weather = entry.weather {
                    HStack(spacing: 6) {
                        WidgetWeatherIcon(symbol: weather.symbol).font(.title2)
                        Text(degrees(weather.temperature)).font(.system(.title, design: .rounded).weight(.bold))
                    }
                    if let wet { Text(wet).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                } else {
                    Text(greeting).font(.headline).lineLimit(2)
                }
                Spacer(minLength: 0)
                counts(boxed: false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .systemMedium:
            VStack(alignment: .leading, spacing: 8) {
                top(size: .headline)
                counts(boxed: true)
                Spacer(minLength: 0)
                if let idea = entry.idea, !hides {
                    Link(destination: EchoURL.idea(idea.id)) {
                        HStack(spacing: 6) {
                            WidgetFace(file: entry.faces[idea.profile], name: idea.agent, size: 18)
                            Text(idea.title).font(.caption).lineLimit(1)
                        }
                        .foregroundStyle(Color.primary)
                    }
                } else if let briefing = entry.briefing, !hides {
                    Label { Text(briefing.heading).lineLimit(1) } icon: { Image(systemName: "sun.horizon") }.font(.caption)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        default:   // large
            VStack(alignment: .leading, spacing: 10) {
                top(size: .title3.weight(.bold))
                if let weather = entry.weather { hours(weather) }
                if !hides {
                    if let idea = entry.idea { ideaCard(idea) }
                    // The newest briefing too, when the weather's hours leave room for it.
                    if let briefing = entry.briefing, entry.idea == nil || entry.weather == nil { briefingCard(briefing, lines: entry.idea == nil ? 5 : 3) }
                }
                Spacer(minLength: 0)
                counts(boxed: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func top(size: Font) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text(greeting).font(size).lineLimit(1)
                Text(day).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if let weather = entry.weather {
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 4) {
                        WidgetWeatherIcon(symbol: weather.symbol)
                        Text(degrees(weather.temperature)).font(.headline)
                    }
                    if let wet {
                        Text(wet).font(.caption2).foregroundStyle(.secondary)
                    } else if let high = weather.high, let low = weather.low {
                        Text("H:\(degrees(high)) L:\(degrees(low))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func hours(_ weather: WidgetWeather) -> some View {
        HStack {
            ForEach(Array(weather.ahead(from: entry.date, count: 5).enumerated()), id: \.offset) { _, hour in
                VStack(spacing: 3) {
                    Text(hour.at.formatted(.dateTime.hour())).font(.caption2).foregroundStyle(.secondary)
                    WidgetWeatherIcon(symbol: WidgetWeather.symbol(hour.code, night: hour.night)).font(.callout).frame(height: 22)
                    Text(degrees(hour.temperature)).font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func ideaCard(_ idea: AgentIdea) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                WidgetFace(file: entry.faces[idea.profile], name: idea.agent, size: 20)
                Text(idea.agent).font(.caption.weight(.semibold)).foregroundStyle(.tint)
            }
            Text(idea.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            if let why = idea.why { Text(why).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            HStack(spacing: 8) {
                Link(destination: EchoURL.idea(idea.id)) {
                    Label { Text("Do It") } icon: { Image(systemName: "bolt.fill") }
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(.tint, in: .capsule).foregroundStyle(.white)
                }
                Button(intent: IdeaNotNowIntent(idea: idea.id)) {
                    Text("Not Now").padding(.horizontal, 12).padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .background(.quaternary, in: .capsule)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
    }

    private func briefingCard(_ briefing: AgentBriefing, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "sun.horizon").foregroundStyle(.tint)
                Text(briefing.heading).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(briefing.at, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
            Text(PlainText.display(DayBrief.withoutNarration(briefing.text))).font(.caption).lineLimit(lines)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 14, style: .continuous))
    }

    private func counts(boxed: Bool) -> some View {
        HStack(spacing: boxed ? 8 : 12) {
            count(entry.toDo, String(localized: "To Do"), boxed: boxed)
            count(entry.briefings, String(localized: "Briefings"), boxed: boxed, accent: entry.briefings > 0)
            count(entry.ideas, String(localized: "Ideas"), boxed: boxed)
        }
    }

    private func count(_ n: Int, _ label: String, boxed: Bool, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(n)").font(.system(boxed ? .headline : .subheadline, design: .rounded).weight(.bold)).monospacedDigit()
                .foregroundStyle(accent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            Text(label).font(.system(size: 9, weight: .bold)).textCase(.uppercase).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: boxed ? .infinity : nil, alignment: .leading)
        .padding(boxed ? 6 : 0)
        .background(boxed ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 9, style: .continuous))
    }
}

struct DayWidgetView: View {
    let entry: DayEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        DayCard(entry: entry, family: family)
            .privacySensitive()
            .widgetURL(EchoURL.open)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct DayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.day, provider: DayProvider()) { entry in
            DayWidgetView(entry: entry)
        }
        .configurationDisplayName("Your Day")
        .description("The weather, what's waiting in Redde, and your agent's newest idea.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
