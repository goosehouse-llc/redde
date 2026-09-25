import Foundation

/// Switches the active Hermes server in the one safe order: tear down the old server's
/// connection and cookies while Settings still describes it, then load the new server and start
/// a fresh conversation (the open one belongs to the old server).
@MainActor
enum ServerSwitcher {
    static func switchTo(_ id: UUID, conversation: Conversation, settings: Settings = .shared) {
        guard id != settings.activeServerID else { return }
        HermesServeClient.shared.resetForServerChange()
        settings.activateServer(id)
        conversation.reset()
    }
}
