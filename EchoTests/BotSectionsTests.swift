import Foundation
import Testing
@testable import Echo

/// Sections of the Bots (asked 2026-11-05, after Hermes Desktop's): who is in which, taken in from
/// the bots, and where a membership is kept.
struct BotSectionsTests {
    private func bot(_ name: String, section: String? = nil, named: String? = nil, setUp: Bool = true, viaAPI: Bool = false) -> HermesBot {
        var bot = HermesBot(name: name, isDefault: name == "default", isSetUp: setUp)
        bot.sectionID = section
        bot.sectionName = named
        bot.viaAPI = viaAPI
        return bot
    }

    private func room(_ id: String) -> GroupRoom {
        GroupRoom(try! JSONValue.parse(Data(#"{"room_id": "\#(id)", "name": "Family"}"#.utf8)))!
    }

    @Test func aBotsRowCarriesItsSection() throws {
        let row = try JSONValue.parse(Data(#"{"name": "scout", "ui_meta": {"hermes-bots": {"title": "Scout", "sectionId": "sec-1", "sectionName": "Clients"}}}"#.utf8))
        let bot = try #require(HermesBot(row))
        #expect(bot.sectionID == "sec-1" && bot.sectionName == "Clients" && bot.title == "Scout")
        let bare = try #require(HermesBot(try JSONValue.parse(Data(#"{"name": "ops", "ui_meta": {"hermes-bots": {"sectionId": ""}}}"#.utf8))))
        #expect(bare.sectionID == nil)
    }

    @Test func eachSectionInOrderThenTheRestEveryItemOnce() {
        let clients = BotSection(id: "a", name: "Clients"), home = BotSection(id: "b", name: "Home")
        let here = BotSectionsHere(sections: [clients, home], kept: ["room:r1": "b", "bot:api": "a"])
        let items: [BotListItem] = [.bot(bot("default")), .bot(bot("scout", section: "a")), .bot(bot("gone", section: "deleted")),
                                    .bot(bot("api", viaAPI: true)), .room(room("r1"))]
        let blocks = BotSectioning.blocks(items, in: here)
        #expect(blocks.map(\.key) == ["a", "b", "loose"])
        #expect(blocks[0].items.map(\.id) == ["bot:scout", "bot:api"])
        #expect(blocks[1].items.map(\.id) == ["room:r1"])
        #expect(blocks[2].items.map(\.id) == ["bot:default", "bot:gone"], "a section no longer listed is none")
        #expect(blocks.flatMap(\.items).count == items.count)
        // An empty one still shows, so a new section is there to file into.
        #expect(BotSectioning.blocks([], in: BotSectionsHere(sections: [clients])).map(\.key) == ["a", "loose"])
    }

    @Test func sectionsMadeElsewhereAreTakenInAndRenamedWhenTheBotsAgree() {
        let here = BotSectionsHere(sections: [BotSection(id: "a", name: "Clients")])
        let bots = [bot("x", section: "a", named: "Customers"), bot("y", section: "a", named: "Customers"),
                    bot("z", section: "c", named: "Lab"), bot("w", section: "d"), bot("v", section: "e", named: "Going")]
        let next = BotSectioning.adopted(here, bots: bots, deleting: ["e"])
        #expect(next.sections == [BotSection(id: "a", name: "Customers"), BotSection(id: "c", name: "Lab")],
                "a nameless one can't be drawn; one being deleted isn't brought back")
        // Mid-rename (the bots disagree), the name here stays.
        let split = BotSectioning.adopted(here, bots: [bot("x", section: "a", named: "One"), bot("y", section: "a", named: "Two")])
        #expect(split.sections == here.sections)
    }

    @Test func aMembershipGoesOnTheBotOnlyWhereBotsAreSetUp() {
        let setUp = BotRoster(bots: [bot("default", setUp: true), bot("scout", setUp: false)])
        let none = BotRoster(bots: [bot("default", setUp: false), bot("scout", setUp: false)])
        #expect(BotSectioning.onServer(bot("scout", setUp: false), roster: setUp), "messaging is on already: writing changes nothing else")
        #expect(!BotSectioning.onServer(bot("scout", setUp: false), roster: none), "it would set the first bot up")
        #expect(!BotSectioning.onServer(bot("api", setUp: true, viaAPI: true), roster: setUp), "the Hermes API alone keeps it here")
    }

    @MainActor @Test func keptHereForAnAPIBotAndAGroupChat() async throws {
        let settings = Settings(defaults: UserDefaults(suiteName: "bot-sections-\(UUID().uuidString)")!)
        let made = try await BotSectionActions.make("  Home  ", filing: [.bot(bot("api", viaAPI: true)), .room(room("r"))],
                                                    roster: nil, settings: settings)
        let section = try #require(made)
        #expect(section.name == "Home" && settings.botSectionsHere.sections == [section])
        #expect(settings.botSectionsHere.kept == ["bot:api": section.id, "room:r": section.id])
        let items: [BotListItem] = [.bot(bot("api", viaAPI: true)), .room(room("r"))]
        try await BotSectionActions.rename(section, to: "House", items: items, roster: nil, settings: settings)
        #expect(settings.botSectionsHere.sections.map(\.name) == ["House"])
        let renamed = try #require(settings.botSectionsHere.sections.first)
        try await BotSectionActions.delete(renamed, items: items, roster: nil, settings: settings)
        #expect(settings.botSectionsHere.isEmpty)
        let blank = try await BotSectionActions.make("   ", roster: nil, settings: settings)
        #expect(blank == nil)
    }
}
