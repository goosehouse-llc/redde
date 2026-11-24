import SwiftUI
import WidgetKit
#if WIDGET_VIEWS_IN_TESTS
@testable import Echo
#endif

// Up Next (asked 2026-10-28, "Proactive"; revamped 2026-11-24, "Up Next with A switching to B"):
// the day in order, its next event with the agent's note for it and the rest of the day after it;
// and, in the hour before it is time to leave for an event, the way out: a ring counting down to
// when to leave, what to take, Directions. From the app group (`DayAhead`, the briefings), which
// the app and the notification extension keep; the timeline holds each moment the plan changes.

struct UpNextEntry: TimelineEntry {
    let date: Date
    var plan: UpNextPlan
    var briefings = 0
    var ideas = 0
    var hidesWords = false

    var relevance: TimelineEntryRelevance? {
        plan.mode == .leave ? TimelineEntryRelevance(score: 90) : plan.next.map { $0.start.timeIntervalSince(date) < 3600 ? TimelineEntryRelevance(score: 40) : TimelineEntryRelevance(score: 10) }
    }

    static func now(_ date: Date = .now) -> UpNextEntry {
        let briefings = AgentBriefing.all()
        return UpNextEntry(date: date, plan: UpNextPlan.make(day: DayAhead.load(), briefings: briefings, now: date),
                           briefings: briefings.filter { !$0.read && $0.showing(at: date) && $0.eventAt == nil }.count,
                           ideas: AgentIdea.showing().count, hidesWords: NeedsYou.hidesWords)
    }

    /// The widget gallery's: a budget review in an hour and twenty minutes, the afternoon after it.
    static func sample(leaving: Bool = false, at now: Date = .now) -> UpNextEntry {
        let review = DayAhead.Event(id: "s1", title: String(localized: "Budget review", comment: "Widget gallery: a sample event"),
                                    start: now.addingTimeInterval(80 * 60), end: now.addingTimeInterval(140 * 60),
                                    place: String(localized: "Conference room B", comment: "Widget gallery: a sample event's place"), color: "#4C8DFF")
        let pickup = DayAhead.Event(id: "s2", title: String(localized: "Pick up Milo", comment: "Widget gallery: a sample event"),
                                    start: now.addingTimeInterval(leaving ? 43 * 60 : 160 * 60), end: now.addingTimeInterval(leaving ? 73 * 60 : 190 * 60),
                                    place: "Maple Street School", color: "#30D158")
        let movie = DayAhead.Event(id: "s3", title: String(localized: "Movie night", comment: "Widget gallery: a sample event"),
                                   start: now.addingTimeInterval(330 * 60), end: now.addingTimeInterval(450 * 60), color: "#BF5AF2")
        var note = AgentBriefing(id: "sample", title: "Heads-up: Budget review", agent: "Sol",
                                 text: String(localized: "You promised Ana the signed copy by Friday. It's still in Drafts.", comment: "Widget gallery: the agent's note for the sample event"),
                                 at: now, failed: false)
        note.eventAt = review.start
        if leaving {
            var heads = AgentBriefing(id: "sample-2", title: "Heads-up: Pick up Milo", agent: "Sol",
                                      text: String(localized: "Milo's swim bag\nThe signed permission slip\nRain from 4: take the umbrella", comment: "Widget gallery: what to take, one thing a line"),
                                      at: now, failed: false)
            heads.eventAt = pickup.start
            let leave = DayAhead.Leave(title: pickup.title, start: pickup.start, leave: now.addingTimeInterval(25 * 60), travel: 18 * 60, mode: .driving, place: pickup.place)
            return UpNextEntry(date: now, plan: UpNextPlan(mode: .leave, next: pickup, later: [movie], leave: leave, note: heads), briefings: 1, ideas: 2)
        }
        return UpNextEntry(date: now, plan: UpNextPlan(mode: .day, next: review, later: [pickup, movie], leave: nil, note: note), briefings: 1, ideas: 2)
    }
}

struct UpNextProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpNextEntry { .sample() }
    func getSnapshot(in context: Context, completion: @escaping (UpNextEntry) -> Void) {
        completion(context.isPreview ? .sample() : .now())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UpNextEntry>) -> Void) {
        let now = Date.now
        // Again at each moment the plan changes: an event starting or ending, an hour before a
        // leaving time (the way out), the leaving time. The countdowns run by themselves between.
        let turns = UpNextPlan.turns(day: DayAhead.load(), briefings: AgentBriefing.all(), after: now).prefix(40)
        let entries = [UpNextEntry.now(now)] + turns.map { UpNextEntry.now($0.addingTimeInterval(1)) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600))))
    }
}

/// The card, by size and by what it shows (the tests draw each).
struct UpNextCard: View {
    let entry: UpNextEntry
    let family: WidgetFamily

