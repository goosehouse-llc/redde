import Foundation
import Testing
@testable import Echo

/// Side chats: a new chat's first session kept as the side chat of the one it came from, by
/// connection, newest first, and the message it's about quoted plainly and clipped.
@MainActor
struct SideChatsTests {

    @Test func keptByConnectionNewestFirstAndRemembered() {
        let defaults = UserDefaults(suiteName: "side-\(UUID().uuidString)")!
        let sides = SideChats(defaults: defaults)
        sides.add("s1", connection: "home", link: .init(parent: "p", title: "Trip", about: "Flights", at: .init(timeIntervalSince1970: 1)))
        sides.add("s2", connection: "home", link: .init(parent: "p", title: "Trip", about: "Hotels", at: .init(timeIntervalSince1970: 2)))
        sides.add("s3", connection: "work", link: .init(parent: "p", title: "Other", about: "x", at: .init(timeIntervalSince1970: 3)))
        #expect(sides.sides(of: "p", connection: "home").map(\.session) == ["s2", "s1"])
        #expect(sides.isSide("s1", connection: "home") && !sides.isSide("s1", connection: "work"))
        #expect(SideChats(defaults: defaults).link(of: "s2", connection: "home")?.about == "Hotels", "kept on the device")
        sides.remove("s1", connection: "home")
        #expect(sides.sides(of: "p", connection: "home").map(\.session) == ["s2"])
    }

    @Test func theMessageIsQuotedPlainAndClipped() {
        let long = String(repeating: "word ", count: 400)
        #expect(SideChats.quote(long).count <= SideChats.longestQuote + 1)
        #expect(SideChats.about("**Flights** to Lisbon\nand more") == "Flights to Lisbon")
    }

    @Test func aSideChatsFirstSessionIsLinked() {
        let settings = Settings(defaults: UserDefaults(suiteName: "side-\(UUID().uuidString)")!)
        let conversation = Conversation(settings: settings,
                                        store: ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "side-\(UUID().uuidString)")))
        let link = SideChats.Link(parent: "parent-1", title: "Trip", about: "Flights", at: .now)
        conversation.sideOf = link
        conversation.serverSessionID = "side-\(UUID().uuidString)"
        #expect(conversation.sideOf == nil)
        #expect(SideChats.shared.link(of: conversation.serverSessionID, connection: settings.connectionKey) == link)
        SideChats.shared.remove(conversation.serverSessionID!, connection: settings.connectionKey)
    }
}
