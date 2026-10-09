import SwiftUI
import WidgetKit

/// The watch app's complications. One so far: Ask Redde, in the four sizes a face has room for.
@main
struct ReddeWatchWidgets: WidgetBundle {
    var body: some Widget {
        AskComplicationWidget()
    }
}

struct AskEntry: TimelineEntry {
    let date: Date
}

/// Nothing to keep up to date: the complication is a way in.
struct AskProvider: TimelineProvider {
    func placeholder(in context: Context) -> AskEntry { AskEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (AskEntry) -> Void) { completion(AskEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AskEntry>) -> Void) {
        completion(Timeline(entries: [AskEntry(date: .now)], policy: .never))
    }
}

struct AskComplicationEntryView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        AskComplicationView(family: family)
            .widgetURL(AskComplication.url)
            .containerBackground(.clear, for: .widget)
    }
}

struct AskComplicationWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AskComplication.kind, provider: AskProvider()) { _ in
            AskComplicationEntryView()
        }
        .configurationDisplayName("Ask Redde")
        .description("Opens Redde listening for a question.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}
