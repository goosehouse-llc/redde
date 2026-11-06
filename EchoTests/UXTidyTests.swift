import Foundation
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

    @Test func theDailyJobsPageListsAllFive() {
        #expect(Set(DailyJobsView.jobs.map(\.name)).count == 5)
        let pages = SettingsPage.allCases
        #expect(pages.firstIndex(of: .day)! < pages.firstIndex(of: .agent)!)
    }
}
