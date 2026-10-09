import Foundation

/// The highlights shown once after an update ("What's New in Redde 1.7"). One entry per
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
        Release(version: "1.7", items: [
            Item(symbol: "bell.badge", title: "Notified when Redde is closed",
                 detail: "Pair your Hermes in Settings → Voice → Notify when Redde is closed, and it tells this iPhone when a reply is ready or the agent waits for you. Approve, deny or answer from the notification. It takes a small plugin on your Hermes, which Redde installs for you over the Dashboard."),
            Item(symbol: "waveform.badge.mic", title: "Voice, your way",
                 detail: "Start speaking while Redde is answering and it stops to listen: on with headphones, and Settings → Voice → Talk over replies adds the speaker. Add stop phrases of your own there, and say “Hey Siri, ask Work in Redde” to talk to a Hermes profile."),
            Item(symbol: "gearshape.2", title: "Your server, from the phone",
                 detail: "Settings → Gateway shows what your Hermes is running, switches its MCP servers, reads its logs and restarts or updates it. Settings → Files opens its folders: look at a file, edit a text one, upload, delete. Both use the Dashboard login."),
            Item(symbol: "checklist", title: "The agent's plan, and two widgets",
                 detail: "When Hermes keeps a task list for a longer job, the reply shows it as a checklist. On the Home Screen or the Lock Screen, Needs you shows a command or a question that waits for you, and Context how full the model's context is."),
            Item(symbol: "bolt", title: "One conversation, its own way",
                 detail: "In the model menu on the Dashboard: Fast mode for models that have one, and Run commands without asking for a conversation you trust. Touch and hold a conversation in the list to move it to a project."),
            Item(symbol: "car", title: "In the car and on the wrist",
                 detail: "CarPlay has a new look: big buttons to Ask, Talk or start a New Chat, your chats on a tab of their own, and a voice card with a moving waveform, Mute and End. Apple Watch gets a list of your chats to carry one on, and Ask Redde as a complication for your watch face."),
            Item(symbol: "square.and.pencil", title: "Writing and reading",
                 detail: "Each conversation keeps its own draft. Dictate into the message field, paste a picture, attach a video, and open a long message on a page of its own. A text size for conversations in Settings → Appearance, and a ring in the header for how full the context is."),
            Item(symbol: "person.badge.key", title: "Sign in with a browser",
                 detail: "A Dashboard that signs you in with Google or another provider works now, and a server behind a reverse proxy can be sent the header it asks for. Both in Settings → Connection details."),
            Item(symbol: "checkmark.seal", title: "Fixes",
                 detail: "On Hermes 0.21.3 and later, approvals and the agent's questions reach you again over the Dashboard, a file attached there reaches the agent, and a message sent the moment a reply ends no longer comes back empty."),
        ]),
        Release(version: "1.6", items: [
            Item(symbol: "applewatch", title: "On your wrist",
                 detail: "Redde for Apple Watch: raise your wrist, tap Ask and say it. The answer is shown and read aloud. It asks through the Hermes API or your OpenAI-compatible endpoint: on the Dashboard, save the API address and key too, in Settings → Connection details."),
            Item(symbol: "qrcode.viewfinder", title: "Set up by code",
                 detail: "Scan a setup code and a server fills itself in. Settings → Connection → Set up another device shows the code for your iPad or a second phone."),
            Item(symbol: "lock.iphone", title: "A reply keeps going",
                 detail: "Lock the phone or switch apps, and the reply you asked for carries on to the end."),
            Item(symbol: "sparkles", title: "A place to start",
                 detail: "A new conversation opens with what's next on your calendar and the conversation you just left, one tap each."),
            Item(symbol: "quote.bubble", title: "Ask about part of a reply",
                 detail: "Choose Select text on a reply, select a sentence and tap Ask about this. It lands in your message as a quote."),
            Item(symbol: "bolt", title: "Long conversations, lighter",
                 detail: "A long thread takes a fraction of the memory it did and stays smooth while a reply streams."),
        ]),
        Release(version: "1.5", items: [
            Item(symbol: "text.insert", title: "Spoken prefixes",
                 detail: "Start a spoken message with a word of your choice and Redde swaps it for a text prefix, switches the conversation to a model you pick, or both. Off until you add one, in Settings → Voice. Typed messages are never changed."),
            Item(symbol: "gauge.with.dots.needle.33percent", title: "Reasoning effort, everywhere",
                 detail: "The level in Settings → Model now reaches whatever model you talk to, and the conversation you have open, not only new ones. Type /reasoning in a Hermes Dashboard chat to change just that one."),
            Item(symbol: "brain", title: "None",
                 detail: "A new level that asks the model to skip thinking and answer straight away. Some models and servers decide that for themselves."),
            Item(symbol: "airpods", title: "Replies stay in your AirPods",
                 detail: "A question asked through AirPods sometimes got its answer from the phone's speaker. Not any more."),
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
