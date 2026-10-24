import Foundation
import Testing
@testable import Echo

/// GitHub issue 32: the bots and the projects above the conversations can each be taken out of
/// the chat list, from Settings → Appearance. Both show until turned off, and the choice goes to
/// the person's other devices.
@MainActor
struct ChatListSectionsTests {
    @Test func bothShowUntilTurnedOffAndTheChoiceSyncs() {
        let defaults = UserDefaults(suiteName: "chat-list-\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        #expect(settings.showBots && settings.projectsInChatList)
        settings.projectsInChatList = false
        #expect(Settings(defaults: defaults).projectsInChatList == false, "kept")
        #expect(Settings.syncedKeys.contains("showBots") && Settings.syncedKeys.contains("projectsInChatList"))
        settings.applySynced("projectsInChatList", true)
        #expect(settings.projectsInChatList, "turned on again from another device")
    }
}
