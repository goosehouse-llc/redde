import SwiftUI
import WidgetKit

/// The "Ask Redde" complication: a tap on the watch face opens Redde listening. Its look is
/// here, in a file the watch app compiles too, so the two agree on the link and the app can show
/// the complication's sizes while it is being worked on.
nonisolated enum AskComplication {
    static let kind = "com.goosehouse.echo.watch.ask"
    /// What a tap opens. The watch app takes it as "start dictation".
    static let url = URL(string: "redde-watch://ask")!

    static func asks(_ url: URL) -> Bool { url.scheme == "redde-watch" && url.host == "ask" }
}

struct AskComplicationView: View {
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryCorner:
            Image(systemName: "mic.fill")
                .font(.title3.weight(.semibold))
                .widgetAccentable()
                .widgetLabel("Ask Redde")
        case .accessoryInline:
            Label("Ask Redde", systemImage: "mic.fill")
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.title3.weight(.semibold))
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Ask Redde").font(.headline)
                    Text("Tap and speak").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill")
                    .font(.title3.weight(.semibold))
                    .widgetAccentable()
            }
        }
    }
}
