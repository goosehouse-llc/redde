import Foundation

/// The highlights shown once after an update ("What's New in Redde 1.4"). One entry per
/// version that has something worth showing; a version without an entry shows nothing.
nonisolated enum WhatsNew {
    struct Item: Identifiable, Equatable, Sendable {
        var symbol: String
        var title: String
        var detail: String
        var id: String { title }
    }

    struct Release: Identifiable, Equatable, Sendable {
        var version: String
        var items: [Item]
        var id: String { version }
    }

    /// Newest first. Keep each to a handful of lines a person reads in ten seconds.
    static let releases: [Release] = [
        Release(version: "1.4", items: [
            Item(symbol: "server.rack", title: "More than one server",
                 detail: "Save Home, Office or any other Hermes server and switch from Settings or the row above your conversations. Each keeps its own keys, profile and model."),
            Item(symbol: "arrow.triangle.2.circlepath", title: "Everything follows",
                 detail: "Switching starts a fresh conversation, and your chats, cron jobs and Kanban board come from the server you pick."),
            Item(symbol: "key", title: "Your setup came along",
                 detail: "The server you already had is now your first one, keys and all. Give it a name in Settings → Server."),
            Item(symbol: "person.2.slash", title: "Clearer profile problems",
                 detail: "If a profile no longer exists on a server, Redde says so and takes you to pick another."),
            Item(symbol: "camera", title: "Take a photo",
                 detail: "Tap + beside the message field and choose Camera to snap a picture and send it with your message."),
            Item(symbol: "hourglass", title: "Long answers, better",
                 detail: "The live thinking keeps scrolling, each reply shows how long it took in total, and the screen stays on while you wait in voice mode."),
        ]),
        Release(version: "1.3", items: [
            Item(symbol: "person.2", title: "Hermes profiles",
                 detail: "Pick which profile Redde talks to, right under Name in Settings. Chats, projects, skills, tools, cron jobs and memory all follow it."),
            Item(symbol: "key", title: "A key for each profile",
                 detail: "On the Hermes API, each profile can have its own key, entered on the same screen. If something's wrong, Redde says how to fix it."),
            Item(symbol: "network", title: "Clearer connections",
                 detail: "Hermes Dashboard, Hermes API and OpenAI-compatible, now under Settings → Connection, with the Dashboard first."),
            Item(symbol: "checkmark.seal", title: "Fixes",
                 detail: "The Kanban column bar always shows, iPad's Chats, Cron and Kanban have room to breathe, and Settings explains locked memory files."),
        ]),
    ]

    /// The app's version, e.g. "1.4".
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// What to show after an update from `lastSeen` to `current`: the current version's entry,
    /// once. Nothing on a fresh install (`isNewInstall`) or when the version has no entry.
    static func pending(lastSeen: String?, current: String, isNewInstall: Bool) -> Release? {
        guard !isNewInstall else { return nil }
        if let lastSeen, compare(lastSeen, current) != .orderedAscending { return nil }
        return releases.first { $0.version == current }
    }

    /// Numeric, component by component: "1.10" is newer than "1.9".
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: - Seen state

    private static let seenKey = "whatsNewSeenVersion"

    static var lastSeen: String? { UserDefaults.standard.string(forKey: seenKey) }
    static func markSeen(_ version: String = currentVersion) { UserDefaults.standard.set(version, forKey: seenKey) }
}
