import Foundation

/// The highlights shown once after an update ("What's New in Redde 1.5"). One entry per
/// version that has something worth showing; a version without an entry shows nothing.
nonisolated enum WhatsNew {
    struct Item: Identifiable, Equatable, Sendable {
        var symbol: String
        var title: String
        var detail: String
        /// Only on iPhone: an iPad has no such thing (its list is a sidebar).
        var phoneOnly = false
        /// Only on iPad.
        var padOnly = false
        var id: String { title }
    }

    struct Release: Identifiable, Equatable, Sendable {
        var version: String
        var items: [Item]
        var id: String { version }
    }

    /// Newest first. Keep each to a handful of lines a person reads in ten seconds.
    static let releases: [Release] = [
        Release(version: "1.5", items: [
            Item(symbol: "gauge.with.dots.needle.33percent", title: "Reasoning effort, everywhere",
                 detail: "The level in Settings → Model now reaches whatever model you talk to, and the conversation you have open, not only new ones. Type /reasoning in a Hermes Dashboard chat to change just that one."),
            Item(symbol: "brain", title: "None",
                 detail: "A new level that asks the model to skip thinking and answer straight away. Some models and servers decide that for themselves."),
            Item(symbol: "airpods", title: "Replies stay in your AirPods",
                 detail: "A question asked through AirPods sometimes got its answer from the phone's speaker. Not any more."),
            Item(symbol: "text.insert", title: "Spoken prefixes",
                 detail: "Start a spoken message with a word of your choice and Redde swaps it for a text prefix, switches the conversation to a model you pick, or both. Off until you add one, in Settings → Voice. Typed messages are never changed."),
        ]),
        Release(version: "1.4", items: [
            Item(symbol: "server.rack", title: "More than one server",
                 detail: "Save Home, Office or any other Hermes server and switch from Settings or the row above your conversations. Chats, cron jobs and Kanban follow the server you pick, and your setup is already the first one."),
            Item(symbol: "globe", title: "Your language",
                 detail: "Pick a Reply language and the language Redde listens for in Settings → Voice. Each reply is read by a voice for the language it's written in."),
            Item(symbol: "hand.draw", title: "Swipe to your conversations",
                 detail: "Swipe right on a chat and your conversation list slides in from the left. Tap the chat or drag it back to close.",
                 phoneOnly: true),
            Item(symbol: "rectangle.split.3x1", title: "Room for your board",
                 detail: "Pick Kanban or Cron in the sidebar and it fills the screen beside it. Redde reopens where you left off.",
                 padOnly: true),
            Item(symbol: "arrow.up.forward.app", title: "Choose where Redde opens",
                 detail: "Your last conversation, the conversation list or voice mode, in Settings → Voice. Voice mode can also start a new conversation every time."),
            Item(symbol: "camera", title: "Take a photo",
                 detail: "Tap + beside the message field and choose Camera to snap a picture and send it with your message."),
            Item(symbol: "gauge.with.dots.needle.100percent", title: "More thinking",
                 detail: "Reasoning effort now goes past High to X-High and Max, for frontier models like Claude and GPT. Find it in Settings → Model."),
            Item(symbol: "speaker.wave.2", title: "Louder replies",
                 detail: "Spoken replies play at full volume on the speaker, follow the volume buttons, and move to the earpiece when you raise the phone to your ear."),
            Item(symbol: "hourglass", title: "Long answers, better",
                 detail: "The live thinking keeps scrolling, each reply shows how long it took, and replies from your own model can take as long as they need."),
            Item(symbol: "heart", title: "Feed the goose",
                 detail: "Settings → About → Support Redde: leave a tip, a coffee, a snack or a dinner. It unlocks nothing; it keeps Redde going."),
            Item(symbol: "checkmark.seal", title: "Fixes",
                 detail: "Chats opened over the Hermes API load again, Redde says so when a profile is gone from a server, and Kokoro keeps talking when you switch to headphones."),
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
        // The newest entry not seen yet, up to this version: a point release without its own
        // entry (1.4) still shows 1.4's to someone coming from 1.3, and nothing to someone on 1.4.
        return releases.first { release in
            compare(release.version, current) != .orderedDescending
                && lastSeen.map { compare(release.version, $0) == .orderedDescending } ?? true
        }
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
