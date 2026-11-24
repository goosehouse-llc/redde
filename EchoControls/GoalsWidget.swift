import AppIntents
import SwiftUI
import WidgetKit
#if WIDGET_VIEWS_IN_TESTS
@testable import Echo
#endif

// Goals (2026-11-24): one goal the agent follows (`GoalReport`, kept in the app group), picked in
// the widget's settings or the one with a step of the person's next: how far along it is, their
// next steps, ticked right on the widget (the app tells the plugin, as the goal page's tick does:
// `TickGoalStepIntent`), the agent's own steps, and its last check-in.

struct GoalsEntry: TimelineEntry {
    let date: Date
    var goal: GoalReport?
    var hidesWords = false

    static let sample: GoalsEntry = {
        let now = Date.now
        var goal = GoalReport(id: "sample", title: String(localized: "Run a 5K", comment: "Widget gallery: a sample goal"), agent: "Sol",
                              done: 3, total: 7,
                              headline: String(localized: "2 km felt easy on Sunday. Try 3 on Thursday.", comment: "Widget gallery: the agent's last check-in on the sample goal"),
                              at: now.addingTimeInterval(-2 * 86_400), failed: false)
        goal.target = now.addingTimeInterval(26 * 86_400)
        goal.steps = [
            .init(title: String(localized: "Buy running shoes", comment: "Widget gallery: a step of the sample goal"), cardID: nil, done: true, who: "you"),
            .init(title: String(localized: "Run 3 km Thursday", comment: "Widget gallery: a step of the sample goal"), cardID: nil, done: false, who: "you"),
            .init(title: String(localized: "Run 5 km Sunday", comment: "Widget gallery: a step of the sample goal"), cardID: nil, done: false, who: "you"),
            .init(title: String(localized: "A four-week training plan", comment: "Widget gallery: a step of the sample goal"), cardID: "c1", done: true, who: "agent"),
            .init(title: String(localized: "Find a 5K race on December 20", comment: "Widget gallery: a step of the sample goal"), cardID: "c2", done: false, who: "agent"),
        ]
        return GoalsEntry(date: now, goal: goal)
    }()
}

struct GoalsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> GoalsEntry { .sample }

    func snapshot(for configuration: GoalWidgetIntent, in context: Context) async -> GoalsEntry {
        context.isPreview && GoalReport.showing().isEmpty ? .sample : entry(configuration, at: .now)
    }

    func timeline(for configuration: GoalWidgetIntent, in context: Context) async -> Timeline<GoalsEntry> {
        // The app and the notification extension reload this as a goal changes; once a day for its days left.
        let midnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86_400)).addingTimeInterval(60)
        return Timeline(entries: [entry(configuration, at: .now)], policy: .after(midnight))
    }

    private func entry(_ configuration: GoalWidgetIntent, at now: Date) -> GoalsEntry {
        let goals = GoalReport.showing()
        let goal = configuration.goal.flatMap { picked in goals.first { $0.id == picked.id } } ?? GoalReport.pick(goals)
        return GoalsEntry(date: now, goal: goal, hidesWords: NeedsYou.hidesWords)
    }
}

struct GoalsCard: View {
    let entry: GoalsEntry
    let family: WidgetFamily

    /// With Redde locked (Settings → Privacy) the goal and its steps show (2026-11-24: "show lists
    /// and goals with the lock on too"); the agent's note on it doesn't. iOS hides it all on a
    /// locked iPhone.
    private var hides: Bool { entry.hidesWords }