    var body: some View {
        Group {
            if entry.plan.mode == .leave, let event = entry.plan.next, let leave = entry.plan.leave {
                UpNextLeaving(entry: entry, event: event, leave: leave, family: family)
            } else {
                UpNextDay(entry: entry, family: family)
            }
        }
        .privacySensitive()
    }
}

// MARK: - The day in order

private struct UpNextDay: View {
    let entry: UpNextEntry
    let family: WidgetFamily

    private var next: DayAhead.Event? { entry.plan.next }
    /// With Redde locked (Settings → Privacy) what the agents wrote is hidden: the heads-up and
    /// what to take. The calendar's own events show, as Calendar's widget shows them (2026-11-24:
    /// "The widget doesn't list what's up next"); iOS still hides it all on a locked iPhone.
    private var hides: Bool { entry.hidesWords }
    private func title(_ event: DayAhead.Event) -> String { event.title }
    private var note: AgentBriefing? { hides ? nil : entry.plan.note }

    private var waiting: String? {
        var parts: [String] = []
        if entry.briefings > 0 { parts.append(String(localized: "\(entry.briefings) briefings")) }
        if entry.ideas > 0 { parts.append(String(localized: "\(entry.ideas) ideas")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Starts in 1 hr, 20 min", or "Now · until 3:00 PM".
    @ViewBuilder private func when(_ event: DayAhead.Event) -> some View {
        if event.isOn(at: entry.date) {
            Text("\(String(localized: "Now")) · \(String(localized: "until \(event.end.widgetTime)", comment: "Today strip, Up Next: the event under way ends at this time"))")
        } else {
            HStack(spacing: 4) {
                Text("Starts in")
                Text(.currentDate, format: .offset(to: event.start, allowedFields: [.hour, .minute], sign: .never))
            }
        }
    }

    /// "1:50 PM · in 1 hour", or "Now · until 2:50 PM".
    @ViewBuilder private func shortWhen(_ event: DayAhead.Event) -> some View {
        if event.isOn(at: entry.date) {
            Text("\(String(localized: "Now")) · \(String(localized: "until \(event.end.widgetTime)", comment: "Today strip, Up Next: the event under way ends at this time"))")
        } else {
            HStack(spacing: 4) {
                Text("\(event.start.widgetTime) ·")
                Text(.currentDate, format: .reference(to: event.start, allowedFields: [.hour, .minute]))
            }
        }
    }

    private func span(_ event: DayAhead.Event) -> String {
        "\(event.start.widgetTime) – \(event.end.widgetTime)"
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            if let next {
                Label { Text("\(title(next)) \(next.start.widgetTime)") } icon: { Image(systemName: "calendar") }
            } else {
                Label(waiting ?? String(localized: "Nothing up next"), systemImage: "sparkles")
            }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "calendar").font(.caption.weight(.semibold))
                    if let next {
                        Text(next.start.widgetClock)
                            .font(.system(.title3, design: .rounded).weight(.bold)).minimumScaleFactor(0.6).monospacedDigit()
                    } else {
                        Text("–").font(.title3.weight(.bold))
                    }
                }
                .widgetAccentable()
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                if let next {
                    Text(title(next)).font(.headline).lineLimit(1).widgetAccentable()
                    shortWhen(next).font(.caption).lineLimit(1)
                    if let note, let line = note.beforeYouGo.first {
                        Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    } else if let after = entry.plan.later.first {
                        Text("\(after.start.widgetTime) \(after.title)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text("Up Next").font(.headline).widgetAccentable()
                    Text(waiting ?? String(localized: "Nothing coming up")).font(.caption).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemSmall:
            VStack(alignment: .leading, spacing: 3) {
                WidgetHeader(title: String(localized: "Up Next"), symbol: "calendar")
                if let next {
                    Text(title(next)).font(.headline).lineLimit(2)
                    Text(next.start.widgetTime).font(.subheadline).foregroundStyle(.secondary)
                    when(next).font(.caption.weight(.semibold)).lineLimit(2)
                    Spacer(minLength: 0)
                    if let note, let line = note.beforeYouGo.first {
                        Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    } else if let waiting {
                        Text(waiting).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    nothing
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .systemMedium:
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    WidgetHeader(title: String(localized: "Up Next"), symbol: "calendar", trailing: next.map { $0.start.widgetTime })
                    if let next {
                        Text(title(next)).font(.headline).lineLimit(2)
                        when(next).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 2)
                        if let note { noteBox(note, lines: 3) }
                    } else {
                        nothing
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if !entry.plan.later.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Later today", comment: "Up Next widget: the day's other events, after the next one")
                            .font(.caption2.weight(.bold)).textCase(.uppercase).foregroundStyle(.secondary)
                        ForEach(entry.plan.later.prefix(3)) { stacked($0) }
                        Spacer(minLength: 0)
                    }
                    .frame(width: 124, alignment: .leading)
                }
            }
        default:   // large
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: String(localized: "Up Next"), symbol: "calendar", trailing: waiting)
                if let next {
                    HStack(alignment: .top, spacing: 10) {
                        Capsule().fill(Color(widgetHex: next.color) ?? .accentColor).frame(width: 4).widgetAccentable()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(next)).font(.title3.weight(.semibold)).lineLimit(2)
                            Text(next.place == nil ? span(next) : "\(span(next)) · \(next.place ?? "")")
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            when(next).font(.subheadline.weight(.semibold))
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    if let note { noteBox(note, lines: 4) }
                    // (Brief Me opens Redde, which asks for Face ID when it's locked.)
                    Link(destination: EchoURL.ask(String(localized: "Brief me for \(next.title) at \(next.start.widgetTime).",
                                                         comment: "What Brief Me on the Up Next widget starts a conversation with: the event and its time"))) {
                        Label { Text("Brief Me", comment: "Up Next widget: a button that asks the agent about the next event") } icon: { Image(systemName: "sparkles") }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.tint.opacity(0.18), in: .capsule)
                    }
                    if !entry.plan.later.isEmpty {
                        Divider()
                        Text("Later today", comment: "Up Next widget: the day's other events, after the next one")
                            .font(.caption2.weight(.bold)).textCase(.uppercase).foregroundStyle(.secondary)
                        ForEach(entry.plan.later.prefix(5)) { row($0, wide: true) }
                    }
                    Spacer(minLength: 0)
                } else {
                    nothing
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func noteBox(_ note: AgentBriefing, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !note.agent.isEmpty {
                Text(note.agent).font(.caption2.weight(.bold)).foregroundStyle(.tint)
            }
            Text(note.beforeYouGo.joined(separator: " ")).font(.caption).lineLimit(lines)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.tint.opacity(0.14), in: .rect(cornerRadius: 10, style: .continuous))
    }

    private func stacked(_ event: DayAhead.Event) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Capsule().fill(Color(widgetHex: event.color) ?? .secondary).frame(width: 3).widgetAccentable()
            VStack(alignment: .leading, spacing: 0) {
                Text(event.start.widgetTime).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Text(event.title).font(.caption).lineLimit(1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ event: DayAhead.Event, wide: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(Color(widgetHex: event.color) ?? .secondary).frame(width: 6, height: 6).widgetAccentable()
            Text(event.start.widgetTime).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: wide ? 62 : nil, alignment: .leading)
            Text(event.title).font(.caption).lineLimit(1)
        }
    }

    private var nothing: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing coming up").font(.headline)
            Spacer(minLength: 0)
            if let waiting { Text(waiting).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - The way out

private struct UpNextLeaving: View {
    let entry: UpNextEntry
    let event: DayAhead.Event
    let leave: DayAhead.Leave
    let family: WidgetFamily

    private var hides: Bool { entry.hidesWords }   // (the agents' words only, as for the day)
    private var title: String { event.title }
    private var late: Bool { leave.leave <= entry.date }
    /// "Leave by 3:40 PM · 18 min by car", "Leave now · …", or just when.
    private var line: String {
        if let travel = leave.travel, let mode = leave.mode, mode != .off {
            return LeaveTime.line(leave: leave.leave, travel: travel, mode: mode, now: entry.date)
        }
        return short
    }
    /// "Leave by 3:40 PM", or "Leave now".
    private var short: String {
        late ? String(localized: "Leave now", comment: "Up Next widget: it is time to leave") : String(localized: "Leave by \(leave.leave.widgetTime)", comment: "Up Next widget: when to leave for the next event")
    }
    /// "18 min by car".
    private var way: String? {
        guard let travel = leave.travel, let mode = leave.mode, mode != .off else { return nil }
        return LeaveTime.way(travel: travel, mode: mode)
    }
    private var checks: [String] { hides ? [] : (entry.plan.note?.beforeYouGo ?? []) }

    private var directions: URL? {
        var parts = URLComponents(string: "https://maps.apple.com/")!
        if let lat = leave.latitude, let lon = leave.longitude {
            parts.queryItems = [.init(name: "daddr", value: "\(lat),\(lon)")]
        } else if let place = leave.place ?? event.place, !place.isEmpty {
            parts.queryItems = [.init(name: "daddr", value: place)]
        } else { return nil }
        let flag = switch leave.mode { case .walking: "w"; case .transit: "r"; default: "d" }
        parts.queryItems?.append(.init(name: "dirflg", value: flag))
        return parts.url
    }

    /// The hour before leaving, emptying as the time comes.
    private var window: ClosedRange<Date> {
        let end = max(leave.leave, entry.date.addingTimeInterval(1))
        return min(end.addingTimeInterval(-UpNextPlan.leaveWindow), entry.date) ... end
    }

    private func ring(_ size: CGFloat, line width: CGFloat) -> some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: width)
            if late {
                Circle().stroke(.orange, lineWidth: width).widgetAccentable()
            } else {
                ProgressView(timerInterval: window, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.circular)
                    .tint(.orange)
                    .widgetAccentable()
            }
            VStack(spacing: 0) {
                if late {
                    Text("Now").font(.system(size: size * 0.22, weight: .bold, design: .rounded))
                } else {
                    Text("Leave in").font(.system(size: size * 0.12, weight: .semibold)).foregroundStyle(.secondary)
                    Text(timerInterval: min(entry.date, leave.leave) ... leave.leave, countsDown: true, showsHours: true)
                        .font(.system(size: size * 0.22, weight: .bold, design: .rounded)).monospacedDigit()
                        .multilineTextAlignment(.center).minimumScaleFactor(0.5).lineLimit(1)
                }
            }
            .padding(width + 4)
        }
        .frame(width: size, height: size)
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label { Text("\(short) · \(title)") } icon: { Image(systemName: "car.fill") }
        case .accessoryCircular:
            if late {
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Image(systemName: "car.fill").font(.caption.weight(.semibold))
                        Text("Now").font(.caption.weight(.bold))
                    }
                }
            } else {
                ProgressView(timerInterval: window, countsDown: true) { EmptyView() } currentValueLabel: {
                    Image(systemName: "car.fill")
                }
                .progressViewStyle(.circular)
                .widgetAccentable()
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                if late {
                    Text("Leave now", comment: "Up Next widget: it is time to leave").font(.headline).widgetAccentable()
                } else {
                    HStack(spacing: 4) {
                        Text("Leave in")
                        Text(timerInterval: min(entry.date, leave.leave) ... leave.leave, countsDown: true, showsHours: true)
                            .monospacedDigit().multilineTextAlignment(.leading)
                    }
                    .font(.headline).lineLimit(1).widgetAccentable()
                }
                Text("\(title) · \(event.start.widgetTime)").font(.caption).lineLimit(1)
                Text(way ?? short).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemSmall:
            VStack(spacing: 6) {
                ring(92, line: 8)
                VStack(spacing: 0) {
                    Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(short).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .systemMedium:
            HStack(spacing: 14) {
                ring(112, line: 9)
                VStack(alignment: .leading, spacing: 3) {
                    WidgetHeader(title: String(localized: "Time to leave", comment: "Up Next widget, in the hour before leaving: its header"), symbol: "car.fill")
                    Text(title).font(.headline).lineLimit(2)
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 2)
                    ForEach(checks.prefix(2), id: \.self) { check in
                        Label { Text(check).lineLimit(1) } icon: { Image(systemName: "circle").foregroundStyle(.secondary) }
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        default:   // large
            VStack(alignment: .leading, spacing: 10) {
                WidgetHeader(title: String(localized: "Time to leave", comment: "Up Next widget, in the hour before leaving: its header"), symbol: "car.fill",
                             trailing: event.start.widgetTime)
                HStack(spacing: 14) {
                    ring(118, line: 10)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.title3.weight(.semibold)).lineLimit(2)
                        if let place = leave.place ?? event.place {
                            Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(line).font(.caption.weight(.semibold)).lineLimit(2)
                    }
                }
                if !checks.isEmpty {
                    Text("Before you go", comment: "Up Next widget: what the agent says to take or do before leaving")
                        .font(.caption2.weight(.bold)).textCase(.uppercase).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(checks.prefix(4), id: \.self) { check in
                            Label { Text(check).lineLimit(1) } icon: { Image(systemName: "circle").foregroundStyle(.secondary) }
                                .font(.subheadline)
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if let directions {
                        Link(destination: directions) {
                            Label { Text("Directions", comment: "Up Next widget: opens the way there in Maps") } icon: { Image(systemName: "arrow.triangle.turn.up.right.diamond.fill") }
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(.orange.opacity(0.85), in: .capsule).foregroundStyle(.white)
                        }
                    }
                    if !late {
                        Button(intent: RemindToLeaveIntent(event: event.title, start: event.start)) {
                            Label { Text("Remind Me in 10", comment: "Up Next widget: a reminder to leave, ten minutes from now") } icon: { Image(systemName: "bell") }
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .background(.quaternary, in: .capsule)
                    }
                }
                .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct UpNextView: View {
    let entry: UpNextEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        UpNextCard(entry: entry, family: family)
            .widgetURL(EchoURL.open)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: UpNext.widgetKind, provider: UpNextProvider()) { UpNextView(entry: $0) }
            .configurationDisplayName("Up Next")
            .description("Your day in order, with your agent's notes. In the hour before you need to leave, a countdown to when to go.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
