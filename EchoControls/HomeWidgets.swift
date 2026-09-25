import SwiftUI
import WidgetKit

// MARK: - Last reply

struct LastReplyEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct LastReplyProvider: TimelineProvider {
    func placeholder(in context: Context) -> LastReplyEntry {
        LastReplyEntry(date: .now, snapshot: WidgetSnapshot(question: "What's on my calendar tomorrow?",
                                                            reply: "Two things: 9:30 standup and 12:15 lunch with Dana. I've added a reminder to call the vet at 4 pm.", date: .now))
    }
    func getSnapshot(in context: Context, completion: @escaping (LastReplyEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : LastReplyEntry(date: .now, snapshot: WidgetSnapshot.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LastReplyEntry>) -> Void) {
        // The app reloads this timeline when a reply lands; nothing to schedule otherwise.
        completion(Timeline(entries: [LastReplyEntry(date: .now, snapshot: WidgetSnapshot.load())], policy: .never))
    }
}

struct LastReplyWidgetView: View {
    let entry: LastReplyEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let s = entry.snapshot {
                VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform").font(.caption2.weight(.semibold))
                        Text(s.question).font(.caption.weight(.semibold)).lineLimit(family == .systemSmall ? 2 : 1).privacySensitive()
                        Spacer(minLength: 0)
                        if family != .systemSmall {
                            Text(s.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.tint)
                    Text(PlainText.display(s.reply))
                        .privacySensitive()
                        .font(family == .systemLarge ? .callout : .footnote)
                        .lineLimit(family == .systemSmall ? 5 : family == .systemMedium ? 4 : 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(.tint)
                    Text("Ask Redde something and the answer shows here.")
                        .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .widgetURL(EchoURL.open)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct LastReplyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.goosehouse.echo.lastreply", provider: LastReplyProvider()) { entry in
            LastReplyWidgetView(entry: entry)
        }
        .configurationDisplayName("Last reply")
        .description("The most recent answer from Redde.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Quick ask

struct QuickAskEntry: TimelineEntry { let date: Date }

struct QuickAskProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickAskEntry { QuickAskEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (QuickAskEntry) -> Void) { completion(QuickAskEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickAskEntry>) -> Void) {
        completion(Timeline(entries: [QuickAskEntry(date: .now)], policy: .never))
    }
}

struct QuickAskWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "waveform").font(.title2.weight(.semibold))
                }
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    Image(systemName: "waveform").font(.title3.weight(.semibold))
                    VStack(alignment: .leading) {
                        Text("Ask Redde").font(.headline)
                        Text("Tap to start listening").font(.caption2)
                    }
                }
            default:
                VStack(spacing: 10) {
                    ZStack {
                        Circle().fill(.tint)
                        Image(systemName: "mic.fill").font(.title.weight(.semibold)).foregroundStyle(.white)
                    }
                    .frame(width: 60, height: 60)
                    Text("Ask Redde").font(.footnote.weight(.semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .widgetURL(EchoURL.listen(handsFree: false))
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct QuickAskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.goosehouse.echo.quickask", provider: QuickAskProvider()) { _ in
            QuickAskWidgetView()
        }
        .configurationDisplayName("Ask Redde")
        .description("One tap opens Redde listening.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}