    var body: some View {
        if let goal = entry.goal {
            content(goal).privacySensitive()
        } else {
            switch family {
            case .accessoryInline: Label("Goals", systemImage: "target")
            case .accessoryCircular: ZStack { AccessoryWidgetBackground(); Image(systemName: "target").font(.title3) }
            default:
                VStack(spacing: 6) {
                    Image(systemName: "target").font(.title2).foregroundStyle(.tint)
                    Text("No goals yet", comment: "Goals widget: the agent follows no goal for the person").font(.footnote.weight(.semibold))
                    if family != .systemSmall && family != .accessoryRectangular {
                        Text("Tell your agent something you'd like to get done, and ask it to help you see it through.",
                             comment: "Goals widget with no goals: how to get one")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func title(_ goal: GoalReport) -> String { goal.title }

    /// Its steps as the person's and the agent's, each with where it is in the goal's list.
    private func steps(_ goal: GoalReport) -> (yours: [(Int, GoalReport.Step)], agents: [(Int, GoalReport.Step)]) {
        let all = Array((goal.steps ?? []).enumerated())
        return (all.filter { $0.element.isYours }.map { ($0.offset, $0.element) }, all.filter { !$0.element.isYours }.map { ($0.offset, $0.element) })
    }

    /// "Dec 20 · in 26 days".
    private func target(_ goal: GoalReport) -> String? {
        guard let target = goal.target else { return nil }
        return target.formatted(.dateTime.month(.abbreviated).day()) + " · " + target.formatted(.relative(presentation: .named))
    }

    @ViewBuilder private func content(_ goal: GoalReport) -> some View {
        let (yours, agents) = steps(goal)
        let open = yours.filter { !$0.1.done }
        switch family {
        case .accessoryInline:
            Label { Text(open.first.map { "\(title(goal)): \($0.1.title)" } ?? "\(title(goal)) \(goal.done)/\(goal.total)") } icon: { Image(systemName: "target") }
        case .accessoryCircular:
            Gauge(value: goal.fraction) { Image(systemName: "target") } currentValueLabel: {
                Text("\(goal.done)/\(goal.total)").monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("\(title(goal)) · \(goal.done)/\(goal.total)").font(.headline).lineLimit(1).widgetAccentable()
                if let next = open.first { Text(next.1.title).font(.caption).lineLimit(1) }
                if let target = target(goal) { Text(target).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemSmall:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ring(goal, size: 50, width: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(goal)).font(.subheadline.weight(.bold)).lineLimit(2)
                        if let target = goal.target {
                            Text(target.formatted(.dateTime.month(.abbreviated).day())).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                if let next = open.first {
                    Text("Your next step", comment: "Goals widget: the person's next step on the goal").font(.system(size: 9, weight: .bold)).textCase(.uppercase).foregroundStyle(.tint)
                    tick(goal, next, font: .caption)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .systemMedium:
            HStack(spacing: 14) {
                VStack(spacing: 4) {
                    ring(goal, size: 80, width: 8)
                    if let target = goal.target {
                        Text(target.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title(goal)).font(.headline).lineLimit(1)
                    ForEach(open.prefix(2), id: \.0) { tick(goal, $0, font: .footnote) }
                    Spacer(minLength: 0)
                    if let doing = agents.first(where: { !$0.1.done }) {
                        Label { Text(doing.1.title).lineLimit(1) } icon: { Text(goal.agent.prefix(1)).font(.caption2.weight(.bold)).foregroundStyle(.tint) }
                            .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8, style: .continuous))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        default:   // large
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ring(goal, size: 58, width: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(goal)).font(.title3.weight(.bold)).lineLimit(2)
                        if let target = target(goal) { Text(target).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if !yours.isEmpty {
                    Text("Your Steps").font(.caption2.weight(.bold)).textCase(.uppercase).foregroundStyle(.tint).padding(.top, 2)
                    // What's left first, then what's done.
                    ForEach((open + yours.filter { $0.1.done }).prefix(4), id: \.0) { tick(goal, $0, font: .subheadline) }
                }
                if !agents.isEmpty, !goal.agent.isEmpty {
                    Text(goal.agent).font(.caption2.weight(.bold)).textCase(.uppercase).foregroundStyle(.secondary).padding(.top, 2)
                    ForEach(agents.prefix(3), id: \.0) { step in
                        HStack(spacing: 8) {
                            Image(systemName: step.1.done ? "checkmark.circle.fill" : "ellipsis.circle").foregroundStyle(.secondary)
                            Text(step.1.title).font(.subheadline).foregroundStyle(step.1.done ? .secondary : .primary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
                if !hides, !goal.headline.isEmpty {
                    Divider()
                    HStack(alignment: .firstTextBaseline) {
                        Text(goal.headline).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Spacer(minLength: 4)
                        Text(goal.at.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func ring(_ goal: GoalReport, size: CGFloat, width: CGFloat) -> some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: width)
            Circle().trim(from: 0, to: goal.fraction).stroke(.tint, style: .init(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90)).widgetAccentable()
            Text("\(goal.done)/\(goal.total)").font(.system(size: size * 0.24, weight: .bold, design: .rounded)).monospacedDigit()
                .minimumScaleFactor(0.6)
        }
        .frame(width: size, height: size)
    }

    private func tick(_ goal: GoalReport, _ step: (Int, GoalReport.Step), font: Font) -> some View {
        Button(intent: TickGoalStepIntent(goal: goal.id, index: step.0, done: !step.1.done)) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                WidgetTick(done: step.1.done, size: 16)
                Text(step.1.title).font(font).lineLimit(1).strikethrough(step.1.done)
                    .foregroundStyle(step.1.done ? .secondary : .primary)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct GoalsWidgetView: View {
    let entry: GoalsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        GoalsCard(entry: entry, family: family)
            .widgetURL(EchoURL.open)
            .tint(.green)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct GoalsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.goals, intent: GoalWidgetIntent.self, provider: GoalsProvider()) { entry in
            GoalsWidgetView(entry: entry)
        }
        .configurationDisplayName("Goals")
        .description("How far along a goal is. Tick off your next step right on the widget.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
