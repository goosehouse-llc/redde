import SwiftUI
import WidgetKit
#if WIDGET_VIEWS_IN_TESTS
@testable import Echo
#endif

// Up Next (asked 2026-10-28, "Proactive": what's next on the Lock Screen): the next event a
// heads-up was set for, counting down, to when to leave where the phone worked that out
// (`LeaveTime`); and what is waiting in Redde, briefings not read and ideas offered. From the app
// group; the notification extension reloads it as each briefing or idea comes.

struct UpNextEntry: TimelineEntry {
    let date: Date
    var event: AgentBriefing?
    var briefings = 0
    var ideas = 0
    var hidesWords = false

    static let sample: UpNextEntry = {
        var dentist = AgentBriefing(id: "sample", title: "Heads-up: Dentist", agent: "", text: "", at: .now, failed: false)
        dentist.eventAt = .now.addingTimeInterval(55 * 60)
        dentist.leaveAt = .now.addingTimeInterval(22 * 60)
        dentist.place = "Dr. Lee, Main St"
        return UpNextEntry(date: .now, event: dentist, briefings: 1, ideas: 3)
    }()

    static func now(_ date: Date = .now) -> UpNextEntry {
        let briefings = AgentBriefing.all()
        return UpNextEntry(date: date, event: AgentBriefing.next(in: briefings, after: date),
                           briefings: briefings.filter { !$0.read && $0.showing(at: date) && $0.eventAt == nil }.count,
                           ideas: AgentIdea.all().count, hidesWords: NeedsYou.hidesWords)
    }
}

struct UpNextProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpNextEntry { .sample }
    func getSnapshot(in context: Context, completion: @escaping (UpNextEntry) -> Void) {
        completion(context.isPreview ? .sample : .now())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UpNextEntry>) -> Void) {
        let now = UpNextEntry.now()
        // Again when it is time to leave, and once the event has started (the next one, then).
        let turns = [now.event?.leaveAt, now.event?.eventAt].compactMap(\.self).filter { $0 > .now }.sorted()
        let later = turns.map { UpNextEntry.now($0.addingTimeInterval(1)) }
        completion(Timeline(entries: [now] + later, policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

/// The card itself, by size (the tests draw it in each).
struct UpNextCard: View {
    let entry: UpNextEntry
    let family: WidgetFamily

    private var event: AgentBriefing? { entry.event }
    private var name: String { entry.hidesWords ? String(localized: "Your next event") : event?.heading ?? "" }
    /// "Leave in 12 min" while there is a leaving time still to come; else "in 40 min".
    private var leaving: Bool { (event?.leaveAt ?? .distantPast) > entry.date }

    private var waiting: String? {
        var parts: [String] = []
        if entry.briefings > 0 { parts.append(String(localized: "\(entry.briefings) briefings")) }
        if entry.ideas > 0 { parts.append(String(localized: "\(entry.ideas) ideas")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var countdown: some View {
        if let event, let at = leaving ? event.leaveAt : event.eventAt {
            HStack(spacing: 4) {
                Text(leaving ? String(localized: "Leave in") : String(localized: "Starts in"))
                Text(at, style: .relative)
            }
        }
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                if let event, let at = event.eventAt {
                    Label { Text("\(name) \(at, style: .time)") } icon: { Image(systemName: leaving ? "car" : "calendar") }
                } else {
                    Label(waiting ?? String(localized: "Nothing up next"), systemImage: "sparkles")
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    if let event, let at = event.eventAt {
                        Text("\(name) · \(at, style: .time)").font(.headline).lineLimit(1).widgetAccentable()
                        countdown.font(.caption)
                        if let waiting { Text(waiting).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    } else {
                        Text("Up Next").font(.headline).widgetAccentable()
                        Text(waiting ?? String(localized: "Nothing coming up")).font(.caption).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                VStack(alignment: .leading, spacing: 6) {
                    Label("Up Next", systemImage: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    if let event, let at = event.eventAt {
                        Text(name).font(.headline).lineLimit(family == .systemSmall ? 2 : 1)
                        Text(at, style: .time).font(.subheadline).foregroundStyle(.secondary)
                        countdown.font(.subheadline.weight(.semibold)).foregroundStyle(leaving ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                        if family != .systemSmall, let place = event.place, !entry.hidesWords {
                            Label(place, systemImage: "mappin").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } else {
                        Text("Nothing coming up").font(.headline)
                    }
                    Spacer(minLength: 0)
                    if let waiting { Text(waiting).font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .privacySensitive()
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
            .description("Your next event with a heads-up, counting down to when to leave, and what's waiting in Redde.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}
