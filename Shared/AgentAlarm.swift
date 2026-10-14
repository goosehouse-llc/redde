import AlarmKit

/// What goes with an alarm or timer Redde set for the agent (Phone tools → Alarms): its title,
/// for the countdown the widget extension draws. Both sides have to know the type.
nonisolated struct AgentAlarm: AlarmMetadata {
    var title: String
}
