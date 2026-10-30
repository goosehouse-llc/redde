import SwiftUI

/// What the conversation in the window in front can do, for the menu bar (`ReddeCommands`).
/// `ContentView` publishes it; nil where it can't be done just now.
struct ChatCommands {
    var newConversation: () -> Void
    var newIncognito: (() -> Void)?
    var voice: () -> Void
    var focusComposer: () -> Void
    var chooseModel: () -> Void
    var find: (() -> Void)?
    var stop: (() -> Void)?
    var export: (() -> Void)?
}

extension FocusedValues {
    @Entry var chatCommands: ChatCommands?
}

/// Redde's menus: File (a new conversation, an incognito one, exporting one), Edit's Find, and
/// the Conversation menu (voice, the message field, the model, stopping a reply), with the
/// iPad's keyboard shortcuts.
struct ReddeCommands: Commands {
    @FocusedValue(\.chatCommands) private var chat

    var body: some Commands {
        SidebarCommands()
        // Redde → Settings… (⌘,): Settings is a window of its own (`ReddeMacApp`), not the Mac's
        // Settings window, whose toolbar centres its items and the back button with them.
        CommandGroup(replacing: .appSettings) { SettingsCommand() }
        CommandGroup(replacing: .newItem) {
            Button("New Conversation") { chat?.newConversation() }
                .keyboardShortcut("n")
                .disabled(chat == nil)
            Button("New Incognito Chat") { chat?.newIncognito?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(chat?.newIncognito == nil)
        }
        CommandGroup(after: .saveItem) {
            Button("Export as Markdown…") { chat?.export?() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(chat?.export == nil)
        }
        CommandGroup(before: .toolbar) {
            ZoomCommands()
            Divider()
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Conversation") { chat?.find?() }
                .keyboardShortcut("f")
                .disabled(chat?.find == nil)
        }
        CommandMenu("Conversation") {
            Button("Voice Mode") { chat?.voice() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(chat == nil)
            Button("Message Field") { chat?.focusComposer() }
                .keyboardShortcut("l")
                .disabled(chat == nil)
            Button("Choose Model…") { chat?.chooseModel() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(chat == nil)
            Divider()
            Button("Stop Reply") { chat?.stop?() }
                .keyboardShortcut(".")
                .disabled(chat?.stop == nil)
        }
    }
}

/// Redde → Settings…, opening (or bringing forward) the Settings window.
private struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") { openWindow(id: ReddeMacApp.settingsWindow) }
            .keyboardShortcut(",")
    }
}

/// View → Actual Size, Zoom In, Zoom Out: the conversation's text (`TextZoom`).
private struct ZoomCommands: View {
    @State private var zoom = TextZoom.shared

    var body: some View {
        Button("Actual Size") { zoom.actualSize() }
            .keyboardShortcut("0")
            .disabled(zoom.isActualSize)
        Button("Zoom In") { zoom.zoomIn() }
            .keyboardShortcut("=")
            .disabled(!zoom.canZoomIn)
        Button("Zoom Out") { zoom.zoomOut() }
            .keyboardShortcut("-")
            .disabled(!zoom.canZoomOut)
    }
}
