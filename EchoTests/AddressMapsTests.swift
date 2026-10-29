import Foundation
import Testing
@testable import Echo

/// Maps for addresses (asked 2026-10-29): which replies and briefings get a map, and of what.
@MainActor
struct AddressMapsTests {
    @Test func aBoldAddressInAHeadsUpIsFoundWithoutWhatFollowsIt() throws {
        let text = "The appointment is confirmed for today at **200 East Robinson St, Orlando, FL 32801** (phone: (407) 555-0100). Bring your photo ID."
        let found = try #require(AddressMaps.find(in: text))
        #expect(found.address.hasPrefix("200 East Robinson St"))
        #expect(found.address.contains("32801"))
        #expect(!found.address.contains("phone") && !found.address.contains("*"))
    }

    @Test func noStreetNoMap() {
        #expect(AddressMaps.find(in: "We'll meet in Winter Park, FL this weekend.") == nil, "a town alone isn't an address")
        #expect(AddressMaps.find(in: "Room 12 at 3:30, bring 2 copies.") == nil)
        #expect(AddressMaps.find(in: "No numbers here at all.") == nil)
    }

    @Test func aReplyWithAMapOfItsOwnGetsNoSecond() {
        var reply = Message(role: .assistant, text: "It's at 200 East Robinson St, Orlando, FL 32801.")
        #expect(AddressMaps.forReply(reply) != nil)
        reply.cards = [.map(.init(title: nil, places: [.init(name: "Office")], route: nil))]
        #expect(AddressMaps.forReply(reply) == nil)
        #expect(AddressMaps.forReply(Message(role: .user, text: "I'm at 200 East Robinson St, Orlando, FL 32801")) == nil, "the person's own messages: no")
    }

    @Test func aHeadsUpsPlaceIsItsMapNamedForTheEvent() {
        var briefing = AgentBriefing(id: "h", title: "Heads-up: Dentist", agent: "Sol", text: "Bring your card.", at: .now, failed: false)
        #expect(briefing.mapPlace == nil)
        briefing.place = "200 East Robinson St, Orlando, FL 32801"
        #expect(briefing.mapPlace == AddressMaps.Found(name: "Dentist", address: "200 East Robinson St, Orlando, FL 32801"))
        let week = AgentBriefing(id: "w", title: WeekAhead.title, agent: "Sol", text: "## Friday, Oct 30\n- 9:00 AM At 200 East Robinson St, Orlando, FL 32801",
                                 at: .now, failed: false)
        #expect(week.mapPlace == nil, "the week ahead is a calendar, not a map")
    }
}
