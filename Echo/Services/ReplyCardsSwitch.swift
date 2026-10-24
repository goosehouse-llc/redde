import Foundation

/// Tells Redde's Hermes plugin whether to offer the agent cards (`redde_show`): Settings → Agent
/// → Cards in replies. Said over the Dashboard when the switch changes, and again each time the
/// app comes forward (another server, or one reached for the first time, offers them until told).
/// With them on, the phone's time zone and temperature units go with it, for "what time is it"
/// and the weather where the agent names neither (plugin 1.7.0; older ones read only on or off).
/// Best effort: on the Hermes API alone it can't be said, and the plugin offers them.
@MainActor
enum ReplyCardsSwitch {
    static func publish(settings: Settings = .shared, dashboard: HermesServeClient = .shared) async {
        guard await dashboard.canUse() else { return }
        _ = try? await PushService.command(over: dashboard)(command(on: settings.replyCards))
    }

    static func command(on: Bool, zone: TimeZone = .current, units: String = ReplyCards.preferredUnits) -> String {
        on ? "cards on tz=\(zone.identifier) units=\(units)" : "cards off"
    }
}
