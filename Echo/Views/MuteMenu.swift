import SwiftUI

/// Mute… for a bot's chat or a group chat (its row's menu, the chat's ••• menu): how long, or
/// Unmute, saying until when it is muted. See `Mutes`.
struct MuteMenu: View {
    /// The row's id (`BotListItem.id`): "bot:<profile>" or "room:<id>".
    let item: String
    @State private var settings = Settings.shared

    var body: some View {
        if let until = Mutes.until(item, settings: settings) {
            Button { Mutes.unmute(item, settings: settings) } label: {
                Label("Unmute", systemImage: "bell")
                Text(Mutes.describe(until: until))
            }
        } else {
            Menu {
                ForEach(MuteSpan.allCases) { span in
                    Button(span.title) { Mutes.mute(item, for: span, settings: settings) }
                }
            } label: {
                Label("Mute", systemImage: "bell.slash")
            }
        }
    }
}

/// The crossed-out bell a muted row wears beside its name.
/// A bot whose voice mode is a live call (`Settings.liveEngine(for:)`), on its row.
struct LiveCallMark: View {
    let engine: LiveEngine
    var body: some View {
        Image(systemName: "phone.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(engine.name) calls")
    }
}

struct MutedMark: View {
    var body: some View {
        Image(systemName: "bell.slash.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Muted")
    }
}
