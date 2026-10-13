import AppIntents
import Foundation

/// Quick capture by Siri or from Shortcuts: "Take a note in Redde", Siri asks for the note, and
/// Redde keeps it to file with Hermes. Runs without opening the app, so it works from the Lock
/// Screen, AirPods and the car. What comes back is "Noted", not a reply: see `CaptureInbox`.
struct CaptureNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Take a Note in Redde"
    static let description = IntentDescription("Hands a note to Redde to file. Nothing is sent back.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Note", requestValueDialog: "What's the note?")
    var note: String

    static var parameterSummary: some ParameterSummary {
        Summary("Note to Redde: \(\.$note)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await CaptureInbox.shared.add(note) else { throw ShortcutRunner.IntentError.emptyQuestion }
        // A run like this ends when it returns, and the system gives it about half a minute: the
        // note is handed over inside that if the server answers, and waits for the app if not.
        await CaptureInbox.shared.settle(within: .seconds(20))
        return .result(dialog: "Noted.")
    }
}
