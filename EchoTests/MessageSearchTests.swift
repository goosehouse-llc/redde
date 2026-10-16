import Foundation
import SwiftUI
import Testing
@testable import Echo

/// Searching inside messages: reading Hermes's answer, the snippet with its matched words, what
/// Find is given on the way into a conversation. Hermes's side is checked against real Hermes in
/// `HermesLabSearchTests`.
@MainActor
struct MessageSearchTests {
    /// One result as Hermes 0.22.2's `/api/sessions/search` answers it (fields as the route builds them).
    private static let answer = """
    {"results": [
      {"snippet": "...the >>>nimbus<<< clouds over the >>>bay<<< today...", "role": "assistant", "source": "desktop",
       "model": "alpha", "session_started": 1792100000.5, "last_active": 1792100400.0, "session_id": "s-tip",
       "lineage_root": "s-root", "profile": "default", "is_default_profile": true, "id": "s-tip", "title": "Weather",
       "started_at": 1792100000.5, "ended_at": null, "is_active": false, "message_count": 6, "tool_call_count": 0,
       "input_tokens": 120, "output_tokens": 80, "preview": "What's it like out?", "parent_session_id": "s-root",
       "archived": true},
      {"snippet": "Session title matched: nimb", "role": null, "source": "api_server", "id": "s2", "title": "Nimbus notes",
       "started_at": 1792000000, "last_active": 1792000100, "archived": false},
      {"snippet": "no id here"}
    ]}
    """

    private func hits() throws -> [MessageSearchHit] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(Self.answer.utf8))
        let data = try JSONEncoder().encode(value["results"] ?? .array([]))
        struct Lenient: Decodable {
            var hit: MessageSearchHit?
            init(from decoder: Decoder) throws { hit = try? MessageSearchHit(from: decoder) }
        }
        return try JSONDecoder().decode([Lenient].self, from: data).compactMap(\.hit)
    }

    @Test func hermesAnswerReadsAsConversationsWithSnippets() throws {
        let hits = try hits()
        #expect(hits.map(\.id) == ["s-tip", "s2"], "a row with no conversation id is skipped, the others kept")
        let first = hits[0]
        #expect(first.session.displayTitle == "Weather")
        #expect(first.session.source == "desktop")
        #expect(first.session.message_count == 6)
        #expect(first.session.lastActiveDate == Date(timeIntervalSince1970: 1792100400))
        #expect(first.archived)
        #expect(first.speaker == "Hermes")
        #expect(hits[1].speaker == nil, "a title match has no speaker")
        #expect(!hits[1].archived)
    }

    @Test func snippetSplitsIntoMatchedAndPlainRuns() {
        let hit = MessageSearchHit(session: .init(id: "x"), snippet: "...the >>>nimbus<<< clouds\nover the >>>bay<<< today...")
        #expect(hit.runs == [
            .init(text: "...the ", matched: false), .init(text: "nimbus", matched: true),
            .init(text: " clouds over the ", matched: false), .init(text: "bay", matched: true),
            .init(text: " today...", matched: false),
        ])
    }

    @Test func snippetWithoutMarksOrCutShortStillReads() {
        #expect(MessageSearchHit(session: .init(id: "x"), snippet: "Session title matched: nimb").runs == [.init(text: "Session title matched: nimb", matched: false)])
        #expect(MessageSearchHit(session: .init(id: "x"), snippet: "cut >>>nimb").runs == [.init(text: "cut ", matched: false), .init(text: "nimb", matched: true)])
        #expect(MessageSearchHit(session: .init(id: "x"), snippet: "").runs.isEmpty)
    }

    @Test func findLooksForWhatHermesMatched() {
        let two = MessageSearchHit(session: .init(id: "x"), snippet: "the >>>nimbus<<< clouds over the >>>bay<<<")
        #expect(two.findText(typed: "nimb bay") == "nimbus", "two words may be far apart: Find takes the first one matched")
        #expect(MessageSearchHit(session: .init(id: "x"), snippet: "Session title matched").findText(typed: " nimb ") == "nimb")
    }

    @Test func listShowsTheMatchMarked() {
        let hit = MessageSearchHit(session: .init(id: "x"), snippet: "the >>>nimbus<<< clouds", role: "user")
        let text = ConversationsList.snippetText(hit, accent: .orange)
        #expect(String(text.characters) == "You: the nimbus clouds")
        var marked: [String] = []
        for run in text.runs where run.foregroundColor == Color.orange {
            marked.append(String(text[run.range].characters))
        }
        #expect(marked == ["nimbus"])
    }

    @Test func searchIsAskedOfTheSelectedProfile() {
        typealias C = HermesServeClient
        #expect(C.profilePlacement(method: "GET", path: "api/sessions/search?q=nimb&limit=30") == .query)
        let (path, _) = C.scoped(method: "GET", path: "api/sessions/search?q=nimb&limit=30", body: nil, profile: "work")
        #expect(path == "api/sessions/search?q=nimb&limit=30&profile=work")
    }
}
