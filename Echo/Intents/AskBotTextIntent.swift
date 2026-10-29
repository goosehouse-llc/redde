import AppIntents
import Foundation
import UserNotifications

/// Shortcuts action: "Ask ⟨bot⟩ ⟨question⟩", answered in the background, in the bot's own chat,
/// for automations ("When I arrive home, ask Home to warm the house"; asked 2026-10-28, after
/// Grok Bot's triggers). The answer is the action's result and, when the person isn't looking at
/// Redde, a notification that opens the bot's chat. "Ask a Redde Bot" opens the app and listens;
/// this one doesn't.
struct AskBotTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask a Redde Bot a Question"
    static let description = IntentDescription("Sends a message to one of your bots in its own chat, in the background, and returns its answer as text. For automations: when you arrive home, at a time of day, when a Focus starts.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Bot", requestValueDialog: "Which bot?")
    var bot: ReddeProfileEntity

    @Parameter(title: "Message", requestValueDialog: "What should it do?")
    var message: String

    @Parameter(title: "Notify Me", description: "Show the bot's answer as a notification from Redde.", default: true)
    var notify: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$bot) \(\.$message)") { \.$notify }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let (id, text, notify) = (bot.id, message, notify)
        let (name, answer) = try await BotTrigger.run(id, text)
        if notify { await BotTrigger.post(answer, from: name, profile: id) }
        let spoken = String(answer.prefix(600))
        return .result(value: answer, dialog: IntentDialog("\(spoken)"))
    }
}

@MainActor
enum BotTrigger {
    /// Words to the bot's model, after the person's: English, as Redde's other notes are.
    static let note = "\n\n[Redde: sent by a Shortcuts automation on the user's iPhone, not typed now; they read your answer as a notification, so keep it short.]"

    enum Problem: LocalizedError {
        case noBots, noSuchBot(String)
        var errorDescription: String? {
            switch self {
            case .noBots: String(localized: "Bots need the Hermes Dashboard, or a bot added for the Hermes API, with Bots on in Redde's Settings.")
            case let .noSuchBot(name): String(localized: "Redde has no bot called \(name) on this server.")
            }
        }
    }

    /// The bot's name and its answer.
    static func run(_ profile: String, _ text: String, note: String = note, settings: Settings = .shared,
                    departure: TurnDeparture = TurnDeparture()) async throws -> (String, String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ShortcutRunner.IntentError.emptyQuestion }
        // As "Ask Redde a Question": with App lock on, it waits for the iPhone to be unlocked.
        if AppLock.shared.isEnabled, !AppState.isProtectedDataAvailable { throw ShortcutRunner.IntentError.locked }
        guard BotDirectory.available(settings) else { throw Problem.noBots }
        var roster = BotDirectory.shared.key == settings.connectionKey ? BotDirectory.shared.roster : nil
        if roster?.named(profile) == nil { roster = try? await BotDirectory.shared.refresh() }
        guard let bot = roster?.named(profile) ?? roster?.asked(profile) else { throw Problem.noSuchBot(profile) }
        let answer = try await BotTurns.ask(bot, trimmed + note, settings: settings, departure: departure)
        let name = bot.label(mainName: settings.headerTitle)
        return (name, answer.isEmpty ? String(localized: "\(name) didn't answer.") : PlainText.spoken(answer))
    }

    /// The answer as Redde's own notification, opening the bot's chat; not when Redde is on screen.
    static func post(_ answer: String, from name: String, profile: String) async {
        guard !AppState.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = String(answer.prefix(300))
        content.threadIdentifier = "redde.trigger.\(profile)"
        content.userInfo = [PushNote.botKey: profile]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "redde.trigger.\(UUID().uuidString)",
                                                                               content: content, trigger: nil))
    }
}
