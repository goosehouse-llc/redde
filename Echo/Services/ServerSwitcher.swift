import Foundation

/// Switches the active Hermes server in the one safe order: while Settings still describes the
/// old server, save its open conversation (stamped with that server) and tear down its connection
/// and cookies; then load the new server.
@MainActor
enum ServerSwitcher {
    static func switchTo(_ id: UUID, conversation: Conversation, settings: Settings = .shared) {
        guard id != settings.activeServerID else { return }
        conversation.reset()   // saves the open conversation as the old server's, then starts fresh
        HermesServeClient.shared.resetForServerChange()
        settings.activateServer(id)
        WatchLink.shared.push()
        EchoShortcuts.updateAppShortcutParameters()   // Siri's profile phrases are this server's profiles now
    }
}
