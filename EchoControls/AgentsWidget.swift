import SwiftUI
import WidgetKit
#if WIDGET_VIEWS_IN_TESTS
@testable import Echo
#endif

// Your Agents (2026-11-24), in Last Reply's place (its kind, so one already on a Home Screen
// becomes this): the main agent and the bots, each at work, waiting on the person, or idle, with
// the last thing said in its chat; and Ask, which opens Redde listening. From the app group
// (`WidgetAgents`), which the app writes as the chat list sees them change.

struct AgentsEntry: TimelineEntry {
    let date: Date
    var agents: WidgetAgents?
    var hidesWords = false

    static let sample: AgentsEntry = {
        let now = Date.now
        let agents: [WidgetAgents.Agent] = [
            .init(id: "default", name: "Sol", status: .working,
                  line: String(localized: "Your Montreal packing list is ready: eight things, two to buy.", comment: "Widget gallery: the main agent's last reply"),
                  at: now.addingTimeInterval(-300), isMain: true),
            .init(id: "home", name: "Home", status: .idle,
                  line: String(localized: "The dryer finished at 11:40.", comment: "Widget gallery: a bot's last message"), at: now.addingTimeInterval(-3600), isMain: false),
            .init(id: "coder", name: "Coder", status: .needsYou,
                  line: String(localized: "Ready to push the login fix.", comment: "Widget gallery: a bot's last message"), at: now.addingTimeInterval(-600), isMain: false),
            .init(id: "research", name: "Research", status: .idle,
                  line: String(localized: "Three hotels near Old Montreal.", comment: "Widget gallery: a bot's last message"), at: now.addingTimeInterval(-7200), isMain: false),
        ]
        return AgentsEntry(date: now, agents: WidgetAgents(agents: agents, written: now))
    }()
}

