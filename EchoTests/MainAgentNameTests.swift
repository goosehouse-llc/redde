import CryptoKit
import Foundation
import Testing
import UIKit
import UserNotifications
@testable import Echo

/// A notification from the main agent says the name the person gave it (2026-11-23).
struct MainAgentNameTests {
    private func note(_ json: String) throws -> PushNote {
        try JSONDecoder().decode(PushNote.self, from: Data(json.utf8))
    }

    @Test func aRemindersNotificationSaysTheAgentsName() throws {
        let reminder = try note(#"{"v": 1, "k": "routine", "p": "default", "d": "Hermes", "t": "water the plants", "b": "Reminder: water the plants."}"#)
        let content = UNMutableNotificationContent()
        #expect(reminder.namingMainAgent("Sol").fill(content))
        #expect(content.subtitle == "Sol")
        #expect(content.title == "water the plants")
    }

    @Test func anIdeasNotificationSaysItToo() throws {
        let ideas = try note(#"{"v": 1, "k": "ideas", "p": "default", "d": "Hermes", "i": "offer", "y": [{"t": "One"}, {"t": "Two"}]}"#)
        #expect(ideas.namingMainAgent("Sol").d == "Sol")
    }

    @Test func onlyTheMainAgentsPlainNameIsReplaced() throws {
        let bot = try note(#"{"v": 1, "k": "routine", "p": "lookout", "d": "Hermes"}"#)
        let titled = try note(#"{"v": 1, "k": "routine", "p": "default", "d": "Atlas"}"#)
        let approval = try note(#"{"v": 1, "k": "approval", "p": "default", "d": "Hermes"}"#)
        let unnamed = try note(#"{"v": 1, "k": "routine", "p": "default", "d": "Hermes"}"#)
        #expect(bot.namingMainAgent("Sol").d == "Hermes", "another profile's")
        #expect(titled.namingMainAgent("Sol").d == "Atlas", "a title on the server")
        #expect(approval.namingMainAgent("Sol").d == "Hermes", "there d is why it stopped")
        #expect(unnamed.namingMainAgent(nil).d == "Hermes" && unnamed.namingMainAgent("").d == "Hermes", "no name given")
    }

    @Test func theNameIsKeptForTheExtension() throws {
        let suite = "MainAgentNameTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        MainAgentName.save("  Sol ", in: defaults)
        #expect(MainAgentName.read(in: defaults) == "Sol")
        MainAgentName.save("", in: defaults)
        #expect(MainAgentName.read(in: defaults) == nil)
    }
}
