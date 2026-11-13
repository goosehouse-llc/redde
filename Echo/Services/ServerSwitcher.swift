import Foundation

/// Switches the active Hermes server in the one safe order: while Settings still describes the
/// old server, save its open conversation (stamped with that server) and tear down its connection
/// and cookies; then load the new server.
@MainActor
enum ServerSwitcher {
    /// A connection picked for the server in use (Setup, Settings › Connection). Another kind of
    /// connection, Hermes or an agent over ACP, on a server that is already set up becomes a new
    /// server, which Redde switches to: the one in use keeps its addresses and sign-ins
    /// (2026-11-12: setting up Claude Code turned his Hermes server into it, and the Dashboard
    /// seemed to have lost its sign-in). An unused server changes in place, and so does the
    /// OpenAI-compatible connection, which is no server's. True when a server was added.
    @discardableResult
    static func choose(_ transport: Transport, conversation: Conversation?, settings: Settings = .shared) -> Bool {
        let own = settings.activeServer?.transport ?? settings.transport
        guard transport != settings.transport else { return false }
        guard let conversation, transport != .chatCompletions, own.kind != transport.kind, !settings.activeServerIsUnused else {
            settings.transport = transport
            return false
        }
        let id = settings.addServer(name: "")
        switchTo(id, conversation: conversation, settings: settings)
        guard settings.activeServerID == id else {
            settings.removeServer(id)
            return false
        }
        settings.transport = transport
        return true
    }

    static func switchTo(_ id: UUID, conversation: Conversation, settings: Settings = .shared) {
        guard id != settings.activeServerID else { return }
        conversation.reset()   // saves the open conversation as the old server's, then starts fresh
        HermesServeClient.shared.resetForServerChange()
        settings.activateServer(id)
        #if os(iOS)
        WatchLink.shared.push()
        #endif
        EchoShortcuts.updateAppShortcutParameters()   // Siri's profile phrases are this server's profiles now
    }
}
