import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen banner + Dynamic Island for a turn in flight.
struct EchoTurnLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: EchoTurnAttributes.self) { context in
            banner(context)
                .activityBackgroundTint(Color(red: 0.114, green: 0.400, blue: 0.851).opacity(0.18))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: symbol(context.state.phase))
                        .font(.title2)
                        .foregroundStyle(tint(context.state.phase))
                        .symbolEffect(.pulse, isActive: context.state.phase != .done && context.state.phase != .failed)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(title(context.state))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.phase == .thinking ? context.attributes.question : context.state.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            } compactLeading: {
                Image(systemName: symbol(context.state.phase))
                    .foregroundStyle(tint(context.state.phase))
                    .symbolEffect(.pulse, isActive: context.state.phase != .done && context.state.phase != .failed)
            } compactTrailing: {
                Text(compact(context.state))
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 60)
            } minimal: {
                Image(systemName: symbol(context.state.phase)).foregroundStyle(tint(context.state.phase))
            }
            .widgetURL(URL(string: "echo://open"))
        }
    }

    private func banner(_ context: ActivityViewContext<EchoTurnAttributes>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(context.state.phase))
                .font(.title2)
                .foregroundStyle(tint(context.state.phase))
                .frame(width: 32)
                .symbolEffect(.pulse, isActive: context.state.phase != .done && context.state.phase != .failed)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title(context.state)).font(.subheadline.weight(.semibold))
                    Spacer()
                    if context.state.phase != .done && context.state.phase != .failed {
                        Text(context.state.startedAt, style: .timer)
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Text(context.attributes.question)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !context.state.detail.isEmpty, context.state.phase != .thinking {
                    Text(context.state.detail).font(.footnote).lineLimit(3)
                }
            }
        }
        .padding(14)
    }

    private func title(_ state: EchoTurnAttributes.ContentState) -> String {
        switch state.phase {
        case .thinking: "Redde is thinking"
        case .tool: "Using \(state.detail)"
        case .replying: "Redde is replying"
        case .done: "Redde replied"
        case .failed: "Redde couldn't reply"
        }
    }

    private func compact(_ state: EchoTurnAttributes.ContentState) -> String {
        switch state.phase {
        case .thinking: "thinking"
        case .tool: state.detail
        case .replying: "replying"
        case .done: "done"
        case .failed: "failed"
        }
    }

    private func symbol(_ phase: EchoTurnAttributes.ContentState.Phase) -> String {
        switch phase {
        case .thinking: "brain"
        case .tool: "gearshape.2"
        case .replying: "waveform"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ phase: EchoTurnAttributes.ContentState.Phase) -> Color {
        switch phase {
        case .thinking, .replying: Color(red: 0.180, green: 0.545, blue: 0.961)
        case .tool: .orange
        case .done: .green
        case .failed: .red
        }
    }
}
