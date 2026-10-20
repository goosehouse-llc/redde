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
        // Quick capture: Siri asks for the note and Redde keeps it to file; the app stays shut.
        AppShortcut(
            intent: CaptureNoteIntent(),
            phrases: [
                "Take a note in \(.applicationName)",
                "Take a note with \(.applicationName)",
                "Note to \(.applicationName)",
                "Add a note to \(.applicationName)",
            ],
            shortTitle: "Take a Note",
            systemImageName: "square.and.pencil"
        )
        // One phrase per bot or profile the phone knows of (`ProfileCatalog`), by the name it was
        // given as a bot: "Ask Claude in Redde" talks to Claude in its own chat.
        AppShortcut(
            intent: AskProfileIntent(),
            phrases: [
                "Ask \(\.$profile) in \(.applicationName)",
                "Talk to \(\.$profile) in \(.applicationName)",
                "Open \(.applicationName) on \(\.$profile)",
            ],
            shortTitle: "Ask a Bot",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .blue
}