struct AgentsProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgentsEntry { .sample }
    func getSnapshot(in context: Context, completion: @escaping (AgentsEntry) -> Void) {
        completion(context.isPreview && WidgetAgents.load() == nil ? .sample : AgentsEntry(date: .now, agents: WidgetAgents.load(), hidesWords: NeedsYou.hidesWords))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AgentsEntry>) -> Void) {
        // The app reloads this as the agents change; once what was heard is too old to believe
        // (`WidgetAgents.believed`), a second entry lets "Working" go.
        let now = Date.now
        let agents = WidgetAgents.load()
        var entries = [AgentsEntry(date: now, agents: agents, hidesWords: NeedsYou.hidesWords)]
        if let agents, agents.agents.contains(where: { $0.status == .working }) {
            let stale = agents.written.addingTimeInterval(WidgetAgents.believed + 1)
            if stale > now { entries.append(AgentsEntry(date: stale, agents: agents, hidesWords: NeedsYou.hidesWords)) }
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

struct AgentsCard: View {
    let entry: AgentsEntry
    let family: WidgetFamily

    private var agents: [WidgetAgents.Agent] { entry.agents?.agents ?? [] }
    private var main: WidgetAgents.Agent? { entry.agents?.main }
    private var mainName: String { main?.name ?? "Redde" }
    private var hides: Bool { entry.hidesWords }

    private func status(_ agent: WidgetAgents.Agent) -> WidgetAgents.Status {
        entry.agents?.status(of: agent, at: entry.date) ?? .idle
    }

    private func word(_ status: WidgetAgents.Status) -> String {
        switch status {
        case .working: String(localized: "Working")
        case .needsYou: String(localized: "Needs you")
        case .idle: String(localized: "Idle")
        }
    }

    private func color(_ status: WidgetAgents.Status) -> AnyShapeStyle {
        switch status {
        case .working: AnyShapeStyle(.tint)
        case .needsYou: AnyShapeStyle(.orange)
        case .idle: AnyShapeStyle(.secondary)
        }
    }

    /// Each face opens that agent's chat; the main agent's goes back to a chat with it when a bot's is open.
    private func link(_ agent: WidgetAgents.Agent) -> URL { EchoURL.bot(agent.id) }

    /// The newest thing an agent said, for the line under the team.
    private var latest: WidgetAgents.Agent? {
        agents.filter { $0.line?.isEmpty == false }.max { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(summary, systemImage: "person.2.fill")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                let waiting = agents.filter { status($0) == .needsYou }.count
                let working = agents.filter { status($0) == .working }.count
                VStack(spacing: 0) {
                    Image(systemName: waiting > 0 ? "hand.raised.fill" : working > 0 ? "ellipsis.bubble.fill" : "bubble.left.and.bubble.right.fill")
                        .font(.caption.weight(.semibold))
                    if waiting + working > 0 { Text("\(waiting > 0 ? waiting : working)").font(.title3.weight(.bold)).monospacedDigit() }
                }
                .widgetAccentable()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("Your Agents").font(.headline).widgetAccentable()
                let busy = agents.filter { status($0) != .idle }.prefix(2)
                if busy.isEmpty {
                    Text(hides ? String(localized: "Idle") : latest?.line ?? String(localized: "Idle")).font(.caption).lineLimit(2)
                } else {
                    ForEach(Array(busy)) { agent in
                        Text(status(agent) == .needsYou ? String(localized: "\(agent.name) needs you", comment: "Your Agents widget, Lock Screen: a bot is waiting on the person")
                             : String(localized: "\(agent.name) is working")).font(.caption).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemSmall:
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    WidgetFace(file: main?.face, name: mainName, size: 64)
                    if let main, status(main) != .idle {
                        Circle().fill(color(status(main))).frame(width: 12, height: 12).overlay { Circle().stroke(.background, lineWidth: 2) }
                    }
                }
                Spacer(minLength: 0)
                Label { Text("Ask \(mainName)") } icon: { Image(systemName: "mic.fill") }
                    .font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.tint, in: .capsule).foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .systemMedium:
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(agents.prefix(4)) { agent in
                        Link(destination: link(agent)) {
                            VStack(spacing: 3) {
                                WidgetFace(file: agent.face, name: agent.name, size: 34)
                                Text(agent.name).font(.caption.weight(.semibold)).lineLimit(1)
                                Text(word(status(agent))).font(.caption2.weight(.semibold)).foregroundStyle(color(status(agent))).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(Color.primary)
                        }
                    }
                }
                askBar(line: hides ? nil : latest)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        default:   // large
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: String(localized: "Your Agents"), symbol: "person.2.fill")
                let shown = Array(agents.prefix(6))
                let rows = max(1, (shown.count + 1) / 2)
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(0 ..< rows, id: \.self) { row in
                        GridRow {
                            ForEach(shown[(row * 2) ..< min(row * 2 + 2, shown.count)]) { agent in card(agent, lines: rows > 2 ? 1 : 3) }
                            if row * 2 + 1 >= shown.count { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                        }
                    }
                }
                Spacer(minLength: 0)
                askBar(line: nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var summary: String {
        if let waiting = agents.first(where: { status($0) == .needsYou }) {
            return String(localized: "\(waiting.name) needs you", comment: "Your Agents widget, Lock Screen: a bot is waiting on the person")
        }
        if let working = agents.first(where: { status($0) == .working }) { return String(localized: "\(working.name) is working") }
        return String(localized: "Ask \(mainName)")
    }

    private func card(_ agent: WidgetAgents.Agent, lines: Int) -> some View {
        Link(destination: link(agent)) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    WidgetFace(file: agent.face, name: agent.name, size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(agent.name).font(.footnote.weight(.semibold)).lineLimit(1)
                        Text(word(status(agent))).font(.caption2.weight(.semibold)).foregroundStyle(color(status(agent))).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if let line = agent.line, !hides {
                    Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(lines).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if let at = agent.at {
                    Text(.currentDate, format: .reference(to: at, allowedFields: [.day, .hour, .minute], maxFieldCount: 1))
                        .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 12, style: .continuous))
            .foregroundStyle(Color.primary)
        }
    }

    /// "**Sol:** Your packing list is ready."
    static func said(_ name: String, _ words: String) -> AttributedString {
        var who = AttributedString(name + ": ")
        who.inlinePresentationIntent = .stronglyEmphasized
        return who + AttributedString(words)
    }

    /// The last thing said (its agent's chat) or Ask (a new chat with the main agent, the keyboard
    /// up), and the microphone: Redde opens listening.
    private func askBar(line: WidgetAgents.Agent?) -> some View {
        HStack(spacing: 8) {
            if let line, let words = line.line {
                Link(destination: link(line)) {
                    Text(Self.said(line.name, words)).font(.caption).lineLimit(2).foregroundStyle(Color.primary).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(.rect)
                }
            } else {
                Link(destination: EchoURL.compose) {
                    Text("Ask \(mainName)").font(.footnote).foregroundStyle(Color.secondary)   // the link's tint, else
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(.rect)
                }
            }
            Link(destination: EchoURL.listen(handsFree: false)) {
                Image(systemName: "mic.fill").font(.footnote.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(.tint, in: .circle)
            }
        }
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: .capsule)
    }
}

struct AgentsWidgetView: View {
    let entry: AgentsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        AgentsCard(entry: entry, family: family)
            .privacySensitive()
            .widgetURL(family == .systemSmall || family == .accessoryCircular ? EchoURL.listen(handsFree: false) : EchoURL.open)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct AgentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.agents, provider: AgentsProvider()) { entry in
            AgentsWidgetView(entry: entry)
        }
        .configurationDisplayName("Your Agents")
        .description("Who's working, who needs you, and what each said last. Tap to ask.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
