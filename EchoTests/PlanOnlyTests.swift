import Foundation
import Testing
@testable import Echo

/// A reply that was only the agent's plan (Redde's plugin 1.49.0, 2026-11-26): the plugin ends it on
/// "Let me now do that." so Hermes's stall guard shows it as working text and asks the model to go
/// on. Hermes marks that note streamed only for an exact match, so the app tells for itself
/// (`StreamedText`); read back, Hermes's "[System: Continue now. …]" row is left out and the plan
/// goes with the answer as a working note (`foldingContinuations`). Real Hermes: HermesLabPlanOnlyTests.
@MainActor
struct PlanOnlyTests {
    static let plan = "Robin's letting me know they're going mini golfing today — just sharing an update. This is a conversational remark, not a task request. Let me respond warmly.\n\nNo tools needed — just an appropriate conversational response."
    static let nudge = "[System: Continue now. Execute the required tool calls and only send your final answer after completing the task.]"

    @Test func aNoteThatGoesOnFromWhatStreamedIsThatText() {
        var seen = StreamedText()
        for word in Self.plan.split(separator: " ", omittingEmptySubsequences: false) {
            _ = seen.pass(.textDelta(String(word) + " "))
        }
        #expect(seen.pass(.interim(text: Self.plan + "\n\nLet me now do that.", alreadyStreamed: false))
                == .interim(text: Self.plan + "\n\nLet me now do that.", alreadyStreamed: true))
        #expect(seen.text.isEmpty, "the answer starts again")
        _ = seen.pass(.textDelta("Have fun out there!"))
        #expect(seen.text == "Have fun out there!")

        // Cut short at a sentence, for a long plan: the start is the same.
        var long = StreamedText()
        _ = long.pass(.textDelta(Self.plan + " " + Self.plan))
        #expect(long.pass(.interim(text: String(Self.plan.prefix(140)) + "…\n\nLet me now do that.", alreadyStreamed: false))
                == .interim(text: String(Self.plan.prefix(140)) + "…\n\nLet me now do that.", alreadyStreamed: true))
    }

    @Test func otherNotesAreLeftAsHermesSaid() {
        var nothing = StreamedText()
        #expect(nothing.pass(.interim(text: "Looking at the calendar.", alreadyStreamed: false))
                == .interim(text: "Looking at the calendar.", alreadyStreamed: false), "nothing streamed: the note is its text")
        var other = StreamedText()
        _ = other.pass(.textDelta("Hello there."))
        #expect(other.pass(.interim(text: "Looking at the calendar.", alreadyStreamed: false))
                == .interim(text: "Looking at the calendar.", alreadyStreamed: false))
        #expect(other.text == "Hello there.", "what streamed stays the reply's")
        var exact = StreamedText()
        _ = exact.pass(.textDelta("Let me look."))
        #expect(exact.pass(.interim(text: "Let me look.", alreadyStreamed: true)) == .interim(text: "Let me look.", alreadyStreamed: true))
        #expect(!StreamedText.continues("Hello", in: "Help me"))
    }

    @Test func whatTheFinalTextLeavesOutIsKept() {
        // Hermes 0.23.2's API: no note for the plan, the two streamed as one, the finished reply the answer.
        #expect(StreamedText.head(of: Self.plan + "[answered after the plan]", before: "[answered after the plan]") == Self.plan)
        #expect(StreamedText.head(of: "Have fun!", before: "Have fun!") == nil)
        #expect(StreamedText.head(of: "Here it is: MEDIA:/tmp/a.png", before: "Here it is: ![a](data:image/png;base64,AA)") == nil)
        #expect(StreamedText.head(of: "Here", before: "Here it is.") == nil, "a reply cut short, made whole")
        #expect(StreamedText.head(of: "", before: "Hi") == nil)
    }

    @Test func readBackFromTheDashboardWhichLeavesHermessWordOut() {
        // The Dashboard's history has no "[System: Continue now" row: the plugin's ending marks the plan.
        let rows: [JSONValue] = [
            .object(["role": .string("user"), "text": .string("lab:plan"), "timestamp": .number(1)]),
            .object(["role": .string("assistant"), "text": .string(Self.plan + "\n\nLet me now do that."), "timestamp": .number(2)]),
            .object(["role": .string("assistant"), "text": .string("[answered after the plan]"), "timestamp": .number(4)]),
        ]
        let shown = Conversation.messages(fromServeRows: rows)
        #expect(shown.map(\.text) == ["lab:plan", "[answered after the plan]"])
        #expect(shown.last?.notes == [WorkingNote(text: Self.plan, afterTools: 0)])
        // Two replies in a row otherwise stay two.
        let two = Conversation.messages(fromServeRows: [
            .object(["role": .string("assistant"), "text": .string("Let me look."), "timestamp": .number(1)]),
            .object(["role": .string("assistant"), "text": .string("Found it."), "timestamp": .number(2)]),
        ])
        #expect(two.count == 2)
    }

    @Test func readBackTheNudgeIsLeftOutAndThePlanIsAWorkingNote() throws {
        let rows: [JSONValue] = [
            .object(["role": .string("user"), "text": .string("We're going mini golfing today"), "timestamp": .number(1)]),
            .object(["role": .string("assistant"), "text": .string(Self.plan + "\n\nLet me now do that."), "timestamp": .number(2)]),
            .object(["role": .string("user"), "text": .string(Self.nudge), "timestamp": .number(3)]),
            .object(["role": .string("assistant"), "text": .string("Have fun out there!"), "timestamp": .number(4)]),
            .object(["role": .string("user"), "text": .string("Thanks"), "timestamp": .number(5)]),
        ]
        let shown = Conversation.messages(fromServeRows: rows)
        #expect(shown.map(\.text) == ["We're going mini golfing today", "Have fun out there!", "Thanks"])
        #expect(shown[1].notes == [WorkingNote(text: Self.plan, afterTools: 0)])

        let stored = try JSONDecoder().decode([HermesSessionsAPI.StoredMessage].self, from: Data(#"""
        [{"role": "user", "content": "Add Muppets Christmas Carol to the film list", "timestamp": 1},
         {"role": "assistant", "content": "Robin wants it on the Christmas Movies list. Let me add it.\n\nLet me now do that.", "timestamp": 2},
         {"role": "user", "content": "[System: Continue now. Execute the required tool calls and only send your final answer after completing the task.]", "timestamp": 3},
         {"role": "assistant", "content": "", "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "redde_list", "arguments": "{}"}}], "timestamp": 4},
         {"role": "tool", "content": "{\"added\": 1}", "tool_name": "redde_list", "timestamp": 5},
         {"role": "assistant", "content": "Added for Dec 5 at 9 PM.", "timestamp": 6}]
        """#.utf8))
        let back = Conversation.mapStored(stored)
        #expect(!back.contains { $0.text.hasPrefix("[System:") })
        #expect(back.first?.text == "Add Muppets Christmas Carol to the film list")
        let plan = back.first { $0.notes.contains { $0.text == "Robin wants it on the Christmas Movies list. Let me add it." } }
        #expect(plan != nil && plan?.role == .assistant, "\(back.map { ($0.role, $0.text, $0.notes) })")
        #expect(back.last?.text == "Added for Dec 5 at 9 PM.")
    }
}
