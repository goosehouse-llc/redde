import Foundation
import Testing
@testable import Echo

struct ProjectTreeTests {
    @Test func decodesProjectWithLanes() throws {
        let j = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"id":"/home/redde/searxng","label":"searxng","path":"/home/redde/searxng","isNoProject":false,"sessionCount":1,
         "lastActive":1770000000,"totalCostUsd":0.12,
         "repos":[{"id":"r","label":"searxng","groups":[{"id":"lane1","label":"main",
           "sessions":[{"id":"s1","title":"Fix config","source":"desktop","started_at":1769999000,"message_count":4}]}]}]}
        """.utf8))
        let p = try #require(HermesServeClient.Project(j))
        #expect(p.label == "searxng" && p.sessionCount == 1 && !p.isHome)
        #expect(p.lanes.count == 1 && p.lanes[0].sessions.first?.id == "s1")
        #expect(p.lanes[0].sessions.first?.displayTitle == "Fix config")
    }

    @Test func homeBucketIsFlagged() throws {
        let j = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"id":"__no_project__","label":"Home","path":null,"isNoProject":true,"sessionCount":425,"lastActive":0,"repos":[]}
        """.utf8))
        let p = try #require(HermesServeClient.Project(j))
        #expect(p.isHome && p.lastActive == nil && p.lanes.isEmpty)
    }
}
