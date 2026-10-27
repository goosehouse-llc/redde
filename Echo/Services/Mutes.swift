import Foundation

/// Muting a bot's chat or a group chat (Mute… in its row's menu in the chat list, or in the chat's
/// ••• menu): for an hour, eight hours, until tomorrow morning, or until it is turned back on. A
/// muted one doesn't notify: the plugin on the person's Hermes is told and sends nothing for it
/// (`PushService.sayMutes`, where there is a Dashboard login to tell it by), and anything that
/// comes anyway (the Hermes API's turns notify every paired phone) arrives quietly, in the list
/// only (`MutedChats`, read by the notification extension too). Its row wears a crossed-out bell
/// and no unread dot; that it is working, or waits on the person, still shows. Kept per server
/// in `Settings.mutes` by the row's id (`BotListItem.id`), so it follows a bot through Start
/// Fresh, and synced with iCloud.
nonisolated enum MuteSpan: String, CaseIterable, Identifiable, Sendable {
    case hour, eightHours, untilTomorrow, untilUnmuted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour: String(localized: "For 1 Hour", comment: "How long to mute a chat")
        case .eightHours: String(localized: "For 8 Hours", comment: "How long to mute a chat")
        case .untilTomorrow: String(localized: "Until Tomorrow", comment: "How long to mute a chat")
        case .untilUnmuted: String(localized: "Until I Turn It Back On", comment: "How long to mute a chat")
        }
    }

    /// Until when, from `now`: tomorrow is eight in the morning.
    func until(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .hour: return now.addingTimeInterval(3600)
        case .eightHours: return now.addingTimeInterval(8 * 3600)
        case .untilTomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86400)
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        case .untilUnmuted: return .distantFuture
        }
    }
}

@MainActor
enum Mutes {
    /// Until when the row (`BotListItem.id`) is muted, or nil when it isn't now.
    static func until(_ item: String, settings: Settings = .shared, now: Date = .now) -> Date? {
        settings.mutesHere[item].flatMap { $0 > now ? $0 : nil }
    }

    static func isMuted(_ item: String, settings: Settings = .shared, now: Date = .now) -> Bool {
        until(item, settings: settings, now: now) != nil
    }

    static func isMuted(bot profile: String, settings: Settings = .shared) -> Bool { isMuted("bot:" + profile, settings: settings) }
    static func isMuted(room: String, settings: Settings = .shared) -> Bool { isMuted("room:" + room, settings: settings) }

    static func mute(_ item: String, for span: MuteSpan, settings: Settings = .shared, now: Date = .now) {
        var here = settings.mutesHere.filter { $0.value > now }   // (the ones run out go)
        here[item] = span.until(from: now)
        settings.mutesHere = here
        publish(settings: settings)
    }

    static func unmute(_ item: String, settings: Settings = .shared) {
        settings.mutesHere[item] = nil
        publish(settings: settings)
    }

    /// What reads "Muted until 3:40 PM", "Muted until tomorrow", or "Muted".
    static func describe(until: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if until == .distantFuture { return String(localized: "Muted") }
        if calendar.isDate(until, inSameDayAs: now) { return String(localized: "Muted until \(until.formatted(date: .omitted, time: .shortened))") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(until, inSameDayAs: tomorrow) {
            return String(localized: "Muted until tomorrow, \(until.formatted(date: .omitted, time: .shortened))")
        }
        return String(localized: "Muted until \(until.formatted(date: .abbreviated, time: .shortened))")
    }

    /// The muted rows as the notes from a Hermes name them: a bot's chats by their sessions (the
    /// one the server's roster has for it, and any this phone keeps for it, on either
    /// connection), a group chat by its room. Pure, for the tests.
    nonisolated static func keys(muted: [String: Date], now: Date, botChats: [String: String],
                                 kept: [(profile: String, session: String)]) -> [String: Date] {
        var keys: [String: Date] = [:]
        for (item, until) in muted where until > now {
            if item.hasPrefix("room:") {
                keys[MutedChats.key(room: String(item.dropFirst(5)))] = until
            } else if item.hasPrefix("bot:") {
                let profile = String(item.dropFirst(4))
                let sessions = [botChats[profile]].compactMap(\.self) + kept.filter { $0.profile == profile }.map(\.session)
                for session in sessions { keys[MutedChats.key(session: session)] = until }
                keys[MutedChats.key(bot: profile)] = until   // (its schedules' runs)
            }
        }
        return keys
    }

    /// Writes what is muted where the notification extension reads it, and tells the plugin on
    /// the Hermes the app is on. Again whenever a mute is set or lifted, the server's bots are
    /// read, or the app comes forward (a timed one may have run out meanwhile).
    static func publish(settings: Settings = .shared, store: ConversationStore = .shared) {
        let directory = BotDirectory.shared
        let botChats = Dictionary((directory.bots(for: settings.connectionKey)).compactMap { bot in bot.chatID.map { (bot.name, $0) } },
                                  uniquingKeysWith: { a, _ in a })
        let kept = store.summaries.compactMap { summary -> (profile: String, session: String)? in
            guard let bot = summary.bot, let session = summary.serverSessionID else { return nil }
            return (bot.profile, session)
        }
        let keys = keys(muted: settings.mutesHere, now: .now, botChats: botChats, kept: kept)
        MutedChats.save(keys)
        PushService.shared.sayMutes(keys, client: .shared, server: settings.connectionKey)
    }
}
