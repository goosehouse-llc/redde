import SwiftUI
import WidgetKit
#if WIDGET_VIEWS_IN_TESTS
@testable import Echo
#endif

// The agent's widget: whatever it last put there with its phone tool (`AgentBoard`). The
// timeline holds every change already known (something set for later starting, something
// running out), so the widget moves on with Redde closed; the app and the notification
// extension reload it when the agent writes.

struct BoardEntry: TimelineEntry {
    let date: Date
    let board: AgentBoard?
    var hidesWords = false

    /// What the widget gallery shows.
    static let sample = BoardEntry(date: .now, board: AgentBoard(
        title: String(localized: "Today", comment: "Widget gallery: a sample title the agent wrote on its widget"),
        text: String(localized: "9:30 standup\n12:15 lunch with Dana\nLeave by 4:40 for the vet", comment: "Widget gallery: sample lines the agent wrote on its widget"),
        from: .now))

    /// What shows now, and at each moment something starts or runs out.
    static func timeline(_ boards: [AgentBoard], from now: Date, hidesWords: Bool) -> [BoardEntry] {
        ([now] + AgentBoard.turns(after: now, among: boards)).map {
            BoardEntry(date: $0, board: AgentBoard.showing(at: $0, among: boards), hidesWords: hidesWords)
        }
    }
}

struct BoardProvider: TimelineProvider {
    func placeholder(in context: Context) -> BoardEntry { .sample }
    func getSnapshot(in context: Context, completion: @escaping (BoardEntry) -> Void) {
        completion(context.isPreview ? .sample : BoardEntry(date: .now, board: AgentBoard.showing(at: .now, among: AgentBoard.all()), hidesWords: NeedsYou.hidesWords))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<BoardEntry>) -> Void) {
        completion(Timeline(entries: BoardEntry.timeline(AgentBoard.all(), from: .now, hidesWords: NeedsYou.hidesWords), policy: .never))
    }
}

/// A title and a few lines, as the agent wrote them; the time under them is when they went up.
struct BoardCard: View {
    let board: AgentBoard?
    var hidesWords = false
    let family: WidgetFamily

    private var title: String { hidesWords ? String(localized: "From your agent") : board?.title ?? "" }
    private var text: String { hidesWords ? String(localized: "Unlock Redde to read it.") : board?.text ?? "" }

    var body: some View {
        if let board, !board.isEmpty {
            switch family {
            case .accessoryInline:
                Label(hidesWords ? String(localized: "From your agent") : board.title.isEmpty ? board.text : board.title, systemImage: "text.bubble")
                    .privacySensitive()
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    if !title.isEmpty { Text(title).font(.headline).lineLimit(1).widgetAccentable() }
                    Text(text).font(.caption).lineLimit(title.isEmpty ? 3 : 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .privacySensitive()
            default:
                VStack(alignment: .leading, spacing: 4) {
                    if !title.isEmpty {
                        Text(title).font(.headline).lineLimit(family == .systemSmall ? 2 : 1).foregroundStyle(.tint)
                    }
                    Text(text)
                        .font(family == .systemSmall ? .footnote : .subheadline)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Text(board.from, style: .time).font(.caption2).foregroundStyle(.secondary)
                }
                .privacySensitive()
            }
        } else {
            switch family {
            case .accessoryInline:
                Label("Nothing from your agent", systemImage: "text.bubble")
            case .accessoryRectangular:
                Text("Nothing from your agent yet.").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            default:
                VStack(spacing: 6) {
                    Image(systemName: "text.bubble").font(.title2).foregroundStyle(.tint)
                    Text("Nothing here yet").font(.footnote.weight(.semibold))
                    Text("Ask your agent to put something on your widget.").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
    }
}

struct BoardWidgetView: View {
    let entry: BoardEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        BoardCard(board: entry.board, hidesWords: entry.hidesWords, family: family)
            .widgetURL(EchoURL.open)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct BoardWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AgentBoard.widgetKind, provider: BoardProvider()) { entry in
            BoardWidgetView(entry: entry)
        }
        .configurationDisplayName("From Your Agent")
        .description("A few lines your agent keeps up to date, with Phone tools turned on.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}
