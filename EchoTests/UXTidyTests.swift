import Foundation
import UIKit
import Testing
@testable import Echo

/// The 2.4 tidy (asked 2026-11-05): cards at the top of the chat list the person can leave out, and
/// an agenda that says where its events came from when it isn't the calendar.
@MainActor
struct UXTidyTests {
    @Test func anAgendaFromAnEmailSaysSo() throws {
        let value = try JSONValue.parse(Data("""
        {"type": "agenda", "date": "2026-12-17", "source": "From your email",
         "events": [{"title": "Dentist", "start": "2026-12-17T09:00:00-05:00"}]}
        """.utf8))
        let card = try #require(ReplyCards.agenda(value, timeZone: TimeZone(identifier: "America/New_York")!))
        #expect(card.source == "From your email")
        #expect(card.events.count == 1)
        // One saved before there was a source still reads.
        let old = try JSONDecoder().decode(ReplyCard.Agenda.self, from: Data(#"{"events": [], "days": ["2026-12-17"]}"#.utf8))
        #expect(old.source == nil)
    }

    @Test func aCardLeftOffTheChatListComesBack() {
        let settings = Settings.shared
        let before = settings.hiddenChatListCards
        defer { settings.hiddenChatListCards = before }
        settings.hiddenChatListCards = []
        let allShown = ChatListCard.allCases.allSatisfy { $0.isShown }
        #expect(allShown)
        ChatListCard.ideas.show(false)
        ChatListCard.ideas.show(false)
        #expect(settings.hiddenChatListCards == ["ideas"], "once, however often it is turned off")
        #expect(!ChatListCard.ideas.isShown && ChatListCard.goals.isShown)
        ChatListCard.ideas.show(true)
        #expect(settings.hiddenChatListCards.isEmpty)
        #expect(Settings.syncedKeys.contains("hiddenChatListCards"), "the choice goes to the person's other devices")
    }

    @Test func theDailyJobsPageListsAllSix() {
        #expect(Set(DailyJobsView.jobs.map(\.name)).count == 6, "When You've Gone Quiet the sixth (2026-11-22)")
        // Your Day sits in the Your Agent group, after Agent itself (2026-11-15).
        let pages = SettingsPage.agentPages
        #expect(pages.firstIndex(of: .agent)! < pages.firstIndex(of: .day)!)
    }

    /// Settings' first screen (2026-11-15): every page is in one group only, Location, Email,
    /// Phone Tools and Calendars in Your Agent, General first among the app's pages.
    @Test func everySettingsPageHasOneHome() {
        let app = [SettingsPage.general, .appearance, .chatList, .writing, .voice, .notifications, .carPlay, .siri]
        let agent = SettingsPage.agentPages
        #expect(Set(app).isDisjoint(with: agent))
        #expect(Set(app + agent + [.connection]) == Set(SettingsPage.allCases))
        #expect(agent.contains(.location) && agent.contains(.email) && agent.contains(.phoneTools) && agent.contains(.calendars))
        #expect(SettingsPage.appPages.first == .general)
        #expect(!SettingsPage.appPages.contains(.carPlay) || UIDevice.current.userInterfaceIdiom == .phone, "CarPlay is an iPhone's")
    }
}
