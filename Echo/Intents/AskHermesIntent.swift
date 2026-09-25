import AppIntents
import Foundation
import os

nonisolated private let intentLog = Logger(subsystem: "com.goosehouse.echo", category: "intent")

/// "Hey Siri, ask Hermes." Opens Echo into voice mode and starts listening immediately.
/// Siri is the trigger only; the audio never goes anywhere but the phone and the tailnet.
struct AskHermesIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Redde"
    static let description = IntentDescription("Opens Redde and starts listening for a question for Redde.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Hands-free",
               description: "Keep listening after each reply until you say “stop listening”.",
               default: false)
    var handsFree: Bool

    func perform() async throws -> some IntentResult {
        intentLog.info("AskHermesIntent.perform handsFree=\(handsFree)")
        await MainActor.run { LaunchRouter.shared.requestVoice(handsFree: handsFree) }
        return .result()
    }
}

/// Same intent, hands-free preset, so it can be its own Siri phrase and Action Button choice.
struct StartConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk with Redde"
    static let description = IntentDescription("Opens Redde in hands-free conversation mode.")
    static let supportedModes: IntentModes = .foreground

    func perform() async throws -> some IntentResult {
        intentLog.info("StartConversationIntent.perform")
        await MainActor.run { LaunchRouter.shared.requestVoice(handsFree: true) }
        return .result()
    }
}

struct EchoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskHermesIntent(),
            phrases: [
                // No bare "\(.applicationName)": Siri turns a lone word into a web search.
                "Hey \(.applicationName)",
                "\(.applicationName) listen",
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
                "Talk to \(.applicationName)",
                "Open \(.applicationName) and listen",
            ],
            shortTitle: "Ask Redde",
            systemImageName: "waveform.circle"
        )
        AppShortcut(
            intent: StartConversationIntent(),
            phrases: [
                "Start a conversation with \(.applicationName)",
                "Chat with \(.applicationName)",
                "\(.applicationName) hands-free",
            ],
            shortTitle: "Talk with Redde",
            systemImageName: "ear"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .blue
}
