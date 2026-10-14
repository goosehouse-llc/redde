import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

/// A timer Redde set for the agent (Phone tools → Alarms), counting down on the Lock Screen and
/// in the Dynamic Island. The alert when it rings is iOS's own; the time before it is the
/// app's to draw, and iOS doesn't keep a timer that has nothing to draw it.
struct AlarmCountdownActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<AgentAlarm>.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "timer")
                    .font(.title2)
                    .foregroundStyle(context.attributes.tintColor)
                Text(Self.title(context.attributes))
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Remaining(state: context.state)
                    .font(.title.monospacedDigit().weight(.semibold))
                    .frame(maxWidth: 120, alignment: .trailing)
            }
            .padding()
            .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(Self.title(context.attributes), systemImage: "timer")
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Remaining(state: context.state)
                        .font(.title2.monospacedDigit().weight(.semibold))
                }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(context.attributes.tintColor)
            } compactTrailing: {
                Remaining(state: context.state)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(context.attributes.tintColor)
            }
        }
    }

    static func title(_ attributes: AlarmAttributes<AgentAlarm>) -> String {
        attributes.metadata?.title ?? "Timer"
    }
}

/// The time left: running, held, or up.
private struct Remaining: View {
    let state: AlarmPresentationState

    var body: some View {
        switch state.mode {
        case let .countdown(countdown):
            Text(timerInterval: Date.now ... max(countdown.fireDate, .now), countsDown: true)
                .multilineTextAlignment(.trailing)
        case let .paused(paused):
            Text(Duration.seconds(max(0, paused.totalCountdownDuration - paused.previouslyElapsedDuration))
                .formatted(.time(pattern: .hourMinuteSecond)))
        case .alert:
            Text("Now")
        @unknown default:
            EmptyView()
        }
    }
}
