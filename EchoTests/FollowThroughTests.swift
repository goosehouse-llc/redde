import Foundation
import Testing
@testable import Echo

/// Follow-Through (plugin 1.39's `follow list`): its switches, where Jellyfin was found, and what's
/// being followed, read and shown in words.
@MainActor
struct FollowThroughTests {
    static let answer = """
    redde-push follow {"switches": {"mail": true, "orders": false, "arrivals": true},
      "jellyfin": {"found": true, "profile": "media"},
      "items": [
        {"id": "p1", "kind": "promise", "name": "Ana Ruiz", "who": "ana@example.com", "subject": "Lease", "said": "I'll send the signed copy by Friday.", "day": "2026-11-27", "due": 1795820000},
        {"id": "w1", "kind": "waiting", "name": "Bo", "who": "bo@example.com", "subject": "Dates", "due": 1795900000},
        {"id": "d1", "kind": "delivery", "shop": "Amazon", "what": "Lego Botanical Bouquet", "order": "112-3", "day": "2026-11-26", "due": 1795910000},
        {"id": "t1", "kind": "trial", "shop": "StreamCo", "what": "Welcome", "day": "2026-12-01", "price": "$14.99/month", "due": 1796000000}]}
    """

    @Test func readsTheSwitchesJellyfinAndTheItems() throws {
        let shown = try #require(FollowThrough.parse(Self.answer))
        #expect(shown.mail && !shown.orders && shown.arrivals)
        #expect(shown.jellyfinFound && shown.jellyfin == "media")
        #expect(shown.items.map(\.kind) == ["promise", "waiting", "delivery", "trial"])
        #expect(shown.items[0].title == "Send Ana what you promised")
        #expect(shown.items[0].detail == "I'll send the signed copy by Friday.")
        #expect(shown.items[1].title == "Waiting on Bo" && shown.items[1].detail == "Dates")
        #expect(shown.items[2].title == "Lego Botanical Bouquet" && shown.items[2].detail.hasPrefix("From Amazon, due "))
        #expect(shown.items[3].title == "StreamCo renews" && shown.items[3].detail.hasSuffix(" · $14.99/month"))
        #expect(shown.items[0].due == Date(timeIntervalSince1970: 1_795_820_000))
    }

    @Test func anOlderPluginsAnswerIsNone() {
        #expect(FollowThrough.parse("redde-push: unknown command follow") == nil)
        #expect(FollowThrough.parse(#"redde-push follow {"switches": {}}"#)?.items == [])
    }
}
