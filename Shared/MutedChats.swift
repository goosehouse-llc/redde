import Foundation
import UserNotifications

/// What is muted now (a bot's chat, a group chat: Mute… in the chat list or the chat's menu), as
/// the notes from a paired Hermes name it: a session ("s:<id>", a bot's chat) or a room
/// ("g:<id>"), each until when. The app writes it (`Mutes.publish`) where the notification
/// extension can read it too, which delivers a muted chat's notification quietly: no sound, no
/// banner, in the list only. (Hiding one outright needs an entitlement Apple hands out rarely.)
/// The plugin is told the same, where it can be, and sends nothing for them at all.
nonisolated enum MutedChats {
    private static let key = "mutedChats"

    static func key(session: String) -> String { "s:" + session }
    static func key(room: String) -> String { "g:" + room }

    /// Every muted key and until when (`Date.distantFuture`: until it is turned back on).
    static func load(_ defaults: UserDefaults? = NeedsYou.shared) -> [String: Date] {
        guard let data = defaults?.data(forKey: key), let saved = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return saved
    }

    static func save(_ muted: [String: Date], _ defaults: UserDefaults? = NeedsYou.shared) {
        if muted.isEmpty { defaults?.removeObject(forKey: key) } else { defaults?.set(try? JSONEncoder().encode(muted), forKey: key) }
    }

    /// The chat a note is about is muted now.
    static func isMuted(session: String?, room: String?, now: Date = .now, in defaults: UserDefaults? = NeedsYou.shared) -> Bool {
        let muted = load(defaults)
        let keys = [session.flatMap { $0.isEmpty ? nil : key(session: $0) }, room.flatMap { $0.isEmpty ? nil : key(room: $0) }]
        return keys.compactMap(\.self).contains { (muted[$0] ?? .distantPast) > now }
    }

    /// A muted chat's notification, delivered quietly: no sound, nothing lit or shown over what is
    /// on screen, kept in the list.
    static func quiet(_ content: UNMutableNotificationContent) {
        content.sound = nil
        content.interruptionLevel = .passive
        content.relevanceScore = 0
    }
}
