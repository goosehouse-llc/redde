#if DEBUG
import Foundation

/// The agents video for Reddit (design/video, `make_agents.py`): `-echo.demoAgents [profile]`, with
/// `-echo.demoProjects -echo.demoBots -displayName Sol`. The sample bots (Sol, Scout, Quill, Fix-it)
/// each have a chat of their own that opens from the drawer's Team row, and the answers in them are
/// canned (`DemoAgentsTransport`: nothing goes to a server): a hike found, Scout asked with an @
/// (it answers in Sol's chat, under its face), and the invite handed to Quill (`message_agent`),
/// whose progress under Sol's reply is played (`HandoffWatch`) until Quill has answered, the invite
/// then in Quill's chat. `profile` is the chat open at launch ("default", Sol's, if none is named).
/// With `-echo.spareAgent NAME`, Redde's demo agent is saved as a server beside it, so the
/// server menu switches to a coding agent and back; on that server everything is the demo agent's
/// own. Everything here is made up.
@MainActor
enum DemoAgents {
    static var on: Bool { DevHooks.has("-echo.demoAgents") }

    /// The chat open at launch.
    static var opening: String {
        let named = DevHooks.value("-echo.demoAgents") ?? ""
        return ["default", "scout", "writer", "fixit"].contains(named) ? named : "default"
    }

    /// The drawer's hello: morning, whatever the Mac's clock says.
    static let clock: Date = Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: .now) ?? .now
    private static let launched = Date.now

    /// A time from while the video is filmed (the hour after launch), as if it were 9:41 then; nil
    /// for any other (the sample chats' own times).
    static func shown(_ date: Date) -> Date? {
        let since = date.timeIntervalSince(launched)
        return (-60 ..< 3_600).contains(since) ? clock.addingTimeInterval(max(0, since)) : nil
    }

    /// Each bot's chat as it was left in this launch, by profile.
    private static var kept: [String: [Message]] = [:]
    /// Quill has written the invite (the hand-off played to its end).
    static var invited = false
    private static var played: Set<String> = []

    static func applyAtLaunch(conversation: Conversation, settings: Settings) {
        guard on else { return }
        if let i = settings.servers.firstIndex(where: { $0.id == settings.activeServerID }), settings.servers[i].name.isEmpty {
            settings.servers[i].name = "Home"
        }
        let bots = ConversationsList.demoBots
        let main = settings.headerTitle
        guard let bot = bots.bots.first(where: { $0.name == opening }) else { return }
        show(bot, in: conversation, mainName: main)
    }

    /// A bot's chat, opened from the Team row (`Conversation.openBot`): the one open is kept as it
    /// is, and the bot's comes back as it was left, or as it starts.
    static func show(_ bot: HermesBot, in conversation: Conversation, mainName: String) {
        // (Only the video's own chats: at launch it is whatever the app opened.)
        if conversation.id.uuidString.hasPrefix("DE5A0000") { kept[conversation.bot?.profile ?? "default"] = conversation.messages }
        conversation.reset()
        let n = ["default": 1, "scout": 2, "writer": 3, "fixit": 4][bot.name] ?? 9
        var messages = kept[bot.name] ?? start(of: bot.name, mainName: mainName)
        if bot.name == "writer", invited, !messages.contains(where: { $0.text.contains("Falls Loop, Saturday") }) {
            messages += invite(mainName: mainName)
        }
        conversation.replaceForDemo(id: UUID(uuidString: "DE5A0000-0000-4000-8000-00000000000\(n)")!, createdAt: .now.addingTimeInterval(-3_600),
                                    messages: messages,
                                    bot: bot.isDefault ? nil : BotRef(profile: bot.name, name: bot.label(mainName: mainName)))
    }

    private static func start(of profile: String, mainName: String) -> [Message] {
        func said(_ text: String) -> Message { Message(role: .user, text: text) }
        func answer(_ text: String) -> Message { Message(role: .assistant, text: text) }
        switch profile {
        case "scout":
            return [said("Any good trails near us?"),
                    answer("Three under two hours from you, all open: **Falls Loop**, **Gold Creek** and **Ridge Walk**. 🌲 Falls Loop has the waterfall.")]
        case "writer":
            return [said("Can you tighten the opening of the hike post?"),
                    answer("""
                        Here's a tighter opening:

                        > We left the car at six, before the fog had made up its mind.

                        It drops the weather report and starts on the trail.
                        """)]
        case "fixit":
            return [said("Is the home server OK?"),
                    answer("All good 🛠️ Disks at 41%, last night's backup ran at 3 AM, and one update is waiting for your OK.")]
        default:
            return [said("Remind me to call the vet at 4."), answer("Done: the reminder is set for 4 pm. ⏰")]
        }
    }

    /// Sol's message in Quill's chat, and Quill's invite.
    private static func invite(mainName: String) -> [Message] {
        var asked = Message(role: .user, text: "Write a short invite for the Falls Loop hike, Saturday at 8. Keep it friendly.")
        asked.delivered = Delivered(kind: .message, profile: "default", name: mainName)
        return [asked, Message(role: .assistant, text: """
            Here's the invite:

            **Falls Loop, Saturday at 8** 🥾
            Five easy miles to the waterfall and back. Bring layers and water. Coffee's on me after! ☕️
            """)]
    }

    // MARK: The hand-off

    /// Quill at work on the invite, as `HandoffWatch` would read it from Quill's chat: asked, a
    /// look at its memory, writing, answered. Played once, from when its row shows.
    static func playHandoff(_ profile: String, set: @escaping @MainActor (Handoff.Progress?) -> Void) {
        guard played.insert(profile).inserted else { return }
        let from = Settings.shared.headerTitle
        let asked = Date.now
        Task { @MainActor in
            let steps: [(Double, Handoff.Progress.Phase, String?, Int)] = [
                (1.0, .working, nil, 0), (2.2, .working, "memory", 1), (3.6, .working, "write_file", 2), (6.0, .answered, nil, 2),
            ]
            var at = 0.0
            for (when, phase, tool, count) in steps {
                try? await Task.sleep(for: .seconds(when - at))
                at = when
                if phase == .answered { invited = true }
                set(Handoff.Progress(phase: phase, from: from, step: tool.map(Handoff.step), steps: count, asked: asked, lastActive: .now))
            }
        }
    }
}

