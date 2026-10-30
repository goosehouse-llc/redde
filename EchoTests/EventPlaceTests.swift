import Foundation
import Testing
@testable import Echo

/// An event's place gets a map and a leaving time only when it is an address; its links are
/// tappable (asked 2026-10-30).
struct EventPlaceTests {
    @Test func streetAddressesAreAddresses() {
        #expect(EventPlace.isAddress("200 East Robinson St, Orlando, FL"))
        #expect(EventPlace.isAddress("Rossio Roasters\n1 Infinite Loop, Cupertino, CA 95014"))
    }

    @Test func roomsLinksAndAppsAreNot() {
        #expect(!EventPlace.isAddress("Office · Room 4"))
        #expect(!EventPlace.isAddress("Conference Room B"))
        #expect(!EventPlace.isAddress("https://zoom.us/j/81234567890"))
        #expect(!EventPlace.isAddress("Zoom"))
        #expect(!EventPlace.isAddress("Microsoft Teams Meeting"))
        #expect(!EventPlace.isAddress(""))
        #expect(!EventPlace.isAddress(nil))
    }

    @Test func noMapsForAPlaceThatIsNoAddress() {
        #expect(AgendaCard.mapsURL("Office · Room 4") == nil)
        #expect(AgendaCard.mapsURL("200 East Robinson St, Orlando, FL") != nil)
    }

    @Test func linksInTheWordsAreMarked() {
        let text = "Agenda: docs.example.com/plan, and join at https://meet.google.com/abc-defg-hij"
        let linked = EventPlace.linked(text)
        let links = linked.runs.compactMap(\.link)
        #expect(links.count == 2)
        #expect(links.contains { $0.host() == "meet.google.com" })
        #expect(String(linked.characters) == text)
        #expect(EventPlace.linked("Bring the glow sticks").runs.allSatisfy { $0.link == nil })
    }
}
