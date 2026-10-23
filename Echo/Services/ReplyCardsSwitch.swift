import Foundation

/// Tells Redde's Hermes plugin whether to offer the agent cards (`redde_show`): Settings → Agent
/// → Cards in replies. Said over the Dashboard when the switch changes, and again when the app
/// comes forward while it is off (another server, or one reached for the first time, offers them
/// until told). Best effort: on the Hermes API alone it can't be said, and the plugin offers them.
@MainActor
enum ReplyCardsSwitch {
    static func publish(settings: Settings = .shared, dashboard: HermesServeClient = .shared) async {
        guard await dashboard.canUse() else { return }
        _ = try? await PushService.command(over: dashboard)("cards " + (settings.replyCards ? "on" : "off"))
    }
}