/// The video's canned answers: Sol's to a chat, a bot's to an @ (`bot`).
nonisolated struct DemoAgentsTransport: HermesTransport {
    var bot: String?

    typealias Tool = (name: String, preview: String, args: String?)

    static func reply(to asked: String, bot: String?) -> ([Tool], String) {
        if bot == "scout" { return ([], "Open! 🥾 It's muddy past the second footbridge, so boots, not sneakers.") }
        if bot != nil { return ([], "On it!") }
        // The coding agents' cut: what's left, and Quill's notes on the fix.
        if asked.contains("release notes") {
            return ([], """
                Here are the notes:

                **What's new**
                • Fixed: signing in no longer fails when your session runs out. You just stay signed in.

                Want a shorter version for the App Store? ✍️
                """)
        }
        if asked.contains("release") {
            return ([("session_search", "release", nil)], "Two things before the release: **the login bug** 🐞 and **the release notes** 📝.")
        }
        if asked.contains("invite") {
            return ([("message_agent", "@quill", "message: Write a short invite for the Falls Loop hike, Saturday at 8. Keep it friendly.\ntarget: quill")],
                    "Quill's on the invite ✍️ It'll be in Quill's chat in a minute.")
        }
        if asked.contains("hike") {
            return ([("web_search", "hikes near me under 3 hours", nil)],
                    "**Falls Loop** is the one: 5 miles, about 2½ hours, with a waterfall halfway round. 🌲 Want Scout to check the trail?")
        }
        return ([], "On it!")
    }

    func stream(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        let (tools, answer) = Self.reply(to: request.userText.lowercased(), bot: bot)
        return AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .seconds(0.9))
                for tool in tools {
                    continuation.yield(.toolStarted(name: tool.name, preview: tool.preview, args: tool.args))
                    try? await Task.sleep(for: .milliseconds(900))
                    continuation.yield(.toolFinished(name: tool.name, failed: false, output: nil))
                    try? await Task.sleep(for: .milliseconds(200))
                }
                var rest = Substring(answer)
                while !rest.isEmpty, !Task.isCancelled {
                    let end = rest.firstIndex(of: " ").map { rest.index(after: $0) } ?? rest.endIndex
                    continuation.yield(.textDelta(String(rest[..<end])))
                    rest = rest[end...]
                    try? await Task.sleep(for: .milliseconds(75))
                }
                continuation.yield(.textFinal(answer))
                continuation.yield(.done)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
