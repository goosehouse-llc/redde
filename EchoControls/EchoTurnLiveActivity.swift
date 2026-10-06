import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen banner + Dynamic Island for a turn in flight. When the system marks the activity
/// stale (the app stopped updating it: a crash, the app closed, a suspension mid-reply), a reply
/// that was still running is shown as interrupted, with no pulse and no running clock.
struct EchoTurnLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: EchoTurnAttributes.self) { context in
            banner(context)
                .activityBackgroundTint(Color(red: 0.114, green: 0.400, blue: 0.851).opacity(0.18))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            let state = context.state, stale = context.isStale
            let running = state.isLive && !stale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.symbol(stale: stale))
                        .font(.title2)
                        .foregroundStyle(tint(state, stale: stale))
                        .symbolEffect(.pulse, isActive: running)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if running {
                        Text(state.startedAt, style: .timer)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title(stale: stale))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(state.detailLine(stale: stale, question: context.attributes.question))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            } compactLeading: {
                Image(systemName: state.symbol(stale: stale))
                    .foregroundStyle(tint(state, stale: stale))
                    .symbolEffect(.pulse, isActive: running)
            } compactTrailing: {
                Text(state.compact(stale: stale))
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 60)
            } minimal: {
                Image(systemName: state.symbol(stale: stale)).foregroundStyle(tint(state, stale: stale))
            }
            .widgetURL(URL(string: "echo://open"))
        }
    }

    private func banner(_ context: ActivityViewContext<EchoTurnAttributes>) -> some View {
        let state = context.state, stale = context.isStale
        let running = state.isLive && !stale
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.symbol(stale: stale))
                .font(.title2)
                .foregroundStyle(tint(state, stale: stale))
                .frame(width: 32)
                .symbolEffect(.pulse, isActive: running)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(state.title(stale: stale)).font(.subheadline.weight(.semibold))
                    Spacer()
                    if running {
                        Text(state.startedAt, style: .timer)
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Text(context.attributes.question)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if stale, state.isLive {
                    Text(state.detailLine(stale: true, question: "")).font(.footnote).lineLimit(2)
                } else if !state.detail.isEmpty, state.phase != .thinking {
                    Text(state.detail).font(.footnote).lineLimit(3)
                }
            }
        }
        .padding(14)
    }

    private func tint(_ state: EchoTurnAttributes.ContentState, stale: Bool) -> Color {
        if stale, state.isLive { return .secondary }
        switch state.phase {
        case .thinking, .replying: return Color(red: 0.180, green: 0.545, blue: 0.961)
        case .tool: return .orange
        case .done: return .green
        case .failed: return .red
        }
    }
}
