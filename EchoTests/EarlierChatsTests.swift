import Foundation
import Testing
@testable import Echo

/// A bot's earlier chats (asked 2026-10-29): which archived sessions are its, and the ones put aside
/// over the Hermes API, remembered on the phone.
@MainActor
struct EarlierChatsTests {
    private func row(_ id: String, title: String?, hidden: Bool? = true, archived: Bool? = true, last: Double = 0) -> HermesSessionsAPI.SessionSummary {
        var row = HermesSessionsAPI.SessionSummary(id: id)
        row.title = title
        row.hidden = hidden
        row.archived = archived
        row.last_active = last
        return row
    }

    @Test func aBotsArchivedChatsAreItsEarlierOnesNewestFirst() {
        let picked = EarlierBotChats.pick([
            row("titled", title: "Bot Chat", last: 100),
            row("untitled", title: nil, last: 300),       // a new chat took the title from it
            row("blank", title: " ", last: 200),
            row("room", title: "dde-1f697fc4"),            // a group room's session
            row("other", title: "Friendly greeting #58"),
            row("shown", title: nil, hidden: false),       // an ordinary chat, archived by hand
            row("live", title: "Bot Chat", archived: false),
            row("incognito", title: nil),
        ], incognito: ["incognito"])
        #expect(picked.map(\.id) == ["untitled", "blank", "titled"])
    }

    @Test func aRowThatDoesntSayHiddenStillCounts() {
        #expect(EarlierBotChats.pick([row("old", title: nil, hidden: nil, archived: nil)]).map(\.id) == ["old"])
    }

    @Test func chatsPutAsideAreRememberedPerServerAndProfile() throws {
        let defaults = try #require(UserDefaults(suiteName: "earlier-\(UUID().uuidString)"))
        EarlierBotChats.remember("a", profile: "ops", server: "s1", defaults: defaults)
        EarlierBotChats.remember("b", profile: "ops", server: "s1", defaults: defaults)
        EarlierBotChats.remember("a", profile: "ops", server: "s1", defaults: defaults)
        EarlierBotChats.remember("c", profile: "ops", server: "s2", defaults: defaults)
        #expect(EarlierBotChats.remembered(profile: "ops", server: "s1", defaults: defaults) == ["a", "b"], "newest first, once each")
        #expect(EarlierBotChats.remembered(profile: "ops", server: "s2", defaults: defaults) == ["c"])
        #expect(EarlierBotChats.remembered(profile: "research", server: "s1", defaults: defaults).isEmpty)
        EarlierBotChats.forget("a", profile: "ops", server: "s1", defaults: defaults)
        #expect(EarlierBotChats.remembered(profile: "ops", server: "s1", defaults: defaults) == ["b"])
    }

    @Test func flagsSentAsNumbersOrLeftOutStillRead() throws {
        // The Dashboard's list of every profile sends SQLite's 0/1 for hidden (lab, 2026-10-29).
        let json = #"{"sessions": [{"id": "a", "hidden": 0, "archived": false}, {"id": "b", "hidden": 1}, {"id": "c"}]}"#
        struct Page: Decodable { var sessions: [HermesSessionsAPI.SessionSummary] }
        let rows = try JSONDecoder().decode(Page.self, from: Data(json.utf8)).sessions
        #expect(rows.map(\.hidden) == [false, true, nil])
        #expect(rows.map(\.archived) == [false, nil, nil])
    }

    @Test func aListedSessionSaysWhetherItIsArchivedAndHidden() throws {
        let json = #"{"id": "x", "title": null, "archived": true, "hidden": true, "message_count": 12}"#
        let decoded = try JSONDecoder().decode(HermesSessionsAPI.SessionSummary.self, from: Data(json.utf8))
        #expect(decoded.archived == true && decoded.hidden == true && decoded.message_count == 12)
    }
}
