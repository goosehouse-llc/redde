import SwiftUI
import WidgetKit

// (Last Reply's place is Your Agents': `AgentsWidget.swift`, with its kind.)

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
