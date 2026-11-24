import AppIntents
import SwiftUI
import WidgetKit
#if WIDGET_VIEWS_IN_TESTS
@testable import Echo
#endif

// Lists (2026-11-24): one of the person's lists (`TodayList`, the plugin's, kept by the app in the
// app group), picked in the widget's settings or the one with most to do. Items are ticked right
// on the widget: the tick shows at once, and the app tells the Hermes (`TickListItemIntent`). A
// watch list shows its posters, as the app saved them small for the widget (`WidgetImages`).

struct ListsEntry: TimelineEntry {
    let date: Date
    var list: TodayList?
    var hidesWords = false

    static let sample: ListsEntry = {
        let items = [("Oat milk", true), ("Lemons", false), ("Sourdough", false), ("Coffee beans", false), ("Basil", true), ("Eggs", false)]
            .enumerated().map { TodayList.Item(id: "\($0.offset)", text: $0.element.0, done: $0.element.1) }
        return ListsEntry(date: .now, list: TodayList(id: "sample", title: String(localized: "Groceries", comment: "Widget gallery: a sample list's name"),
                                                      items: items, kind: .shopping, emoji: "🛒", hue: .green))
    }()
}

struct ListsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ListsEntry { .sample }

    func snapshot(for configuration: ListWidgetIntent, in context: Context) async -> ListsEntry {
        context.isPreview && TodayList.kept().isEmpty ? .sample : entry(configuration, at: .now)
    }

    func timeline(for configuration: ListWidgetIntent, in context: Context) async -> Timeline<ListsEntry> {
        // The app reloads this when a list changes; a list by when moves its items on at midnight.
        let midnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86_400)).addingTimeInterval(60)
        return Timeline(entries: [entry(configuration, at: .now)], policy: .after(midnight))
    }

    private func entry(_ configuration: ListWidgetIntent, at now: Date) -> ListsEntry {
        let lists = TodayList.kept()
        let list = configuration.list.flatMap { picked in lists.first { $0.id == picked.id } } ?? TodayList.pick(lists)
        return ListsEntry(date: now, list: list, hidesWords: NeedsYou.hidesWords)
    }
}

extension TodayList.Hue {
    var widgetColor: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }
}

struct ListsCard: View {
    let entry: ListsEntry
    let family: WidgetFamily

    // The list shows with Redde locked too (Settings → Privacy), as Reminders' widget does
    // (2026-11-24: "show lists and goals with the lock on too"); iOS hides it on a locked iPhone.

