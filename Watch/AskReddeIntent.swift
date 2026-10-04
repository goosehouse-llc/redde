import AppIntents

/// The Action button's way in (Settings › Action Button › Shortcut › Ask Redde), and a Siri
/// phrase: opens the watch app and starts dictation at once, as the Ask button does. The watch
/// has no API for the button itself; it runs a shortcut, and an App Shortcut is one.
struct AskReddeIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Redde"
    static let description = IntentDescription("Opens Redde on your watch and listens for a question.")
    static let supportedModes: IntentModes = .foreground

    func perform() async throws -> some IntentResult {
        await MainActor.run { WatchStore.shared.requestDictation() }
        return .result()
    }
}

struct EchoWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskReddeIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
                "Hey \(.applicationName)",
            ],
            shortTitle: "Ask Redde",
            systemImageName: "waveform.circle"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .blue
}
