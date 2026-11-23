import Foundation
import Testing
@testable import Echo

/// Plan For It (asked 2026-11-23): the plan card read from the call, its answer's note (what's for
/// now, what's for later with its time as the agent wrote it, what was left out), the answer read
/// back, and a later pick as a Follow-Through row.
@MainActor
struct PlanCardTests {
    static let json = #"""
    {"cards": [{"type": "plan", "title": "Driving to Montreal · Friday", "actions": [
      {"title": "Check the border", "why": "Crossing into Canada", "when": "now", "request": "Check what I need", "picked": true},
      {"title": "Leave-By alert", "when": "2026-11-27T07:00:00-05:00", "request": "Tell me when to leave"},
      {"title": "Packing list", "request": "Make me a packing list", "picked": true}]}]}
    """#

    private func plan() throws -> ReplyCard.Plan {
        guard case let .plan(p) = try #require(ReplyCards.parse(try JSONValue.parse(Data(Self.json.utf8))).first) else {
            Issue.record("not a plan"); throw CancellationError()
        }
        return p
    }

    @Test func aPlanIsRead() throws {
        let p = try plan()
        #expect(p.title == "Driving to Montreal · Friday" && p.actions.count == 3)
        #expect(p.actions.map(\.picked) == [true, false, true])
        #expect(p.actions[0].at == nil && p.actions[0].when == nil, "now")
        #expect(p.actions[1].at == Date(timeIntervalSince1970: 1_795_780_800) && p.actions[1].when == "2026-11-27T07:00:00-05:00")
        #expect(p.actions[2].why == nil)
        #expect(ReplyCards.parse(try JSONValue.parse(Data(#"{"cards": [{"type": "plan", "title": "X", "actions": [{"title": "A"}]}]}"#.utf8))).isEmpty,
                "two actions at least")
        #expect(ReplyCard.plan(p).answerable)
    }

    @Test func itsAnswerSaysWhatsForNowAndForLater() throws {
        let p = try plan()
        let note = PlanCard.note(p, picked: [1, 2])
        #expect(note.hasPrefix("plan {"))
        let body = try #require(try JSONSerialization.jsonObject(with: Data(note.dropFirst(5).utf8)) as? [String: Any])
        #expect((body["now"] as? [[String: String]]) == [["title": "Packing list", "request": "Make me a packing list"]])
        #expect((body["later"] as? [[String: String]]) == [["title": "Leave-By alert", "request": "Tell me when to leave", "at": "2026-11-27T07:00:00-05:00"]])
        #expect((body["left"] as? [String]) == ["Check the border"])
        #expect(PlanCard.picked(in: note) == ["Packing list", "Leave-By alert"])
        // The note as it travels and comes back from the transcript.
        let found = try #require(CardNote.find(in: "Do these: Packing list" + CardNote.note(key: ReplyCard.plan(p).key, said: note)))
        #expect(found.key == ReplyCard.plan(p).key && PlanCard.picked(in: found.said) == ["Packing list", "Leave-By alert"])
        #expect(PlanCard.when(p.actions[0]) == "Now")
    }

    @Test func aLaterPickIsAFollowThroughRow() throws {
        let shown = try #require(FollowThrough.parse(#"""
        redde-push follow {"switches": {}, "items": [{"id": "q1", "kind": "planned", "title": "Leave-By alert",
          "what": "Driving to Montreal · Friday", "day": "2026-11-27", "due": 1795780800}]}
        """#))
        #expect(shown.items[0].title == "Leave-By alert")
        #expect(shown.items[0].detail.hasPrefix("For Driving to Montreal · Friday · "))
    }
}
