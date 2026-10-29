import Foundation

/// How much each agent may do for the person unasked (asked 2026-10-28, "Proactive", after Muse's
/// adjustable threshold): ask first, do the small easy-to-undo things, or act and say after. Kept
/// on the phone and told to Redde's plugin over the Dashboard (`/redde-push autonomy`), which words
/// the agent's note before an errand by it (`cards.py`). Hermes's own approvals for commands are
/// not touched: this is about the person's errands, a message sent or a table booked.
@MainActor
enum AgentAutonomy {
    enum Level: String, CaseIterable, Identifiable {
        case ask, routine, act
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ask: String(localized: "Ask Me First")
            case .routine: String(localized: "Small Things Are Fine")
            case .act: String(localized: "Act, Tell Me After")
            }
        }
        var detail: String {
            switch self {
            case .ask: String(localized: "Shows you what it will do, as a card to approve, before anything is sent, booked, bought or changed.")
            case .routine: String(localized: "Does small things that are easy to undo (a reminder, a light, a list) and tells you; asks before sending, paying, booking or deleting.")
            case .act: String(localized: "Does what you ask and tells you exactly what it did; asks only before paying or deleting.")
            }
        }
    }

    private static let key = "agentAutonomy"

    static func level(_ profile: String, defaults: UserDefaults = .standard) -> Level {
        (defaults.dictionary(forKey: key)?[profile] as? String).flatMap(Level.init) ?? .ask
    }

    static func set(_ profile: String, _ level: Level, defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        all[profile] = level.rawValue
        defaults.set(all, forKey: key)
        Task { await publish(defaults: defaults) }
    }

    /// What the plugin is told: every agent's level that isn't the default.
    static func command(defaults: UserDefaults = .standard) -> String? {
        let all = (defaults.dictionary(forKey: key) as? [String: String] ?? [:]).filter { Level(rawValue: $0.value) != nil }
        guard !all.isEmpty else { return nil }
        return "autonomy " + all.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    /// Said when a level changes and each time Redde comes forward (another server hears it too).
    static func publish(defaults: UserDefaults = .standard, dashboard: HermesServeClient = .shared) async {
        guard let command = command(defaults: defaults), await dashboard.canUse() else { return }
        _ = try? await PushService.command(over: dashboard)(command)
    }
}