    var body: some View {
        if let list = entry.list {
            VStack(alignment: .leading, spacing: family == .systemSmall ? 5 : 7) {
                header(list)
                if list.open.isEmpty {
                    Spacer(minLength: 0)
                    Label { Text("All done", comment: "Lists widget: nothing left on the list") } icon: { Image(systemName: "checkmark.circle.fill") }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                    Spacer(minLength: 0)
                } else if list.kind == .watch, family != .systemSmall {
                    posters(list)
                } else if list.groupsByWhen, family == .systemLarge {
                    byWhen(list)
                } else {
                    // What's left, then what was ticked (to untick one ticked by mistake).
                    rows(Array((list.open + list.items.filter(\.done)).prefix(most)), in: list)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .tint(list.hue?.widgetColor ?? .accentColor)
            .privacySensitive()
        } else {
            VStack(spacing: 6) {
                Image(systemName: "checklist").font(.title2).foregroundStyle(.tint)
                Text("No lists yet", comment: "Lists widget: the person has no lists").font(.footnote.weight(.semibold))
                if family != .systemSmall {
                    Text("Ask your agent to make you a list.", comment: "Lists widget with no lists: how to get one")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var most: Int {
        switch family {
        case .systemSmall: 4
        case .systemMedium: 4
        default: 10
        }
    }

    private func header(_ list: TodayList) -> some View {
        Link(destination: EchoURL.list(list.id)) {
            HStack(spacing: 5) {
                if let emoji = list.emoji { Text(emoji).font(.subheadline) }
                Text(list.title)
                    .font(.subheadline.weight(.bold)).lineLimit(1)
                Spacer(minLength: 4)
                if !list.open.isEmpty {
                    Text("\(list.open.count) left", comment: "Lists widget: how many items are still to do")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .foregroundStyle(Color.primary)
        }
    }

    private func rows(_ items: [TodayList.Item], in list: TodayList) -> some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 5 : 6) {
            ForEach(items) { item in row(item, in: list) }
        }
    }

    private func row(_ item: TodayList.Item, in list: TodayList) -> some View {
        Button(intent: TickListItemIntent(list: list.id, item: item.id, done: !item.done)) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                WidgetTick(done: item.done, size: family == .systemSmall ? 15 : 17)
                Text(item.text).font(family == .systemSmall ? .caption : .subheadline).lineLimit(1)
                    .strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary)
                Spacer(minLength: 0)
                if family == .systemLarge, let when = item.timeAndCompany, item.when.map({ Calendar.current.isDateInToday($0) }) == true {
                    Text(when).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func byWhen(_ list: TodayList) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Self.trimmed(list.openByWhen(now: entry.date), most: 9)) { group in
                Text(Self.title(group.when)).font(.caption2.weight(.bold)).textCase(.uppercase)
                    .foregroundStyle(group.when == .overdue ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .padding(.top, 2)
                ForEach(group.items) { item in row(item, in: list) }
            }
            Spacer(minLength: 0)
        }
    }

    /// The groups, cut to `most` items in all.
    static func trimmed(_ groups: [TodayList.WhenGroup], most: Int) -> [TodayList.WhenGroup] {
        var left = most
        var kept: [TodayList.WhenGroup] = []
        for group in groups where left > 0 {
            let items = Array(group.items.prefix(left))
            kept.append(TodayList.WhenGroup(when: group.when, items: items))
            left -= items.count
        }
        return kept
    }

    static func title(_ when: TodayList.When) -> String {
        switch when {
        case .overdue: String(localized: "Overdue", comment: "A to-do list: the group of items whose day has passed")
        case .today: String(localized: "Today", comment: "An agenda card's day")
        case .thisWeek: String(localized: "This week")
        case .later: String(localized: "Later")
        case .anytime: String(localized: "Anytime", comment: "A to-do list: the group of items with no day")
        }
    }

    /// A watch list: its posters, the next one planned under them.
    private func posters(_ list: TodayList) -> some View {
        let open = list.open
        let large = family == .systemLarge
        let count = large ? 8 : 5
        let columns = Array(repeating: GridItem(.flexible(), spacing: large ? 8 : 6), count: large ? 4 : 5)
        let planned = open.filter { $0.when.map { $0 > entry.date } ?? false }.min { ($0.when ?? .distantFuture) < ($1.when ?? .distantFuture) }
        return VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(open.prefix(count)) { item in poster(item, in: list).frame(height: large ? 118 : 86) }
            }
            Spacer(minLength: 0)
            if let planned, let plan = planned.plan {
                Label { Text("\(planned.name) · \(plan)").lineLimit(1) } icon: { Image(systemName: "calendar") }
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func poster(_ item: TodayList.Item, in list: TodayList) -> some View {
        Button(intent: TickListItemIntent(list: list.id, item: item.id, done: true)) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let file = item.poster.map({ WidgetImages.name(for: $0) }), let image = WidgetImages.image(file) {
                        Image(uiImage: image).resizable().widgetAccentedRenderingMode(.accentedDesaturated).scaledToFill()
                    } else {
                        ZStack {
                            Rectangle().fill(.tint.opacity(0.22))
                            Text(item.name).font(.caption2.weight(.semibold)).multilineTextAlignment(.center).lineLimit(4).padding(4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(.rect(cornerRadius: 6, style: .continuous))
                Image(systemName: "checkmark.circle.fill").font(.caption).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.45)).padding(3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.name)
    }
}

struct ListsWidgetView: View {
    let entry: ListsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        ListsCard(entry: entry, family: family)
            .widgetURL(entry.list.map { EchoURL.list($0.id) } ?? EchoURL.open)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct ListsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.lists, intent: ListWidgetIntent.self, provider: ListsProvider()) { entry in
            ListsWidgetView(entry: entry)
        }
        .configurationDisplayName("Lists")
        .description("One of your lists. Tick things off right on the widget.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
